import DocumentSDK
import DocumentCaptureApple
import Foundation
import XCTest
@testable import KenshikiReference

@MainActor private final class DocumentFlowGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private enum DocumentProbeError: Error { case unavailable }
private enum DocumentProbeStep: CaseIterable { case capture, preparation, extraction, portrait }
private enum DocumentProbeMismatch: CaseIterable {
    case sourceSide, sourceHash, preparedSource, preparedHash, readingSource, portraitSource, portraitHash, portraitBounds
}

@MainActor private final class DocumentCameraProbe: DocumentFlowCamera {
    var starts = 0
    var stops = 0
    var captures: [DocumentSide] = []
    var startGate: DocumentFlowGate?
    var stopGate: DocumentFlowGate?
    var captureGate: DocumentFlowGate?
    var startFails = false
    var stopFails = false
    var captureFails = false
    var mismatch: DocumentProbeMismatch?
    var automaticCapture: (@MainActor (DocumentCaptureObservationIdentity) -> Void)?
    var identities: [DocumentCaptureObservationIdentity?] = []
    var livePDF417: (@MainActor (String) -> Void)?
    var liveCandidates: [String?] = []
    var startedSides: [DocumentSide] = []
    func observeLivePDF417(_ receive: @escaping @MainActor (String) -> Void) { livePDF417 = receive }
    func start(side: DocumentSide) async throws { startedSides.append(side); try await start() }
    func capture(side: DocumentSide, observationIdentity: DocumentCaptureObservationIdentity?, livePDF417Candidate: String?) async throws -> DocumentFlowSource {
        liveCandidates.append(livePDF417Candidate)
        return try await capture(side: side, observationIdentity: observationIdentity)
    }

    func observeAutomaticCapture(_ receive: @escaping @MainActor (DocumentCaptureObservationIdentity) -> Void) {
        automaticCapture = receive
    }
    func capture(side: DocumentSide, observationIdentity: DocumentCaptureObservationIdentity?) async throws -> DocumentFlowSource {
        identities.append(observationIdentity)
        return try await capture(side: side)
    }

    func start() async throws {
        starts += 1
        await startGate?.wait()
        if startFails { throw DocumentProbeError.unavailable }
    }
    func stop() async throws {
        stops += 1
        await stopGate?.wait()
        if stopFails { throw DocumentProbeError.unavailable }
    }
    func capture(side: DocumentSide) async throws -> DocumentFlowSource {
        captures.append(side)
        await captureGate?.wait()
        if captureFails { throw DocumentProbeError.unavailable }
        let bytes = Data(side == .front ? [1, 2, 3] : [4, 5, 6])
        return DocumentFlowSource(side: mismatch == .sourceSide ? .back : side,
            data: bytes, sha256: mismatch == .sourceHash ? "different" : digest(bytes), pixelWidth: 100, pixelHeight: 60)
    }
}

@MainActor private final class DocumentFlowProbe {
    var cameras: [DocumentCameraProbe] = []
    var configureCamera: (DocumentCameraProbe, Int) -> Void = { _, _ in }
    var preparationGate: DocumentFlowGate?
    var extractionGate: DocumentFlowGate?
    var portraitGate: DocumentFlowGate?
    var failedStep: DocumentProbeStep?
    var mismatch: DocumentProbeMismatch?
    var prepared: [DocumentSide] = []
    var extracted: [DocumentSide] = []
    var portraitCalls = 0
    var omitPortraits = false
    var cameraCreated: (() -> Void)?

    var ports: DocumentFlowPorts {
        DocumentFlowPorts(makeCamera: {
            let value = DocumentCameraProbe()
            value.mismatch = self.mismatch
            value.captureFails = self.failedStep == .capture
            self.configureCamera(value, self.cameras.count)
            self.cameras.append(value)
            self.cameraCreated?()
            return value
        }, prepare: { source in
            self.prepared.append(source.side)
            await self.preparationGate?.wait()
            if self.failedStep == .preparation { throw DocumentProbeError.unavailable }
            let bytes = source.data + Data([9])
            return DocumentFlowPrepared(sourceSHA256: self.mismatch == .preparedSource ? "different" : source.sha256,
                data: bytes, sha256: self.mismatch == .preparedHash ? "different" : digest(bytes),
                pixelWidth: 100, pixelHeight: 60, derivation: Data("synthetic-unit-derivation".utf8))
        }, extract: { source in
            self.extracted.append(source.side)
            await self.extractionGate?.wait()
            if self.failedStep == .extraction { throw DocumentProbeError.unavailable }
            return DocumentFlowReading(sourceSHA256: self.mismatch == .readingSource ? "different" : source.sha256,
                recognizedText: ["SYNTHETIC UNIT TEXT"], pdf417Payloads: ["raw-unit-payload"],
                parsedPDF417: [AAMVAPDF417Parser.parse("raw-unit-payload")])
        }, portraits: { prepared in
            self.portraitCalls += 1
            await self.portraitGate?.wait()
            if self.failedStep == .portrait { throw DocumentProbeError.unavailable }
            if self.omitPortraits { return [] }
            let face = PortraitFaceObservation(boundingBox: .init(
                x: self.mismatch == .portraitBounds ? 0.8 : 0.2, y: 0.2, width: 0.15, height: 0.3), confidence: 1)
            let assessment = PortraitCropPolicy.evaluate(faces: [face],
                imageWidth: self.mismatch == .portraitBounds ? 200 : 100, imageHeight: 60)
            let geometry = try XCTUnwrap(assessment.candidates.first)
            let bytes = Data([7, 8, 9])
            return [DocumentFlowPortrait(sourceSHA256: self.mismatch == .portraitSource ? "different" : prepared.sha256,
                data: bytes, sha256: self.mismatch == .portraitHash ? "different" : digest(bytes), geometry: geometry)]
        }, sha256: digest)
    }
}

/// Synthetic ports test controller transitions and ownership; they are not camera qualification.
@MainActor final class DocumentFlowControllerTests: XCTestCase {
    func testAutomaticFrontPreservesIdentityAndManualRaceCannotCaptureTwice() async throws {
        let probe = DocumentFlowProbe(), gate = DocumentFlowGate()
        probe.configureCamera = { camera, _ in camera.captureGate = gate }
        let controller = ready(probe)
        await controller.waitUntilSettled()
        let camera = try XCTUnwrap(probe.cameras.first)
        let identity = try automaticIdentity()
        camera.automaticCapture?(identity)
        XCTAssertEqual(controller.processingSide, .front)
        controller.send(.capture)
        camera.automaticCapture?(identity)
        await eventually { gate.entered }
        XCTAssertEqual(camera.identities, [identity])
        gate.release()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        XCTAssertNil(controller.processingSide)
        camera.automaticCapture?(identity)
        await controller.waitUntilSettled()
        XCTAssertEqual(camera.captures, [.front])
    }

    func testRetiredAutomaticCallbackCannotCaptureReplacementCamera() async throws {
        let probe = DocumentFlowProbe(), controller = ready(probe)
        await controller.waitUntilSettled()
        let retired = try XCTUnwrap(probe.cameras.first?.automaticCapture)
        controller.send(.reset)
        controller.send(.start)
        await controller.waitUntilSettled()
        retired(try automaticIdentity())
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .front)
        XCTAssertTrue(probe.cameras.allSatisfy { $0.captures.isEmpty })
        controller.send(.hidden)
        await controller.waitUntilSettled()
    }

    private func automaticIdentity() throws -> DocumentCaptureObservationIdentity {
        try JSONDecoder().decode(DocumentCaptureObservationIdentity.self,
            from: Data(#"{"sequence":7,"geometryRevision":2,"observedAt":100}"#.utf8))
    }

    func testCameraIsLazyAndRequiresExplicitStartWhileVisibleAndForeground() async {
        let probe = DocumentFlowProbe(), controller = DocumentFlowController(ports: probe.ports)
        controller.send(.start)
        controller.send(.visible)
        controller.send(.start)
        controller.setForeground(true)
        await controller.waitUntilSettled()
        XCTAssertTrue(probe.cameras.isEmpty)
        let active = DocumentFlowController(ports: probe.ports)
        active.setForeground(true); active.send(.start)
        XCTAssertTrue(probe.cameras.isEmpty)
        active.send(.visible)
        await active.waitUntilSettled()
        XCTAssertTrue(probe.cameras.isEmpty)
        active.send(.start)
        await active.waitUntilSettled()
        XCTAssertEqual(probe.cameras.count, 1)
        XCTAssertEqual(active.phase, .front)
        active.send(.hidden); await active.waitUntilSettled()
    }

    func testFrontAndBackRetainExactIndependentSourceAndDerivativeObservations() async {
        let probe = DocumentFlowProbe(), controller = ready(probe)
        await controller.waitUntilSettled()
        controller.send(.capture); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        XCTAssertEqual(controller.front?.source.data, Data([1, 2, 3]))
        XCTAssertEqual(controller.front?.prepared?.data, Data([1, 2, 3, 9]))
        XCTAssertEqual(controller.front?.reading.recognizedText, ["SYNTHETIC UNIT TEXT"])
        XCTAssertEqual(controller.front?.reading.pdf417Payloads, ["raw-unit-payload"])
        XCTAssertEqual(controller.front?.reading.parsedPDF417.first?.status, .malformed)
        XCTAssertEqual(controller.front?.portraits.count, 1)
        XCTAssertEqual(controller.front?.prepared?.sourceSHA256, controller.front?.source.sha256)
        XCTAssertEqual(controller.front?.portraits.first?.sourceSHA256, controller.front?.prepared?.sha256)
        controller.send(.capture); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .review)
        XCTAssertEqual(controller.back?.source.data, Data([4, 5, 6]))
        XCTAssertEqual(controller.back?.prepared?.data, Data([4, 5, 6, 9]))
        XCTAssertEqual(controller.back?.portraits.count, 0)
        XCTAssertEqual(probe.portraitCalls, 1)
        XCTAssertEqual(probe.cameras[0].captures, [.front])
        XCTAssertEqual(probe.cameras[1].captures, [.back])
        XCTAssertEqual(probe.cameras[0].stops, 1)
        XCTAssertEqual(probe.cameras[1].stops, 1)
        controller.send(.reset); await controller.waitUntilSettled()
    }

    func testNoPortraitObservationRemainsReviewableWithoutInventedMatch() async {
        let probe = DocumentFlowProbe()
        probe.omitPortraits = true
        let controller = ready(probe)
        await controller.waitUntilSettled()
        controller.send(.capture); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        XCTAssertEqual(controller.front?.portraits.count, 0)
        XCTAssertEqual(controller.front?.source.data, Data([1, 2, 3]))
        XCTAssertNil(controller.failure)
        controller.send(.capture); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .review)
        XCTAssertEqual(controller.front?.portraits.count, 0)
        controller.send(.hidden); await controller.waitUntilSettled()
    }

    func testRepeatedStartAndCaptureIntentsCannotDuplicateAcquisition() async {
        let probe = DocumentFlowProbe(), gate = DocumentFlowGate()
        probe.configureCamera = { camera, _ in camera.captureGate = gate }
        let controller = ready(probe)
        controller.send(.start)
        await controller.waitUntilSettled()
        controller.send(.start)
        controller.send(.capture)
        await eventually { gate.entered }
        controller.send(.capture)
        XCTAssertEqual(probe.cameras.count, 1)
        XCTAssertEqual(probe.cameras[0].captures, [.front])
        gate.release()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        controller.send(.capture); controller.send(.capture)
        await controller.waitUntilSettled()
        XCTAssertEqual(probe.cameras[0].captures, [.front])
        XCTAssertEqual(probe.cameras[1].captures, [.back])
        XCTAssertEqual(controller.phase, .review)
        controller.send(.hidden); await controller.waitUntilSettled()
    }

    func testCameraStartupFailureSettlesBeforeExplicitRetry() async {
        let probe = DocumentFlowProbe()
        probe.configureCamera = { camera, index in camera.startFails = index == 0 }
        let controller = ready(probe)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .failure)
        XCTAssertEqual(controller.failure, .cameraStart)
        XCTAssertEqual(probe.cameras[0].stops, 1)
        XCTAssertTrue(probe.cameras[0].captures.isEmpty)
        controller.send(.start); await controller.waitUntilSettled()
        XCTAssertEqual(probe.cameras.count, 2)
        XCTAssertEqual(controller.phase, .front)
        controller.send(.hidden); await controller.waitUntilSettled()
    }

    func testBackFailurePreservesFrontForExplicitBackRetake() async {
        let probe = DocumentFlowProbe(), controller = ready(probe)
        await controller.waitUntilSettled()
        controller.send(.capture); await controller.waitUntilSettled()
        let originalFront = controller.front?.source.data
        probe.cameras[1].captureFails = true
        controller.send(.capture); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .failure)
        XCTAssertEqual(controller.failure, .capture)
        XCTAssertEqual(controller.front?.source.data, originalFront)
        XCTAssertNil(controller.back)
        controller.send(.retakeBack); await controller.waitUntilSettled()
        controller.send(.capture); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .review)
        XCTAssertEqual(controller.front?.source.data, originalFront)
        XCTAssertNotNil(controller.back)
        controller.send(.hidden); await controller.waitUntilSettled()
    }

    func testRetakeBackPreservesFrontAndRetakeFrontClearsBothSides() async {
        let probe = DocumentFlowProbe(), controller = ready(probe)
        await controller.waitUntilSettled()
        controller.send(.capture); await controller.waitUntilSettled()
        controller.send(.capture); await controller.waitUntilSettled()
        let originalFront = controller.front?.source.data
        controller.send(.retakeBack); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        XCTAssertEqual(controller.front?.source.data, originalFront)
        XCTAssertNil(controller.back)
        controller.send(.capture); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .review)
        controller.send(.retakeFront); await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .front)
        XCTAssertNil(controller.front); XCTAssertNil(controller.back)
        XCTAssertEqual(probe.cameras.count, 4)
        controller.send(.hidden); await controller.waitUntilSettled()
    }

    func testResetLeaveAndBackgroundImmediatelyClearAllReviewMedia() async {
        for action in [DocumentFlowIntent.reset, .hidden] {
            let probe = DocumentFlowProbe(), controller = ready(probe)
            await controller.waitUntilSettled()
            controller.send(.capture); await controller.waitUntilSettled()
            controller.send(.capture); await controller.waitUntilSettled()
            XCTAssertNotNil(controller.front); XCTAssertNotNil(controller.back)
            controller.send(action)
            XCTAssertNil(controller.front); XCTAssertNil(controller.back)
            XCTAssertEqual(controller.phase, .intro)
            await controller.waitUntilSettled()
        }
        let probe = DocumentFlowProbe(), controller = ready(probe)
        await controller.waitUntilSettled()
        controller.send(.capture); await controller.waitUntilSettled()
        controller.send(.capture); await controller.waitUntilSettled()
        XCTAssertNotNil(controller.front); XCTAssertNotNil(controller.back)
        controller.setForeground(false)
        XCTAssertNil(controller.front); XCTAssertNil(controller.back)
        XCTAssertEqual(controller.phase, .intro)
        await controller.waitUntilSettled()
        controller.setForeground(true)
        await controller.waitUntilSettled()
        XCTAssertEqual(probe.cameras.count, 2)
        XCTAssertEqual(controller.phase, .intro)
    }

    func testEachSuspendedProcessingStageIsFencedAfterBackground() async {
        for step in DocumentProbeStep.allCases {
            let probe = DocumentFlowProbe(), gate = DocumentFlowGate()
            switch step {
            case .capture: probe.configureCamera = { camera, _ in camera.captureGate = gate }
            case .preparation: probe.preparationGate = gate
            case .extraction: probe.extractionGate = gate
            case .portrait: probe.portraitGate = gate
            }
            let controller = ready(probe)
            await controller.waitUntilSettled()
            controller.send(.capture)
            await eventually { gate.entered }
            controller.setForeground(false)
            XCTAssertNil(controller.front); XCTAssertNil(controller.back)
            gate.release()
            await controller.waitUntilSettled()
            XCTAssertEqual(controller.phase, .intro)
            XCTAssertNil(controller.front); XCTAssertNil(controller.back)
            XCTAssertEqual(probe.prepared.count, step == .capture ? 0 : 1)
            XCTAssertEqual(probe.extracted.count, [.capture, .preparation].contains(step) ? 0 : 1)
            XCTAssertEqual(probe.portraitCalls, step == .portrait ? 1 : 0)
            XCTAssertEqual(probe.cameras[0].stops, 1)
        }
    }

    func testOldStartAndStopSettleBeforeReplacementCameraIsConstructed() async {
        let probe = DocumentFlowProbe(), start = DocumentFlowGate(), stop = DocumentFlowGate()
        probe.configureCamera = { camera, index in if index == 0 { camera.startGate = start; camera.stopGate = stop } }
        let controller = ready(probe)
        await eventually { start.entered }
        controller.send(.hidden); controller.send(.visible); controller.send(.start)
        XCTAssertEqual(probe.cameras.count, 1)
        start.release()
        await eventually { stop.entered }
        XCTAssertEqual(probe.cameras.count, 1)
        stop.release()
        await controller.waitUntilSettled()
        XCTAssertEqual(probe.cameras.count, 2)
        XCTAssertEqual(controller.phase, .front)
        XCTAssertEqual(probe.cameras[1].stops, 0)
        controller.send(.hidden); await controller.waitUntilSettled()
    }

    func testStalePortraitCompletionCannotPublishOrStopNewCamera() async {
        let probe = DocumentFlowProbe(), gate = DocumentFlowGate()
        probe.portraitGate = gate
        let controller = ready(probe)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await eventually { gate.entered }
        controller.send(.reset); controller.send(.start)
        await eventually { probe.cameras.count == 2 && controller.phase == .front }
        XCTAssertEqual(probe.cameras[0].stops, 1)
        XCTAssertEqual(probe.cameras[1].stops, 0)
        gate.release()
        await controller.waitUntilSettled()
        XCTAssertNil(controller.front); XCTAssertNil(controller.back)
        XCTAssertEqual(controller.phase, .front)
        XCTAssertEqual(probe.cameras[1].stops, 0)
        controller.send(.hidden); await controller.waitUntilSettled()
    }

    func testFailedNativeSettlementBlocksReplacementUntilExplicitRetrySucceeds() async {
        let probe = DocumentFlowProbe()
        probe.configureCamera = { camera, index in if index == 0 { camera.stopFails = true } }
        let controller = ready(probe)
        await controller.waitUntilSettled()
        controller.send(.reset); await controller.waitUntilSettled()
        XCTAssertEqual(controller.failure, .cameraSettlement)
        controller.send(.start); await controller.waitUntilSettled()
        XCTAssertEqual(probe.cameras.count, 1)
        XCTAssertEqual(controller.failure, .cameraSettlement)
        probe.cameras[0].stopFails = false
        controller.send(.start); await controller.waitUntilSettled()
        XCTAssertEqual(probe.cameras.count, 2)
        XCTAssertEqual(controller.phase, .front)
        controller.send(.hidden); await controller.waitUntilSettled()
    }

    func testSourceDerivativeReadingAndPortraitBindingMismatchesAreRefused() async {
        for mismatch in DocumentProbeMismatch.allCases {
            let probe = DocumentFlowProbe()
            probe.mismatch = mismatch
            let controller = ready(probe)
            await controller.waitUntilSettled()
            controller.send(.capture); await controller.waitUntilSettled()
            XCTAssertEqual(controller.phase, .failure)
            XCTAssertEqual(controller.failure, .sourceBinding)
            XCTAssertNil(controller.front); XCTAssertNil(controller.back)
            controller.send(.hidden); await controller.waitUntilSettled()
        }
    }

    func testProcessingFailuresRemainStageSpecificWithoutReviewSuccess() async {
        for step in DocumentProbeStep.allCases {
            let probe = DocumentFlowProbe()
            probe.failedStep = step
            let controller = ready(probe)
            await controller.waitUntilSettled()
            controller.send(.capture); await controller.waitUntilSettled()
            let expected: DocumentFlowFailure
            switch step {
            case .capture: expected = .capture
            case .preparation: expected = .preparation
            case .extraction: expected = .extraction
            case .portrait: expected = .portrait
            }
            XCTAssertEqual(controller.phase, .failure)
            XCTAssertEqual(controller.failure, expected)
            XCTAssertNil(controller.front); XCTAssertNil(controller.back)
            controller.send(.hidden); await controller.waitUntilSettled()
        }
    }

    func testReentrantVisibilityWithdrawalDoesNotStartCameraOrProcessing() async {
        let probe = DocumentFlowProbe(), controller = DocumentFlowController(ports: probe.ports)
        controller.setForeground(true); controller.send(.visible)
        controller.changed = { if controller.phase == .starting { controller.send(.hidden) } }
        controller.send(.start); await controller.waitUntilSettled()
        XCTAssertTrue(probe.cameras.isEmpty)
        let active = ready(probe)
        await active.waitUntilSettled()
        active.changed = { if active.phase == .processing { active.send(.hidden) } }
        active.send(.capture); await active.waitUntilSettled()
        XCTAssertTrue(probe.cameras[0].captures.isEmpty)
        XCTAssertTrue(probe.prepared.isEmpty)
        XCTAssertNil(active.front)
    }

    func testFactoryWithdrawalCannotStartTheReturnedCamera() async {
        let probe = DocumentFlowProbe()
        let controller = DocumentFlowController(ports: probe.ports)
        probe.cameraCreated = { controller.send(.hidden) }
        controller.setForeground(true); controller.send(.visible); controller.send(.start)
        await controller.waitUntilSettled()
        XCTAssertEqual(probe.cameras.count, 1)
        XCTAssertEqual(probe.cameras[0].starts, 0)
        XCTAssertEqual(probe.cameras[0].stops, 1)
        XCTAssertEqual(controller.phase, .intro)
    }

    func testLivePDF417BeforeBackIsIgnoredAndExactCandidateCapturesBackOnlyOnce() async throws {
        let probe = DocumentFlowProbe(), gate = DocumentFlowGate()
        probe.configureCamera = { camera, index in if index == 1 { camera.captureGate = gate } }
        let controller = ready(probe)
        await controller.waitUntilSettled()
        let front = try XCTUnwrap(probe.cameras.first)
        front.livePDF417?("premature-front-read")
        await controller.waitUntilSettled()
        XCTAssertTrue(front.captures.isEmpty)
        controller.send(.capture)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        XCTAssertEqual(probe.cameras.count, 2)
        XCTAssertEqual(front.stops, 1)
        XCTAssertEqual(front.startedSides, [.front])
        let back = probe.cameras[1]
        XCTAssertEqual(back.startedSides, [.back])
        front.livePDF417?("late-retired-front-read")
        XCTAssertTrue(back.captures.isEmpty)
        let raw = "@\nSYNTHETIC RAW PDF417\u{001e} \r\n"
        back.livePDF417?(raw)
        controller.send(.capture)
        back.livePDF417?("duplicate-read")
        await eventually { gate.entered }
        XCTAssertEqual(back.captures, [.back])
        XCTAssertEqual(back.liveCandidates, [raw])
        gate.release()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .review)
        XCTAssertEqual(controller.back?.source.data, Data([4, 5, 6]))
        XCTAssertEqual(front.captures, [.front])
        XCTAssertEqual(back.stops, 1)
    }

    func testPDF417DuringBackStartupWaitsForReadyBackOwner() async throws {
        let probe = DocumentFlowProbe(), start = DocumentFlowGate()
        probe.configureCamera = { camera, index in if index == 1 { camera.startGate = start } }
        let controller = ready(probe)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await eventually { start.entered }
        XCTAssertEqual(controller.phase, .starting)
        let back = probe.cameras[1]
        back.livePDF417?("read-before-back-ready")
        XCTAssertTrue(back.captures.isEmpty)
        start.release()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        back.livePDF417?("ready-back-candidate")
        await controller.waitUntilSettled()
        XCTAssertEqual(back.liveCandidates, ["ready-back-candidate"])
        XCTAssertEqual(controller.phase, .review)
    }

    func testRetiredPDF417CallbacksCannotCaptureReplacementBackOrCancelledSession() async throws {
        for cancel in [false, true] {
            let probe = DocumentFlowProbe(), controller = ready(probe)
            await controller.waitUntilSettled()
            controller.send(.capture)
            await controller.waitUntilSettled()
            let old = probe.cameras[1], callback = try XCTUnwrap(old.livePDF417)
            controller.send(.retakeBack)
            await controller.waitUntilSettled()
            XCTAssertEqual(probe.cameras.count, 3)
            let replacement = probe.cameras[2]
            if cancel { controller.setForeground(false) }
            callback("retired-back-candidate")
            if cancel { replacement.livePDF417?("cancelled-current-back-candidate") }
            await controller.waitUntilSettled()
            XCTAssertTrue(old.captures.isEmpty)
            XCTAssertTrue(replacement.captures.isEmpty)
            XCTAssertEqual(controller.phase, cancel ? .intro : .back)
            XCTAssertEqual(replacement.stops, cancel ? 1 : 0)
            controller.send(.hidden)
            await controller.waitUntilSettled()
        }
    }

    func testCameraWithoutLiveBarcodeSupportRefusesInsteadOfDowngradingCandidate() async throws {
        let camera = LegacyDocumentCameraProbe()
        do {
            _ = try await camera.capture(side: .back, observationIdentity: nil, livePDF417Candidate: "raw-barcode")
            XCTFail("A barcode request cannot silently become manual capture")
        } catch DocumentFlowFailure.capture {}
        XCTAssertEqual(camera.captures, 0)
    }

    func testLiveBarcodeBypassesFailingPreparationAndExtractionWithoutInventingStillOCR() async throws {
        for failure in [DocumentProbeStep.preparation, .extraction] {
            let probe = DocumentFlowProbe(), controller = ready(probe)
            await controller.waitUntilSettled()
            controller.send(.capture)
            await controller.waitUntilSettled()
            probe.failedStep = failure
            let raw = "SYNTHETIC RAW\u{001e}LIVE\r\nPDF417"
            probe.cameras[1].livePDF417?(raw)
            await controller.waitUntilSettled()
            XCTAssertEqual(controller.phase, .review)
            XCTAssertNil(controller.failure)
            XCTAssertNotNil(controller.front?.prepared)
            let back = try XCTUnwrap(controller.back)
            XCTAssertNil(back.prepared)
            XCTAssertEqual(back.reading.barcodeOrigin, .admittedLiveMetadata)
            XCTAssertEqual(back.reading.pdf417Payloads, [raw])
            XCTAssertEqual(back.reading.sourceSHA256, back.source.sha256)
            XCTAssertTrue(back.reading.recognizedText.isEmpty)
            XCTAssertTrue(back.reading.parsedPDF417.isEmpty)
            XCTAssertNil(back.reading.licenseFront)
            XCTAssertTrue(back.portraits.isEmpty)
            XCTAssertEqual(probe.prepared, [.front])
            XCTAssertEqual(probe.extracted, [.front])
            XCTAssertEqual(probe.portraitCalls, 1)
        }
    }

    private func ready(_ probe: DocumentFlowProbe) -> DocumentFlowController {
        let controller = DocumentFlowController(ports: probe.ports)
        controller.setForeground(true); controller.send(.visible); controller.send(.start)
        return controller
    }
    private func eventually(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Synthetic asynchronous port did not reach its checkpoint")
    }
}

/// Unit-test byte identity; production adapters supply their SHA-256 implementation.
@MainActor private func digest(_ data: Data) -> String { data.base64EncodedString() }

@MainActor private final class LegacyDocumentCameraProbe: DocumentFlowCamera {
    var captures = 0
    func start() async throws {}
    func stop() async throws {}
    func capture(side: DocumentSide) async throws -> DocumentFlowSource {
        captures += 1
        throw DocumentProbeError.unavailable
    }
}
