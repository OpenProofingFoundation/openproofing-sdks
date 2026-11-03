import AVFoundation
import Foundation

/// Called only on the native camera owner's queue. Cancellation requests a smooth
/// stop; only subsequent native readback can establish that a ramp has stopped.
func retireNativeZoomRamp(_ device: AVCaptureDevice?) throws {
  #if os(iOS)
    guard let device else { return }
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    device.cancelVideoZoomRamp()
  #endif
}

extension AVFoundationCameraSessionController {
  func retireCurrentZoomRamp() throws {
    dispatchPrecondition(condition: .onQueue(sessionQueue))
    guard state.activeDevice != nil || !state.zoomRetirementFailed else {
      throw PhotoCaptureError.configurationFailed("zoom_retirement_failed")
    }
    do {
      try retireZoomRamp(state.activeDevice)
      state.zoomRetirementFailed = false
    } catch {
      state.zoomRetirementFailed = true
      state.nativeOperationUncertain = true
      throw PhotoCaptureError.configurationFailed("zoom_retirement_failed")
    }
  }
}
