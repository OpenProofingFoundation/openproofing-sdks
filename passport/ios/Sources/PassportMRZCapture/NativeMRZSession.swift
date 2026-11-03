#if os(iOS)
  import AVFoundation
  import Foundation
  import PassportSDK
  import OSLog

  /// Headless camera/OCR lifecycle. The host owns visibility, foreground intent,
  /// review, text and manual confirmation. A stop fences every late permission/frame callback.
  @MainActor
  public final class NativeMRZSession {
    public enum Consent: Sendable { case withheld, permitted }
    public enum State: Equatable, Sendable {
      case stopped, requestingPermission, starting, running
      case failed(MRZCameraFailure)
    }
    public private(set) var state: State = .stopped { didSet { onState?(state) } }
    public var onState: ((State) -> Void)?
    public var onFrame: ((MRZOCRFrame) -> Void)?
    /// Emitted once per acquisition only after a full, stable TD3 read inside the preview guide.
    public var onReady: ((PassportMRZObservation) -> Void)?
    private var readiness = MRZReadinessGate()
    private let logger = Logger(subsystem: "com.kenshiki.passport", category: "MRZCapture")
    private var lastDiagnostic: (String, TimeInterval)?
    private var guideRegion: CGRect?
    private var guideRevision = UUID()
    private var generation = UUID()
    private var starting = false
    private var stopping = 0
    private let effects: MRZCameraEffects
    private var orientation: MRZCaptureOrientation = .portrait

    public convenience init(
      policy: MRZOCRPolicy = .engineeringV1, notificationsCenter: NotificationCenter
    ) {
      self.init(effects: .live(policy: policy, notificationsCenter: notificationsCenter))
    }
    init(effects: MRZCameraEffects) { self.effects = effects }

    deinit {
      let effects = effects
      Task { @MainActor in await effects.stop() }
    }

    @_spi(Preview) public var previewSession: AVCaptureSession? { effects.previewSession }

    /// The shared preview supplies its scene orientation automatically. Headless hosts that
    /// render their own preview must supply the same orientation here. Old-orientation OCR
    /// completions are fenced before delivery while the serial camera queue applies the update.
    public func updateOrientation(_ value: MRZCaptureOrientation) {
      guard orientation != value else { return }
      orientation = value
      updateGuideRegion(nil)
      effects.updateOrientation(value)
    }

    /// Unrotated, top-left-normalized camera region, converted by the preview layer.
    /// Nil withdraws geometry admission when the preview is absent or not laid out.
    @_spi(Preview) public func updateGuideRegion(_ region: CGRect?) {
      let valid = region.flatMap { MRZReadinessGate.validRegion($0) ? $0 : nil }
      guard guideRegion != valid else { return }
      guideRegion = valid
      guideRevision = UUID()
      readiness.reset()
      effects.updateGuideRegion(valid, guideRevision)
    }

    /// Await stop before starting another camera capability. No camera opens without explicit
    /// acquisition consent; OS permission remains a separate requirement.
    public func start(consent: Consent) async throws {
      guard consent == .permitted else { throw MRZCameraFailure.consentRequired }
      guard !starting, stopping == 0, state != .running else { throw MRZCameraFailure.busy }
      starting = true
      readiness.reset()
      defer { starting = false }
      let attempt = UUID()
      generation = attempt
      do {
        try Task.checkCancellation()
        state = .requestingPermission
        guard generation == attempt else { throw CancellationError() }
        let allowed = await effects.authorize()
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        guard allowed else { throw MRZCameraFailure.cameraPermissionDenied }
        state = .starting
        guard generation == attempt else { throw CancellationError() }
        try await effects.start(
          { [weak self] frame in
            guard let self, self.generation == attempt, self.state == .running,
              frame.orientation == self.orientation
            else { return }
            self.onFrame?(frame)
            guard self.generation == attempt, self.state == .running else { return }
            guard frame.guideRevision == self.guideRevision, let region = self.guideRegion else {
              self.diagnose("awaiting_current_guide", frame: frame)
              return
            }
            let observation = self.readiness.ingest(frame, rawGuideRegion: region)
            self.diagnose(self.readiness.status.rawValue, frame: frame)
            if let observation { self.onReady?(observation) }
          },
          { [weak self] failure in
            guard let self, self.generation == attempt else { return }
            self.generation = UUID()
            self.readiness.reset()
            self.stopping += 1
            self.state = .failed(failure)
            Task {
              await self.effects.stop()
              self.stopping -= 1
            }
          })
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        state = .running
      } catch {
        if generation == attempt {
          let failedAttempt = UUID()
          generation = failedAttempt
          readiness.reset()
          await effects.stop()
          let failure =
            (error as? MRZCameraFailure)
            ?? (error is CancellationError ? .cancelled : .captureFailed)
          if generation == failedAttempt { state = .failed(failure) }
        }
        throw (error as? MRZCameraFailure)
          ?? (error is CancellationError ? .cancelled : .captureFailed)
      }
    }

    /// Scalar acquisition diagnostics only: never log recognized text, identity fields or images.
    private func diagnose(_ status: String, frame: MRZOCRFrame) {
      if let previous = lastDiagnostic, previous.0 == status,
        frame.timestamp - previous.1 < 1 { return }
      lastDiagnostic = (status, frame.timestamp)
      logger.notice("mrz_gate status=\(status, privacy: .public) rows=\(frame.candidates.count) inside=\(self.readiness.insideRowCount) stable=\(self.readiness.stableFrameCount)")
    }

    public func stop() async {
      stopping += 1
      defer { stopping -= 1 }
      generation = UUID()
      readiness.reset()
      state = .stopped
      await effects.stop()
    }
  }

  /// Internal effects seam for lifecycle tests; adopters cannot replace acquisition mechanics.
  @MainActor
  struct MRZCameraEffects {
    let previewSession: AVCaptureSession?
    let authorize: () async -> Bool
    let start:
      (
        @escaping @MainActor @Sendable (MRZOCRFrame) -> Void,
        @escaping @MainActor @Sendable (MRZCameraFailure) -> Void
      ) async throws -> Void
    let stop: () async -> Void
    var updateOrientation: (MRZCaptureOrientation) -> Void = { _ in }
    var updateGuideRegion: (CGRect?, UUID) -> Void = { _, _ in }

    static func live(policy: MRZOCRPolicy, notificationsCenter: NotificationCenter) -> Self {
      let driver = MRZCameraDriver(policy: policy, notificationsCenter: notificationsCenter)
      return Self(
        previewSession: driver.session,
        authorize: {
          switch AVCaptureDevice.authorizationStatus(for: .video) {
          case .authorized: return true
          case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
          default: return false
          }
        }, start: { frame, failure in try await driver.start(onFrame: frame, onFailure: failure) },
        stop: { await driver.stop() }, updateOrientation: { driver.updateOrientation($0) },
          updateGuideRegion: { driver.updateGuideRegion($0, revision: $1) })
    }
  }
#endif
