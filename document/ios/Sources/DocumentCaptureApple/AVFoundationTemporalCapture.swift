import AVFoundation
import Foundation

extension AVFoundationCameraSessionController {
  /// Fence ordered analysis transactions before publishing the new clock boundary.
  func temporalClockDidChange(
    to replacement: CMClock?,
    observedTransition: (previous: ObjectIdentifier?, current: ObjectIdentifier?)? = nil
  ) {
    // First binding can finish pending setup; it cannot preserve an already-started attempt.
    let observedInitialBinding =
      observedTransition.map { transition in
        transition.previous == nil && transition.current != nil
          && transition.current == replacement.map(ObjectIdentifier.init)
      } ?? false
    let recorder = state.temporalRecorder
    let preservingPendingClockBinding =
      observedInitialBinding && replacement != nil
      && state.tiltGuidance.holding && state.tiltGuidance.beginCompletion != nil
      && !state.tiltGuidance.controllerStarted
      && recorder.map { recorder in
        recorder.withState { recorder.clock == nil && !recorder.pinned }
      } == true
    if !preservingPendingClockBinding { cancelTiltGuidance(reason: .clockChanged) }
    state.temporalRecorder?.clockDidChange(to: replacement)
    resetGeometryObservationEpoch(
      reason: .clockChanged, preservingPendingClockBinding: preservingPendingClockBinding)
  }

  func startTemporalRecording() {
    guard let recorder = state.temporalRecorder else { return }
    recorder.start(clock: state.captureSession.synchronizationClock)
    updateTemporalCameraState()
    state.temporalReadbackTimer?.cancel()
    let epoch = state.temporalObservationEpoch
    let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      guard let self, epoch == state.temporalObservationEpoch else { return }
      updateTemporalCameraState()
    }
    state.temporalReadbackTimer = timer
    timer.resume()
    if state.temporalClockObservation == nil {
      state.temporalClockObservation = state.captureSession.observe(
        \.synchronizationClock, options: [.old, .new]
      ) { [weak self] _, change in
        let previous = change.oldValue.flatMap { $0 }.map(ObjectIdentifier.init)
        let current = change.newValue.flatMap { $0 }.map(ObjectIdentifier.init)
        guard previous != current, let self else { return }
        self.sessionQueue.async { [self] in
          guard epoch == state.temporalObservationEpoch else { return }
          let replacement = state.captureSession.synchronizationClock
          temporalClockDidChange(
            to: replacement,
            observedTransition: (previous: previous, current: current))
        }
      }
    }
    guard state.temporalNotifications.isEmpty else { return }
    let interrupted = AVCaptureSession.wasInterruptedNotification
    let runtimeError = AVCaptureSession.runtimeErrorNotification
    let notificationNames = [interrupted, runtimeError]
    for name in notificationNames {
      let token = notifications.addObserver(
        forName: name, object: state.captureSession, queue: nil
      ) { [weak self] notification in
        let reason = notification.name.rawValue
        guard let self else { return }
        self.sessionQueue.async { [self] in
          guard epoch == state.temporalObservationEpoch else { return }
          reportNativeFailure(reason)
        }
      }
      state.temporalNotifications.append(token)
    }
  }

  func updateTemporalCameraState() {
    pollTiltGuidance()
    #if os(iOS)
      guard let recorder = state.temporalRecorder, let device = state.activeDevice else { return }
      let connection = state.videoOutput.connection(with: .video)
      let rotation: Double
      if #available(iOS 17.0, macOS 14.0, *) {
        rotation = Double(connection?.videoRotationAngle ?? 0)
      } else {
        rotation = 0
      }
      let geometryRevision = state.geometryRevision
      recorder.updateCamera(
        DocumentTemporalCameraState(
          readbackHostTimeSeconds: DocumentTemporalRecorder.hostNow(),
          geometryRevision: geometryRevision, opticalRevision: state.opticalRevision,
          focusModeRawValue: device.focusMode.rawValue,
          exposureModeRawValue: device.exposureMode.rawValue,
          deviceUniqueID: device.uniqueID, lensPosition: device.lensPosition,
          exposureDurationSeconds: CMTimeGetSeconds(device.exposureDuration), iso: device.iso,
          zoomFactor: Double(device.videoZoomFactor), adjustingFocus: device.isAdjustingFocus,
          adjustingExposure: device.isAdjustingExposure, rotationDegrees: rotation,
          mirrored: connection?.isVideoMirrored ?? false))
    #endif
  }

  func completeTemporalCapture(
    identifier: Int64, result: Result<CapturedDocumentPhoto, PhotoCaptureError>,
    completion: @escaping @Sendable (Result<CapturedDocumentPhoto, PhotoCaptureError>) -> Void
  ) {
    guard let recorder = state.temporalRecorder, case .success(let photo) = result else {
      state.temporalRecorder?.abandonCapture()
      deliverTemporalCapture(identifier: identifier, result: result, completion: completion)
      return
    }
    let delay = recorder.delayAfterPhoto(photo)
    sessionQueue.asyncAfter(deadline: .now() + delay) { [self] in
      finishTemporalTail(
        identifier: identifier, photo: photo, remainingChecks: 10, completion: completion)
    }
  }

  private func finishTemporalTail(
    identifier: Int64, photo: CapturedDocumentPhoto, remainingChecks: Int,
    completion: @escaping @Sendable (Result<CapturedDocumentPhoto, PhotoCaptureError>) -> Void
  ) {
    guard let recorder = state.temporalRecorder else { return }
    if remainingChecks > 0, recorder.needsTailObservation(photo) {
      sessionQueue.asyncAfter(deadline: .now() + 0.05) { [self] in
        finishTemporalTail(
          identifier: identifier, photo: photo, remainingChecks: remainingChecks - 1,
          completion: completion)
      }
      return
    }
    let evidence = recorder.finishForDelivery(photo)
    let bound = CapturedDocumentPhoto(
      sessionID: photo.sessionID, side: photo.side, requestedAt: photo.requestedAt,
      captureTimestamp: photo.captureTimestamp, processedAt: photo.processedAt,
      data: photo.data, fidelity: photo.fidelity, admission: photo.admission,
      platformMetadata: photo.platformMetadata, location: photo.location,
      temporalEvidence: evidence, motionEvidence: photo.motionEvidence)
    deliverTemporalCapture(identifier: identifier, result: .success(bound), completion: completion)
  }

  private func deliverTemporalCapture(
    identifier: Int64, result: Result<CapturedDocumentPhoto, PhotoCaptureError>,
    completion: @escaping @Sendable (Result<CapturedDocumentPhoto, PhotoCaptureError>) -> Void
  ) {
    state.processors[identifier] = nil
    if state.graphReleasePending { releaseStoppedCaptureGraph() }
    reconcileOpticalState()
    if state.previewRefreshPending {
      state.previewRefreshPending = false
      notifyPreviewEpoch()
    }
    completion(result)
  }
}
