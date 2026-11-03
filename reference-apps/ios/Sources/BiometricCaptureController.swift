import BiometricCapture
import BiometricInference
import BiometricQuality
import Foundation

enum CaptureOrientation: Equatable { case portrait, portraitUpsideDown, landscapeLeft, landscapeRight }
struct CaptureViewport: Equatable {
    let size: CGSize
    let orientation: CaptureOrientation
    let guideOval: CGRect
}
enum CaptureDriverState { case requestingPermission, running, failed(SelfieCameraFailure) }
@MainActor protocol BiometricCaptureDriver: AnyObject {
    var onState: ((CaptureDriverState) -> Void)? { get set }
    var onReadiness: ((SelfieAdmissionGate.Readiness) -> Void)? { get set }
    var onCapture: ((CapturedSelfie) -> Void)? { get set }
    var onCaptureWindow: (([CapturedSelfie]) -> Void)? { get set }
    func setConsent(_ consent: SelfieCaptureConsent)
    func setActive(_ active: Bool)
    func stop()
    func capture()
    func retry() -> Bool
    func updateViewport(_ viewport: CaptureViewport)
}

extension BiometricCaptureDriver {
    var onCaptureWindow: (([CapturedSelfie]) -> Void)? {
        get { nil }
        set { /* Legacy single-capture test drivers do not support burst delivery. */ }
    }
}

enum BiometricCaptureIntent {
    case allow, allowWhenVisible, cancel, retry, shutter, useSelfie, visible, hidden
    case viewport(CaptureViewport)
}

/// An in-memory acquisition handoff. Admission is not a face-match or identity verdict.
struct AcceptedSelfie: Sendable {
    let capture: CapturedSelfie
    let snapshot: SelfiePixelSnapshot
    let selection: FaceCaptureSelectionRecord?
    let preparedSelfie: FaceImagePreflightObservation?
    init(capture: CapturedSelfie, snapshot: SelfiePixelSnapshot, selection: FaceCaptureSelectionRecord? = nil,
         preparedSelfie: FaceImagePreflightObservation? = nil) {
        self.capture = capture; self.snapshot = snapshot; self.selection = selection; self.preparedSelfie = preparedSelfie
    }
}

/// Consent, effects and stale-result fencing belong here; views only render supplied state.
@MainActor final class BiometricCaptureController {
    enum Phase: Equatable { case consent, capturing, processing, captured, failure(String), finished }
    private(set) var phase: Phase = .consent
    private var pendingUserConsent = false
    private(set) var snapshot: SelfiePixelSnapshot?
    var onClose: (() -> Void)?
    var onAccepted: ((AcceptedSelfie) -> Void)?
    var beforeAction: ((String) async throws -> Void)?
    private var actionTask: Task<Void, Never>?
    var persistCapturedSelfie: ((CapturedSelfie) async throws -> Void)?
    var persistSelectedSelfie: ((AcceptedSelfie) async throws -> Void)?
    var selectCaptureWindow: (@Sendable ([CapturedSelfie], @escaping FaceCaptureSelectionProcessor.Progress) async throws -> AcceptedSelfie)?
    private(set) var selectionRefusal: FaceCaptureSelectionRefusal?
    private(set) var selectionProgress: FaceCaptureSelectionProgress?
    private var selectedSelfie: AcceptedSelfie?
    private let decode: @Sendable (CapturedSelfie) async throws -> SelfiePixelSnapshot
    private let makeDriver: () -> any BiometricCaptureDriver
    private var driver: (any BiometricCaptureDriver)?
    private(set) var capturedEvidence: CapturedSelfie?
    var capturedPNG: Data? { capturedEvidence?.encodedPNG }
    var onChange: (() -> Void)?
    private var viewport: CaptureViewport?
    private var generation = UUID()
    private var visible = false
    private var foreground = true
    private(set) var messageKey = "capture.consent.body"
    private(set) var shutterEnabled = false
    private var decodeTask: Task<Void, Never>?

    convenience init(makeDriver: @escaping () -> any BiometricCaptureDriver) {
        self.init(makeDriver: makeDriver, decode: { capture in
            try await Task.detached(priority: .userInitiated) {
                try SelfiePixelBridge.decodeOrientedPNG(capture.encodedPNG, expectedSourceSHA256: capture.sha256)
            }.value
        })
    }

    init(makeDriver: @escaping () -> any BiometricCaptureDriver,
         decode: @escaping @Sendable (CapturedSelfie) async throws -> SelfiePixelSnapshot) {
        self.makeDriver = makeDriver
        self.decode = decode
    }

    func send(_ intent: BiometricCaptureIntent) {
        let code: String?
        switch intent {
        case .shutter: code = "selfie.shutter"
        case .useSelfie: code = "selfie.compare"
        case .retry: code = "selfie.retry"
        default: code = nil
        }
        if let code, let beforeAction {
            guard actionTask == nil, visible, foreground, phase != .finished else { return }
            let token = generation
            actionTask = Task { [weak self] in
                do {
                    try await beforeAction(code)
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.actionTask = nil
                    self.perform(intent)
                } catch {
                    guard let self, self.generation == token else { return }
                    self.actionTask = nil
                    self.phase = .failure("capture.failure.storage")
                    self.messageKey = "capture.failure.storage"
                    self.render()
                }
            }
            return
        }
        perform(intent)
    }

    private func perform(_ intent: BiometricCaptureIntent) {
        guard phase != .finished else {
            if case .hidden = intent { visible = false }
            return
        }
        switch intent {
        case .allowWhenVisible:
            guard phase == .consent, foreground else { return }
            pendingUserConsent = true
            if visible { start() }
        case .allow:
            guard phase == .consent, visible, foreground else { return }
            start()
        case .cancel:
            phase = .finished
            let close = onClose
            onClose = nil
            onAccepted = nil
            release()
            render()
            close?()
        case .useSelfie:
            guard phase == .captured, visible, foreground,
                  let capture = capturedEvidence, let snapshot,
                  snapshot.sourceEncodedSHA256 == capture.sha256 else { return }
            let accepted = selectedSelfie ?? AcceptedSelfie(capture: capture, snapshot: snapshot)
            let deliver = onAccepted
            onAccepted = nil
            onClose = nil
            phase = .finished
            release()
            render()
            guard visible, foreground else { return }
            deliver?(accepted)
        case .retry:
            switch phase {
            case .failure:
                guard visible, foreground else { return }
                if messageKey == "capture.failure.storage", let saved = capturedEvidence {
                    if let selectedSelfie { receivedSelected(selectedSelfie) }
                    else { received(saved) }
                    return
                }
                guard let driver else {
                    phase = .consent
                    messageKey = "capture.consent.body"
                    render()
                    return
                }
                let attempt = generation
                phase = .capturing
                messageKey = "capture.starting"
                shutterEnabled = false
                render()
                guard generation == attempt, phase == .capturing, self.driver === driver else { return }
                let retried = driver.retry()
                guard generation == attempt, phase == .capturing, self.driver === driver else { return }
                if !retried {
                    phase = .failure("capture.failure.camera")
                    messageKey = "capture.failure.camera"
                    render()
                }
            case .captured:
                guard visible, foreground else { return }
                withdraw(message: "capture.consent.body")
            default: break
            }
        case .shutter:
            guard phase == .capturing, visible, foreground, shutterEnabled else { return }
            driver?.capture()
        case .visible:
            guard !visible else { return }
            visible = true
            if pendingUserConsent, foreground, phase == .consent {
                start()
                return
            }
            driver?.setActive(foreground && viewport != nil)
        case .hidden:
            pendingUserConsent = false
            guard visible else { return }
            visible = false
            withdraw()
        case .viewport(let prepared):
            guard prepared.size.width.isFinite, prepared.size.height.isFinite,
                  prepared.size.width > 0, prepared.size.height > 0,
                  prepared.guideOval.width > 0, prepared.guideOval.height > 0,
                  prepared.guideOval.minX >= 0, prepared.guideOval.minY >= 0,
                  prepared.guideOval.maxX <= prepared.size.width,
                  prepared.guideOval.maxY <= prepared.size.height else { return }
            guard viewport != prepared else { return }
            viewport = prepared
            let attempt = generation
            if let expected = driver {
                expected.updateViewport(prepared)
                guard current(attempt, expected) else { return }
                expected.setActive(visible && foreground)
            }

        }
    }

    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if active {
            driver?.setActive(visible && viewport != nil)
        } else {
            withdraw()
        }
    }

    func backgrounded() { setForeground(false) }

    private func start() {
        phase = .processing
        release()
        guard phase == .processing, visible, foreground else { return }
        phase = .capturing
        messageKey = "capture.starting"
        let attempt = generation
        let created = makeDriver()
        guard generation == attempt, phase == .capturing else {
            created.setConsent(.withheld)
            created.stop()
            return
        }
        driver = created
        created.onState = { [weak self] state in
            guard let self, self.generation == attempt, self.phase == .capturing else { return }
            switch state {
            case .failed(let failure):
                self.phase = .failure(self.failureKey(failure.reason))
                self.messageKey = self.failureKey(failure.reason)
                self.shutterEnabled = false
            case .requestingPermission: self.messageKey = "capture.permission"
            case .running: return
            }
            self.render()
        }
        created.onReadiness = { [weak self] readiness in
            guard let self, self.generation == attempt, self.phase == .capturing else { return }
            let key = self.guidanceKey(readiness.refusal)
            guard self.messageKey != key || self.shutterEnabled != readiness.captureReady else { return }
            self.messageKey = key
            self.shutterEnabled = readiness.captureReady
            self.render()
        }
        created.onCaptureWindow = { [weak self] captures in
            guard let self, self.generation == attempt, self.phase == .capturing else { return }
            self.receivedWindow(captures)
        }
        created.onCapture = { [weak self] capture in
            guard let self, self.generation == attempt, self.phase == .capturing else { return }
            self.received(capture)
        }
        render()
        guard current(attempt, created) else { return }
        if let viewport { created.updateViewport(viewport) }
        guard current(attempt, created) else { return }
        created.setConsent(.permitted)
        guard current(attempt, created) else { return }
        created.setActive(visible && foreground && viewport != nil)
    }

    private func receivedWindow(_ captures: [CapturedSelfie]) {
        guard let selectCaptureWindow else {
            phase = .failure("capture.selection.failure.qualityUnavailable")
            messageKey = "capture.selection.failure.qualityUnavailable"
            release(); render(); return
        }
        phase = .processing
        release()
        guard phase == .processing else { return }
        let attempt = generation
        messageKey = "capture.selection.quality"
        selectionProgress = .init(stage: .quality, completed: 0, total: captures.count)
        render()
        guard generation == attempt, phase == .processing else { return }
        decodeTask = Task { [weak self] in
            do {
                let selected = try await selectCaptureWindow(captures) { [weak self] progress in
                    guard let self, self.generation == attempt, self.phase == .processing, !Task.isCancelled else { return }
                    self.selectionProgress = progress
                    self.messageKey = "capture.selection.\(progress.stage.rawValue)"
                    self.render()
                }
                guard let self, self.generation == attempt, self.phase == .processing, !Task.isCancelled else { return }
                self.decodeTask = nil
                self.receivedSelected(selected)
            } catch {
                guard let self, self.generation == attempt, self.phase == .processing, !Task.isCancelled else { return }
                self.decodeTask = nil; self.selectionProgress = nil
                self.selectionRefusal = error as? FaceCaptureSelectionRefusal
                let key: String
                if let reason = error as? FaceQualityFailure {
                    switch reason {
                    case .resourceLimit: key = "capture.selection.failure.resources"
                    case .invalidPixels: key = "capture.selection.failure.source"
                    case .missingAsset, .invalidAssets, .artifactIntegrity, .initializationFailed: key = "capture.selection.failure.qualityUnavailable"
                    case .assessmentFailed, .closed: key = "capture.selection.failure.qualityFailed"
                    }
                } else { key = self.selectionRefusal?.reason.messageKey ?? (error as? FaceCaptureSelectionFailure)?.messageKey ?? "capture.selection.failure.qualityFailed" }
                self.phase = .failure(key); self.messageKey = key; self.render()
            }
        }
    }

    func receivedSelected(_ selected: AcceptedSelfie) {
        let storageRetry = phase == .failure("capture.failure.storage")
            && selectedSelfie?.capture.id == selected.capture.id && selectedSelfie?.selection == selected.selection
        guard visible, foreground, phase == .capturing || phase == .processing || storageRetry else { return }
        phase = .processing
        let attempt = generation
        selectionProgress = nil
        messageKey = "capture.processing"
        selectedSelfie = selected
        snapshot = selected.snapshot
        capturedEvidence = selected.capture
        render()
        guard generation == attempt, phase == .processing else { return }
        let persist = persistSelectedSelfie
        decodeTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self, self.generation == attempt, self.phase == .processing else { throw CancellationError() }
                guard selected.snapshot.sourceEncodedSHA256 == selected.capture.sha256 else { throw FaceWorkflowStorageFailure.invalidRecord }
                try selected.selection?.validate(selected: FaceCaptureContext(capture: selected.capture), imageSHA256: selected.capture.sha256)
                try Task.checkCancellation()
                try await persist?(selected)
                guard self.generation == attempt, self.phase == .processing, !Task.isCancelled else { return }
                self.decodeTask = nil; self.phase = .captured; self.messageKey = "capture.complete.body"; self.render()
            } catch {
                guard let self, self.generation == attempt, self.phase == .processing, !Task.isCancelled else { return }
                self.decodeTask = nil; self.phase = .failure("capture.failure.storage"); self.messageKey = "capture.failure.storage"; self.render()
            }
        }
    }

    private func received(_ capture: CapturedSelfie) {
        // Consume acquisition consent before decoding. Reentrant callbacks cannot deliver twice.
        phase = .processing
        release()
        guard phase == .processing else { return }
        messageKey = "capture.processing"
        let attempt = generation
        render()
        guard generation == attempt, phase == .processing else { return }
        let decode = self.decode
        let persist = self.persistCapturedSelfie
        decodeTask = Task { [weak self] in
            let result: Result<SelfiePixelSnapshot, Error>
            var decoded: SelfiePixelSnapshot?
            do {
                let snapshot = try await decode(capture)
                guard snapshot.sourceEncodedSHA256 == capture.sha256 else { throw FaceWorkflowStorageFailure.invalidRecord }
                decoded = snapshot
                try Task.checkCancellation()
                try await persist?(capture)
                result = .success(snapshot)
            }
            catch { result = .failure(error) }
            guard let self, self.generation == attempt, self.phase == .processing, !Task.isCancelled else { return }
            self.decodeTask = nil
            switch result {
            case .success(let snapshot):
                guard snapshot.sourceEncodedSHA256 == capture.sha256 else {
                    self.phase = .failure("capture.failure.image")
                    self.messageKey = "capture.failure.image"
                    self.render()
                    return
                }
                self.snapshot = snapshot
                self.capturedEvidence = capture
                self.phase = .captured
                self.messageKey = "capture.complete.body"
            case .failure:
                if let decoded {
                    self.snapshot = decoded
                    self.capturedEvidence = capture
                    self.phase = .failure("capture.failure.storage")
                    self.messageKey = "capture.failure.storage"
                } else {
                    self.phase = .failure("capture.failure.image")
                    self.messageKey = "capture.failure.image"
                }
            }
            self.render()
        }
    }

    private func withdraw(message: String = "capture.interrupted") {
        guard phase != .finished else { return }
        phase = .processing
        release()
        guard phase == .processing else { return }
        phase = .consent
        messageKey = message
        render()
    }

    private func release() {
        actionTask?.cancel(); actionTask = nil
        pendingUserConsent = false
        generation = UUID()
        decodeTask?.cancel()
        decodeTask = nil
        let retired = driver
        driver = nil
        retired?.onState = nil
        retired?.onReadiness = nil
        retired?.onCapture = nil
        retired?.onCaptureWindow = nil
        retired?.setConsent(.withheld)
        retired?.stop()
        capturedEvidence = nil
        selectedSelfie = nil
        selectionProgress = nil
        selectionRefusal = nil
        snapshot = nil
        shutterEnabled = false
    }

    private func current(_ attempt: UUID, _ expected: any BiometricCaptureDriver) -> Bool {
        generation == attempt && phase == .capturing && driver === expected
    }

    private func render() { onChange?() }

    private func failureKey(_ reason: SelfieCameraFailure.Reason) -> String {
        switch reason {
        case .unavailable: "capture.failure.unsupported"
        case .cameraPermissionDenied: "capture.failure.denied"
        case .cameraPermissionRestricted: "capture.failure.restricted"
        case .depthUnavailable: "capture.failure.depth"
        case .captureWindowEmpty: "capture.selection.failure.noSelection"
        case .captureWindowResourceLimit: "capture.selection.failure.resources"
        case .frameSnapshotFailed: "capture.failure.image"
        case .analysisTimedOut, .renderingTimedOut, .noFrames: "capture.failure.timeout"
        case .frameworkFailure, .sensorInputFailed, .invalidConfiguration, .analysisFailed, .renderingFailed: "capture.failure.camera"
        }
    }

    private func guidanceKey(_ refusal: SelfieAdmissionGate.Refusal?) -> String {
        switch refusal {
        case nil: "capture.guidance.ready"
        case .multipleFacesObserved: "capture.guidance.single"
        case .blinkNotObserved, .blinkExpired, .eyesClosed: "capture.guidance.blink"
        case .steadyHoldIncomplete, .captureInProgress: "capture.guidance.hold"
        case .captureQualityUnavailable, .captureQualityBelowMinimum: "capture.guidance.quality"
        case .depthUnavailable, .depthStale, .depthInsufficient, .depthFlat: "capture.guidance.depth"
        default: "capture.guidance.center"
        }
    }
}
