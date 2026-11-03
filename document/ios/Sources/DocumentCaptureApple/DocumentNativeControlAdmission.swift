import AVFoundation
import Foundation

/// Recheck native readback at shutter admission against the accepted observation.
/// This does not establish image readability; that remains a post-capture result.
enum DocumentNativeControlAdmission {
  static func matches(
    admitted: DocumentCameraControlSnapshot, current: DocumentCameraControlSnapshot
  ) -> Bool {
    guard admitted.adaptiveFailureReason == nil, admitted.settled,
      let identity = admitted.opticalIdentity, identity == current.opticalIdentity,
      current.focusModeRawValue == AVCaptureDevice.FocusMode.locked.rawValue,
      !current.adjustingFocus, !current.adjustingExposure, !current.rampingZoom,
      let admittedX = admitted.focusPointX, let admittedY = admitted.focusPointY,
      let currentX = current.focusPointX, let currentY = current.focusPointY
    else { return false }
    return abs(admittedX - currentX) <= 0.001 && abs(admittedY - currentY) <= 0.001
      && abs(admitted.zoomFactor - current.zoomFactor) <= 0.001
  }
}
