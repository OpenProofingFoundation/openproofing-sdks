import Foundation

/// A single begin may wait for the previous run's archive. It owns no native controls or evidence
/// until the old drain completes and admission is checked again on the session queue.
struct NativeTiltBeginRequest {
  let runID: UUID
  let configuration: DocumentTiltConfiguration
  let cancellation: DocumentTiltStartCancellation
  let requestedAt: Double
  let completion: @Sendable (Result<DocumentTiltPresentation, PhotoCaptureError>) -> Void

  func isCurrent(at now: Double) -> Bool {
    !cancellation.isCancelled
      && now - requestedAt <= DocumentCaptureTuning.Controls.adjustmentTimeoutSeconds
  }
}

extension AVFoundationCameraSessionController {
  func admitTiltBegin(_ request: NativeTiltBeginRequest) {
    guard request.isCurrent(at: DocumentTemporalRecorder.hostNow()), request.configuration.valid,
      state.nativeCaptureReady, state.isConfigured, state.processors.isEmpty,
      !state.graphReleasePending, !state.nativeOperationUncertain,
      !state.needsOpticalReconfiguration, state.pendingDiagnosticID == nil,
      !state.tiltGuidance.holding, state.tiltGuidance.pendingBegin == nil,
      state.frameAnalyzer != nil
    else {
      request.completion(.failure(.cameraNotReady))
      return
    }
    if state.tiltGuidance.archiveDrainPending {
      state.tiltGuidance.pendingBegin = request
      return
    }
    do {
      try retireCurrentZoomRamp()
      try prepareNativeTiltFocus(state.activeDevice)
    } catch {
      request.completion(.failure(.configurationFailed("guidance_native_controls_unavailable")))
      return
    }
    state.tiltGuidance = NativeTiltGuidanceState(
      runID: request.runID, holding: true, configuration: request.configuration,
      startedAt: DocumentTemporalRecorder.hostNow(), beginCompletion: request.completion)
    state.latestQualityObservation = nil
    #if os(iOS)
      state.adaptiveController.reset()
    #endif
    pollTiltGuidance()
  }

  func resumePendingTiltBegin() {
    guard let request = state.tiltGuidance.pendingBegin else { return }
    state.tiltGuidance.pendingBegin = nil
    admitTiltBegin(request)
  }

  func cancelPendingTiltBegin(runID: UUID? = nil) {
    guard let request = state.tiltGuidance.pendingBegin,
      runID == nil || request.runID == runID
    else { return }
    state.tiltGuidance.pendingBegin = nil
    request.completion(.failure(.cameraNotReady))
  }

  /// The existing native readback timer also bounds a begin waiting on archival, even though that
  /// request has not acquired controls. Stop and lifecycle invalidation resolve it immediately.
  func expirePendingTiltBegin(now: Double) {
    guard let request = state.tiltGuidance.pendingBegin, !request.isCurrent(at: now) else { return }
    cancelPendingTiltBegin()
  }
}
