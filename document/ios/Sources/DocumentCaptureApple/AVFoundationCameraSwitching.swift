import AVFoundation
import Foundation

extension AVFoundationCameraSessionController {
  /// Called only by the serial owner. No input replacement during a still or
  /// manual lens command. A failed replacement restores the previous graph.
  func switchCamera(to choice: DocumentCameraDeviceChoice) throws {
    dispatchPrecondition(condition: .onQueue(sessionQueue))
    guard state.processors.isEmpty, state.pendingDiagnosticID == nil,
      let oldInput = state.activeInput, state.isConfigured
    else {
      throw PhotoCaptureError.cameraNotReady
    }
    guard let selection = policy.selectCamera(choice: choice) else {
      throw PhotoCaptureError.backCameraUnavailable
    }
    if selection.device.uniqueID == oldInput.device.uniqueID {
      state.selection = choice
      return
    }
    let nextInput = try replacementInput(device: selection.device)
    let previousReport = state.hardwareSelection
    let previousChoice = state.selection
    state.isConfiguring = true
    state.captureSession.beginConfiguration()
    state.captureSession.removeInput(oldInput)
    var failure: (any Error)?
    do {
      guard state.captureSession.canAddInput(nextInput) else {
        throw PhotoCaptureError.cannotAddCameraInput
      }
      state.captureSession.addInput(nextInput)
      try policy.configure(device: selection.device, photoOutput: state.photoOutput)
      state.activeInput = nextInput
      state.activeDevice = selection.device
      state.hardwareSelection = selection.hardwareSelection
      state.selection = choice
    } catch {
      failure = error
      restoreCameraInput(
        oldInput, removing: nextInput, report: previousReport, choice: previousChoice)
    }
    state.captureSession.commitConfiguration()
    state.isConfiguring = false
    state.nativeOperationUncertain = false
    state.manualFocusAppliedDeviceTime = nil
    if let device = state.activeDevice {
      observeOpticalChanges(device)
      state.opticalSignature = ""
      reconcileOpticalState()
    } else {
      invalidateOpticalEvidence()
    }
    if let failure { throw failure }
    guard !state.needsOpticalReconfiguration, !state.nativeOperationUncertain else {
      throw PhotoCaptureError.configurationFailed("replacement_camera_configuration_failed")
    }
  }

  private func replacementInput(device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
    try retireCurrentZoomRamp()
    return try AVCaptureDeviceInput(device: device)
  }

  private func restoreCameraInput(
    _ oldInput: AVCaptureDeviceInput, removing nextInput: AVCaptureDeviceInput,
    report: DocumentCameraHardwareSelection?, choice: DocumentCameraDeviceChoice
  ) {
    if state.captureSession.inputs.contains(nextInput) {
      state.captureSession.removeInput(nextInput)
    }
    if state.captureSession.canAddInput(oldInput) {
      state.captureSession.addInput(oldInput)
      state.activeInput = oldInput
      state.activeDevice = oldInput.device
      state.hardwareSelection = report
      state.selection = choice
    } else {
      state.isConfigured = false
      state.activeInput = nil
      state.activeDevice = nil
    }
  }
}
