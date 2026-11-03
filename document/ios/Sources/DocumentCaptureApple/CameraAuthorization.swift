import AVFoundation
import Foundation

enum CameraAuthorizationDecision: Equatable, Sendable {
  case authorized
  case denied
  case indeterminate
}

protocol CameraAuthorizationProviding: Sendable {
  func resolveAuthorization() async -> CameraAuthorizationDecision
}

struct SystemCameraAuthorizationProvider: CameraAuthorizationProviding {
  func resolveAuthorization() async -> CameraAuthorizationDecision {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return .authorized
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
    case .denied, .restricted:
      return .denied
    @unknown default:
      return .indeterminate
    }
  }
}
