import AVFoundation
import Foundation

extension AVFoundationCameraSessionController: CameraSessionDiagnosticsControlling {
  func performDiagnostic(
    _ command: DocumentCameraDiagnosticCommand,
    completion:
      @escaping @Sendable (Result<DocumentCameraNativeSnapshot, PhotoCaptureError>) -> Void
  ) {
    sessionQueue.async { [self] in
      do {
        reconcileOpticalState()
        if case .inspect = command {
          completion(.success(try nativeSnapshot()))
          return
        }
        guard state.isConfigured, state.captureSession.isRunning, state.processors.isEmpty,
          state.pendingDiagnosticID == nil, !state.nativeOperationUncertain,
          !state.isConfiguring, !state.needsOpticalReconfiguration
        else { throw PhotoCaptureError.cameraNotReady }
        cancelTiltGuidance(reason: .nativeControlsChanged)
        #if os(iOS)
          try executeDiagnostic(command, completion: completion)
        #else
          throw PhotoCaptureError.configurationFailed("native_diagnostics_requires_ios")
        #endif
      } catch let error as PhotoCaptureError {
        notifyPreviewEpoch()
        completion(.failure(error))
      } catch {
        notifyPreviewEpoch()
        completion(.failure(.configurationFailed(String(describing: error))))
      }
    }
  }

  func cancelPendingDiagnostic() {
    let completion = state.pendingDiagnosticCompletion
    if state.pendingDiagnosticID != nil { state.nativeOperationUncertain = true }
    state.pendingDiagnosticID = nil
    state.pendingDiagnosticCompletion = nil
    completion?(.failure(.cameraNotReady))
  }

  func nativeSnapshot() throws -> DocumentCameraNativeSnapshot {
    dispatchPrecondition(condition: .onQueue(sessionQueue))
    #if os(iOS)
      guard let device = state.activeDevice else { throw PhotoCaptureError.cameraNotReady }
      let video = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
      let photo = state.photoOutput.maxPhotoDimensions
      return DocumentCameraNativeSnapshot(
        snapshotTime: now(), selection: state.selection,
        availableChoices: policy.availableChoices(),
        logicalDeviceID: device.uniqueID, logicalDeviceType: device.deviceType.rawValue,
        activePrimaryDeviceID: device.activePrimaryConstituent?.uniqueID,
        activePrimaryDeviceType: device.activePrimaryConstituent?.deviceType.rawValue,
        opticalRevision: state.opticalRevision,
        adaptiveCaptureEnabled: state.adaptiveCaptureEnabled,
        reconfiguring: state.isConfiguring || state.needsOpticalReconfiguration
          || state.pendingDiagnosticID != nil || state.nativeOperationUncertain,
        zoom: Double(device.videoZoomFactor),
        minimumZoom: Double(device.minAvailableVideoZoomFactor),
        maximumZoom: Double(device.maxAvailableVideoZoomFactor),
        focusModeRawValue: device.focusMode.rawValue,
        lensPosition: Double(device.lensPosition), adjustingFocus: device.isAdjustingFocus,
        adjustingExposure: device.isAdjustingExposure, rampingZoom: device.isRampingVideoZoom,
        supportsManualFocus: !device.isVirtualDevice
          && device.isLockingFocusWithCustomLensPositionSupported,
        videoWidth: Int(video.width), videoHeight: Int(video.height),
        photoWidth: Int(photo.width), photoHeight: Int(photo.height),
        manualFocusAppliedDeviceTime: state.manualFocusAppliedDeviceTime)
    #else
      throw PhotoCaptureError.configurationFailed("native_diagnostics_requires_ios")
    #endif
  }
}

#if os(iOS)
  extension AVFoundationCameraSessionController {
    private func executeDiagnostic(
      _ command: DocumentCameraDiagnosticCommand,
      completion:
        @escaping @Sendable (Result<DocumentCameraNativeSnapshot, PhotoCaptureError>) -> Void
    ) throws {
      guard let device = state.activeDevice else { throw PhotoCaptureError.cameraNotReady }
      try retireCurrentZoomRamp()
      state.adaptiveCaptureEnabled = false
      invalidateOpticalEvidence()
      switch command {
      case .inspect: break
      case .selectCamera(let choice): try switchCamera(to: choice)
      case .setAdaptiveCaptureEnabled(let enabled):
        if enabled { try continuousFocus(device) }
        state.adaptiveCaptureEnabled = enabled
      case .setLensPosition(let position):
        try requestManualFocus(position, device: device, completion: completion)
        return
      case .setZoom(let zoom):
        try setDiagnosticZoom(zoom, device: device)
      case .autofocusCenter:
        guard try AVFoundationAdaptiveDevice(device: device).focus(at: CGPoint(x: 0.5, y: 0.5))
        else {
          throw PhotoCaptureError.configurationFailed("center_autofocus_unsupported")
        }
      case .continuousFocus: try continuousFocus(device)
      }
      reconcileOpticalState()
      notifyPreviewEpoch()
      completion(.success(try nativeSnapshot()))
    }

    private func setDiagnosticZoom(_ zoom: Double, device: AVCaptureDevice) throws {
      guard zoom.isFinite, zoom >= Double(device.minAvailableVideoZoomFactor),
        zoom <= Double(device.maxAvailableVideoZoomFactor)
      else {
        throw PhotoCaptureError.configurationFailed("zoom_out_of_range")
      }
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      device.videoZoomFactor = CGFloat(zoom)
    }

    private func continuousFocus(_ device: AVCaptureDevice) throws {
      guard device.isFocusModeSupported(.continuousAutoFocus) else {
        throw PhotoCaptureError.configurationFailed("continuous_autofocus_unsupported")
      }
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      if device.isFocusPointOfInterestSupported {
        device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
      }
      device.focusMode = .continuousAutoFocus
      if device.isExposurePointOfInterestSupported {
        device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
      }
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
    }

    private func requestManualFocus(
      _ position: Double, device: AVCaptureDevice,
      completion:
        @escaping @Sendable (Result<DocumentCameraNativeSnapshot, PhotoCaptureError>) -> Void
    ) throws {
      guard !device.isVirtualDevice, device.isLockingFocusWithCustomLensPositionSupported,
        position.isFinite, (0...1).contains(position)
      else {
        throw PhotoCaptureError.configurationFailed(
          "manual_focus_configuration_unsupported")
      }
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      let requestID = UUID()
      state.pendingDiagnosticID = requestID
      state.pendingDiagnosticCompletion = completion
      state.manualFocusAppliedDeviceTime = nil
      device.setFocusModeLocked(lensPosition: Float(position)) { [weak self] timestamp in
        self?.sessionQueue.async { [weak self] in
          guard let self, state.pendingDiagnosticID == requestID else { return }
          state.manualFocusAppliedDeviceTime =
            timestamp.isNumeric ? CMTimeGetSeconds(timestamp) : nil
          finishManualFocus(requestID)
        }
      }
      sessionQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
        guard let self, state.pendingDiagnosticID == requestID else { return }
        state.nativeOperationUncertain = true
        cancelPendingDiagnostic()
      }
    }

    private func finishManualFocus(_ requestID: UUID) {
      guard state.pendingDiagnosticID == requestID else { return }
      let completion = state.pendingDiagnosticCompletion
      state.pendingDiagnosticID = nil
      state.pendingDiagnosticCompletion = nil
      reconcileOpticalState()
      notifyPreviewEpoch()
      do { completion?(.success(try nativeSnapshot())) } catch {
        completion?(.failure(.configurationFailed("manual_focus_readback_failed")))
      }
    }
  }
#endif
