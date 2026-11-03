#if os(iOS)
  import ARKit
  import AVFoundation
  import Foundation
  import UIKit

  /// Camera ownership extracted from the existing ARKit adapter. No comparison models are loaded.
  /// Host visibility/foreground intent is explicit. AR frame timestamps retain their native meaning.
  @MainActor
  public final class NativeSelfieSession: NSObject, @preconcurrency ARSessionDelegate {
    public enum State: Sendable, Equatable {
      case stopped, awaitingConsent, requestingPermission, starting, running
      case captured(UUID)
      case failed(SelfieCameraFailure)
    }
    public private(set) var state: State = .stopped {
      didSet { onState?(state) }
    }
    public var onState: ((State) -> Void)?
    public var onReadiness: ((SelfieAdmissionGate.Readiness) -> Void)?
    public var onCapture: ((CapturedSelfie) -> Void)?
    /// Optional bounded window. Every element owns its original pixels and same-frame receipt.
    /// This callback replaces onCapture only when captureWindow was explicitly configured.
    public var onCaptureWindow: (([CapturedSelfie]) -> Void)?
    private var windowCandidates: [CapturedSelfie] = []
    private let motionSnapshot: ((String, TimeInterval) -> SelfieMotionEvidence?)?
    public private(set) var guideOval = CGRect.zero
    private let session = ARSession()
    private let motion = NativeSelfieMotion()
    private let coordinator: SelfieCaptureCoordinator
    private var viewport = CGSize.zero
    private var orientation = UIInterfaceOrientation.portrait
    private var desiredActive = false
    private var interrupted = false
    public private(set) var consent: SelfieCaptureConsent = .withheld
    private let camera: SelfieCameraAccess
    private var permissionTask: Task<Void, Never>?
    private var generation = UUID()
    private var frameFloor = TimeInterval.zero

    public convenience init(
      policy: SelfieAdmissionPolicy = .init(requiresGuideContainment: true),
      depthPolicy: SelfieDepthPolicy = .engineeringV1,
      timeouts: SelfieCaptureTimeouts = .operationalV1,
      captureWindow: SelfieCaptureWindowPolicy? = nil,
      monotonicClock: @escaping @Sendable () -> TimeInterval
    ) {
      let coordinator = SelfieCaptureCoordinator(
        policy: policy, depthPolicy: depthPolicy, timeouts: timeouts, captureWindow: captureWindow,
        analyze: { input in
          await Task.detached(priority: .userInitiated) {
            SelfieFrameAnalyzer.analyze(input, depthPolicy: depthPolicy, monotonicClock: monotonicClock)
          }.value
        }, clock: monotonicClock)
      self.init(coordinator: coordinator, camera: .live)
    }

    init(coordinator: SelfieCaptureCoordinator, camera: SelfieCameraAccess,
      motionSnapshot: ((String, TimeInterval) -> SelfieMotionEvidence?)? = nil) {
      self.coordinator = coordinator
      self.camera = camera
      self.motionSnapshot = motionSnapshot
      super.init()
      session.delegate = self
      session.delegateQueue = .main
      coordinator.onFailure = { [weak self] failure in self?.fail(failure) }
      coordinator.onReadiness = { [weak self] value in self?.onReadiness?(value) }
      coordinator.onCapture = { [weak self] bytes, receipt in
        guard let self, self.consent == .permitted, self.desiredActive else { return }
        let capture = self.bindCapture(bytes, receipt: receipt)
        let deliveryAttempt = self.pause()
        guard self.generation == deliveryAttempt, self.consent == .permitted,
          self.desiredActive
        else { return }
        self.state = .captured(capture.id)
        guard self.generation == deliveryAttempt, self.consent == .permitted,
          self.desiredActive
        else { return }
        self.onCapture?(capture)
      }
      coordinator.onWindowCandidate = { [weak self] bytes, receipt in
        guard let self, self.consent == .permitted, self.desiredActive else { return }
        self.windowCandidates.append(self.bindCapture(bytes, receipt: receipt))
      }
      coordinator.onWindowReset = { [weak self] in self?.windowCandidates.removeAll() }
      coordinator.onWindowCompleted = { [weak self] in
        guard let self, self.consent == .permitted, self.desiredActive,
          let first = self.windowCandidates.first else { return }
        let captures = self.windowCandidates
        let deliveryAttempt = self.pause()
        guard self.generation == deliveryAttempt, self.consent == .permitted,
          self.desiredActive else { return }
        self.state = .captured(first.id)
        guard self.generation == deliveryAttempt, self.consent == .permitted,
          self.desiredActive else { return }
        self.onCaptureWindow?(captures)
      }
    }

    private func bindCapture(_ bytes: Data, receipt: SelfieAdmissionReceipt) -> CapturedSelfie {
      var boundReceipt = receipt
      let original = CapturedSelfie(encodedPNG: bytes, admissionReceipt: receipt)
      if let motionSnapshot {
        boundReceipt.motionEvidence = motionSnapshot(original.sha256, receipt.frameTimestamp)
      } else {
        boundReceipt.motionEvidence = motion.evidence(imageSHA256: original.sha256,
          frameTimestamp: receipt.frameTimestamp)
      }
      boundReceipt.motionStatus = motion.status
      return CapturedSelfie(encodedPNG: bytes, admissionReceipt: boundReceipt)
    }

    @_spi(Preview) public var previewSession: ARSession { session }

    /// The host prepares the localized/design-system presentation geometry.
    public func updateViewport(
      _ size: CGSize, orientation: UIInterfaceOrientation, guideOval: CGRect
    ) {
      guard [size.width, size.height, guideOval.origin.x, guideOval.origin.y,
        guideOval.width, guideOval.height].allSatisfy({ $0.isFinite }),
        size.width > 0, size.height > 0, guideOval.width > 0, guideOval.height > 0,
        CGRect(origin: .zero, size: size).contains(guideOval),
        [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight].contains(orientation)
      else {
        fail(.init(reason: .invalidConfiguration))
        return
      }
      viewport = size
      self.orientation = orientation
      self.guideOval = guideOval
      coordinator.updateGuide(oval: guideOval, viewport: size, orientation: orientation)
    }

    /// The host supplies presentation/foreground intent; interruptions remain native facts.
    public func setActive(_ active: Bool) {
      desiredActive = active
      reconcile()
    }

    /// Withdraws acquisition permission immediately, including pending permission/analysis results.
    /// Host-retained evidence has an independent retention/erasure contract.
    public func setConsent(_ consent: SelfieCaptureConsent) {
      guard self.consent != consent else { return }
      self.consent = consent
      if consent == .withheld {
        pause()
        if case .captured = state { return }
        state = desiredActive ? .awaitingConsent : .stopped
      } else {
        if state == .awaitingConsent { state = .stopped }
        reconcile()
      }
    }

    /// A failed native request must finish before another attempt can consume a worker slot.
    /// Returning false means the caller must wait or end this capture surface; retry never
    /// abandons a hung task to launch an unbounded replacement.
    @discardableResult
    public func retry() -> Bool {
      guard case .failed = state, consent == .permitted, desiredActive, !interrupted,
        coordinator.isQuiescent
      else { return false }
      state = .stopped
      reconcile()
      if case .failed = state { return false }
      return true
    }

    public func stop() {
      desiredActive = false
      pause()
      if case .captured = state { return }
      if case .failed = state { return }
      state = .stopped
    }

    public func capture() {
      guard consent == .permitted, desiredActive else { return }
      coordinator.shutterTapped()
    }

    private func reconcile() {
      guard desiredActive, !interrupted else {
        pause()
        if state == .starting || state == .running || state == .requestingPermission {
          state = .stopped
        }
        return
      }
      guard consent == .permitted else {
        pause()
        if case .captured = state { return }
        state = .awaitingConsent
        return
      }
      if case .failed = state { return }
      if case .captured = state { return }
      guard state != .starting, state != .running, state != .requestingPermission else { return }
      guard camera.isSupported() else {
        fail(.init(reason: .unavailable))
        return
      }
      switch camera.authorizationStatus() {
      case .authorized: startCamera()
      case .denied: fail(.init(reason: .cameraPermissionDenied))
      case .restricted: fail(.init(reason: .cameraPermissionRestricted))
      case .notDetermined:
        let attempt = generation
        state = .requestingPermission
        guard generation == attempt, consent == .permitted, desiredActive,
          !interrupted, state == .requestingPermission, permissionTask == nil
        else { return }
        permissionTask = Task { [weak self, camera] in
          guard self?.generation == attempt, self?.consent == .permitted,
            self?.desiredActive == true, self?.interrupted == false
          else {
            guard let self else { return }
            self.permissionTask = nil
            if self.state == .requestingPermission {
              self.state = .stopped
              self.reconcile()
            }
            return
          }
          let allowed = await camera.requestPermission()
          guard let self else { return }
          self.permissionTask = nil
          guard self.generation == attempt, self.consent == .permitted,
            self.desiredActive, !self.interrupted
          else {
            if self.state == .requestingPermission {
              self.state = .stopped
              self.reconcile()
            }
            return
          }
          if allowed {
            self.startCamera()
          } else {
            self.fail(.init(reason: .cameraPermissionDenied))
          }
        }
      @unknown default: fail(.init(reason: .cameraPermissionDenied))
      }
    }

    private func startCamera() {
      let attempt = generation
      frameFloor = session.currentFrame?.timestamp.nextUp ?? 0
      guard coordinator.start(after: frameFloor) else {
        fail(.init(reason: .invalidConfiguration))
        return
      }
      guard generation == attempt, consent == .permitted, desiredActive, !interrupted else {
        coordinator.stop()
        return
      }
      state = .starting
      guard generation == attempt, consent == .permitted, desiredActive, !interrupted,
        state == .starting
      else { return }
      camera.run(session)
      motion.start()
    }

    @discardableResult
    private func pause() -> UUID {
      let pausedAttempt = UUID()
      generation = pausedAttempt
      windowCandidates.removeAll()
      permissionTask?.cancel()
      // Keep the slot until the OS callback returns, even when cancellation is ignored.
      coordinator.stop()
      motion.stop()
      camera.pause(session)
      return pausedAttempt
    }

    private func fail(_ failure: SelfieCameraFailure) {
      if case .failed = state { return }
      pause()
      state = .failed(failure)
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
      guard desiredActive, !interrupted, consent == .permitted, frame.timestamp >= frameFloor else {
        return
      }
      if case .failed = state { return }
      if case .captured = state { return }
      guard state == .starting || state == .running else { return }
      let frameAttempt = generation
      if state == .starting { state = .running }
      guard generation == frameAttempt, consent == .permitted, desiredActive,
        state == .running
      else { return }
      let faces = frame.anchors.compactMap { $0 as? ARFaceAnchor }
      let face = faces.first
      let imageOrientation: CGImagePropertyOrientation
      switch orientation {
      case .landscapeLeft: imageOrientation = .up
      case .landscapeRight: imageOrientation = .down
      case .portraitUpsideDown: imageOrientation = .left
      default: imageOrientation = .right
      }
      let input: SelfieCaptureFrame
      do {
        input = SelfieCaptureFrame(
        input: try SelfieFrameInput(
          buffer: frame.capturedImage, orientation: imageOrientation,
          depth: try frame.capturedDepthData.map {
            try SelfieDepthMap(data: $0, imageTimestamp: frame.timestamp,
              depthTimestamp: frame.capturedDepthDataTimestamp)
          }),
        observation: .init(
          timestamp: frame.timestamp, anchorID: face?.identifier, faceCount: faces.count,
          trackingObserved: face?.isTracked == true,
          leftEyeClosed: face?.blendShapes[.eyeBlinkLeft]?.floatValue,
          rightEyeClosed: face?.blendShapes[.eyeBlinkRight]?.floatValue),
        displayTransform: frame.displayTransform(for: orientation, viewportSize: viewport),
        anchorPoint: frame.camera.projectPoint(
          SIMD3(
            face?.transform.columns.3.x ?? 0, face?.transform.columns.3.y ?? 0,
            face?.transform.columns.3.z ?? 0),
          orientation: orientation, viewportSize: viewport))
      } catch {
        fail(.init(reason: .frameSnapshotFailed))
        return
      }
      coordinator.observe(input, now: session.currentFrame?.timestamp ?? frame.timestamp)
    }

    public func sessionWasInterrupted(_ _: ARSession) {
      interrupted = true
      reconcile()
    }
    public func sessionInterruptionEnded(_ _: ARSession) {
      interrupted = false
      reconcile()
    }
    public func session(_ _: ARSession, didFailWithError error: Error) {
      guard desiredActive, !interrupted, consent == .permitted,
        state == .starting || state == .running
      else { return }
      fail(.framework(error as NSError))
    }
  }

  /// Internal native effects seam; tests exercise consent and late OS permission without a camera.
  @MainActor
  struct SelfieCameraAccess {
    let isSupported: () -> Bool
    let authorizationStatus: () -> AVAuthorizationStatus
    let requestPermission: () async -> Bool
    let run: (ARSession) -> Void
    let pause: (ARSession) -> Void

    static var live: Self {
      .init(
        // Since iOS 14, Neural Engine face tracking can use RGB without TrueDepth.
        // https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration
        isSupported: {
          ARFaceTrackingConfiguration.isSupported
            && AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil
        },
        authorizationStatus: { AVCaptureDevice.authorizationStatus(for: .video) },
        requestPermission: { await AVCaptureDevice.requestAccess(for: .video) },
        run: {
          $0.run(ARFaceTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        },
        pause: { $0.pause() })
    }
  }
#endif
