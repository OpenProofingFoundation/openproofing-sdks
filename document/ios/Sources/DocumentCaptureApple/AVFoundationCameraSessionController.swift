import AVFoundation
import Foundation
import DocumentSDK

/// Serial ownership boundary for mutable AVFoundation capture state.
///
/// All session configuration, lifecycle changes, photo settings, and delegate
/// retention run on `sessionQueue`. The unchecked conformance belongs to this
/// synchronized owner; no AVFoundation type is declared Sendable. On iOS, the
/// preview layer receives a non-mutating reference on the main actor, matching
/// AVFoundation's UI integration boundary. SDK code never accesses or mutates
/// the session through that preview reference.
final class AVFoundationCameraSessionController: CameraSessionControlling, @unchecked Sendable {
  typealias QualityObservationHandler =
    @Sendable (DocumentCaptureQualityObservation) -> Void

  let policy: AVFoundationDocumentCapturePolicy
  let admissionPolicy = DocumentCaptureAdmissionPolicy()
  let sessionQueue: DispatchQueue
  let state: State
  let retireZoomRamp: @Sendable (AVCaptureDevice?) throws -> Void
  var diagnosticsConfiguration = DocumentCameraDiagnosticsConfiguration.qualityOnly
  var qualityObservationHandler: QualityObservationHandler = { _ in }
  let tiltGuidanceMailbox = DocumentTiltGuidanceMailbox()
  var tiltGuidanceHandler: @Sendable (DocumentTiltPresentation) -> Void = { _ in }
  let guidanceZoomIsRamping: @Sendable (AVCaptureDevice?) -> Bool?
  let geometryMailbox = DocumentGeometryObservationMailbox()
  var geometryObservationHandler: @Sendable (DocumentLiveGeometryObservation) -> Void = { _ in }

  var pdf417Handler: @Sendable (String) -> Void = { _ in }
  let notifications: NotificationCenter
  let now: @Sendable () -> Date

  init(
    notifications: NotificationCenter,
    now: @escaping @Sendable () -> Date,
    diagnosticSink: @escaping @Sendable (Data) -> Void = { _ in },
    configuration: DocumentCaptureConfiguration,
    retireZoomRamp: @escaping @Sendable (AVCaptureDevice?) throws -> Void = retireNativeZoomRamp,
    guidanceZoomIsRamping: @escaping @Sendable (AVCaptureDevice?) -> Bool? =
      nativeGuidanceZoomIsRamping
  ) {
    self.now = now
    self.notifications = notifications
    self.retireZoomRamp = retireZoomRamp
    self.guidanceZoomIsRamping = guidanceZoomIsRamping
    policy = AVFoundationDocumentCapturePolicy(configuration: configuration)
    let queue = DispatchQueue(
      label: "IdentityEvidenceSDK.AVFoundationCameraSessionController"
    )
    sessionQueue = queue
    state = queue.sync { State(now: now) }
    state.temporalRecorder = DocumentTemporalRecorder(
      configuration: configuration.temporalEvidence, diagnosticSink: diagnosticSink)
  }

  deinit {
    for token in state.temporalNotifications { notifications.removeObserver(token) }
    state.temporalReadbackTimer?.cancel()
    state.temporalRecorder?.stop()
  }

  func setQualityObservationHandler(
    configuration: DocumentCameraDiagnosticsConfiguration,
    handler: @escaping @Sendable (DocumentCaptureQualityObservation) -> Void
  ) {
    sessionQueue.sync {
      diagnosticsConfiguration = configuration
      #if os(iOS)
        state.adaptiveController = DocumentAdaptiveCameraController(
          tuning: configuration.tuning, now: now)
      #endif
      qualityObservationHandler = handler
    }
  }

  func start(
    completion:
      @escaping @Sendable (
        Result<DocumentCameraHardwareSelection, PhotoCaptureError>
      ) -> Void
  ) {
    sessionQueue.async { [self] in
      state.nativeCaptureReady = false
      do {
        guard state.processors.isEmpty, !state.graphReleasePending else {
          throw PhotoCaptureError.cameraNotReady
        }
        if let issue = diagnosticsConfiguration.tuning.validationIssue {
          throw PhotoCaptureError.configurationFailed(issue)
        }
        guard policy.configuration.temporalEvidence.valid else {
          throw PhotoCaptureError.configurationFailed("invalid_temporal_evidence_limits")
        }
        try configureIfNeeded()
        if !state.captureSession.isRunning {
          state.captureSession.startRunning()
        }
        guard state.captureSession.isRunning else {
          releaseFailedStartup {
            completion(.failure(.configurationFailed("session_did_not_start")))
          }
          return
        }
        #if os(iOS)
          guard !state.captureSession.isInterrupted else {
            releaseFailedStartup { completion(.failure(.cameraNotReady)) }
            return
          }
        #endif
        guard let hardwareSelection = state.hardwareSelection else {
          releaseFailedStartup {
            completion(.failure(.configurationFailed("camera_selection_unavailable")))
          }
          return
        }
        reconcileOpticalState()
        guard !state.needsOpticalReconfiguration, !state.nativeOperationUncertain else {
          releaseFailedStartup {
            completion(.failure(.configurationFailed("optical_configuration_unavailable")))
          }
          return
        }
        startTemporalRecording()
        state.zoomRetirementFailed = false
        state.nativeCaptureReady = true
        completion(.success(hardwareSelection))
      } catch let error as PhotoCaptureError {
        completion(.failure(error))
      } catch {
        completion(.failure(.configurationFailed(String(describing: error))))
      }
    }
  }

  func stop() {
    sessionQueue.async { [self] in
      cancelTiltGuidance(reason: .sessionStopped)
      state.nativeCaptureReady = false
      state.temporalReadbackTimer?.cancel()
      state.temporalReadbackTimer = nil
      state.temporalRecorder?.stop()
      if state.captureSession.isRunning {
        state.captureSession.stopRunning()
      }
      cancelPendingDiagnostic()
      state.latestQualityObservation = nil
      state.frameAnalyzer?.reset()
      #if os(iOS)
        state.adaptiveController.reset()
        refreshAnalysisGeometry()
      #endif
      releaseStoppedCaptureGraph()
    }
  }

  func capture(
    request: CameraPhotoCaptureRequest,
    completion:
      @escaping @Sendable (
        Result<CapturedDocumentPhoto, PhotoCaptureError>
      ) -> Void
  ) {
    sessionQueue.async { [self] in
      reconcileOpticalState()
      guard state.captureAdmissionEnabled else {
        completion(.failure(.captureAdmissionSuspended))
        return
      }
      guard !state.needsOpticalReconfiguration,
        state.pendingDiagnosticID == nil,
        !state.nativeOperationUncertain
      else {
        completion(.failure(.cameraNotReady))
        return
      }
      #if os(iOS)
        let isGuideAvailable = state.captureDeviceGuideRegion != nil
        let currentGeometryRevision: UInt64? = state.geometryRevision
        let nativeGuideRegion = state.captureDeviceGuideRegion
        let captureOrientation = state.captureOrientation
      #else
        let isGuideAvailable = true
        let currentGeometryRevision: UInt64? = nil
        let nativeGuideRegion: DocumentCameraGuideRegion? = nil
        let captureOrientation: DocumentCameraOrientation? = nil
      #endif
      let admittedAt = now()
      if request.qualityGate == .livePDF417AutoCapture {
        guard policy.configuration.livePDF417, request.side == .back,
          let candidate = state.pdf417Candidate,
          request.livePDF417Candidate == candidate.payload,
          (0...1).contains(admittedAt.timeIntervalSince(candidate.observedAt))
        else {
          completion(.failure(.captureObservationUnavailable))
          return
        }
      }
      let admissionContext = DocumentCaptureAdmissionPolicy.Context(
        isConfigured: state.isConfigured,
        isRunning: state.captureSession.isRunning,
        isCaptureInFlight: !state.processors.isEmpty,
        isGuideAvailable: isGuideAvailable,
        currentGeometryRevision: currentGeometryRevision,
        observation: state.latestQualityObservation,
        side: request.side,
        qualityGate: request.qualityGate,
        requiredObservationIdentity: request.requiredObservationIdentity,
        admissionTime: admittedAt
      )
      if let failure = admissionPolicy.failure(in: admissionContext) {
        completion(.failure(failure))
        return
      }

      if !controlsPermitCapture(request) {
        completion(.failure(.captureQualityNotReady))
        return
      }
      performAdmittedCapture(
        request: request, admittedAt: admittedAt, nativeGuideRegion: nativeGuideRegion,
        captureOrientation: captureOrientation, completion: completion)
    }
  }

  private func performAdmittedCapture(
    request: CameraPhotoCaptureRequest,
    admittedAt: Date,
    nativeGuideRegion: DocumentCameraGuideRegion?,
    captureOrientation: DocumentCameraOrientation?,
    completion: @escaping @Sendable (Result<CapturedDocumentPhoto, PhotoCaptureError>) -> Void
  ) {
    let settings = policy.makePhotoSettings(
      photoOutput: state.photoOutput,
      locationAssertion: request.locationAssertion
    )
    let admission = makeAdmissionSnapshot(
      request: request,
      admittedAt: admittedAt,
      photoSettingsUniqueID: settings.uniqueID,
      nativeCaptureDeviceGuideRegion: nativeGuideRegion,
      captureOrientation: captureOrientation
    )
    updateTemporalCameraState()
    state.temporalRecorder?.beginCapture()
    capturePhoto(
      settings: settings,
      admission: admission,
      locationAssertion: request.locationAssertion,
      completion: completion
    )
  }

  #if os(iOS)
    @MainActor
    func attachPreview(to previewLayer: AVCaptureVideoPreviewLayer) {
      previewLayer.session = state.captureSession
    }

    @MainActor
    func updateCaptureOrientation(_ orientation: DocumentCameraOrientation) {
      sessionQueue.async { [self] in
        guard orientation != state.captureOrientation else { return }
        state.captureOrientation = orientation
        applyStoredOrientation()
        refreshAnalysisGeometry()
      }
    }

    @MainActor
    func updateDocumentGuideRegion(_ region: DocumentCameraGuideRegion?) {
      sessionQueue.async { [self] in
        let validatedRegion = region?.normalizedTopLeftRect.map {
          DocumentCameraGuideRegion(
            minX: $0.minX,
            minY: $0.minY,
            width: $0.width,
            height: $0.height
          )
        }
        if let validatedRegion, let currentRegion = state.captureDeviceGuideRegion {
          if validatedRegion.isEffectivelyEqual(to: currentRegion) {
            return
          }
        }
        guard validatedRegion != state.captureDeviceGuideRegion else { return }
        state.captureDeviceGuideRegion = validatedRegion
        refreshAnalysisGeometry()
      }
    }
  #endif
}

extension AVFoundationCameraSessionController: CameraSessionStopAwaiting {
  func afterStop(_ completion: @escaping @Sendable (Bool) -> Void) {
    sessionQueue.async { [self] in
      if state.graphReleasePending {
        state.stopWaiters.append(completion)
      } else {
        completion(
          !state.captureSession.isRunning && !state.isConfigured && !state.zoomRetirementFailed)
      }
    }
  }
}

#if os(iOS)
  extension AVFoundationCameraSessionController {
    func refreshAnalysisGeometry(
      resetReason: DocumentLiveGeometryObservation.ResetReason = .geometryRevisionChanged,
      preservingPendingClockBinding: Bool = false
    ) {
      // Initial guide publication may arrive after an opted-in begin. Its controller is
      // queued only after this guide update; there is no prior geometry to invalidate yet.
      if state.tiltGuidance.controllerStarted
        || (resetReason == .clockChanged && !preservingPendingClockBinding)
      {
        cancelTiltGuidance(
          reason: resetReason == .clockChanged ? .clockChanged : .geometryChanged,
          resetGeometry: false)
      }
      resetAnalysisGeometry(resetReason: resetReason)
    }

    /// One source/readiness fence, shared by geometry changes and standalone controls release.
    /// This mutation never re-enters tilt cancellation.
    func resetAnalysisGeometry(
      resetReason: DocumentLiveGeometryObservation.ResetReason = .geometryRevisionChanged
    ) {
      state.temporalRecorder?.discontinuity("geometry_revision_changed")
      state.geometryRevision &+= 1
      state.latestQualityObservation = nil
      state.videoBufferGuideRegion = state.captureDeviceGuideRegion?.convertedToVideoBuffer(
        orientation: state.captureOrientation
      )
      state.frameAnalyzer?.updateGuideRegion(
        state.videoBufferGuideRegion,
        geometryRevision: state.geometryRevision, resetReason: resetReason
      )
    }

    func applyStoredOrientation() {
      if let photoConnection = state.photoOutput.connection(with: .video) {
        apply(state.captureOrientation, to: photoConnection)
      }
      if let videoConnection = state.videoOutput.connection(with: .video) {
        apply(state.captureOrientation, to: videoConnection)
      }
    }

    func apply(
      _ orientation: DocumentCameraOrientation,
      to connection: AVCaptureConnection
    ) {
      if #available(iOS 17.0, *) {
        let angle = orientation.videoRotationAngle
        if connection.isVideoRotationAngleSupported(angle) {
          connection.videoRotationAngle = angle
        }
      } else if connection.isVideoOrientationSupported {
        connection.videoOrientation = orientation.legacyVideoOrientation
      }
    }
  }
#endif

extension AVFoundationCameraSessionController {
  func publishAdaptiveObservation(_ input: DocumentCaptureQualityObservation) {
    reconcileOpticalState()
    guard state.captureAdmissionEnabled, !state.needsOpticalReconfiguration,
      state.pendingDiagnosticID == nil,
      !state.nativeOperationUncertain
    else { return }
    #if os(iOS)
      guard input.geometryRevision == state.geometryRevision else { return }
    #endif
    var observation = input
    #if os(iOS)
      let adaptiveEnabled =
        diagnosticsConfiguration.includesAdaptiveCapture
        && state.adaptiveCaptureEnabled && !state.tiltGuidance.holding
      if adaptiveEnabled {
        guard state.processors.isEmpty, let device = state.activeDevice
        else { return }
        let point = CGPoint(
          x: input.metrics.documentCenterX ?? input.metrics.guideCenterX ?? 0.5,
          y: input.metrics.documentCenterY ?? input.metrics.guideCenterY ?? 0.5)
        let nativePoint = state.captureOrientation.captureDevicePoint(fromVideoBuffer: point)
        guard
          let adjusted = state.adaptiveController.process(
            input, device: AVFoundationAdaptiveDevice(device: device),
            nativePoint: nativePoint
          )
        else {
          state.latestQualityObservation = nil
          refreshAnalysisGeometry()
          return
        }
        observation = adjusted
      }
    #endif
    updateTemporalCameraState()
    state.latestQualityObservation = observation
    qualityObservationHandler(observation)
  }
}

extension AVFoundationCameraSessionController: CameraSessionFailureReporting {
  func setFailureHandler(_ handler: @escaping @Sendable () -> Void) {
    sessionQueue.async { [self] in state.failureHandler = handler }
  }

  func reportNativeFailure(_ reason: String) {
    cancelTiltGuidance(reason: .sessionStopped)
    state.nativeCaptureReady = false
    state.latestQualityObservation = nil
    resetGeometryObservationEpoch(reason: .sessionReset)
    state.temporalRecorder?.sessionFailed(reason: reason)
    state.failureHandler?()
  }
}
