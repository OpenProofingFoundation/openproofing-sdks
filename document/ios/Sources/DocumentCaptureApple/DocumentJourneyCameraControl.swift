import AVFoundation
import Foundation

protocol DocumentJourneyCameraControlling: Sendable {
  func setJourneyRecordingSink(_ sink: (any DocumentJourneyRecordingSink)?)
  func detachJourneyRecordingSink(completion: @escaping @Sendable () -> Void)
  func setCaptureAdmissionEnabled(_ enabled: Bool)
  func updateCaptureAnalysis(
    configuration: DocumentCameraDiagnosticsConfiguration,
    completion: @escaping @Sendable (Result<Void, PhotoCaptureError>) -> Void)
}

extension DocumentCamera {
  public func setJourneyRecordingSink(_ sink: (any DocumentJourneyRecordingSink)?) {
    sink?.appendEvent(
      .init(
        kind: "camera_session_bound",
        hostTimeSeconds: CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())),
        sessionID: sessionID.rawValue.uuidString))
    (sessionController as? any DocumentJourneyCameraControlling)?.setJourneyRecordingSink(sink)
  }

  public func detachJourneyRecordingSink() async {
    guard let controller = sessionController as? any DocumentJourneyCameraControlling else {
      return
    }
    await withCheckedContinuation { continuation in
      controller.detachJourneyRecordingSink { continuation.resume() }
    }
  }

  /// Recording may continue while capture admission is suspended for review.
  public func setCaptureAdmissionEnabled(_ enabled: Bool) {
    (sessionController as? any DocumentJourneyCameraControlling)?.setCaptureAdmissionEnabled(
      enabled)
  }

  public func updateCaptureAnalysis(
    _ configuration: DocumentCameraDiagnosticsConfiguration
  ) async throws {
    guard let controller = sessionController as? any DocumentJourneyCameraControlling else {
      throw PhotoCaptureError.cameraNotReady
    }
    try await withCheckedThrowingContinuation { continuation in
      controller.updateCaptureAnalysis(configuration: configuration) { result in
        continuation.resume(with: result)
      }
    }
  }
}

extension AVFoundationCameraSessionController: DocumentJourneyCameraControlling {
  func setJourneyRecordingSink(_ sink: (any DocumentJourneyRecordingSink)?) {
    sessionQueue.async { [self] in state.temporalRecorder?.setJourneySink(sink) }
  }

  func detachJourneyRecordingSink(completion: @escaping @Sendable () -> Void) {
    sessionQueue.async { [self] in
      guard let analyzer = state.frameAnalyzer else {
        guard let recorder = state.temporalRecorder else {
          completion()
          return
        }
        recorder.detachJourneySink(completion: completion)
        return
      }
      analyzer.ingressQueue.async { [self] in
        analyzer.analysisQueue.async { [self] in
          sessionQueue.async { [self] in
            guard let recorder = state.temporalRecorder else {
              completion()
              return
            }
            recorder.detachJourneySink(completion: completion)
          }
        }
      }
    }
  }

  func setCaptureAdmissionEnabled(_ enabled: Bool) {
    sessionQueue.async { [self] in
      if !enabled { cancelTiltGuidance(reason: .cancelled) }
      state.captureAdmissionRequested = enabled
      state.latestQualityObservation = nil
      if !enabled {
        #if os(iOS)
          state.adaptiveController.reset()
          refreshAnalysisGeometry()
        #endif
      }
      if !enabled && state.processors.isEmpty {
        do { try retireCurrentZoomRamp() } catch {
          reportNativeFailure("zoom_retirement_failed")
        }
      }
    }
  }

  func updateCaptureAnalysis(
    configuration: DocumentCameraDiagnosticsConfiguration,
    completion: @escaping @Sendable (Result<Void, PhotoCaptureError>) -> Void
  ) {
    sessionQueue.async { [self] in
      guard state.processors.isEmpty, state.isConfigured,
        let analyzer = state.frameAnalyzer, configuration.tuning.validationIssue == nil
      else {
        completion(.failure(.cameraNotReady))
        return
      }
      cancelTiltGuidance(reason: .configurationChanged)
      state.captureAdmissionRequested = false
      state.latestQualityObservation = nil
      do { try retireCurrentZoomRamp() } catch {
        completion(
          .failure(.configurationFailed("zoom_retirement_failed")))
        return
      }
      diagnosticsConfiguration = configuration
      #if os(iOS)
        state.adaptiveController = DocumentAdaptiveCameraController(tuning: configuration.tuning, now: now)
        state.captureDeviceGuideRegion = nil
        refreshAnalysisGeometry(resetReason: .configurationChanged)
      #else
        resetGeometryObservationEpoch(reason: .configurationChanged)
      #endif
      analyzer.updateConfiguration(configuration) { [self] in
        sessionQueue.async { [self] in
          notifyPreviewEpoch()
          completion(.success(()))
        }
      }
    }
  }
}
