import Foundation
import XCTest
@testable import KenshikiReference

@MainActor final class LiquidRetirementTests: XCTestCase {
    func testAuraOnlyPipelinePersistsAndReusesResultWithoutCreatingVisualRecords() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let capture = try record()
        try await repository.saveFaceCapture(capture)
        let expected = completion(capture)
        let pipeline = FaceWorkflowPipeline(persistence: repository.comparisonEffects, compare: { _ in expected })
        let first = try await pipeline.runAura(capture.input)
        let reopened = fixture.repository()
        let reuse = FaceWorkflowPipeline(persistence: reopened.comparisonEffects,
            compare: { _ in throw FaceWorkflowStorageFailure.unavailable })
        let second = try await reuse.runAura(capture.input)
        XCTAssertEqual(first.score, second.score)
        let visual = try await reopened.loadFaceStage(capture.input.operationID, engine: .liquid)
        let passes = try await reopened.loadLiquidPasses(capture.input.operationID)
        XCTAssertNil(visual)
        XCTAssertTrue(passes.isEmpty)
    }

    func testHistoricalVisualStageRemainsReadableWithoutAppearingInLiveUI() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let capture = try record()
        let repository = fixture.repository()
        try await repository.saveFaceCapture(capture)
        let aura = SavedFaceStage(operationID: capture.input.operationID, engine: .aura,
            durationMilliseconds: 2, aura: completion(capture))
        try await repository.saveFaceStage(aura)
        let old = FaceVisualAssessmentCompletion(operationID: capture.input.operationID,
            referenceSHA256: capture.input.referenceSHA256, selfieSHA256: capture.input.selfieSHA256,
            consistency: .uncertain, issues: [], durationMilliseconds: 3,
            report: .init(summary: "Synthetic historical report", sections: []))
        let stage = SavedFaceStage(operationID: capture.input.operationID, engine: .liquid,
            durationMilliseconds: 3, liquid: old, precedingAuraID: aura.id)
        try await repository.saveFaceStage(stage)
        let restored = try await fixture.repository().loadFaceStage(capture.input.operationID, engine: .liquid)
        XCTAssertEqual(restored?.id, stage.id)
        XCTAssertEqual(restored?.liquid, old)
        XCTAssertTrue(LegacyLiquidArchive.isHistorical(old))
        let paragraphs = FaceComparisonPresentation.paragraphs(phase: .completed(0.72), visual: .completed(old),
            durationMilliseconds: 2, expanded: true)
        XCTAssertFalse(paragraphs.contains { $0.identifier.hasPrefix("comparison.visual") })
        XCTAssertFalse(paragraphs.contains { $0.text == old.report?.summary })
        XCTAssertTrue(paragraphs.contains { $0.identifier == "comparison.score" })
    }

    func testHistoricalPassBytesAndEvidenceBindingsSurviveReopenAfterRetirement() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let capture = try record()
        let store = fixture.repository()
        try await store.saveFaceCapture(capture)
        let aura = SavedFaceStage(operationID: capture.input.operationID, engine: .aura,
            durationMilliseconds: 2, aura: completion(capture))
        try await store.saveFaceStage(aura)
        let snapshot = try SavedComparisonSnapshot(capture: capture, archive: nil)
        try await store.saveComparisonSnapshot(snapshot)
        let request = try LiquidPassEvidence.request(capture: capture, aura: aura, snapshot: snapshot)
        let fixtureDescriptor = ArchiveDescriptorFixture(modelDirectory: URL(fileURLWithPath: "/unused"),
            contractDirectory: URL(fileURLWithPath: "/unused"))
        let descriptor = try await fixtureDescriptor.describe(pass: .presentation, request: request)
        let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
        let failed = pending.failed(.init(reason: .invalidOutput, rawOutput: "Synthetic historical output"), code: "invalid_output")
        try await store.saveLiquidPass(pending)
        try await store.saveLiquidPass(failed)
        let records = try await fixture.repository().loadLiquidPasses(capture.input.operationID)
        XCTAssertEqual(records.map(\.id), [pending.id, failed.id])
        XCTAssertEqual(records.last?.descriptor.contextJSON, descriptor.contextJSON)
        XCTAssertEqual(records.last?.failure?.rawOutput, failed.failure?.rawOutput)
        XCTAssertEqual(try records.last?.exportObject()["status"] as? String, "failed")
    }

    func testNewComparisonExportMarksVisualRuntimeRetired() async throws {
        let capture = try record()
        let expected = completion(capture)
        let controller = FaceComparisonController(compare: { _ in expected })
        let aura = SavedFaceStage(operationID: capture.input.operationID, engine: .aura,
            durationMilliseconds: 2, aura: completion(capture))
        try controller.restore(capture, aura: aura, liquid: nil)
        XCTAssertEqual(controller.visualPhase, .idle)
        let text = try XCTUnwrap(controller.reportForExport())
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((value["liquid"] as? [String: Any])?["status"] as? String, "retired")
        XCTAssertFalse(controller.isProcessing)
    }

    // Preserve the SDK's pure validation tests with the app-owned historical readers.
    func testHistoricalTasksAndDescriptorsDecodeWithoutV4Fields() throws {
        for task in ["quality", "comparison", "presentation"] {
            let encoded = Data("\"\(task)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(LiquidEvidencePass.self, from: encoded).rawValue, task)
        }
        let historical: [String: Any] = ["pass": "comparison", "profileID": "lfm25-vl16b-affine4-g64-mlx-discrete-review-v3",
            "artifactSHA256": digest, "promptContractSHA256": digest, "contextSHA256": digest,
            "promptSHA256": digest, "schemaSHA256": digest, "contextJSON": Data("{}".utf8).base64EncodedString()]
        let value = try JSONDecoder().decode(LiquidPassDescriptor.self,
            from: JSONSerialization.data(withJSONObject: historical))
        XCTAssertNil(value.modelInputJSON)
        XCTAssertNil(value.modelInputSHA256)
        XCTAssertNotEqual(value.profileID, LiquidPassProfile.id)
    }

    func testMetricsRemainOptionalForHistoryAndSurviveFailedGeneration() throws {
        let history = Data(#"{"reason":"deadline","rawOutput":"partial","promptTokens":100,"generatedTokens":10}"#.utf8)
        let old = try JSONDecoder().decode(LiquidPassFailure.self, from: history)
        XCTAssertNil(old.metrics)
        let metrics = LiquidRuntimeMetrics(modelSetupMilliseconds: 5, imagePreparationMilliseconds: 6,
            grammarPreparationMilliseconds: 7, prefillMilliseconds: 8, generationMilliseconds: 9,
            cleanupMilliseconds: 10, activeMemoryBytes: 11, cacheMemoryBytes: 12, peakMemoryBytes: 13)
        let failure = LiquidPassFailure(reason: .deadline, rawOutput: "partial", promptTokens: 101,
            generatedTokens: 17, metrics: metrics)
        let copy = try JSONDecoder().decode(LiquidPassFailure.self, from: JSONEncoder().encode(failure))
        XCTAssertEqual(copy.reason, .deadline)
        XCTAssertEqual(copy.rawOutput, "partial")
        XCTAssertEqual(copy.promptTokens, 101)
        XCTAssertEqual(copy.generatedTokens, 17)
        XCTAssertEqual(copy.metrics?.prefillMilliseconds, 8)
        XCTAssertEqual(copy.metrics?.cleanupMilliseconds, 10)
        XCTAssertEqual(copy.metrics?.peakMemoryBytes, 13)
    }

    func testMetricAllocatorScopeDefaultsForLegacyAndRejectsUnknownScope() throws {
        let metrics = LiquidRuntimeMetrics(peakMemoryBytes: 13)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics)) as? [String: Any])
        XCTAssertEqual(object["allocatorPeakScope"] as? String, "process_lifetime")
        object.removeValue(forKey: "allocatorPeakScope")
        let legacy = try JSONDecoder().decode(LiquidRuntimeMetrics.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.allocatorPeakScope, .processLifetime)
        object["allocatorPeakScope"] = "per_task"
        XCTAssertThrowsError(try JSONDecoder().decode(LiquidRuntimeMetrics.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }

    func testPureDescriptorValidationRejectsRehashedEvidenceSubstitution() throws {
        let reference = Data([1]), selfie = Data([2])
        let selfieDigest = LiquidPromptContract.digest(selfie)
        let measurement = CaptureMeasurements(binding: .init(imageSHA256: selfieDigest, sourceSHA256: digest,
            frameTimestampSeconds: 12, clockDomain: "arkit_session_seconds"), depth: nil, blink: nil,
            tracking: .init(consecutiveFrames: 10, steadyHoldSeconds: 1), quality: nil)
        let request = LiquidPassRequest(reference: reference, referenceSHA256: LiquidPromptContract.digest(reference),
            selfie: selfie, selfieSHA256: selfieDigest, measurements: measurement, aura: nil, document: nil, workflow: nil)
        let evidence = try LiquidPassContract.evidence(pass: .sensorConsistency, request: request)
        func descriptor(context: Data, model: Data) -> LiquidPassDescriptor {
            LiquidPassDescriptor(task: .sensorConsistency, profileID: LiquidPassProfile.id,
                artifactSHA256: LiquidProfile.weightsSHA256, promptContractSHA256: LiquidPassProfile.sha256,
                contextSHA256: LiquidPromptContract.digest(context), promptSHA256: digest, schemaSHA256: digest,
                contextJSON: context, modelInputJSON: model, modelInputSHA256: LiquidPromptContract.digest(model))
        }
        XCTAssertNoThrow(try descriptor(context: evidence.context, model: evidence.modelInput).validateEvidence(request: request))
        var context = try XCTUnwrap(JSONSerialization.jsonObject(with: evidence.context) as? [String: Any])
        var measurements = try XCTUnwrap(context["measurements"] as? [String: Any])
        measurements["tracking"] = ["consecutiveFrames": 1000, "steadyHoldSeconds": 100]
        context["measurements"] = measurements
        let substituted = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try descriptor(context: substituted, model: evidence.modelInput).validateEvidence(request: request))
        let falseProjection = Data(#"{"task":"sensor_consistency","captureMode":"still","measurements":null,"workflow":null}"#.utf8)
        XCTAssertThrowsError(try descriptor(context: evidence.context, model: falseProjection).validateEvidence(request: request))
        let wrongImage = LiquidPassRequest(reference: Data([3]), referenceSHA256: request.referenceSHA256,
            selfie: selfie, selfieSHA256: selfieDigest, measurements: measurement, aura: nil, document: nil, workflow: nil)
        XCTAssertThrowsError(try descriptor(context: evidence.context, model: evidence.modelInput).validateEvidence(request: wrongImage))
    }

    func testStrictJSONRejectsEscapedDuplicateKeysAndInvalidNumbers() {
        for text in [#"{"a":1,"\u0061":2}"#, "{\"a\":NaN}", "[1e9999]", "[01]", "[1,]", "{} {}"] {
            XCTAssertThrowsError(try ReviewJSON.parse(Data(text.utf8), maximumBytes: 1024))
        }
        XCTAssertNoThrow(try ReviewJSON.parse(Data(#"{"a":-1.5e2,"b":null}"#.utf8), maximumBytes: 1024))
    }

    func testCaptureBindingsAndNonfiniteMeasurementsAreRejected() throws {
        XCTAssertThrowsError(try measurements().validate(selfieSHA256: reference))
        XCTAssertThrowsError(try measurements(score: .nan).validate(selfieSHA256: selfie))
        let bad = CaptureMeasurements(binding: .init(imageSHA256: selfie, sourceSHA256: source,
            frameTimestampSeconds: 12, clockDomain: "arkit_session_seconds"), depth: nil, blink: nil,
            tracking: .init(consecutiveFrames: Int(Int32.max) + 1, steadyHoldSeconds: 1), quality: nil)
        XCTAssertThrowsError(try bad.validate(selfieSHA256: selfie))
    }

    func testAuraContextChecksSourceAndRejectsBidiControls() throws {
        let valid = AuraContext(cosineSimilarity: 0.8, interpretation: "Cosine observation only", policyId: nil,
            resultSHA256: source, referenceSHA256: reference, selfieSHA256: selfie)
        XCTAssertNoThrow(try valid.validate(referenceSHA256: reference, selfieSHA256: selfie))
        XCTAssertThrowsError(try valid.validate(referenceSHA256: selfie, selfieSHA256: selfie))
        let bad = AuraContext(cosineSimilarity: 0.8, interpretation: "Observation\u{202e}", policyId: nil,
            resultSHA256: source, referenceSHA256: reference, selfieSHA256: selfie)
        XCTAssertThrowsError(try bad.validate(referenceSHA256: reference, selfieSHA256: selfie))
    }

    func testMotionBindingRejectsAWindowFromAnotherFrame() throws {
        let motion = CaptureMeasurements.Motion(sourceSHA256: source, frameTimestampSeconds: 13,
            windowStartTimestampSeconds: 11, windowEndTimestampSeconds: 14, requestedSampleRateHz: 50,
            summary: .init(sampleCount: 100, durationSeconds: 2,
                statistics: .init(accelerationRMSg: 0.01, rotationRMSRadPerSecond: 0.02, tremorBandRatio: nil,
                    approachRMSg: nil, settleRatio: nil),
                gravity: .init(dominantAxis: .z, dominance: 0.9, driftRadians: nil),
                magnetic: .init(deltaMicrotesla: nil, calibrated: false), rawWindowSHA256: source))
        let value = CaptureMeasurements(binding: .init(imageSHA256: selfie, sourceSHA256: source,
            frameTimestampSeconds: 12, clockDomain: "arkit_session_seconds"), depth: nil, blink: nil,
            tracking: nil, quality: nil, motion: motion)
        XCTAssertThrowsError(try value.validate(selfieSHA256: selfie))
    }

    func testMotionRejectsStaleReversedNonfiniteAndInconsistentWindows() throws {
        func candidate(start: Double, end: Double, duration: Double) -> CaptureMeasurements {
            let motion = CaptureMeasurements.Motion(sourceSHA256: source, frameTimestampSeconds: 12,
                windowStartTimestampSeconds: start, windowEndTimestampSeconds: end, requestedSampleRateHz: 50,
                summary: .init(sampleCount: 100, durationSeconds: duration,
                    statistics: .init(accelerationRMSg: nil, rotationRMSRadPerSecond: nil,
                        tremorBandRatio: nil, approachRMSg: nil, settleRatio: nil),
                    gravity: .init(dominantAxis: nil, dominance: nil, driftRadians: nil),
                    magnetic: .init(deltaMicrotesla: nil, calibrated: false), rawWindowSHA256: source))
            return .init(binding: .init(imageSHA256: selfie, sourceSHA256: source,
                frameTimestampSeconds: 12, clockDomain: "arkit_session_seconds"), depth: nil, blink: nil,
                tracking: nil, quality: nil, motion: motion)
        }
        XCTAssertNoThrow(try candidate(start: 10, end: 12, duration: 2).validate(selfieSHA256: selfie))
        for (start, end, duration) in [(10.0, 11.0, 1.0), (12, 10, 2), (.nan, 12, 2),
                                      (10, .infinity, 2), (10, 12, 0), (10, 12, 1), (12, 12, 0)] {
            XCTAssertThrowsError(try candidate(start: start, end: end, duration: duration).validate(selfieSHA256: selfie))
        }
    }

    private var reference: String { String(repeating: "a", count: 64) }
    private var selfie: String { String(repeating: "b", count: 64) }
    private var source: String { String(repeating: "c", count: 64) }
    private func measurements(score: Double = 0.8) -> CaptureMeasurements {
        .init(binding: .init(imageSHA256: selfie, sourceSHA256: source, frameTimestampSeconds: 12,
                           clockDomain: "arkit_session_seconds"),
              depth: .init(sourceSHA256: source,
                  timing: .init(imageTimestampSeconds: 12, depthTimestampSeconds: 11.99, ageAtAdmissionSeconds: 0.03),
                  map: .init(width: 640, height: 480, filtered: false), sampleCount: 100, residualRMSMetres: 0.007),
              blink: .init(completedAtSeconds: 11.5, ageSeconds: 0.52, leftEyeClosed: 0.1, rightEyeClosed: 0.2, eyesOpen: true),
              tracking: .init(consecutiveFrames: 12, steadyHoldSeconds: 0.4),
              quality: .init(score: score, revision: 3, insideGuide: true, analysisDurationSeconds: 0.01,
                             frameAgeAtAdmissionSeconds: 0.02))
    }
    private var digest: String { String(repeating: "a", count: 64) }

    private func record() throws -> SavedFaceCapture {
        let passport = try CaptureStoreFixture.capture()
        let reference = try XCTUnwrap(passport.nfc.portrait)
        let selfie = Data("synthetic-retirement-selfie".utf8)
        return try SavedFaceCapture(input: .init(operationID: UUID(), reference: reference,
            referenceSHA256: SavedPassportCapture.digest(reference), selfie: selfie,
            selfieSHA256: SavedPassportCapture.digest(selfie), passport: passport))
    }

    private nonisolated func completion(_ capture: SavedFaceCapture) -> FaceComparisonCompletion {
        FaceComparisonCompletion(operationID: capture.input.operationID,
            referenceSHA256: capture.input.referenceSHA256, selfieSHA256: capture.input.selfieSHA256,
            score: 0.72, resultSHA256: String(repeating: "a", count: 64))
    }
}
