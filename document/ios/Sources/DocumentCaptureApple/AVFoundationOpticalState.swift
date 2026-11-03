import AVFoundation
import Foundation

extension AVFoundationCameraSessionController {
  func observeOpticalChanges(_ device: AVCaptureDevice) {
    dispatchPrecondition(condition: .onQueue(sessionQueue))
    state.deviceObservations.removeAll()
    state.observationEpoch &+= 1
    let epoch = state.observationEpoch
    state.deviceObservations.append(
      device.observe(\.activeFormat, options: [.new]) { [weak self] _, _ in
        self?.enqueueOpticalChange(epoch: epoch)
      })
    #if os(iOS)
      state.deviceObservations.append(
        device.observe(\.activePrimaryConstituent, options: [.new]) { [weak self] _, _ in
          self?.enqueueOpticalChange(epoch: epoch)
        })
    #endif
  }

  private func enqueueOpticalChange(epoch: UInt64) {
    sessionQueue.async { [weak self] in
      guard let self, epoch == state.observationEpoch else { return }
      reconcileOpticalState()
    }
  }

  /// Reconcile on every observation/admission as well as KVO: queued notifications
  /// must not allow an old optical epoch through the shutter.
  func reconcileOpticalState() {
    dispatchPrecondition(condition: .onQueue(sessionQueue))
    guard state.isConfigured, !state.graphReleasePending, !state.isConfiguring,
      let device = state.activeDevice else { return }
    let signature = opticalSignature(device)
    if state.opticalSignature != signature {
      state.opticalSignature = signature
      state.needsOpticalReconfiguration = true
      invalidateOpticalEvidence()
    }
    guard state.needsOpticalReconfiguration, state.processors.isEmpty,
      state.pendingDiagnosticID == nil, !state.nativeOperationUncertain
    else { return }
    reconfigureOpticalOutput {
      try policy.configurePhotoOutput(
        device: device, photoOutput: state.photoOutput)
      #if os(iOS)
        guard applyVerifiedOutputOrientation() else {
          throw PhotoCaptureError.configurationFailed("output_rotation_unavailable")
        }
      #endif
    }
  }

  /// Finish the native transaction before notifying the recording/coordinator failure path.
  /// Continuing with an unverified optical epoch would admit stale capture evidence.
  func reconfigureOpticalOutput(_ configure: () throws -> Void) {
    dispatchPrecondition(condition: .onQueue(sessionQueue))
    guard !state.nativeOperationUncertain else { return }
    state.isConfiguring = true
    state.captureSession.beginConfiguration()
    var failed = false
    defer {
      state.captureSession.commitConfiguration()
      state.isConfiguring = false
      notifyPreviewEpoch()
      if failed { reportNativeFailure("optical_configuration_failed") }
    }
    do {
      try configure()
      state.needsOpticalReconfiguration = false
    } catch {
      state.nativeOperationUncertain = true
      failed = true
    }
  }

  func notifyPreviewEpoch() {
    if let handler = state.previewInvalidationHandler {
      let revision = state.opticalRevision
      Task { @MainActor in handler(revision) }
    }
  }

  func invalidateOpticalEvidence() {
    state.opticalRevision &+= 1
    state.latestQualityObservation = nil
    #if os(iOS)
      state.adaptiveController.reset()
      state.captureDeviceGuideRegion = nil
      refreshAnalysisGeometry()
    #else
      state.frameAnalyzer?.reset()
    #endif
  }

  private func opticalSignature(_ device: AVCaptureDevice) -> String {
    #if os(iOS)
      let primary = device.activePrimaryConstituent?.uniqueID ?? "unavailable"
    #else
      let primary = device.uniqueID
    #endif
    return device.uniqueID + "/" + primary + "/"
      + String(describing: ObjectIdentifier(device.activeFormat))
  }

  #if os(iOS)
    func applyVerifiedOutputOrientation() -> Bool {
      guard let photo = state.photoOutput.connection(with: .video),
        let video = state.videoOutput.connection(with: .video)
      else { return false }
      for connection in [photo, video] {
        if #available(iOS 17.0, *) {
          let angle = state.captureOrientation.videoRotationAngle
          guard connection.isVideoRotationAngleSupported(angle) else { return false }
          if connection.videoRotationAngle != angle { connection.videoRotationAngle = angle }
          guard connection.videoRotationAngle == angle else { return false }
        } else {
          guard connection.isVideoOrientationSupported else { return false }
          if connection.videoOrientation != state.captureOrientation.legacyVideoOrientation {
            connection.videoOrientation = state.captureOrientation.legacyVideoOrientation
          }
          guard connection.videoOrientation == state.captureOrientation.legacyVideoOrientation
          else { return false }
        }
      }
      return true
    }
  #endif
}
