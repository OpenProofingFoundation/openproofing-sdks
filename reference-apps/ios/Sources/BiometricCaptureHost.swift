import BiometricCapture
import BiometricCapturePreview
import UIKit

@MainActor struct CaptureAnnouncementEffects {
    let now: () -> TimeInterval
    let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void)
    let post: (String) -> Void
    let isVisible: (UIView?) -> Bool

    static var native: Self {
        Self(now: { ProcessInfo.processInfo.systemUptime }, schedule: { delay, action in
            let task = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard !Task.isCancelled else { return }
                action()
            }
            return { task.cancel() }
        }, post: { UIAccessibility.post(notification: .announcement, argument: $0) },
        isVisible: { $0?.window != nil })
    }
}

/// Native effects and resource binding only. Workflow decisions remain in the plain controller.
@MainActor final class BiometricCaptureHost {
    let controller: BiometricCaptureController
    var useSelfieKey = "capture.use"
    var titleKey = "capture.live.title"
    var scopeKey = "capture.scope"
    private var selectionScopeKey: String?
    var evidenceStatusKey: String? { didSet { if oldValue != evidenceStatusKey { render() } } }
    var onClose: (() -> Void)?
    var onAccepted: ((AcceptedSelfie) -> Void)?
    private var announcedPhase: BiometricCaptureController.Phase?
    private var announcedMessage: String?
    private let announcementEffects: CaptureAnnouncementEffects
    private var cancelAnnouncement: (() -> Void)?
    private var pendingAnnouncementID: UUID?
    private var foreground = true
    private var presented = true
    private var lastAnnouncementAt: TimeInterval = -.infinity
    private var displayedPhase: BiometricCaptureController.Phase?
    private var displayedMessageKey: String?
    private var pendingGuidanceKey: String?
    private var pendingGuidanceID: UUID?
    private var cancelGuidance: (() -> Void)?
    private let guidanceSettlement: TimeInterval = 0.25
    private let actionSurface = UIStackView()
    private var buttonsByIdentifier: [String: UIButton] = [:]
    private var driver: NativeBiometricCaptureDriver?
    private var renderer: BiometricCaptureRenderer?

    convenience init() {
        // The factory holder avoids constructing a camera before the holder's Allow intent.
        let factory = NativeCaptureFactory()
        self.init(controller: BiometricCaptureController { factory.create() })
        factory.onCreate = { [weak self] driver in self?.driver = driver }
        selectionScopeKey = "capture.selection.scope"
        let qualityDirectory = Bundle.main.url(forResource: "FaceQuality", withExtension: nil)
        let modelURL = Bundle.main.url(forResource: "AuraFace", withExtension: "onnx")
        controller.selectCaptureWindow = { captures, progress in
            let selected = try await FaceCaptureSelectionProcessor.run(captures, qualityDirectory: qualityDirectory, modelURL: modelURL, progress: progress)
            return AcceptedSelfie(capture: selected.capture, snapshot: selected.snapshot, selection: selected.record, preparedSelfie: selected.prepared)
        }
    }

    init(controller: BiometricCaptureController, announcementEffects: CaptureAnnouncementEffects = .native) {
        self.controller = controller
        self.announcementEffects = announcementEffects
        actionSurface.axis = .vertical
        actionSurface.spacing = KenshikiDesign.gapSpacing
        controller.onAccepted = { [weak self] selfie in self?.onAccepted?(selfie) }
        controller.onClose = { [weak self] in self?.onClose?() }
        controller.onChange = { [weak self] in self?.render() }
    }

    func makeRenderer() -> BiometricCaptureRenderer {
        let view = BiometricCaptureRenderer(screen: screen(), emit: { [weak self] in self?.send($0) })
        renderer = view
        return view
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if !active { cancelPendingAnnouncement(); cancelPendingGuidance() }
        controller.setForeground(active)
    }
    func backgrounded() {
        foreground = false
        cancelPendingAnnouncement()
        cancelPendingGuidance()
        controller.backgrounded()
    }

    private func send(_ intent: BiometricCaptureViewIntent) {
        switch intent {
        case .action(.hidden):
            presented = false
            cancelPendingAnnouncement()
            cancelPendingGuidance()
            controller.send(.hidden)
        case .action(.visible):
            presented = true
            controller.send(.visible)
            render()
        case .action(let action): controller.send(action)
        case .viewport(let size, let orientation):
            let width = size.width * CGFloat(KenshikiDesign.selfieGuideWidthPercent) / 100
            let height = width * CGFloat(KenshikiDesign.selfieGuideHeightPercent) / 100
            let oval = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
            controller.send(.viewport(.init(size: size, orientation: orientation.captureOrientation, guideOval: oval)))
            renderer?.applyGuide(oval)
        }
    }

    private func render() {
        switch controller.phase {
        case .capturing, .failure: break
        default: driver = nil
        }
        prepareDisplayedGuidance()
        renderer?.apply(screen())
        cancelPendingAnnouncement()
        guard foreground, presented, controller.phase != .finished,
              announcementEffects.isVisible(renderer?.viewIfLoaded) else { return }
        let phaseChanged = announcedPhase != controller.phase
        if phaseChanged {
            announcedPhase = controller.phase
            UIAccessibility.post(notification: .layoutChanged, argument: renderer?.headingElement)
        }
        let key = displayedMessageKey ?? controller.messageKey
        guard announcedMessage != key else { return }
        let delay = max(0, 3 - (announcementEffects.now() - lastAnnouncementAt))
        if phaseChanged || delay == 0 {
            announce(key)
            return
        }
        let pendingID = UUID()
        pendingAnnouncementID = pendingID
        let phase = controller.phase
        cancelAnnouncement = announcementEffects.schedule(delay) { [weak self] in
            guard let self, self.pendingAnnouncementID == pendingID,
                  self.foreground, self.presented, self.controller.phase == phase,
                  self.displayedMessageKey == key,
                  self.announcementEffects.isVisible(self.renderer?.viewIfLoaded) else { return }
            self.pendingAnnouncementID = nil
            self.cancelAnnouncement = nil
            self.announce(key)
        }
    }

    private func announce(_ key: String) {
        lastAnnouncementAt = announcementEffects.now()
        announcedMessage = key
        announcementEffects.post(copy(key))
    }

    private func cancelPendingAnnouncement() {
        pendingAnnouncementID = nil
        let cancel = cancelAnnouncement
        cancelAnnouncement = nil
        cancel?()
    }

    private func prepareDisplayedGuidance() {
        let key = controller.messageKey
        guard displayedPhase == controller.phase, controller.phase == .capturing,
              key != "capture.starting", key != "capture.permission" else {
            cancelPendingGuidance()
            displayedPhase = controller.phase
            displayedMessageKey = key
            return
        }
        if displayedMessageKey == key { cancelPendingGuidance(); return }
        guard pendingGuidanceKey != key else { return }
        cancelPendingGuidance()
        if displayedMessageKey == "capture.guidance.ready" || displayedMessageKey == "capture.starting" || displayedMessageKey == "capture.permission" {
            displayedMessageKey = "capture.guidance.center"
        }
        let id = UUID()
        pendingGuidanceKey = key
        pendingGuidanceID = id
        cancelGuidance = announcementEffects.schedule(guidanceSettlement) { [weak self] in
            guard let self, self.pendingGuidanceID == id, self.foreground, self.presented,
                  self.controller.phase == .capturing, self.controller.messageKey == key,
                  self.announcementEffects.isVisible(self.renderer?.viewIfLoaded) else { return }
            self.pendingGuidanceKey = nil
            self.pendingGuidanceID = nil
            self.cancelGuidance = nil
            self.displayedMessageKey = key
            self.render()
        }
    }

    private func cancelPendingGuidance() {
        pendingGuidanceID = nil
        pendingGuidanceKey = nil
        let cancel = cancelGuidance
        cancelGuidance = nil
        cancel?()
    }

    private func screen() -> BiometricCaptureScreen {
        let heading: String
        var actions: [PreparedCaptureAction] = []
        switch controller.phase {
        case .consent:
            heading = "capture.consent.title"
            actions.append(action("capture.allow", .allow))
        case .capturing:
            heading = "capture.live.title"
            actions.append(action("capture.shutter", .shutter,
                enabled: controller.shutterEnabled && pendingGuidanceKey == nil))
        case .processing: heading = "capture.processing"
        case .captured:
            heading = "capture.complete.title"
            actions.append(action(useSelfieKey, .useSelfie))
            actions.append(action("capture.retake", .retry, primary: false))
        case .failure:
            heading = "capture.failure.title"
            actions.append(action("capture.retry", .retry))
        case .finished: heading = "capture.live.title"
        }
        actions.append(action("capture.cancel", .cancel, primary: false))
        reconcile(actions)
        let image = controller.capturedPNG.flatMap { UIImage(data: $0) }
        return BiometricCaptureScreen(title: copy(titleKey), heading: copy(heading),
            message: preparedMessage(), scope: copy(scopeKey) + (selectionScopeKey.map { "\n" + copy($0) } ?? "") + (evidenceStatusKey.map { "\n" + copy($0) } ?? ""),
            previewLabel: copy("capture.preview.label"), imageLabel: copy("capture.image.label"),
            preview: controller.phase == .capturing ? driver?.preview : nil,
            image: image, mediaHidden: controller.phase != .capturing && image == nil, actionSurface: actionSurface,
            messageVariants: controller.phase == .capturing ? ["capture.starting", "capture.permission",
                "capture.guidance.center", "capture.guidance.single", "capture.guidance.blink", "capture.guidance.hold",
                "capture.guidance.quality", "capture.guidance.depth", "capture.guidance.ready"].map(copy) : [])
    }

    private func preparedMessage() -> String {
        let message = copy(displayedMessageKey ?? controller.messageKey)
        guard let progress = controller.selectionProgress else { return message }
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        let completed = formatter.string(from: NSNumber(value: progress.completed)) ?? String(progress.completed)
        let total = formatter.string(from: NSNumber(value: progress.total)) ?? String(progress.total)
        return message + " " + completed + copy("capture.selection.progressSeparator") + total
    }

    private func reconcile(_ actions: [PreparedCaptureAction]) {
        let identifiers = Set(actions.map(\.identifier))
        for (identifier, button) in buttonsByIdentifier where !identifiers.contains(identifier) {
            button.removeFromSuperview()
            buttonsByIdentifier.removeValue(forKey: identifier)
        }
        for (index, action) in actions.enumerated() {
            let existing = buttonsByIdentifier[action.identifier]
            let button = existing ?? MultilineActionButton(type: .system)
            if existing == nil || button.configuration?.title != action.title {
                var configuration = action.primary ? KenshikiIOSDesign.primaryConfiguration() : KenshikiIOSDesign.secondaryConfiguration()
                configuration.title = action.title
                configuration.buttonSize = .large
                configuration.titleLineBreakMode = .byWordWrapping
                button.configuration = configuration
            }
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            if button.isEnabled != action.enabled { button.isEnabled = action.enabled }
            button.accessibilityIdentifier = action.identifier
            button.accessibilityHint = copy("capture.actionHint")
            if existing == nil {
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: KenshikiDesign.minimumTargetIOS).isActive = true
                button.addAction(UIAction { [weak self] _ in self?.send(.action(action.intent)) }, for: .touchUpInside)
                buttonsByIdentifier[action.identifier] = button
            }
            if actionSurface.arrangedSubviews.indices.contains(index), actionSurface.arrangedSubviews[index] === button { continue }
            actionSurface.insertArrangedSubview(button, at: index)
        }
        // Stack layout order is independent of UIView subview insertion/z-order.
        // VoiceOver follows the same deliberate primary-to-cancel order as layout.
        actionSurface.accessibilityElements = actionSurface.arrangedSubviews
    }

    private func action(_ key: String, _ intent: BiometricCaptureIntent, enabled: Bool = true, primary: Bool = true) -> PreparedCaptureAction {
        PreparedCaptureAction(title: copy(key), identifier: key, enabled: enabled, intent: intent, primary: primary)
    }
    private func copy(_ key: String) -> String { KenshikiCopy.text(key) }
}

private struct PreparedCaptureAction {
    let title: String
    let identifier: String
    let enabled: Bool
    let intent: BiometricCaptureIntent
    let primary: Bool
}

@MainActor private final class NativeCaptureFactory {
    var onCreate: ((NativeBiometricCaptureDriver) -> Void)?
    func create() -> NativeBiometricCaptureDriver {
        let driver = NativeBiometricCaptureDriver()
        onCreate?(driver)
        return driver
    }
}

@MainActor private final class NativeBiometricCaptureDriver: BiometricCaptureDriver {
    private let session = NativeSelfieSession(captureWindow: .engineeringV1, monotonicClock: { ProcessInfo.processInfo.systemUptime })
    lazy var preview: UIView = NativeSelfiePreviewView(captureSession: session)
    var onState: ((CaptureDriverState) -> Void)? {
        didSet {
            session.onState = { [weak self] state in
                switch state {
                case .failed(let failure): self?.onState?(.failed(failure))
                case .requestingPermission: self?.onState?(.requestingPermission)
                default: self?.onState?(.running)
                }
            }
        }
    }
    var onReadiness: ((SelfieAdmissionGate.Readiness) -> Void)? {
        get { session.onReadiness }
        set { session.onReadiness = newValue }
    }
    var onCapture: ((CapturedSelfie) -> Void)? {
        get { session.onCapture }
        set { session.onCapture = newValue }
    }
    var onCaptureWindow: (([CapturedSelfie]) -> Void)? {
        get { session.onCaptureWindow }
        set { session.onCaptureWindow = newValue }
    }
    func setConsent(_ consent: SelfieCaptureConsent) { session.setConsent(consent) }
    func setActive(_ active: Bool) { session.setActive(active) }
    func stop() { session.stop() }
    func capture() { session.capture() }
    func retry() -> Bool { session.retry() }
    func updateViewport(_ viewport: CaptureViewport) {
        session.updateViewport(viewport.size, orientation: viewport.orientation.interfaceOrientation, guideOval: viewport.guideOval)
    }
}

private extension UIInterfaceOrientation {
    var captureOrientation: CaptureOrientation {
        switch self {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .portraitUpsideDown: .portraitUpsideDown
        default: .portrait
        }
    }
}
private extension CaptureOrientation {
    var interfaceOrientation: UIInterfaceOrientation {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }
}
