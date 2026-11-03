import XCTest
import CryptoKit
import UIKit
import Darwin
@testable import BiometricCapture
@testable import PassportSDK
@testable import KenshikiReference

final class FaceComparisonControllerTests: XCTestCase {
    @MainActor func testHistoricalV4ExportPreservesEverySchemaIndicatorValueAndRuntimeMetric() async throws {
        let (capture, aura, descriptors) = try await v4DetailsFixture()
        let directory = v4ContractDirectory.appendingPathComponent("profiles/liquid-passes-v4")
        let defaults = try descriptors.map { descriptor in
            try v4DetailsEvent(descriptor, output: v4DetailsOutput(descriptor.task), capture: capture, aura: aura)
        }
        for (index, descriptor) in descriptors.enumerated() {
            let bytes = try Data(contentsOf: directory.appendingPathComponent("\(descriptor.task.rawValue).schema.json"))
            let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            var outputs = [v4DetailsOutput(descriptor.task)]
            var requiredKeys = ["report.pass.\(descriptor.task.rawValue)"]
            if let indicators = properties["indicators"] as? [String: Any],
               let items = indicators["items"] as? [String: Any], let fields = items["properties"] as? [String: Any] {
                let kindSchema = try XCTUnwrap(fields["kind"] as? [String: Any])
                let statusSchema = try XCTUnwrap(fields["status"] as? [String: Any])
                let kinds = try XCTUnwrap(kindSchema["enum"] as? [String])
                let statuses = try XCTUnwrap(statusSchema["enum"] as? [String])
                requiredKeys += kinds.map { "report.indicator.\($0)" } + statuses.map { "report.status.\($0)" }
                for kind in kinds {
                    for status in statuses {
                        var output = v4DetailsOutput(descriptor.task)
                        output["indicators"] = [["kind": kind, "status": status, "evidence": "Synthetic evidence"]]
                        outputs.append(output)
                    }
                }
            }
            if let relationshipSchema = properties["auraRelationship"] as? [String: Any] {
                for relationship in try XCTUnwrap(relationshipSchema["enum"] as? [String]) {
                    requiredKeys.append("report.aura.\(relationship)")
                    var output = v4DetailsOutput(descriptor.task)
                    output["auraRelationship"] = relationship
                    outputs.append(output)
                }
            }
            for key in requiredKeys { XCTAssertNotNil(KenshikiCopy(rawValue: key), "Missing dynamic localization: \(key)") }
            for output in outputs {
                var events = defaults
                events[index] = try v4DetailsEvent(descriptor, output: output, capture: capture, aura: aura)
                let completion = LegacyLiquidArchive.presentation(capture: capture, aura: aura, events: events)
                let sections = try XCTUnwrap(completion.report).sections
                for task in LiquidEvidencePass.allCases {
                    XCTAssertTrue(sections.contains { $0.titleKey == "report.pass.\(task.rawValue)" })
                }
                let fields = sections.flatMap(\.fields)
                for metric in ["modelSetup", "imagePreparation", "grammarPreparation", "prefill", "generation", "cleanup", "activeMemory", "cacheMemory", "peakMemoryBytes"] {
                    XCTAssertTrue(fields.contains { $0.key == "report.pass.\(metric)" }, metric)
                }
                let object = try events[index].exportObject()
                let result = try XCTUnwrap(object["result"] as? [String: Any])
                let raw = try XCTUnwrap(result["rawOutput"] as? String)
                let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                XCTAssertEqual(decoded as NSDictionary, output as NSDictionary)

            }
        }
    }

    @MainActor func testHistoricalV4AggregateStatesRemainReadableWithoutRendering() async throws {
        let (capture, aura, descriptors) = try await v4DetailsFixture()
        let completed = try descriptors.map { try v4DetailsEvent($0, output: v4DetailsOutput($0.task), capture: capture, aura: aura) }
        let pending = descriptors.map { SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: $0) }
        let failed = pending.map { $0.failed(.init(reason: .deadline, metrics: .init(cleanupMilliseconds: 12)), code: "deadline") }
        let cancelled = pending.map { $0.failed(.init(reason: .cancelled), code: "cancelled") }
        let cases: [([SavedLiquidPass], Bool, FaceVisualAggregateStatus)] = [
            ([], false, .processing), ([], true, .failed), (pending, false, .processing),
            (failed, true, .failed), (cancelled, true, .cancelled),
            (Array(completed.prefix(1)) + Array(failed.dropFirst()), true, .partial), (completed, true, .completed)]
        for (events, settled, status) in cases {
            let completion = LegacyLiquidArchive.presentation(capture: capture, aura: aura, events: events, settled: settled)
            XCTAssertEqual(completion.aggregateStatus, status)
            XCTAssertTrue(LegacyLiquidArchive.isHistorical(completion))
            let rows = renderV4Details(completion, processing: !settled)
            XCTAssertFalse(rows.contains { $0.identifier.hasPrefix("comparison.visual") })

        }
    }

    @MainActor func testUnknownHistoricalDiagnosticKeysRemainPreservedWithoutRendering() throws {
        let report = FaceVisualReport(summary: "Synthetic report", sections: [.init(titleKey: "report.future.section", fields: [
            .init(key: "report.future.field", value: .code("report.future.status")),
            .init(key: "report.pass.status", value: .code("report.future.otherStatus"))])])
        let completion = FaceVisualAssessmentCompletion(operationID: UUID(), referenceSHA256: String(repeating: "a", count: 64),
            selfieSHA256: String(repeating: "b", count: 64), consistency: nil, issues: [], durationMilliseconds: 42, report: report)
        for processing in [false, true] {
            let rows = renderV4Details(completion, processing: processing)
            XCTAssertFalse(rows.contains { $0.text == report.summary })
            XCTAssertFalse(rows.contains { $0.identifier == "report.future.section" })
            XCTAssertFalse(rows.contains { $0.identifier.contains("report.future.field.value.") })
        }
        let restored = try JSONDecoder().decode(FaceVisualReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(restored, report, "Safe display must not replace or erase original diagnostic keys")
    }

    @MainActor private func renderV4Details(_ completion: FaceVisualAssessmentCompletion, processing: Bool) -> [ReferenceParagraph] {
        let rows = FaceComparisonPresentation.paragraphs(phase: .completed(0.6),
            visual: processing ? .processing : .completed(completion), durationMilliseconds: 3, expanded: true,
            partial: processing ? completion : nil)
        let renderer = ReferenceRenderer(screen: .init(title: KenshikiCopy.text("journey.title"),
            heading: KenshikiCopy.text("journey.result.title"), paragraphs: rows, primaryActions: []), emit: { _ in })
        renderer.loadViewIfNeeded()
        return rows
    }

    private var v4ContractDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contracts")
    }

    @MainActor private func v4DetailsFixture() async throws -> (SavedFaceCapture, SavedFaceStage, [LiquidPassDescriptor]) {
        let bytes = Data("synthetic-v4-details-source".utf8)
        let digest = SavedPassportCapture.digest(bytes)
        let capture = try SavedFaceCapture(input: .init(operationID: UUID(), reference: bytes, referenceSHA256: digest,
            selfie: bytes, selfieSHA256: digest))
        let aura = SavedFaceStage(operationID: capture.input.operationID, engine: .aura, durationMilliseconds: 3,
            aura: .init(operationID: capture.input.operationID, referenceSHA256: digest, selfieSHA256: digest,
                score: 0.6, resultSHA256: String(repeating: "a", count: 64)))
        let snapshot = try SavedComparisonSnapshot(capture: capture, archive: nil)
        let request = try LiquidPassEvidence.request(capture: capture, aura: aura, snapshot: snapshot)
        let engine = ArchiveDescriptorFixture(modelDirectory: v4ContractDirectory.appendingPathComponent("unused"),
            contractDirectory: v4ContractDirectory)
        var descriptors: [LiquidPassDescriptor] = []
        for task in LiquidEvidencePass.allCases { descriptors.append(try await engine.describe(pass: task, request: request)) }
        return (capture, aura, descriptors)
    }

    private func v4DetailsOutput(_ task: LiquidEvidencePass) -> [String: Any] {
        var output: [String: Any] = ["summary": "Synthetic task result", "observations": ["Synthetic observation"], "limitations": ["Synthetic limitation"]]
        switch task {
        case .quality: output["issues"] = ["blur"]
        case .comparison: output["auraRelationship"] = "supports"
        case .age: output["referenceAgeRange"] = [40, 60]; output["selfieAgeRange"] = [40, 60]
        case .presentation, .sensorConsistency: output["indicators"] = [] as [[String: String]]
        }
        return output
    }

    private func v4DetailsEvent(_ descriptor: LiquidPassDescriptor, output: [String: Any],
                               capture: SavedFaceCapture, aura: SavedFaceStage) throws -> SavedLiquidPass {
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        let body: [String: Any] = ["pass": descriptor.task.rawValue, "profileID": descriptor.profileID,
            "artifactSHA256": descriptor.artifactSHA256, "promptContractSHA256": descriptor.promptContractSHA256,
            "referenceSHA256": capture.input.referenceSHA256, "selfieSHA256": capture.input.selfieSHA256,
            "contextSHA256": descriptor.contextSHA256, "promptSHA256": descriptor.promptSHA256, "schemaSHA256": descriptor.schemaSHA256,
            "outputJSON": bytes.base64EncodedString(), "report": output, "durationMilliseconds": 100,
            "promptTokens": 100, "generatedTokens": 30, "peakMemoryBytes": 10000]
        var result = try JSONDecoder().decode(LiquidPassResult.self, from: JSONSerialization.data(withJSONObject: body))
        result.metrics = .init(modelSetupMilliseconds: 1, imagePreparationMilliseconds: 2, grammarPreparationMilliseconds: 3,
            prefillMilliseconds: 4, generationMilliseconds: 5, cleanupMilliseconds: 6,
            activeMemoryBytes: 700, cacheMemoryBytes: 800, peakMemoryBytes: 10000)
        let event = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor).completed(result)
        try event.validate(capture: capture, aura: aura)
        return event
    }



    @MainActor func testReportExportPreservesPendingAndUnavailableStatesWithoutStaleData() async throws {
        let engine = ComparisonSuspension()
        let controller = FaceComparisonController { try await engine.compare($0) }
        XCTAssertNil(controller.reportForExport())
        let capture = try CaptureTestFixtures.capture()
        controller.start(reference: capture.encodedPNG, selfie: capture.encodedPNG, selfieSHA256: capture.sha256)
        XCTAssertNil(controller.reportForExport())
        try await waitForCalls(1, engine)
        await engine.complete(0, score: 0.5)
        try await settled(controller)
        let text = try XCTUnwrap(controller.reportForExport())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((json["liquid"] as? [String: Any])?["status"] as? String, "retired")
        XCTAssertTrue(json["captureReceipt"] is NSNull)
        _ = controller.beginCapture(referenceID: UUID(), reference: Data([9]))
        XCTAssertNil(controller.reportForExport())
        controller.clear()
    }

    @MainActor func testAppPortraitAndReviewedSelfieReachComparisonAndVisibleResult() async throws {
        let engine = ComparisonSuspension()
        let comparison = FaceComparisonController { try await engine.compare($0) }
        let (app, capture, driver) = launch(comparison)
        defer { app.window?.isHidden = true }
        let reference = try CaptureTestFixtures.capture().encodedPNG
        app.acceptPassportPortrait(portrait(reference))
        let selfie = try await acquire(app, capture: capture, driver: driver)
        try await waitForCalls(1, engine)
        let first = await engine.firstInput()
        let input = try XCTUnwrap(first)
        XCTAssertEqual(input.reference, reference)
        XCTAssertEqual(input.selfie, selfie)
        XCTAssertEqual(input.referenceSHA256, digest(reference))
        XCTAssertEqual(input.selfieSHA256, digest(selfie))
        await engine.complete(0, score: 0.5)
        try await settled(comparison)
        XCTAssertEqual(comparison.phase, .completed(0.5))
        XCTAssertTrue(app.biometricScreen().paragraphs.contains { $0.identifier == "comparison.score" })
        let navigation = try selectedNavigation(app)
        XCTAssertEqual(navigation.viewControllers.count, 1)
        let root = try XCTUnwrap(navigation.topViewController as? ReferenceRenderer)
        root.loadViewIfNeeded()
        XCTAssertNotNil(root.accessibilityElement(identifier: "comparison.score"))
    }

    @MainActor func testAppTabWithdrawalRejectsLateComparisonResult() async throws {
        let engine = ComparisonSuspension()
        let comparison = FaceComparisonController { try await engine.compare($0) }
        let (app, capture, driver) = launch(comparison)
        defer { app.window?.isHidden = true }
        app.acceptPassportPortrait(portrait(try CaptureTestFixtures.capture().encodedPNG))
        _ = try await acquire(app, capture: capture, driver: driver)
        try await waitForCalls(1, engine)
        let tabs = try XCTUnwrap(app.window?.rootViewController as? UITabBarController)
        let document = try XCTUnwrap(tabs.viewControllers?.first {
            $0.tabBarItem.accessibilityIdentifier == "capability.document"
        })
        XCTAssertTrue(app.tabBarController(tabs, shouldSelect: document))
        await engine.complete(0, score: 1)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(comparison.phase, .idle)
        XCTAssertFalse(app.biometricScreen().paragraphs.contains { $0.identifier == "comparison.score" })
    }

    @MainActor func testAppRoutesReviewedSelfieThroughRealInferenceAdapter() async throws {
        let missingModel = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("AuraFace.onnx")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingModel.path))
        let comparison = FaceComparisonHost.makeController(modelURL: missingModel)
        let (app, capture, driver) = launch(comparison)
        defer { app.window?.isHidden = true }
        // The real SDK decoder must reject malformed bytes through the actual app adapter.
        // This boundary does not require the simulator's unavailable Vision model resources.
        app.acceptPassportPortrait(portrait(Data([0x01, 0x02, 0x03])))
        _ = try await acquire(app, capture: capture, driver: driver)
        try await settled(comparison)
        XCTAssertEqual(comparison.phase, .failed("comparison.error.image"))
        XCTAssertTrue(app.biometricScreen().paragraphs.contains {
            $0.identifier == "comparison.status" && $0.text == KenshikiCopy.text("comparison.error.image")
        })
    }















    @MainActor func testAppMissingInferenceModelReturnsUnavailableWithoutScore() async throws {
        let comparison = FaceComparisonHost.makeController(modelURL: nil)
        let (app, capture, driver) = launch(comparison)
        defer { app.window?.isHidden = true }
        app.acceptPassportPortrait(portrait(try CaptureTestFixtures.capture().encodedPNG))
        _ = try await acquire(app, capture: capture, driver: driver)
        try await settled(comparison)
        XCTAssertEqual(comparison.phase, .failed("comparison.error.model"))
        let result = app.biometricScreen().paragraphs
        XCTAssertTrue(result.contains {
            $0.identifier == "comparison.status" && $0.text == KenshikiCopy.text("comparison.error.model")
        })
        XCTAssertFalse(result.contains { $0.identifier == "comparison.score" })
    }

    @MainActor func testRetiredVisualValuesNeverAppearInActivePresentation() {
        let issues: [FaceVisualIssue] = [.blur, .poorLighting, .occlusion, .pose, .lowResolution, .other]
        for consistency in [FaceVisualConsistency.consistent, .inconsistent, .uncertain] {
            let completion = FaceVisualAssessmentCompletion(operationID: UUID(),
                referenceSHA256: String(repeating: "a", count: 64), selfieSHA256: String(repeating: "b", count: 64),
                consistency: consistency, issues: issues, durationMilliseconds: 100)
            let paragraphs = FaceComparisonPresentation.paragraphs(phase: .processing,
                visual: .completed(completion), durationMilliseconds: nil)
            let renderer = ReferenceRenderer(screen: ReferenceScreen(title: KenshikiCopy.text("journey.title"),
                heading: KenshikiCopy.text("journey.result.title"), paragraphs: paragraphs, primaryActions: []), emit: { _ in })
            renderer.loadViewIfNeeded()
            let consistencyKey = "comparison.visual.consistency.\(consistency.rawValue)"
            let status = renderer.accessibilityElement(identifier: "comparison.visual.status") as? UILabel
            XCTAssertNil(status)
            XCTAssertNotEqual(status?.text, consistencyKey)
            for issue in issues {
                let key = "comparison.visual.issue.\(issue.rawValue)"
                let label = renderer.accessibilityElement(identifier: key) as? UILabel
                XCTAssertNil(label)
                XCTAssertNotEqual(label?.text, key)
            }
        }
    }



    @MainActor func testMissingCaptureMetricsRemainUnavailableWithoutInventedZeros() throws {
        let capture = try CaptureTestFixtures.capture()
        let context = FaceCaptureContext(capture: capture)
        let supplied = try XCTUnwrap(FaceComparisonHost.captureMeasurements(context, selfieSHA256: capture.sha256))
        XCTAssertNil(supplied.depth)
        XCTAssertNil(supplied.motion)
        XCTAssertNil(supplied.quality?.score)
        XCTAssertNil(supplied.quality?.revision)
        let input = FaceInputTelemetry(operationID: UUID(), referenceSHA256: capture.sha256, selfieSHA256: capture.sha256,
            referenceBytes: capture.encodedPNG.count, selfieBytes: capture.encodedPNG.count, captureContext: context)
        let fields = FaceComparisonTelemetry.fields(input)
        XCTAssertEqual(fields.first { $0.key == "telemetry.depth.residualRMS" }?.value, .unavailable)
        XCTAssertEqual(fields.first { $0.key == "telemetry.capture.quality" }?.value, .unavailable)
        XCTAssertEqual(fields.first { $0.key == "telemetry.frame.sequence" }?.value, .unavailable)
        XCTAssertNil(try FaceComparisonHost.captureMeasurements(nil, selfieSHA256: capture.sha256))
    }







    @MainActor func testCaptureAndAuraSubstitutionCannotEnterReviewContext() throws {
        let capture = try telemetryCapture()
        var receipt = capture.admissionReceipt
        receipt.depthEvidence?.imageSHA256 = String(repeating: "0", count: 64)
        let replaced = CapturedSelfie(encodedPNG: capture.encodedPNG, admissionReceipt: receipt)
        XCTAssertThrowsError(try FaceComparisonHost.captureMeasurements(FaceCaptureContext(capture: replaced), selfieSHA256: replaced.sha256)) {
            XCTAssertEqual($0 as? FaceVisualAssessmentFailure, .sourceMismatch)
        }
        let source = FaceComparisonInput(operationID: UUID(), reference: capture.encodedPNG, referenceSHA256: capture.sha256,
            selfie: capture.encodedPNG, selfieSHA256: capture.sha256)
        let foreign = FaceComparisonCompletion(operationID: UUID(), referenceSHA256: capture.sha256,
            selfieSHA256: capture.sha256, score: 0.5, resultSHA256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try FaceComparisonHost.auraContext(.init(source: source, aura: foreign))) {
            XCTAssertEqual($0 as? FaceVisualAssessmentFailure, .sourceMismatch)
        }
    }





    @MainActor func testForeignMotionImageTimeAndClockCannotEnterReviewContext() throws {
        let source = try telemetryCapture(withMotion: true)
        let motion = try XCTUnwrap(source.admissionReceipt.motionEvidence)
        for mutation in 0...3 {
            var receipt = source.admissionReceipt
            receipt.motionEvidence = .init(imageSHA256: mutation == 0 ? String(repeating: "0", count: 64) : motion.imageSHA256,
                frameTimestampSeconds: mutation == 1 ? 2 : motion.frameTimestampSeconds,
                windowStartTimestampSeconds: motion.windowStartTimestampSeconds,
                windowEndTimestampSeconds: motion.windowEndTimestampSeconds,
                requestedSampleRateHz: motion.requestedSampleRateHz,
                clockDomain: mutation == 2 ? "unrelated_clock" : motion.clockDomain,
                alignment: mutation == 3 ? "unverified" : motion.alignment, summary: motion.summary)
            let capture = CapturedSelfie(encodedPNG: source.encodedPNG, admissionReceipt: receipt)
            XCTAssertThrowsError(try FaceComparisonHost.captureMeasurements(FaceCaptureContext(capture: capture), selfieSHA256: capture.sha256)) {
                XCTAssertEqual($0 as? FaceVisualAssessmentFailure, .sourceMismatch)
            }
        }
    }

    @MainActor func testRecordedMotionPermissionStatesAreVisibleAndDeniedEvidenceIsRejected() throws {
        let capture = try telemetryCapture(withMotion: true)
        for status in ["notRequested", "requesting", "authorized", "denied", "unavailable"] {
            var receipt = capture.admissionReceipt
            receipt.motionStatus = try XCTUnwrap(type(of: receipt.motionStatus).init(rawValue: status))
            if status != "authorized" { receipt.motionEvidence = nil }
            let sample = CapturedSelfie(encodedPNG: capture.encodedPNG, admissionReceipt: receipt)
            let context = FaceCaptureContext(capture: sample)
            let input = FaceInputTelemetry(operationID: UUID(), referenceSHA256: sample.sha256, selfieSHA256: sample.sha256,
                referenceBytes: sample.encodedPNG.count, selfieBytes: sample.encodedPNG.count, captureContext: context)
            let rows = FaceComparisonPresentation.paragraphs(phase: .processing, visual: .processing,
                durationMilliseconds: nil, expanded: true, input: input)
            let key = "telemetry.motionPermission.\(status)"
            XCTAssertTrue(rows.contains { $0.identifier.hasPrefix("telemetry.motion.permissionStatus.value.") && $0.text == KenshikiCopy.text(key) })
            let mapped = try XCTUnwrap(FaceComparisonHost.captureMeasurements(context, selfieSHA256: sample.sha256))
            if status != "authorized" { XCTAssertNil(mapped.motion) }
        }
        var denied = capture.admissionReceipt
        denied.motionStatus = .denied
        let deniedCapture = CapturedSelfie(encodedPNG: capture.encodedPNG, admissionReceipt: denied)
        XCTAssertThrowsError(try FaceComparisonHost.captureMeasurements(FaceCaptureContext(capture: deniedCapture), selfieSHA256: deniedCapture.sha256)) {
            XCTAssertEqual($0 as? FaceVisualAssessmentFailure, .sourceMismatch)
        }
    }

    private func telemetryCapture(withMotion: Bool = false) throws -> CapturedSelfie {
        let source = try CaptureTestFixtures.capture()
        var receipt = SelfieAdmissionReceipt(policyVersion: SelfieAdmissionPolicy.version, trigger: .manual,
            frameTimestamp: 1, anchorID: UUID(), consecutiveTrackedFrames: 12, blinkCompletedAt: 0.5, blinkAge: 0.55,
            leftEyeClosed: 0.1, rightEyeClosed: 0.2, eyesOpen: true, steadyHoldDuration: 1.2,
            captureQuality: 0.73, captureQualityEnforced: false, insideGuide: true, guideContainmentEnforced: false)
        receipt.effectivePolicy = .engineeringV1
        receipt.frameEvidence = SelfieFrameEvidence(sessionID: UUID(), sequence: 4, guideRevision: 2,
            pixelWidth: 1, pixelHeight: 1, orientation: 1, qualityRevision: 1, analysisDuration: 0.02, frameAgeAtAdmission: 0.05)
        receipt.depthEvidence = SelfieDepthEvidence(schemaVersion: 1,
            measurement: .init(policy: .engineeringV1, sampleCount: 128, residualRMS: 0.012), imageTimestamp: 1,
            depthTimestamp: 1, orientation: 1, mapWidth: 16, mapHeight: 16, filtered: false,
            ageAtAdmission: 0.05 + receipt.frameTimestamp - 1,
            imageSHA256: source.sha256)
        if withMotion {
            receipt.motionStatus = .authorized
            receipt.motionEvidence = .init(imageSHA256: source.sha256, frameTimestampSeconds: 1,
                windowStartTimestampSeconds: 0.5, windowEndTimestampSeconds: 1, requestedSampleRateHz: 50,
                clockDomain: "core_motion_boot_seconds", alignment: "host_uptime_checked",
                summary: .init(ceremony: .faceMatch, sampleCount: 25, durationSeconds: 0.5,
                    accelerationRMSg: 0.03, rotationRMSRadPerSecond: 0.2, tremorBandRatio: 0.1,
                    gravityDominantAxis: "z", gravityDominance: 0.9, gravityDriftRadians: 0.02,
                    approachRMSg: 0.05, settleRatio: 0.6, magneticDeltaMicrotesla: nil,
                    magnetometerCalibrated: false, rawWindowSHA256: String(repeating: "a", count: 64)))
        }
        return CapturedSelfie(encodedPNG: source.encodedPNG, admissionReceipt: receipt)
    }

    private func decodedReview() throws -> VisualEvidenceReview {
        let image: [String: Any] = ["qualityIssues": ["blur"], "observations": ["Synthetic image observation"],
            "apparentAge": ["rangeYears": [25, 35], "basis": "Synthetic age basis", "limitations": ["Synthetic age limitation"]]]
        var selfie = image
        selfie["apparentAge"] = ["rangeYears": NSNull(), "basis": "No estimate", "limitations": ["Insufficient detail"]]
        let data: [String: Any] = ["reference": image, "selfie": selfie,
            "auraReview": ["relationship": "not_assessable", "evidence": [], "limitations": ["No supplied score"]],
            "ageReview": ["relationship": "not_assessable", "evidence": [], "limitations": ["No claimed age"]],
            "captureReview": ["indicators": [["indicator": "motion_parallax", "status": "not_observable", "evidence": "Still images only", "sourceImageIds": ["Media-2"]]],
                "observations": ["Synthetic capture observation"], "limitations": ["Synthetic capture limitation"]],
            "summary": "Synthetic model summary"]
        return try JSONDecoder().decode(VisualEvidenceReview.self, from: JSONSerialization.data(withJSONObject: data))
    }






    @MainActor private func visualSettled(_ comparison: FaceComparisonController) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while comparison.visualPhase == .processing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotEqual(comparison.visualPhase, .processing)
    }

    @MainActor private func launch(_ comparison: FaceComparisonController,
        writeClipboard: @escaping (String) -> Void = { UIPasteboard.general.string = $0 })
        -> (ApplicationHost, BiometricCaptureController, WiringCaptureDriver) {
        let driver = WiringCaptureDriver()
        let capture = BiometricCaptureController { driver }
        let host = BiometricCaptureHost(controller: capture)
        let app = ApplicationHost(comparison: comparison, makeCapture: { host }, startsInExamples: true, writeClipboard: writeClipboard)
        _ = app.application(UIApplication.shared, didFinishLaunchingWithOptions: nil)
        return (app, capture, driver)
    }

    @MainActor private func selectedNavigation(_ app: ApplicationHost) throws -> UINavigationController {
        let tabs = try XCTUnwrap(app.window?.rootViewController as? UITabBarController)
        return try XCTUnwrap(tabs.selectedViewController as? UINavigationController)
    }

    @MainActor private func acquire(_ app: ApplicationHost, capture: BiometricCaptureController,
                                   driver: WiringCaptureDriver, evidence: CapturedSelfie? = nil) async throws -> Data {
        let navigation = try selectedNavigation(app)
        let root = try XCTUnwrap(navigation.topViewController)
        root.loadViewIfNeeded()
        try button("capture.live.start", in: root.view).sendActions(for: .touchUpInside)
        let renderer = try XCTUnwrap(navigation.topViewController)
        renderer.loadViewIfNeeded()
        try await navigationSettled(navigation, showing: renderer)
        capture.send(.visible)
        try button("capture.allow", in: renderer.view).sendActions(for: .touchUpInside)
        let selfie = try evidence ?? CaptureTestFixtures.capture()
        driver.onCapture?(selfie)
        let deadline = ContinuousClock.now + .seconds(5)
        while capture.phase == .processing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(capture.phase, .captured)
        try button("comparison.compare", in: renderer.view).sendActions(for: .touchUpInside)
        XCTAssertEqual(capture.phase, .finished)
        try await navigationSettled(navigation, showing: root)
        return selfie.encodedPNG
    }

    @MainActor private func navigationSettled(_ navigation: UINavigationController,
                                             showing controller: UIViewController) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while (navigation.topViewController !== controller || navigation.transitionCoordinator != nil),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(navigation.topViewController === controller)
        XCTAssertNil(navigation.transitionCoordinator)
    }

    @MainActor private func button(_ id: String, in view: UIView) throws -> UIButton {
        if let button = view as? UIButton, button.accessibilityIdentifier == id { return button }
        for child in view.subviews {
            if let found = try? button(id, in: child) { return found }
        }
        throw WiringFailure.missingButton
    }
    private enum WiringFailure: Error { case missingButton }

    private func portrait(_ bytes: Data) -> AcceptedPassportPortrait {
        let read = PassportReadObservation(documentNumber: "L898902C3", surname: "ERIKSSON", givenNames: "ANNA MARIA",
            nationality: "UTO", issuingState: "UTO", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415",
            sex: "F", personalNumber: nil, dateOfIssue: nil, issuingAuthority: nil, placeOfBirth: nil,
            basicAccessControl: .succeeded, pace: .notPerformed, activeAuthentication: .notPerformed,
            chipAuthentication: .notPerformed, countrySigningChain: .succeeded, documentSignature: .succeeded,
            dataGroupHashes: .succeeded, documentSigningCertificateDER: nil, activeAuthenticationChallenge: nil,
            activeAuthenticationSignature: nil, securityObject: Data([1]), dataGroups: [:], declaredDataGroups: ["DG2"],
            dg2: Data([0x75, 1, 1]), portrait: bytes, dg2Digest: String(repeating: "a", count: 64),
            dg2DigestAlgorithm: "SHA-256", chipAuthenticationResponse: nil)
        return AcceptedPassportPortrait(attemptID: UUID(), read: read, printedMRZ: nil)
    }
    @MainActor func testAcceptedImagesAutomaticallyProcessAndPublishSimilarity() async throws {
        let engine = ComparisonSuspension()
        let controller = FaceComparisonController { try await engine.compare($0) }
        let selfie = Data([4,5,6])
        controller.start(reference: Data([1,2,3]), selfie: selfie, selfieSHA256: digest(selfie))
        XCTAssertEqual(controller.phase, .processing)
        try await waitForCalls(1, engine)
        await engine.complete(0, score: 0.75)
        try await settled(controller)
        XCTAssertEqual(controller.phase, .completed(0.75))
    }
    @MainActor func testCancellationRejectsNonCooperativeLateCompletion() async throws {
        let engine = ComparisonSuspension()
        let controller = FaceComparisonController { try await engine.compare($0) }
        let selfie = Data([4])
        controller.start(reference: Data([1]), selfie: selfie, selfieSHA256: digest(selfie))
        try await waitForCalls(1, engine)
        controller.clear()
        await engine.complete(0, score: 1)
        await Task.yield()
        XCTAssertEqual(controller.phase, .idle)
    }
    @MainActor func testReplacementCannotConsumePreviousOperationCompletion() async throws {
        let engine = ComparisonSuspension()
        let controller = FaceComparisonController { try await engine.compare($0) }
        let selfie = Data([4])
        controller.start(reference: Data([1]), selfie: selfie, selfieSHA256: digest(selfie))
        try await waitForCalls(1, engine)
        controller.start(reference: Data([2]), selfie: selfie, selfieSHA256: digest(selfie))
        try await waitForCalls(2, engine)
        await engine.complete(0, score: 1)
        await Task.yield()
        XCTAssertEqual(controller.phase, .processing)
        await engine.complete(1, score: 0.25)
        try await settled(controller)
        XCTAssertEqual(controller.phase, .completed(0.25))
    }
    @MainActor func testForeignOperationOrImageBindingsNeverPublishScore() async throws {
        for mutation in 1...3 {
            let engine = ComparisonSuspension()
            let controller = FaceComparisonController { try await engine.compare($0) }
            let selfie = Data([4])
            controller.start(reference: Data([1]), selfie: selfie, selfieSHA256: digest(selfie))
            try await waitForCalls(1, engine)
            await engine.complete(0, score: 1, mutation: mutation)
            try await settled(controller)
            XCTAssertEqual(controller.phase, .failed("comparison.error.source"))
        }
    }
    @MainActor func testNonfiniteAndOutOfRangeScoresNeverPublish() async throws {
        for score in [Double.nan, .infinity, -.infinity, 1.01, -1.01] {
            let engine = ComparisonSuspension()
            let controller = FaceComparisonController { try await engine.compare($0) }
            let selfie = Data([4])
            controller.start(reference: Data([1]), selfie: selfie, selfieSHA256: digest(selfie))
            try await waitForCalls(1, engine)
            await engine.complete(0, score: score)
            try await settled(controller)
            XCTAssertEqual(controller.phase, .failed("comparison.error.source"))
        }
    }
    @MainActor func testSourceSubstitutionFailsBeforeEngineConstruction() async throws {
        let engine = ComparisonSuspension()
        let controller = FaceComparisonController { try await engine.compare($0) }
        controller.start(reference: Data([1]), selfie: Data([4]), selfieSHA256: digest(Data([5])))
        XCTAssertEqual(controller.phase, .failed("comparison.error.source"))
        let count = await engine.count
        XCTAssertEqual(count, 0)
    }
    @MainActor func testReentrantWithdrawalPreventsEngineWork() async throws {
        let engine = ComparisonSuspension()
        let controller = FaceComparisonController { try await engine.compare($0) }
        controller.onChange = { controller.clear() }
        let selfie = Data([4])
        controller.start(reference: Data([1]), selfie: selfie, selfieSHA256: digest(selfie))
        await Task.yield()
        let count = await engine.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(controller.phase, .idle)
    }
    @MainActor func testReentrantSameOperationReplacementStartsOnlyItsOwnInference() async throws {
        let engine = ComparisonSuspension()
        let controller = FaceComparisonController { try await engine.compare($0) }
        let operationID = UUID()
        let selfie = Data([4])
        var replaced = false
        controller.onChange = {
            guard !replaced else { return }
            replaced = true
            controller.start(reference: Data([1]), selfie: selfie,
                selfieSHA256: self.digest(selfie), id: operationID)
        }
        controller.start(reference: Data([1]), selfie: selfie, selfieSHA256: digest(selfie), id: operationID)
        try await waitForCalls(1, engine)
        for _ in 0..<20 { await Task.yield() }
        let count = await engine.count
        XCTAssertEqual(count, 1)
        // Settle every admitted call even when the regression admits duplicates.
        for index in 0..<count { await engine.complete(index, score: 0.5) }
        try await settled(controller)
        XCTAssertEqual(controller.phase, .completed(0.5))
        controller.clear()
    }








    @MainActor func testReviewedCaptureIsBoundToTheSelectedReferenceAndConsumedOnce() async throws {
        let engine = ComparisonSuspension()
        let controller = FaceComparisonController { try await engine.compare($0) }
        let referenceID = UUID()
        let capture = controller.beginCapture(referenceID: referenceID, reference: Data([1]))
        let selfie = Data([4])
        XCTAssertTrue(controller.acceptCapture(id: capture, currentReferenceID: referenceID,
            selfie: selfie, selfieSHA256: digest(selfie)))
        XCTAssertFalse(controller.acceptCapture(id: capture, currentReferenceID: referenceID,
            selfie: selfie, selfieSHA256: digest(selfie)))
        try await waitForCalls(1, engine)
        await engine.complete(0, score: 0.5)
        try await settled(controller)
        XCTAssertEqual(controller.phase, .completed(0.5))
    }
    @MainActor func testPortraitReplacementDuringReviewRejectsCaptureBeforeInference() async throws {
        let engine = ComparisonSuspension()
        let controller = FaceComparisonController { try await engine.compare($0) }
        let capture = controller.beginCapture(referenceID: UUID(), reference: Data([1]))
        let selfie = Data([4])
        XCTAssertFalse(controller.acceptCapture(id: capture, currentReferenceID: UUID(),
            selfie: selfie, selfieSHA256: digest(selfie)))
        XCTAssertEqual(controller.phase, .failed("comparison.error.source"))
        let count = await engine.count
        XCTAssertEqual(count, 0)
    }
    @MainActor func testRetiredCaptureAndCancellationCannotConsumeReplacementCapture() async throws {
        let engine = ComparisonSuspension()
        let controller = FaceComparisonController { try await engine.compare($0) }
        let first = controller.beginCapture(referenceID: UUID(), reference: Data([1]))
        let referenceID = UUID()
        let second = controller.beginCapture(referenceID: referenceID, reference: Data([2]))
        let selfie = Data([4])
        controller.cancelCapture(id: first)
        XCTAssertFalse(controller.acceptCapture(id: first, currentReferenceID: referenceID,
            selfie: selfie, selfieSHA256: digest(selfie)))
        XCTAssertTrue(controller.acceptCapture(id: second, currentReferenceID: referenceID,
            selfie: selfie, selfieSHA256: digest(selfie)))
        try await waitForCalls(1, engine)
        await engine.complete(0, score: 0.25)
        try await settled(controller)
        XCTAssertEqual(controller.phase, .completed(0.25))
    }
    @MainActor private func settled(_ controller: FaceComparisonController) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.phase == .processing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotEqual(controller.phase, .processing)
    }
    @MainActor private func waitForCalls(_ count: Int, _ engine: ComparisonSuspension) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await engine.count < count && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let actual = await engine.count
        XCTAssertEqual(actual, count)
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
private actor ComparisonSuspension {
    private var inputs: [FaceComparisonInput] = []
    private var continuations: [CheckedContinuation<FaceComparisonCompletion, Error>?] = []
    var count: Int { inputs.count }
    func firstInput() -> FaceComparisonInput? { inputs.first }
    func compare(_ input: FaceComparisonInput) async throws -> FaceComparisonCompletion {
        try await withCheckedThrowingContinuation { continuation in
            inputs.append(input)
            continuations.append(continuation)
        }
    }
    func complete(_ index: Int, score: Double, mutation: Int = 0, resultSHA256: String? = nil) {
        let input = inputs[index]
        let completion = FaceComparisonCompletion(operationID: mutation == 1 ? UUID() : input.operationID,
            referenceSHA256: mutation == 2 ? String(repeating: "0", count: 64) : input.referenceSHA256,
            selfieSHA256: mutation == 3 ? String(repeating: "0", count: 64) : input.selfieSHA256, score: score, resultSHA256: resultSHA256)
        let continuation = continuations[index]
        continuations[index] = nil
        continuation?.resume(returning: completion)
    }
}

@MainActor private final class WiringCaptureDriver: BiometricCaptureDriver {
    var onState: ((CaptureDriverState) -> Void)?
    var onReadiness: ((SelfieAdmissionGate.Readiness) -> Void)?
    var onCapture: ((CapturedSelfie) -> Void)?
    func setConsent(_: SelfieCaptureConsent) {}
    func setActive(_: Bool) {}
    func stop() {}
    func capture() {}
    func retry() -> Bool { false }
    func updateViewport(_: CaptureViewport) {}
}
