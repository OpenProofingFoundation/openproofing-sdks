import CoreGraphics
import ImageIO
@testable import BiometricCapture
import XCTest
@testable import KenshikiReference

@MainActor private final class FakeCaptureDriver: BiometricCaptureDriver {
    var onState: ((CaptureDriverState) -> Void)?
    var onReadiness: ((SelfieAdmissionGate.Readiness) -> Void)?
    var onCapture: ((CapturedSelfie) -> Void)?
    var viewports: [CaptureViewport] = []
    var effects: [String] = []
    var grants: [SelfieCaptureConsent] = []
    var activations: [Bool] = []
    var stops = 0
    var captures = 0
    var retries = 0
    var retryAllowed = false
    var onViewport: (() -> Void)?
    var onGrant: ((SelfieCaptureConsent) -> Void)?
    func setConsent(_ consent: SelfieCaptureConsent) { grants.append(consent); onGrant?(consent) }
    func setActive(_ active: Bool) { activations.append(active); effects.append(active ? "active" : "inactive") }
    func stop() { stops += 1 }
    func capture() { captures += 1 }
    func retry() -> Bool { retries += 1; return retryAllowed }
    func updateViewport(_ viewport: CaptureViewport) { viewports.append(viewport); effects.append("viewport"); onViewport?() }
}

private actor CaptureDecodeCounter {
    private(set) var calls = 0
    func record() { calls += 1 }
}

private actor SuspendedCaptureDecode {
    private(set) var entered = false
    private var continuation: CheckedContinuation<SelfiePixelSnapshot, Never>?
    func run() async -> SelfiePixelSnapshot {
        entered = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ snapshot: SelfiePixelSnapshot) { continuation?.resume(returning: snapshot); continuation = nil }
}

@MainActor private final class CaptureCommitGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func save() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

final class BiometricCaptureControllerTests: XCTestCase {
    @MainActor func testConsentAndVisibilityPrecedeDriverConstruction() {
        let driver = FakeCaptureDriver()
        var created = 0
        let controller = BiometricCaptureController { created += 1; return driver }
        controller.send(.allow)
        XCTAssertEqual(created, 0)
        controller.send(.visible)
        XCTAssertEqual(created, 0)
        controller.send(.allow)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(driver.grants, [.permitted])
        XCTAssertEqual(driver.activations, [false])
        controller.send(.viewport(.init(size: CGSize(width: 100, height: 100), orientation: .portrait, guideOval: CGRect(x: 10, y: 10, width: 80, height: 80))))
        XCTAssertEqual(driver.activations, [false, true])
        controller.send(.allow)
        XCTAssertEqual(created, 1)
    }

    @MainActor func testViewportIsValidatedCachedAndDeliveredBeforeActivation() {
        let driver = FakeCaptureDriver()
        let controller = BiometricCaptureController { driver }
        let initial = CaptureViewport(size: CGSize(width: 100, height: 100), orientation: .portrait,
            guideOval: CGRect(x: 10, y: 10, width: 80, height: 80))
        controller.send(.viewport(.init(size: .zero, orientation: .portrait, guideOval: .zero)))
        controller.send(.viewport(initial))
        controller.send(.visible)
        controller.send(.allow)
        XCTAssertEqual(driver.viewports, [initial])
        XCTAssertEqual(driver.activations, [true])
        XCTAssertEqual(driver.effects, ["viewport", "active"])
        let rotated = CaptureViewport(size: CGSize(width: 200, height: 100), orientation: .landscapeLeft,
            guideOval: CGRect(x: 70, y: 10, width: 60, height: 80))
        controller.send(.viewport(rotated))
        XCTAssertEqual(driver.viewports, [initial, rotated])
        controller.send(.viewport(.init(size: CGSize(width: 100, height: 100), orientation: .portrait,
            guideOval: CGRect(x: -1, y: 0, width: 20, height: 20))))
        XCTAssertEqual(driver.viewports, [initial, rotated])
        let effectCount = driver.effects.count
        controller.send(.viewport(rotated))
        controller.send(.visible)
        controller.setForeground(true)
        XCTAssertEqual(driver.effects.count, effectCount)
        var renders = 0
        controller.onChange = { renders += 1 }
        driver.onState?(.running)
        driver.onState?(.running)
        XCTAssertEqual(renders, 0)
    }

    @MainActor func testShutterRequiresCurrentAdmissionReadiness() {
        let driver = FakeCaptureDriver()
        let controller = BiometricCaptureController { driver }
        controller.send(.visible)
        controller.send(.allow)
        controller.send(.shutter)
        XCTAssertEqual(driver.captures, 0)
        driver.onReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
        controller.send(.shutter)
        XCTAssertEqual(driver.captures, 1)
        driver.onReadiness?(.init(trackingObserved: true, captureReady: false, blinkPhase: .reopened, refusal: .depthStale))
        controller.send(.shutter)
        XCTAssertEqual(driver.captures, 1)
    }

    @MainActor func testWithdrawalInvalidatesLateCallbacksBeforeRelease() {
        let driver = FakeCaptureDriver()
        let controller = BiometricCaptureController { driver }
        controller.send(.visible)
        controller.send(.allow)
        let lateState = driver.onState
        let lateReadiness = driver.onReadiness
        controller.backgrounded()
        XCTAssertEqual(driver.grants, [.permitted, .withheld])
        XCTAssertEqual(driver.stops, 1)
        XCTAssertNil(driver.onState)
        XCTAssertNil(driver.onReadiness)
        XCTAssertNil(driver.onCapture)
        lateState?(.failed(.init(reason: .frameworkFailure)))
        lateReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
        XCTAssertEqual(controller.phase, .consent)
        controller.send(.shutter)
        XCTAssertEqual(driver.captures, 0)
        XCTAssertNil(controller.snapshot)
    }

    @MainActor func testCancelledControllerCannotReopenOrDeliverLateFailure() {
        let driver = FakeCaptureDriver()
        let controller = BiometricCaptureController { driver }
        controller.send(.visible)
        controller.send(.allow)
        let lateState = driver.onState
        var closes = 0
        controller.onClose = { closes += 1; controller.send(.allow) }
        controller.send(.cancel)
        lateState?(.failed(.init(reason: .cameraPermissionDenied)))
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(driver.grants, [.permitted, .withheld])
    }

    @MainActor func testFailureReasonsMapToScopedLocalizableStates() {
        let cases: [(SelfieCameraFailure.Reason, String)] = [
            (.unavailable, "capture.failure.unsupported"),
            (.frameSnapshotFailed, "capture.failure.image"),
            (.cameraPermissionDenied, "capture.failure.denied"),
            (.cameraPermissionRestricted, "capture.failure.restricted"),
            (.depthUnavailable, "capture.failure.depth"),
            (.analysisTimedOut, "capture.failure.timeout"),
            (.renderingTimedOut, "capture.failure.timeout"),
            (.noFrames, "capture.failure.timeout"),
            (.frameworkFailure, "capture.failure.camera"),
            (.sensorInputFailed, "capture.failure.camera"),
            (.invalidConfiguration, "capture.failure.camera"),
            (.analysisFailed, "capture.failure.camera"),
            (.renderingFailed, "capture.failure.camera")
        ]
        for (reason, key) in cases {
            let driver = FakeCaptureDriver()
            let controller = BiometricCaptureController { driver }
            controller.send(.visible)
            controller.send(.allow)
            driver.onState?(.failed(.init(reason: reason)))
            XCTAssertEqual(controller.phase, .failure(key))
            controller.send(.shutter)
            XCTAssertEqual(driver.captures, 0)
        }
    }

    @MainActor func testRetryPreservesSameDriverAndDoesNotAbandonOccupiedWorker() {
        let driver = FakeCaptureDriver()
        var created = 0
        let controller = BiometricCaptureController { created += 1; return driver }
        controller.send(.visible)
        controller.send(.allow)
        driver.onState?(.failed(.init(reason: .analysisTimedOut)))
        controller.send(.retry)
        XCTAssertEqual(controller.phase, .failure("capture.failure.camera"))
        XCTAssertEqual(driver.retries, 1)
        XCTAssertEqual(created, 1)
        driver.retryAllowed = true
        controller.send(.retry)
        XCTAssertEqual(controller.phase, .capturing)
        XCTAssertEqual(driver.retries, 2)
        XCTAssertEqual(created, 1)
    }

    @MainActor func testHiddenAndForegroundStateCannotGrantAcquisition() {
        let driver = FakeCaptureDriver()
        var created = 0
        let controller = BiometricCaptureController { created += 1; return driver }
        controller.send(.visible)
        controller.setForeground(false)
        controller.send(.allow)
        XCTAssertEqual(created, 0)
        controller.setForeground(true)
        controller.send(.allow)
        controller.send(.hidden)
        controller.setForeground(true)
        XCTAssertEqual(controller.phase, .consent)
        controller.send(.allow)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(driver.grants, [.permitted, .withheld])
    }
    @MainActor func testReentrantCancellationAtFactoryRenderViewportAndGrantNeverReactivatesDriver() {
        for boundary in ["factory", "render", "viewport", "grant"] {
            let driver = FakeCaptureDriver()
            var controller: BiometricCaptureController!
            controller = BiometricCaptureController(makeDriver: {
                if boundary == "factory" { controller.send(.cancel) }
                return driver
            })
            controller.send(.viewport(.init(size: CGSize(width: 100, height: 100), orientation: .portrait,
                guideOval: CGRect(x: 10, y: 10, width: 80, height: 80))))
            if boundary == "render" {
                controller.onChange = { if controller.phase == .capturing { controller.send(.cancel) } }
            }
            if boundary == "viewport" { driver.onViewport = { controller.send(.cancel) } }
            if boundary == "grant" {
                driver.onGrant = { if $0 == .permitted { controller.send(.cancel) } }
            }
            controller.send(.visible)
            controller.send(.allow)
            XCTAssertEqual(controller.phase, .finished, boundary)
            XCTAssertFalse(driver.activations.contains(true), boundary)
            XCTAssertEqual(driver.grants.last, .withheld, boundary)
            XCTAssertGreaterThanOrEqual(driver.stops, 1, boundary)
        }
    }

    @MainActor func testReentrantProcessingCancellationNeverStartsDecoder() async throws {
        let driver = FakeCaptureDriver()
        let counter = CaptureDecodeCounter()
        let controller = BiometricCaptureController(makeDriver: { driver }, decode: { capture in
            await counter.record()
            return try SelfiePixelBridge.decodeOrientedPNG(capture.encodedPNG, expectedSourceSHA256: capture.sha256)
        })
        controller.send(.visible)
        controller.send(.allow)
        controller.onChange = { if controller.phase == .processing { controller.send(.cancel) } }
        driver.onCapture?(try fixture())
        for _ in 0..<10 { await Task.yield() }
        let calls = await counter.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertNil(controller.capturedEvidence)
    }

    @MainActor func testReentrantRetryCancellationCannotRetryRetiredDriver() {
        let driver = FakeCaptureDriver()
        let controller = BiometricCaptureController(makeDriver: { driver })
        controller.send(.visible)
        controller.send(.allow)
        driver.onState?(.failed(.init(reason: .analysisTimedOut)))
        controller.onChange = { if controller.phase == .capturing { controller.send(.cancel) } }
        controller.send(.retry)
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertEqual(driver.retries, 0)
        XCTAssertNil(controller.snapshot)
    }

    @MainActor func testCapturedImageDecodesToOwnedPixelsAndRetakeClearsEvidence() async throws {
        let driver = FakeCaptureDriver()
        let controller = BiometricCaptureController(makeDriver: { driver })
        let capture = try fixture()
        controller.send(.visible)
        controller.send(.allow)
        driver.onCapture?(capture)
        try await waitUntil { controller.phase == .captured }
        XCTAssertEqual(controller.snapshot?.pixels.bytes, [8, 16, 32])
        XCTAssertEqual(controller.snapshot?.sourceEncodedSHA256, capture.sha256)
        XCTAssertNotEqual(controller.snapshot?.pixels.sha256, capture.sha256)
        XCTAssertEqual(controller.capturedEvidence?.id, capture.id)
        XCTAssertEqual(controller.capturedEvidence?.admissionReceipt, capture.admissionReceipt)
        XCTAssertEqual(driver.grants, [.permitted, .withheld])
        controller.send(.retry)
        XCTAssertEqual(controller.phase, .consent)
        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.capturedEvidence)
        XCTAssertNil(controller.capturedPNG)
    }

    @MainActor func testDecoderSourceSubstitutionFailsWithoutPublishingEvidence() async throws {
        let driver = FakeCaptureDriver()
        let capture = try fixture()
        let correct = try SelfiePixelBridge.decodeOrientedPNG(capture.encodedPNG, expectedSourceSHA256: capture.sha256)
        let substituted = SelfiePixelSnapshot(sourceEncodedSHA256: String(repeating: "0", count: 64),
            pixels: correct.pixels, derivationProfile: correct.derivationProfile, colorSpace: correct.colorSpace,
            alphaConversion: correct.alphaConversion, interpolation: correct.interpolation)
        let controller = BiometricCaptureController(makeDriver: { driver }, decode: { _ in substituted })
        controller.send(.visible)
        controller.send(.allow)
        driver.onCapture?(capture)
        try await waitUntil { controller.phase == .failure("capture.failure.image") }
        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.capturedEvidence)
        var deliveries = 0
        controller.onAccepted = { _ in deliveries += 1 }
        controller.send(.useSelfie)
        XCTAssertEqual(deliveries, 0)
        controller.send(.retry)
        XCTAssertEqual(controller.phase, .consent)
    }

    @MainActor func testCancellationRejectsSuspendedDecodeCompletion() async throws {
        try await assertRetiredDecodeIsRejected(background: false)
    }

    @MainActor func testBackgroundRejectsSuspendedDecodeCompletion() async throws {
        try await assertRetiredDecodeIsRejected(background: true)
    }

    @MainActor func testDuplicateAndRetiredCaptureCallbacksCannotReplaceOwnedEvidence() async throws {
        let driver = FakeCaptureDriver()
        let controller = BiometricCaptureController(makeDriver: { driver })
        controller.send(.visible)
        controller.send(.allow)
        let callback = try XCTUnwrap(driver.onCapture)
        let first = try fixture()
        let replacement = try fixture()
        callback(first)
        callback(replacement)
        try await waitUntil { controller.phase == .captured }
        XCTAssertEqual(controller.capturedEvidence?.id, first.id)
        controller.send(.retry)
        callback(replacement)
        XCTAssertEqual(controller.phase, .consent)
        XCTAssertNil(controller.capturedEvidence)
    }

    @MainActor func testUseSelfieTransfersExactBoundBundleOnceAfterTerminalRelease() async throws {
        let driver = FakeCaptureDriver()
        let controller = BiometricCaptureController(makeDriver: { driver })
        let capture = try fixture()
        var delivered: AcceptedSelfie?
        var deliveries = 0
        var closes = 0
        controller.onClose = { closes += 1 }
        controller.onAccepted = { accepted in
            deliveries += 1
            XCTAssertEqual(controller.phase, .finished)
            XCTAssertNil(controller.snapshot)
            XCTAssertNil(controller.capturedEvidence)
            XCTAssertNil(controller.capturedPNG)
            XCTAssertNil(driver.onCapture)
            XCTAssertEqual(driver.grants.last, .withheld)
            delivered = accepted
            controller.send(.useSelfie)
            controller.send(.cancel)
            controller.send(.retry)
            controller.send(.allow)
        }
        controller.send(.useSelfie)
        controller.send(.visible)
        controller.send(.allow)
        controller.send(.useSelfie)
        driver.onCapture?(capture)
        try await waitUntil { controller.phase == .captured }
        controller.onChange = { if controller.phase == .finished { controller.send(.useSelfie) } }
        controller.send(.useSelfie)
        controller.send(.useSelfie)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(closes, 0)
        let accepted = try XCTUnwrap(delivered)
        XCTAssertEqual(accepted.capture.id, capture.id)
        XCTAssertEqual(accepted.capture.encodedPNG, capture.encodedPNG)
        XCTAssertEqual(accepted.capture.admissionReceipt, capture.admissionReceipt)
        XCTAssertEqual(accepted.snapshot.sourceEncodedSHA256, capture.sha256)
        XCTAssertEqual(accepted.snapshot.pixels.bytes, [8, 16, 32])
        XCTAssertNotEqual(accepted.snapshot.pixels.sha256, capture.sha256)
        delivered = nil
        XCTAssertNil(delivered)
    }

    @MainActor func testCapturedReviewWithdrawalAndRetakeCannotDeliverOldBundle() async throws {
        for interruption in ["hidden", "background", "retake", "cancel"] {
            let driver = FakeCaptureDriver()
            let controller = BiometricCaptureController(makeDriver: { driver })
            var deliveries = 0
            controller.onAccepted = { _ in deliveries += 1 }
            controller.send(.visible)
            controller.send(.allow)
            let staleCapture = try XCTUnwrap(driver.onCapture)
            staleCapture(try fixture())
            try await waitUntil { controller.phase == .captured }
            switch interruption {
            case "hidden": controller.send(.hidden)
            case "background": controller.setForeground(false)
            case "retake": controller.send(.retry)
            default: controller.send(.cancel)
            }
            controller.send(.useSelfie)
            controller.send(.visible)
            controller.setForeground(true)
            staleCapture(try fixture())
            controller.send(.useSelfie)
            XCTAssertEqual(deliveries, 0, interruption)
            XCTAssertNil(controller.snapshot, interruption)
            XCTAssertNil(controller.capturedEvidence, interruption)
        }
    }

    @MainActor func testInactiveForegroundRevokesReadyShutterAndLateAcquisition() throws {
        let driver = FakeCaptureDriver()
        let controller = BiometricCaptureController(makeDriver: { driver })
        controller.send(.visible)
        controller.send(.allow)
        let staleCapture = try XCTUnwrap(driver.onCapture)
        let staleReady = try XCTUnwrap(driver.onReadiness)
        staleReady(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
        controller.setForeground(false)
        staleReady(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
        staleCapture(try fixture())
        controller.send(.shutter)
        XCTAssertEqual(controller.phase, .consent)
        XCTAssertFalse(controller.shutterEnabled)
        XCTAssertNil(controller.capturedEvidence)
        XCTAssertEqual(driver.captures, 0)
        XCTAssertEqual(driver.grants.last, .withheld)
        XCTAssertEqual(driver.stops, 1)
    }

    @MainActor func testReviewRotationPreservesAcceptedSourceAndPixels() async throws {
        let driver = FakeCaptureDriver()
        let controller = BiometricCaptureController(makeDriver: { driver })
        var delivered: AcceptedSelfie?
        controller.onAccepted = { delivered = $0 }
        controller.send(.visible)
        controller.send(.allow)
        let capture = try fixture()
        driver.onCapture?(capture)
        try await waitUntil { controller.phase == .captured }
        let pixelDigest = try XCTUnwrap(controller.snapshot?.pixels.sha256)
        controller.send(.viewport(.init(size: CGSize(width: 200, height: 100), orientation: .landscapeRight,
            guideOval: CGRect(x: 70, y: 10, width: 60, height: 80))))
        controller.send(.useSelfie)
        XCTAssertEqual(delivered?.capture.id, capture.id)
        XCTAssertEqual(delivered?.snapshot.pixels.sha256, pixelDigest)
        XCTAssertEqual(delivered?.snapshot.sourceEncodedSHA256, capture.sha256)
    }

    @MainActor func testReentrantConsentWithdrawalCannotOverwriteCancellation() {
        for trigger in ["cancel", "hidden", "background"] {
            let driver = FakeCaptureDriver()
            let controller = BiometricCaptureController(makeDriver: { driver })
            controller.send(.visible)
            controller.send(.allow)
            var closes = 0
            controller.onClose = { closes += 1 }
            driver.onGrant = { if $0 == .withheld { controller.send(.cancel) } }
            switch trigger {
            case "hidden": controller.send(.hidden)
            case "background": controller.setForeground(false)
            default: controller.send(.cancel)
            }
            XCTAssertEqual(controller.phase, .finished, trigger)
            XCTAssertEqual(closes, 1, trigger)
            XCTAssertEqual(driver.stops, 1, trigger)
            XCTAssertNil(controller.capturedEvidence, trigger)
        }
    }

    @MainActor func testTerminalRenderWithdrawalCannotDeliverAcceptedSelfie() async throws {
        for interruption in ["hidden", "background"] {
            let driver = FakeCaptureDriver()
            let controller = BiometricCaptureController(makeDriver: { driver })
            var deliveries = 0
            controller.onAccepted = { _ in deliveries += 1 }
            controller.send(.visible)
            controller.send(.allow)
            driver.onCapture?(try fixture())
            try await waitUntil { controller.phase == .captured }
            controller.onChange = {
                guard controller.phase == .finished else { return }
                if interruption == "hidden" { controller.send(.hidden) }
                else { controller.setForeground(false) }
            }
            controller.send(.useSelfie)
            controller.send(.useSelfie)
            XCTAssertEqual(deliveries, 0, interruption)
            XCTAssertEqual(controller.phase, .finished, interruption)
            XCTAssertNil(controller.snapshot, interruption)
            XCTAssertNil(controller.capturedEvidence, interruption)
        }
    }

    @MainActor func testSelfieReviewWaitsForCommitAndDuplicateUseCannotEscape() async throws {
        let driver = FakeCaptureDriver()
        let gate = CaptureCommitGate()
        let controller = BiometricCaptureController(makeDriver: { driver })
        controller.persistCapturedSelfie = { _ in await gate.save() }
        var accepted = 0
        controller.onAccepted = { _ in accepted += 1 }
        controller.send(.visible)
        controller.send(.allow)
        driver.onCapture?(try fixture())
        try await waitUntil { gate.entered }
        XCTAssertEqual(controller.phase, .processing)
        controller.send(.useSelfie)
        controller.send(.useSelfie)
        XCTAssertEqual(accepted, 0)
        gate.finish()
        try await waitUntil { controller.phase == .captured }
        controller.send(.useSelfie)
        XCTAssertEqual(accepted, 1)
    }

    @MainActor func testFailedSelfieCommitRetriesSameImageWithoutReopeningCamera() async throws {
        let driver = FakeCaptureDriver()
        var creations = 0
        var ids: [UUID] = []
        let controller = BiometricCaptureController(makeDriver: { creations += 1; return driver })
        controller.persistCapturedSelfie = { value in
            ids.append(value.id)
            if ids.count == 1 { throw FaceWorkflowStorageFailure.unavailable }
        }
        let image = try fixture()
        controller.send(.visible)
        controller.send(.allow)
        driver.onCapture?(image)
        try await waitUntil { controller.phase == .failure("capture.failure.storage") }
        XCTAssertEqual(controller.capturedPNG, image.encodedPNG)
        controller.send(.retry)
        controller.send(.retry)
        try await waitUntil { controller.phase == .captured }
        XCTAssertEqual(ids, [image.id, image.id])
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(driver.retries, 0)
        XCTAssertEqual(driver.captures, 0)
    }

    @MainActor func testCancelledSelfieCommitCannotPublishReviewAfterWriteSettles() async throws {
        let driver = FakeCaptureDriver()
        let gate = CaptureCommitGate()
        let controller = BiometricCaptureController(makeDriver: { driver })
        controller.persistCapturedSelfie = { _ in await gate.save() }
        controller.send(.visible)
        controller.send(.allow)
        driver.onCapture?(try fixture())
        try await waitUntil { gate.entered }
        controller.send(.cancel)
        gate.finish()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertNil(controller.capturedEvidence)
        XCTAssertNil(controller.snapshot)
    }

    @MainActor private func assertRetiredDecodeIsRejected(background: Bool) async throws {
        let driver = FakeCaptureDriver()
        let gate = SuspendedCaptureDecode()
        let controller = BiometricCaptureController(makeDriver: { driver }, decode: { _ in await gate.run() })
        let capture = try fixture()
        let snapshot = try SelfiePixelBridge.decodeOrientedPNG(capture.encodedPNG, expectedSourceSHA256: capture.sha256)
        controller.send(.visible)
        controller.send(.allow)
        driver.onCapture?(capture)
        try await waitUntil { await gate.entered }
        XCTAssertEqual(controller.phase, .processing)
        if background { controller.backgrounded() } else { controller.send(.cancel) }
        await gate.finish(snapshot)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.phase, background ? .consent : .finished)
        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.capturedEvidence)
    }

    @MainActor private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let fulfilled = await condition()
        XCTAssertTrue(fulfilled)
    }

    private func fixture() throws -> CapturedSelfie { try CaptureTestFixtures.capture() }
}

enum CaptureTestFixtures {
    static func capture() throws -> CapturedSelfie {
        let provider = try XCTUnwrap(CGDataProvider(data: Data([8, 16, 32, 255]) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let receipt = SelfieAdmissionReceipt(policyVersion: SelfieAdmissionPolicy.version, trigger: .manual,
            frameTimestamp: 1, anchorID: UUID(), consecutiveTrackedFrames: 1, blinkCompletedAt: 0.5,
            blinkAge: 0.5, leftEyeClosed: 0, rightEyeClosed: 0, eyesOpen: true, steadyHoldDuration: 1,
            captureQuality: nil, captureQualityEnforced: false, insideGuide: true, guideContainmentEnforced: true)
        return CapturedSelfie(encodedPNG: Data(referencing: data), admissionReceipt: receipt)
    }

}
