import Foundation

public enum PhotoCaptureError: Error, Equatable, Sendable {
  case cameraPermissionDenied
  case cameraAuthorizationIndeterminate
  case backCameraUnavailable
  case cannotAddCameraInput
  case cannotAddPhotoOutput
  case cannotAddVideoOutput
  case captureAdmissionSuspended
  case cameraNotReady
  case captureQualityNotReady
  case captureGuideUnavailable
  case captureObservationUnavailable
  case captureIdentityMismatch
  case captureTimestampUnavailable
  case configurationFailed(String)
  case captureFailed(String)
  case encodedPhotoUnavailable
  case imageMetadataUnavailable

  public var code: String {
    switch self {
    case .cameraPermissionDenied:
      "camera_permission_denied"
    case .cameraAuthorizationIndeterminate:
      "camera_authorization_indeterminate"
    case .backCameraUnavailable:
      "back_camera_unavailable"
    case .cannotAddCameraInput:
      "cannot_add_camera_input"
    case .cannotAddPhotoOutput:
      "cannot_add_photo_output"
    case .cannotAddVideoOutput:
      "cannot_add_video_output"
    case .captureAdmissionSuspended:
      "capture_admission_suspended"
    case .cameraNotReady:
      "camera_not_ready"
    case .captureQualityNotReady:
      "capture_quality_not_ready"
    case .captureGuideUnavailable:
      "capture_guide_unavailable"
    case .captureObservationUnavailable:
      "capture_observation_unavailable"
    case .captureIdentityMismatch:
      "capture_identity_mismatch"
    case .captureTimestampUnavailable:
      "capture_timestamp_unavailable"
    case .configurationFailed:
      "configuration_failed"
    case .captureFailed:
      "capture_failed"
    case .encodedPhotoUnavailable:
      "encoded_photo_unavailable"
    case .imageMetadataUnavailable:
      "image_metadata_unavailable"
    }
  }

}
