import XCTest
import BiometricInference
import BiometricQuality
@testable import BiometricCapture
@testable import KenshikiReference

@MainActor private final class WindowCaptureDriver: BiometricCaptureDriver {
    var onState: ((CaptureDriverState) -> Void)?
    var onReadiness: ((SelfieAdmissionGate.Readiness) -> Void)?
    var onCapture: ((CapturedSelfie) -> Void)?
    var onCaptureWindow: (([CapturedSelfie]) -> Void)?
    var stops = 0
    func setConsent(_: SelfieCaptureConsent) {}
    func setActive(_: Bool) {}
    func stop() { stops += 1 }
    func capture() {}
    func retry() -> Bool { false }
    func updateViewport(_: CaptureViewport) {}
}

private actor SelectionSuspension {
    private(set) var entered = false
    private var continuation: CheckedContinuation<AcceptedSelfie, Never>?
    func wait() async -> AcceptedSelfie {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: AcceptedSelfie) { continuation?.resume(returning: value); continuation = nil }
}

private actor FailingQualitySession: FaceCaptureQualitySession {
    let failure: FaceQualityFailure
    private(set) var calls = 0
    private(set) var closed = false
    init(_ failure: FaceQualityFailure) { self.failure = failure }
    func assess(_ snapshot: SelfiePixelSnapshot) async throws -> FaceCaptureSelectionRecord.Quality {
        calls += 1
        if calls == 1 { throw failure }
        return .init(sourceSHA256: snapshot.sourceEncodedSHA256, rasterSHA256: snapshot.pixels.sha256,
            artifactManifestSHA256: OFIQFaceQuality.artifactManifestSHA256, returnCode: 0, faceCount: 1,
            components: (Int32(0x41)...Int32(0x5c)).map { .init(measureID: $0, code: $0 == 0x41 ? 0 : 1,
                native: $0 == 0x41 ? 30 : nil, mapped: $0 == 0x41 ? 50 : nil) })
    }
    func close() { closed = true }
}

private actor SelectionLeaseGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
}

@MainActor private final class SelectionInputRecorder {
    var values: [FaceComparisonInput] = []
    func append(_ input: FaceComparisonInput) { values.append(input) }
}

@MainActor final class FaceCaptureSelectionTests: XCTestCase {
    func testEarlierWinnerKeepsOwnReceiptThroughBatchReviewProtectedCheckpointAndCompare() async throws {
        let captures = try [capture(at: 1), capture(at: 2)]
        let record = try selection(captures, scores: [30, 20])
        let driver = WindowCaptureDriver()
        let controller = BiometricCaptureController(makeDriver: { driver })
        let snapshot = try SelfiePixelBridge.decodeOrientedPNG(captures[0].encodedPNG, expectedSourceSHA256: captures[0].sha256)
        let accepted = AcceptedSelfie(capture: captures[0], snapshot: snapshot, selection: record)
        let fixture = try CaptureStoreFixture(); defer { fixture.remove() }
        let repository = fixture.repository()
        let receivedInputs = SelectionInputRecorder()
        let comparison = FaceComparisonController(compare: { input in
            await receivedInputs.append(input)
            return .init(operationID: input.operationID, referenceSHA256: input.referenceSHA256,
                selfieSHA256: input.selfieSHA256, score: 0.6)
        }, persistence: repository.comparisonEffects)
        let operationID = comparison.beginCapture(referenceID: UUID(), reference: Data([1, 2, 3]))
        controller.selectCaptureWindow = { window, progress in
            XCTAssertEqual(window.map(\.id), captures.map(\.id))
            await progress(.init(stage: .quality, completed: 2, total: 2))
            return accepted
        }
        controller.persistSelectedSelfie = { value in
            try await comparison.checkpointCapture(value.capture, id: operationID, selection: value.selection)
        }
        var delivered: AcceptedSelfie?
        controller.onAccepted = { delivered = $0 }
        controller.send(.visible); controller.send(.allow)
        driver.onCaptureWindow?(captures)
        try await until { controller.phase == .captured }
        XCTAssertEqual(driver.stops, 1)
        XCTAssertEqual(controller.capturedEvidence?.id, captures[0].id)
        controller.send(.useSelfie)
        let value = try XCTUnwrap(delivered)
        XCTAssertEqual(value.capture.admissionReceipt.frameTimestamp, 1)
        XCTAssertNotEqual(value.capture.admissionReceipt.frameTimestamp, captures[1].admissionReceipt.frameTimestamp)
        XCTAssertEqual(value.selection?.candidates.map { $0.capture.receipt.frameTimestamp }, [1, 2])
        let stored = try await repository.loadFaceCapture(operationID)
        XCTAssertEqual(stored.input.selfie, captures[0].encodedPNG)
        XCTAssertEqual(stored.input.captureContext?.captureID, captures[0].id)
        XCTAssertEqual(stored.input.selection, record)
        // Exercise the actual saved-input path; comparison receives the selected original.
        try comparison.runSaved(stored)
        try await until { comparison.hasResult }
        XCTAssertEqual(receivedInputs.values.count, 1)
        XCTAssertEqual(receivedInputs.values.first?.captureContext?.receipt.frameTimestamp, 1)
        XCTAssertEqual(receivedInputs.values.first?.selection, record)
        let exported = try XCTUnwrap(comparison.reportForExport())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
        XCTAssertNotNil(object["frameSelection"])
    }

    func testSelectionRejectsLatestReceiptAndConsistentButLowerQualityWinner() throws {
        let captures = try [capture(at: 1), capture(at: 2)]
        let record = try selection(captures, scores: [30, 20])
        XCTAssertThrowsError(try record.validate(selected: FaceCaptureContext(capture: captures[1]), imageSHA256: captures[1].sha256))
        let forged = FaceCaptureSelectionRecord(version: record.version, policyID: record.policyID, policySHA256: record.policySHA256,
            qualityArtifactSHA256: record.qualityArtifactSHA256, matcherArtifactSHA256: record.matcherArtifactSHA256,
            selectedCaptureID: captures[1].id, selectedSHA256: captures[1].sha256,
            selectedAlignedSHA256: String(repeating: "b", count: 64), candidates: record.candidates)
        XCTAssertThrowsError(try forged.validate(selected: FaceCaptureContext(capture: captures[1]), imageSHA256: captures[1].sha256))
    }

    func testForeignProfilePolicyAndNonCanonicalMetricsCannotValidateAsCurrentLineage() throws {
        let capture = try capture(at: 1), record = try selection([capture], scores: [30])
        for mutation in ["policy", "quality", "matcher", "duplicate", "missing", "code"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            var rows = try XCTUnwrap(object["candidates"] as? [[String: Any]])
            var quality = try XCTUnwrap(rows[0]["quality"] as? [String: Any])
            var prepared = try XCTUnwrap(rows[0]["preparation"] as? [String: Any])
            var metrics = try XCTUnwrap(quality["components"] as? [[String: Any]])
            switch mutation {
            case "policy": object["policySHA256"] = String(repeating: "0", count: 64)
            case "quality":
                object["qualityArtifactSHA256"] = String(repeating: "0", count: 64)
                quality["artifactManifestSHA256"] = object["qualityArtifactSHA256"]
            case "matcher":
                object["matcherArtifactSHA256"] = String(repeating: "0", count: 64)
                prepared["artifactManifestSHA256"] = object["matcherArtifactSHA256"]
            case "duplicate": metrics[1] = metrics[0]
            case "missing": metrics.removeLast()
            default: metrics[1]["code"] = 99
            }
            quality["components"] = metrics; rows[0]["quality"] = quality; rows[0]["preparation"] = prepared; object["candidates"] = rows
            let changed = try JSONDecoder().decode(FaceCaptureSelectionRecord.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try changed.validate(selected: FaceCaptureContext(capture: capture), imageSHA256: capture.sha256), mutation)
        }
    }

    func testLiveSelectedHandoffRequiresPreparedOwnerInsteadOfRepeatingSelfiePreparation() throws {
        let capture = try capture(at: 1), record = try selection([capture], scores: [30])
        let comparison = FaceComparisonController(compare: { _ in XCTFail("Missing selected owner must not rerun comparison"); throw FaceInferenceFailure.inferenceFailed })
        let referenceID = UUID(), operation = comparison.beginCapture(referenceID: referenceID, reference: Data([1]))
        XCTAssertFalse(comparison.acceptCapture(id: operation, currentReferenceID: referenceID, selfie: capture.encodedPNG,
            selfieSHA256: capture.sha256, captureContext: FaceCaptureContext(capture: capture), selection: record, preparedSelfie: nil))
        XCTAssertEqual(comparison.phase, .failed("comparison.error.source"))
    }

    func testLiveQualityAdapterRefusesProfileOutsideSignedApplicationBundle() throws {
        XCTAssertThrowsError(try NativeFaceCaptureQualitySession(directory: FileManager.default.temporaryDirectory)) { error in
            XCTAssertEqual(error as? FaceQualityFailure, .invalidAssets)
        }
    }

    func testMatcherFailureExcludesHigherQualityAndPersistsItsFailureWithoutScoreFallback() throws {
        let captures = try [capture(at: 1), capture(at: 2)]
        let record = try selection(captures, scores: [20, 99], failedPreparation: 1)
        XCTAssertEqual(record.selectedCaptureID, captures[0].id)
        XCTAssertEqual(record.candidates[1].failureCode, "face_missing")
        XCTAssertNotEqual(record.candidates[1].exclusions, 0)
        XCTAssertNil(record.candidates[1].preparation)
        try record.validate(selected: FaceCaptureContext(capture: captures[0]), imageSHA256: captures[0].sha256)
    }

    func testHistoricalInputWithoutSelectionStillDecodesAndCurrentLineageRoundTrips() throws {
        let capture = try capture(at: 1), record = try selection([capture], scores: [30])
        let input = FaceComparisonInput(operationID: UUID(), reference: Data([1]), referenceSHA256: SavedPassportCapture.digest(Data([1])),
            selfie: capture.encodedPNG, selfieSHA256: capture.sha256, captureContext: FaceCaptureContext(capture: capture), selection: record)
        let saved = try SavedFaceCapture(input: input)
        let restored = try JSONDecoder().decode(SavedFaceCapture.self, from: JSONEncoder().encode(saved))
        try restored.validate(); XCTAssertEqual(restored.input.selection, record)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var fields = try XCTUnwrap(legacy["input"] as? [String: Any]); fields.removeValue(forKey: "selection"); legacy["input"] = fields
        let old = try JSONDecoder().decode(SavedFaceCapture.self, from: JSONSerialization.data(withJSONObject: legacy))
        try old.validate(); XCTAssertNil(old.input.selection)
    }

    func testCancelledAndBackgroundedSelectionCannotPublishLateWinnerOrProgress() async throws {
        for background in [false, true] {
            let capture = try capture(at: 1), record = try selection([capture], scores: [30])
            let snapshot = try SelfiePixelBridge.decodeOrientedPNG(capture.encodedPNG, expectedSourceSHA256: capture.sha256)
            let accepted = AcceptedSelfie(capture: capture, snapshot: snapshot, selection: record)
            let gate = SelectionSuspension(), driver = WindowCaptureDriver()
            let controller = BiometricCaptureController(makeDriver: { driver })
            controller.selectCaptureWindow = { _, progress in
                let value = await gate.wait()
                await progress(.init(stage: .selection, completed: 1, total: 1))
                return value
            }
            var commits = 0
            controller.persistSelectedSelfie = { _ in commits += 1 }
            controller.send(.visible); controller.send(.allow); driver.onCaptureWindow?([capture])
            try await until { await gate.entered }
            if background { controller.backgrounded() } else { controller.send(.cancel) }
            await gate.finish(accepted)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(controller.phase, background ? .consent : .finished)
            XCTAssertEqual(commits, 0); XCTAssertNil(controller.snapshot); XCTAssertNil(controller.selectionProgress)
        }
    }

    func testNoSelectionRetainsTypedCandidateDiagnosticsWithoutCheckpointOrReview() async throws {
        let capture = try capture(at: 1), record = try selection([capture], scores: [30])
        let original = try XCTUnwrap(record.candidates.first)
        let failed = FaceCaptureSelectionRecord.Candidate(index: 0, capture: original.capture, quality: original.quality,
            preparation: nil, failureCode: "face_missing", exclusions: 224)
        let driver = WindowCaptureDriver(), controller = BiometricCaptureController(makeDriver: { driver })
        controller.selectCaptureWindow = { _, _ in
            throw FaceCaptureSelectionRefusal(reason: .noSelection, policyID: record.policyID, policySHA256: record.policySHA256,
                qualityArtifactSHA256: record.qualityArtifactSHA256, matcherArtifactSHA256: record.matcherArtifactSHA256, candidates: [failed])
        }
        var commits = 0; controller.persistSelectedSelfie = { _ in commits += 1 }
        controller.send(.visible); controller.send(.allow); driver.onCaptureWindow?([capture])
        try await until { controller.phase == .failure("capture.selection.failure.noSelection") }
        XCTAssertEqual(controller.selectionRefusal?.candidates.count, 1)
        XCTAssertNil(controller.capturedEvidence); XCTAssertEqual(commits, 0)
        controller.send(.cancel); XCTAssertNil(controller.selectionRefusal)
    }

    func testSelectionStorageRetryUsesSameWinnerWithoutReassessingOrRecapturing() async throws {
        let capture = try capture(at: 1), record = try selection([capture], scores: [30])
        let snapshot = try SelfiePixelBridge.decodeOrientedPNG(capture.encodedPNG, expectedSourceSHA256: capture.sha256)
        let driver = WindowCaptureDriver(), controller = BiometricCaptureController(makeDriver: { driver })
        controller.selectCaptureWindow = { _, _ in AcceptedSelfie(capture: capture, snapshot: snapshot, selection: record) }
        var writes: [UUID] = []
        controller.persistSelectedSelfie = { value in
            writes.append(value.capture.id)
            if writes.count == 1 { throw FaceWorkflowStorageFailure.unavailable }
        }
        controller.send(.visible); controller.send(.allow)
        let old = try XCTUnwrap(driver.onCaptureWindow)
        old([capture])
        try await until { controller.phase == .failure("capture.failure.storage") }
        let replacement = try self.capture(at: 2)
        old([replacement])
        let replacementSnapshot = try SelfiePixelBridge.decodeOrientedPNG(replacement.encodedPNG, expectedSourceSHA256: replacement.sha256)
        controller.receivedSelected(AcceptedSelfie(capture: replacement, snapshot: replacementSnapshot,
            selection: try self.selection([replacement], scores: [40])))
        XCTAssertEqual(controller.phase, .failure("capture.failure.storage"))
        XCTAssertEqual(controller.capturedEvidence?.id, capture.id)
        XCTAssertEqual(writes, [capture.id])
        controller.send(.retry)
        try await until { controller.phase == .captured }
        XCTAssertEqual(writes, [capture.id, capture.id])
        XCTAssertEqual(controller.capturedEvidence?.id, capture.id)
        XCTAssertEqual(driver.stops, 1)
    }

    func testCancellationBeforeSelectedCheckpointTaskBeginsDoesNotWrite() async throws {
        let capture = try capture(at: 1), record = try selection([capture], scores: [30])
        let snapshot = try SelfiePixelBridge.decodeOrientedPNG(capture.encodedPNG, expectedSourceSHA256: capture.sha256)
        let driver = WindowCaptureDriver(), controller = BiometricCaptureController(makeDriver: { driver })
        var writes = 0
        controller.persistSelectedSelfie = { _ in writes += 1 }
        controller.send(.visible); controller.send(.allow)
        controller.receivedSelected(AcceptedSelfie(capture: capture, snapshot: snapshot, selection: record))
        controller.send(.cancel)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(writes, 0); XCTAssertEqual(controller.phase, .finished)
        XCTAssertNil(controller.capturedEvidence)
    }

    func testPerFrameAssessmentFailureRetainsDiagnosticsContinuesAndClosesBeforeRefusal() async throws {
        let session = FailingQualitySession(.assessmentFailed)
        let captures = try [capture(at: 1), capture(at: 2)]
        do {
            _ = try await FaceCaptureSelectionProcessor.run(captures, qualityDirectory: URL(fileURLWithPath: "/unused"),
                modelURL: URL(fileURLWithPath: "/unused/AuraFace.onnx"), qualitySession: session, progress: { _ in })
            XCTFail("A one-pixel contract image cannot produce a prepared face")
        } catch let refusal as FaceCaptureSelectionRefusal {
            XCTAssertEqual(refusal.reason, .noSelection)
            XCTAssertEqual(refusal.candidates.count, 2)
            XCTAssertEqual(refusal.candidates[0].failureCode, "assessment_failed")
            XCTAssertNil(refusal.candidates[0].quality)
            XCTAssertEqual(refusal.candidates[1].quality?.components.count, 28)
            XCTAssertNotEqual(refusal.candidates[1].exclusions, 0)
        }
        let calls = await session.calls, closed = await session.closed
        XCTAssertEqual(calls, 2); XCTAssertTrue(closed)
    }

    func testQualityResourceFailureAbortsWindowAndClosesWithoutAssessingLaterFrame() async throws {
        let session = FailingQualitySession(.resourceLimit)
        do {
            _ = try await FaceCaptureSelectionProcessor.run(try [capture(at: 1), capture(at: 2)], qualityDirectory: URL(fileURLWithPath: "/unused"),
                modelURL: URL(fileURLWithPath: "/unused/AuraFace.onnx"), qualitySession: session, progress: { _ in })
            XCTFail("Native resource failure must abort the attempt")
        } catch let reason as FaceQualityFailure { XCTAssertEqual(reason, .resourceLimit) }
        let calls = await session.calls, closed = await session.closed
        XCTAssertEqual(calls, 1); XCTAssertTrue(closed)
    }

    func testSDKExampleComparisonWaitsForExistingInferenceLease() async throws {
        let gate = SelectionLeaseGate()
        let lease = Task { try await FaceInferenceScheduler.shared.run { await gate.wait() } }
        try await until { await gate.entered }
        let comparison = FaceComparisonHost.makeController(modelURL: nil)
        let selfie = Data([2])
        comparison.start(reference: Data([1]), selfie: selfie, selfieSHA256: SavedPassportCapture.digest(selfie))
        try await until { await FaceInferenceScheduler.shared.queuedCount == 1 || comparison.hasResult }
        XCTAssertEqual(comparison.phase, .processing)
        await gate.finish(); try await lease.value
        try await until { comparison.hasResult }
        XCTAssertEqual(comparison.phase, .failed("comparison.error.model"))
    }

    private func capture(at timestamp: Double) throws -> CapturedSelfie {
        let image = try CaptureTestFixtures.capture()
        let receipt = SelfieAdmissionReceipt(policyVersion: SelfieAdmissionPolicy.version, trigger: .manual,
            frameTimestamp: timestamp, anchorID: UUID(), consecutiveTrackedFrames: 10, blinkCompletedAt: timestamp - 0.5,
            blinkAge: 0.5, leftEyeClosed: 0, rightEyeClosed: 0, eyesOpen: true, steadyHoldDuration: 1,
            captureQuality: nil, captureQualityEnforced: false, insideGuide: true, guideContainmentEnforced: false)
        return CapturedSelfie(encodedPNG: image.encodedPNG, admissionReceipt: receipt)
    }

    private func selection(_ captures: [CapturedSelfie], scores: [Double], failedPreparation: Int? = nil) throws -> FaceCaptureSelectionRecord {
        let qualitySHA = OFIQFaceQuality.artifactManifestSHA256, matcherSHA = FaceCaptureSelectionProcessor.matcherManifest
        let policySHA = FaceCaptureSelectionProcessor.policySHA256
        var candidates: [FaceCaptureSelectionRecord.Candidate] = [], descriptors: [FaceFrameSelection.Candidate] = []
        for (index, capture) in captures.enumerated() {
            let prepared = index != failedPreparation
            let pixels = try SelfiePixelBridge.decodeOrientedPNG(capture.encodedPNG, expectedSourceSHA256: capture.sha256)
            let q = FaceCaptureSelectionRecord.Quality(sourceSHA256: capture.sha256, rasterSHA256: pixels.pixels.sha256,
                artifactManifestSHA256: qualitySHA, returnCode: 0, faceCount: 1,
                components: (Int32(0x41)...Int32(0x5c)).map { .init(measureID: $0, code: $0 == 0x41 ? 0 : 1,
                    native: $0 == 0x41 ? scores[index] : nil, mapped: $0 == 0x41 ? 50 : nil) })
            let p = prepared ? FaceCaptureSelectionRecord.Preparation(sourceSHA256: capture.sha256, alignedSHA256: String(repeating: "b", count: 64),
                artifactManifestSHA256: matcherSHA, alignmentRoute: "apple-vision-revision3-five-point-cpp-bilinear-v1") : nil
            candidates.append(.init(index: index, capture: FaceCaptureContext(capture: capture), quality: q, preparation: p,
                failureCode: prepared ? nil : "face_missing", exclusions: 0))
            descriptors.append(.init(source: .init(identifier: capture.id.uuidString, originalFrameIndex: UInt32(index), sha256: capture.sha256),
                quality: .init(sourceSHA256: capture.sha256, returnCode: 0, faceCount: 1, score: .init(code: 0, native: scores[index], mapped: 50)),
                matcher: .init(sourceSHA256: p?.sourceSHA256, status: prepared ? .passed : .failed, alignedSHA256: p?.alignedSHA256)))
        }
        let report = try FaceFrameSelection.select(descriptors, configuration: .init(policy: .highestNativeUQS, identities: .init(
            policy: .init(identifier: FaceCaptureSelectionProcessor.policyID, sha256: policySHA),
            qualityArtifact: .init(identifier: "ofiq-1.0.3-mobile-v1", sha256: qualitySHA), matcherArtifact: .init(identifier: "sdk-vision3-cpp-preflight-v1", sha256: matcherSHA))))
        for index in candidates.indices { candidates[index].exclusions = report.candidates[index].exclusions.rawValue }
        guard case let .selected(winner) = report.outcome else { throw FaceCaptureSelectionFailure.noSelection }
        return FaceCaptureSelectionRecord(version: 1, policyID: FaceCaptureSelectionProcessor.policyID, policySHA256: policySHA,
            qualityArtifactSHA256: qualitySHA, matcherArtifactSHA256: matcherSHA, selectedCaptureID: captures[winner.inputOffset].id,
            selectedSHA256: winner.source.sha256, selectedAlignedSHA256: winner.alignedSHA256, candidates: candidates)
    }
    private func until(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let complete = await condition(); XCTAssertTrue(complete)
    }
}
