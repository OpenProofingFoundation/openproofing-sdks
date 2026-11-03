@testable import BiometricCapture
@testable import KenshikiReference
import UIKit
import XCTest

@MainActor private final class HostCaptureDriver: BiometricCaptureDriver {
    var onState: ((CaptureDriverState) -> Void)?
    var onReadiness: ((SelfieAdmissionGate.Readiness) -> Void)?
    var onCapture: ((CapturedSelfie) -> Void)?
    private(set) var captures = 0
    func setConsent(_: SelfieCaptureConsent) { /* Supplied state drives this synthetic driver. */ }
    func setActive(_: Bool) { /* No hardware resources are acquired by this test double. */ }
    func stop() { /* No hardware resources are acquired by this test double. */ }
    func capture() { captures += 1 }
    func retry() -> Bool { false }
    func updateViewport(_: CaptureViewport) { /* Layout is supplied by the host under test. */ }
}

@MainActor private final class AnnouncementClock {
    var now: TimeInterval = 0
    var posted: [String] = []
    var pending: [() -> Void] = []
    var cancellations = 0
    var effects: CaptureAnnouncementEffects {
        CaptureAnnouncementEffects(now: { self.now }, schedule: { _, action in
            self.pending.append(action)
            return { self.cancellations += 1 }
        }, post: { self.posted.append($0) }, isVisible: { _ in true })
    }
    func advanceAndFire() {
        now += 3
        let callbacks = pending
        pending.removeAll()
        // Deliberately execute canceled callbacks too, proving the host's stale-message fence.
        callbacks.forEach { $0() }
    }
}

final class BiometricCaptureHostTests: XCTestCase {
    @MainActor func testReadinessKeepsButtonIdentityOrderAndSingleBinding() throws {
        let driver = HostCaptureDriver()
        let controller = BiometricCaptureController { driver }
        let clock = AnnouncementClock()
        let host = BiometricCaptureHost(controller: controller, announcementEffects: clock.effects)
        let renderer = host.makeRenderer()
        renderer.loadViewIfNeeded()
        controller.send(.visible)
        try button("capture.allow", in: renderer.view).sendActions(for: .touchUpInside)
        let shutter = try button("capture.shutter", in: renderer.view)
        let cancel = try button("capture.cancel", in: renderer.view)
        XCTAssertFalse(shutter.isEnabled)
        let constraintCount = shutter.constraints.count
        for _ in 0..<5 {
            driver.onReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
            driver.onReadiness?(.init(trackingObserved: true, captureReady: false, blinkPhase: .reopened, refusal: .depthStale))
        }
        driver.onReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
        XCTAssertTrue(shutter === (try button("capture.shutter", in: renderer.view)))
        XCTAssertTrue(cancel === (try button("capture.cancel", in: renderer.view)))
        XCTAssertFalse(shutter.isEnabled, "A brief ready pulse must not flash the shutter")
        clock.advanceAndFire()
        XCTAssertTrue(shutter.isEnabled)
        XCTAssertEqual(shutter.constraints.count, constraintCount)
        try assertActionOrder(["capture.shutter", "capture.cancel"], in: renderer.view)
        XCTAssertFalse(buttons(in: renderer.view).contains { $0.accessibilityIdentifier == "capture.use" })
        shutter.sendActions(for: .touchUpInside)
        XCTAssertEqual(driver.captures, 1)
    }

    @MainActor func testRapidReadinessCannotFlashShutterAndStaleTimersCannotReenableIt() throws {
        let driver = HostCaptureDriver()
        let controller = BiometricCaptureController { driver }
        let clock = AnnouncementClock()
        let host = BiometricCaptureHost(controller: controller, announcementEffects: clock.effects)
        let renderer = host.makeRenderer()
        renderer.loadViewIfNeeded()
        controller.send(.visible)
        try button("capture.allow", in: renderer.view).sendActions(for: .touchUpInside)
        let shutter = try button("capture.shutter", in: renderer.view)
        for _ in 0..<30 {
            driver.onReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
            driver.onReadiness?(.init(trackingObserved: true, captureReady: false, blinkPhase: .reopened, refusal: .depthStale))
            XCTAssertFalse(shutter.isEnabled)
            let message = try XCTUnwrap(descendants(in: renderer.view).first { $0.accessibilityIdentifier == "capture.message" } as? UILabel)
            XCTAssertNotEqual(message.text, KenshikiCopy.text("capture.guidance.ready"))
        }
        clock.advanceAndFire()
        XCTAssertFalse(shutter.isEnabled)
        driver.onReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
        XCTAssertFalse(shutter.isEnabled)
        clock.advanceAndFire()
        XCTAssertTrue(shutter.isEnabled)
        driver.onReadiness?(.init(trackingObserved: true, captureReady: false, blinkPhase: .reopened, refusal: .depthStale))
        XCTAssertFalse(shutter.isEnabled, "Refusal must revoke the button immediately")
        driver.onReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
        host.backgrounded()
        clock.advanceAndFire()
        XCTAssertFalse(shutter.isEnabled)
        XCTAssertEqual(driver.captures, 0)
    }

    @MainActor func testGuidanceChurnNeverReattachesOrMovesThePreview() throws {
        let preview = PreviewAttachmentProbe()
        let actions = UIStackView()
        let shutter = UIButton(type: .system)
        shutter.setTitle("Synthetic shutter", for: .normal)
        shutter.heightAnchor.constraint(greaterThanOrEqualToConstant: KenshikiDesign.minimumTargetIOS).isActive = true
        actions.addArrangedSubview(shutter)
        let variants = ["capture.guidance.ready", "capture.guidance.depth", "capture.guidance.center", "capture.guidance.blink"].map { KenshikiCopy.text($0) }
        func screen(_ message: String, live: Bool = true) -> BiometricCaptureScreen {
            .init(title: "Synthetic selfie", heading: "Synthetic capture", message: message, scope: "Synthetic scope",
                previewLabel: "Synthetic preview", imageLabel: "Synthetic image", preview: live ? preview : nil,
                image: nil, mediaHidden: !live, actionSurface: actions, messageVariants: variants)
        }
        let renderer = BiometricCaptureRenderer(screen: screen(variants[0]), emit: { _ in })
        let navigation = UINavigationController(rootViewController: renderer)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        renderer.view.layoutIfNeeded()
        window.layoutIfNeeded()
        let parent = try XCTUnwrap(preview.superview)
        let originalFrame = preview.convert(preview.bounds, to: renderer.view)
        XCTAssertGreaterThan(originalFrame.height, 0)
        let removals = preview.removals
        for _ in 0..<10 {
            for text in variants {
                renderer.apply(screen(text))
                renderer.view.setNeedsLayout()
                renderer.view.layoutIfNeeded()
                XCTAssertTrue(preview.superview === parent)
                XCTAssertEqual(preview.removals, removals)
                XCTAssertEqual(preview.convert(preview.bounds, to: renderer.view), originalFrame)
            }
        }
        renderer.apply(screen(variants[0], live: false))
        XCTAssertNil(preview.superview)
        XCTAssertEqual(preview.removals, removals + 1)
    }

    @MainActor func testReviewedUseHandsExactBundleOnceAndReleasesImage() async throws {
        let driver = HostCaptureDriver()
        let controller = BiometricCaptureController { driver }
        let host = BiometricCaptureHost(controller: controller)
        let renderer = host.makeRenderer()
        renderer.loadViewIfNeeded()
        controller.send(.visible)
        try button("capture.allow", in: renderer.view).sendActions(for: .touchUpInside)
        let cancel = try button("capture.cancel", in: renderer.view)
        let capture = try CaptureTestFixtures.capture()
        driver.onCapture?(capture)
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.phase == .processing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(controller.phase, .captured)
        try assertActionOrder(["capture.use", "capture.retake", "capture.cancel"], in: renderer.view)
        XCTAssertTrue(cancel === (try button("capture.cancel", in: renderer.view)))
        let pixelDigest = try XCTUnwrap(controller.snapshot?.pixels.sha256)
        var delivered: [AcceptedSelfie] = []
        host.onAccepted = { delivered.append($0) }
        let use = try button("capture.use", in: renderer.view)
        use.sendActions(for: .touchUpInside)
        use.sendActions(for: .touchUpInside)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.capture.id, capture.id)
        XCTAssertEqual(delivered.first?.capture.encodedPNG, capture.encodedPNG)
        XCTAssertEqual(delivered.first?.snapshot.pixels.sha256, pixelDigest)
        XCTAssertEqual(delivered.first?.snapshot.sourceEncodedSHA256, capture.sha256)
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.capturedEvidence)
        XCTAssertFalse(descendants(in: renderer.view).contains { $0.accessibilityIdentifier == "capture.image" })
    }

    @MainActor func testLatestReadinessAnnouncementArrivesWithoutAnotherRenderAndDoesNotFlood() throws {
        let driver = HostCaptureDriver()
        let controller = BiometricCaptureController { driver }
        let clock = AnnouncementClock()
        let host = BiometricCaptureHost(controller: controller, announcementEffects: clock.effects)
        let renderer = host.makeRenderer()
        renderer.loadViewIfNeeded()
        controller.send(.visible)
        try button("capture.allow", in: renderer.view).sendActions(for: .touchUpInside)
        let initialCount = clock.posted.count
        for _ in 0..<10 {
            driver.onReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
            driver.onReadiness?(.init(trackingObserved: true, captureReady: false, blinkPhase: .reopened, refusal: .depthStale))
        }
        driver.onReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
        XCTAssertEqual(clock.posted.count, initialCount)
        XCTAssertFalse(clock.pending.isEmpty)
        clock.advanceAndFire()
        XCTAssertEqual(clock.posted.count, initialCount + 1)
        XCTAssertEqual(clock.posted.last, KenshikiCopy.text("capture.guidance.ready"))
        driver.onReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
        clock.advanceAndFire()
        XCTAssertEqual(clock.posted.count, initialCount + 1)
        XCTAssertGreaterThan(clock.cancellations, 0)
    }

    @MainActor func testPendingAnnouncementsCannotSurviveHiddenForegroundBackgroundOrCancel() throws {
        for interruption in ["hidden", "foreground", "background", "cancel"] {
            let driver = HostCaptureDriver()
            let controller = BiometricCaptureController { driver }
            let clock = AnnouncementClock()
            let host = BiometricCaptureHost(controller: controller, announcementEffects: clock.effects)
            let renderer = host.makeRenderer()
            renderer.loadViewIfNeeded()
            controller.send(.visible)
            try button("capture.allow", in: renderer.view).sendActions(for: .touchUpInside)
            driver.onReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
            XCTAssertFalse(clock.pending.isEmpty, interruption)
            switch interruption {
            case "hidden":
                renderer.beginAppearanceTransition(false, animated: false)
                renderer.endAppearanceTransition()
            case "foreground": host.setForeground(false)
            case "background": host.backgrounded()
            default: try button("capture.cancel", in: renderer.view).sendActions(for: .touchUpInside)
            }
            let countAfterInterruption = clock.posted.count
            clock.advanceAndFire()
            XCTAssertEqual(clock.posted.count, countAfterInterruption, interruption)
            XCTAssertGreaterThan(clock.cancellations, 0, interruption)
        }
    }

    @MainActor func testPhaseChangeAndUseInvalidateDeferredGuidance() async throws {
        let driver = HostCaptureDriver()
        let controller = BiometricCaptureController { driver }
        let clock = AnnouncementClock()
        let host = BiometricCaptureHost(controller: controller, announcementEffects: clock.effects)
        let renderer = host.makeRenderer()
        renderer.loadViewIfNeeded()
        controller.send(.visible)
        try button("capture.allow", in: renderer.view).sendActions(for: .touchUpInside)
        driver.onReadiness?(.init(trackingObserved: true, captureReady: true, blinkPhase: .reopened, refusal: nil))
        XCTAssertFalse(clock.pending.isEmpty)
        driver.onCapture?(try CaptureTestFixtures.capture())
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.phase == .processing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(controller.phase, .captured)
        try button("capture.use", in: renderer.view).sendActions(for: .touchUpInside)
        let countAfterUse = clock.posted.count
        clock.advanceAndFire()
        XCTAssertEqual(clock.posted.count, countAfterUse)
        XCTAssertFalse(clock.posted.contains(KenshikiCopy.text("capture.guidance.ready")))
        XCTAssertEqual(controller.phase, .finished)
    }

    @MainActor func testBiometricRootRequiresReferenceAndHasNoAcceptedSelfieDeadEnd() throws {
        let initial = ApplicationHost().biometricScreen()
        XCTAssertEqual(initial.heading, KenshikiCopy.text("comparison.reference.required"))
        XCTAssertEqual(initial.primaryActions.map(\.identifier), ["passport.reference.open"])
        let reference = try XCTUnwrap(initial.primaryActions.first)
        guard case .passportReference = reference.event else {
            return XCTFail("Reference action must open the live passport journey")
        }
        XCTAssertFalse(initial.paragraphs.contains { $0.identifier == "capture.accepted.body" })
        XCTAssertTrue(initial.paragraphs.contains { $0.identifier == "comparison.scope" })
    }

    @MainActor private func assertActionOrder(_ expected: [String], in view: UIView) throws {
        let first = try button(try XCTUnwrap(expected.first), in: view)
        let surface = try XCTUnwrap(first.superview as? UIStackView)
        XCTAssertEqual(surface.axis, .vertical)
        XCTAssertEqual(surface.arrangedSubviews.compactMap(\.accessibilityIdentifier), expected)
        let readingOrder = try XCTUnwrap(surface.accessibilityElements as? [UIView])
        XCTAssertEqual(readingOrder.compactMap(\.accessibilityIdentifier), expected)
        XCTAssertEqual(readingOrder.count, surface.arrangedSubviews.count)
        for (spoken, visual) in zip(readingOrder, surface.arrangedSubviews) {
            XCTAssertTrue(spoken === visual)
        }
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        for (upper, lower) in zip(surface.arrangedSubviews, surface.arrangedSubviews.dropFirst()) {
            XCTAssertGreaterThanOrEqual(upper.bounds.height, KenshikiDesign.minimumTargetIOS)
            XCTAssertLessThanOrEqual(upper.frame.maxY, lower.frame.minY)
        }
    }

    @MainActor private func button(_ identifier: String, in view: UIView) throws -> UIButton {
        try XCTUnwrap(buttons(in: view).first { $0.accessibilityIdentifier == identifier })
    }

    @MainActor private func buttons(in view: UIView) -> [UIButton] {
        descendants(in: view).compactMap { $0 as? UIButton }
    }

    @MainActor private func descendants(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }
}

@MainActor private final class PreviewAttachmentProbe: UIView {
    private(set) var removals = 0
    override func willMove(toSuperview newSuperview: UIView?) {
        if superview != nil && newSuperview == nil { removals += 1 }
        super.willMove(toSuperview: newSuperview)
    }
}
