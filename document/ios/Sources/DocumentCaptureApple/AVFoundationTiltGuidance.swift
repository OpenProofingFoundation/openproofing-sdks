import AVFoundation
import Foundation

struct NativeTiltGuidanceState {
  var runID: UUID?
  var holding = false
  var archiveDrainPending = false
  var pendingBegin: NativeTiltBeginRequest?
  var configuration = DocumentTiltConfiguration.provisionalV1
  var startedAt = 0.0
  var controllerStarted = false
  var beginCompletion: (@Sendable (Result<DocumentTiltPresentation, PhotoCaptureError>) -> Void)?
}

func nativeGuidanceZoomIsRamping(_ device: AVCaptureDevice?) -> Bool? {
  #if os(iOS)
    return device?.isRampingVideoZoom
  #else
    return device == nil ? nil : false
  #endif
}

/// Select native continuous focus once; retain exposure settings and focus point.
/// Unsupported hardware retains its actual mode, reported by normal camera readback.
func prepareNativeTiltFocus(_ device: AVCaptureDevice?) throws {
  guard let device, device.isFocusModeSupported(.continuousAutoFocus) else { return }
  try device.lockForConfiguration()
  defer { device.unlockForConfiguration() }
  device.focusMode = .continuousAutoFocus
}

extension AVFoundationCameraSessionController: CameraSessionTiltGuidanceControlling {
  func setTiltGuidanceHandler(_ handler: @escaping @Sendable (DocumentTiltPresentation) -> Void) {
    sessionQueue.sync { tiltGuidanceHandler = handler }
  }

  func beginTiltGuidance(
    runID: UUID, configuration: DocumentTiltConfiguration,
    cancellation: DocumentTiltStartCancellation,
    completion: @escaping @Sendable (Result<DocumentTiltPresentation, PhotoCaptureError>) -> Void
  ) {
    sessionQueue.async { [self] in
      admitTiltBegin(
        .init(
          runID: runID, configuration: configuration, cancellation: cancellation,
          requestedAt: DocumentTemporalRecorder.hostNow(), completion: completion))
    }
  }

  func endTiltGuidance(
    runID: UUID, reason: DocumentTiltReason, completion: @escaping @Sendable () -> Void
  ) {
    sessionQueue.async { [self] in
      cancelPendingTiltBegin(runID: runID)
      guard state.tiltGuidance.runID == runID else {
        completion()
        return
      }
      finishTiltGuidance(runID: runID, reason: reason, completion: completion)
    }
  }
}

extension AVFoundationCameraSessionController {
  /// Existing native readback timer supplies both cancellation readback and silence failure.
  func pollTiltGuidance(now: Double = DocumentTemporalRecorder.hostNow()) {
    expirePendingTiltBegin(now: now)
    guard state.tiltGuidance.holding, let runID = state.tiltGuidance.runID,
      let analyzer = state.frameAnalyzer
    else { return }
    let silenceExceeded = analyzer.tiltGuidanceTransport.silenceExceeded(
      runID: runID, now: now,
      maximum: state.tiltGuidance.configuration.observationSilenceTimeoutSeconds)
    if state.tiltGuidance.beginCompletion != nil {
      let elapsed = now - state.tiltGuidance.startedAt
      if elapsed > DocumentCaptureTuning.Controls.adjustmentTimeoutSeconds {
        cancelTiltGuidance(
          reason: guidanceZoomIsRamping(state.activeDevice) == false
            ? .observationUnavailable : .zoomNotSettled)
        return
      }
      if !state.tiltGuidance.controllerStarted {
        guard guidanceZoomIsRamping(state.activeDevice) == false else { return }
        guard let recorder = state.temporalRecorder,
          recorder.withState({ recorder.clock != nil && !recorder.pinned })
        else { return }
        #if os(iOS)
          guard state.captureDeviceGuideRegion != nil, state.videoBufferGuideRegion != nil else {
            return
          }
        #endif
        startTiltController(runID: runID, analyzer: analyzer)
        return
      }
    } else if silenceExceeded {
      cancelTiltGuidance(reason: .observationSilence)
    }
  }

  private func startTiltController(runID: UUID, analyzer: DocumentFrameAnalyzer) {
    state.tiltGuidance.controllerStarted = true
    analyzer.beginTiltGuidance(
      runID: runID, configuration: state.tiltGuidance.configuration
    ) { [self] value in
      sessionQueue.async { [self] in
        guard state.tiltGuidance.runID == runID, state.tiltGuidance.holding else { return }
        guard let value else {
          cancelTiltGuidance(reason: .cancelled)
          return
        }
        let completion = state.tiltGuidance.beginCompletion
        state.tiltGuidance.beginCompletion = nil
        completion?(.success(value))
      }
    }
  }

  func cancelTiltGuidance(reason: DocumentTiltReason, resetGeometry: Bool = true) {
    cancelPendingTiltBegin()
    guard state.tiltGuidance.holding, let runID = state.tiltGuidance.runID else { return }
    finishTiltGuidance(
      runID: runID, reason: reason, resetGeometry: resetGeometry, completion: {
        // Cancellation has no caller waiting on the end of guidance.
      })
  }

  private func finishTiltGuidance(
    runID: UUID, reason: DocumentTiltReason, resetGeometry: Bool = true,
    completion: @escaping @Sendable () -> Void
  ) {
    // A second end acknowledges the already released controls without changing terminal evidence.
    guard state.tiltGuidance.holding else {
      completion()
      return
    }
    let pending = state.tiltGuidance.beginCompletion
    state.tiltGuidance.beginCompletion = nil
    state.tiltGuidance.holding = false
    state.tiltGuidance.archiveDrainPending = state.frameAnalyzer != nil
    if let analyzer = state.frameAnalyzer {
      // Reserve and invalidate control-only archival synchronously, without enqueueing an active begin.
      let unstartedConfiguration =
        state.tiltGuidance.controllerStarted ? nil : state.tiltGuidance.configuration
      state.tiltGuidance.controllerStarted = true
      analyzer.endTiltGuidance(
        runID: runID, reason: reason, unstartedConfiguration: unstartedConfiguration
      ) { [self] in
        sessionQueue.async { [self] in
          guard state.tiltGuidance.runID == runID else { return }
          state.tiltGuidance.archiveDrainPending = false
          resumePendingTiltBegin()
        }
      }
    }
    restoreAfterTiltGuidance(resetGeometry: resetGeometry)
    pending?(.failure(.cameraNotReady))
    // Controls and source admission are fenced now. Archival remains on the real analysis drain;
    // only optional guidance re-entry waits for it. Manual capture must not wait on Vision.
    completion()
  }

  private func restoreAfterTiltGuidance(resetGeometry: Bool) {
    state.latestQualityObservation = nil
    #if os(iOS)
      state.adaptiveController.reset()
      if resetGeometry { resetAnalysisGeometry() }
    #endif
  }

  func enqueueTiltGuidance(_ value: DocumentTiltPresentation, generation: UInt64) {
    if value.phase.terminal {
      // Terminal cleanup is a single critical callback per run, never lossy UI delivery.
      sessionQueue.async { [self] in
        guard state.geometryObservationGeneration == generation,
          state.tiltGuidance.runID == value.runID, state.tiltGuidance.holding
        else { return }
        finishTiltGuidance(
          runID: value.runID, reason: value.reason ?? .completed, completion: {
            // A terminal presentation ends the run; nothing waits on that end.
          })
      }
    }
    guard tiltGuidanceMailbox.offer(value, generation: generation) else { return }
    sessionQueue.async { [self] in
      guard let entry = tiltGuidanceMailbox.take(), state.nativeCaptureReady,
        entry.generation == state.geometryObservationGeneration,
        state.tiltGuidance.runID == entry.presentation.runID
      else { return }
      tiltGuidanceHandler(entry.presentation)
    }
  }
}
