import Foundation

public enum DocumentCameraDeviceChoice: String, CaseIterable, Codable, Sendable {
  case automatic, wide, ultraWide, telephoto
}

public enum DocumentCameraDiagnosticCommand: Sendable {
  case inspect
  case selectCamera(DocumentCameraDeviceChoice)
  case setLensPosition(Double)
  case setZoom(Double)
  case autofocusCenter
  case continuousFocus
  case setAdaptiveCaptureEnabled(Bool)
}

/// Native readback for local experiments. Device-clock completion is not wall time.
public struct DocumentCameraNativeSnapshot: Codable, Equatable, Sendable {
  public let snapshotTime: Date
  public let selection: DocumentCameraDeviceChoice
  public let availableChoices: [DocumentCameraDeviceChoice]
  public let logicalDeviceID: String
  public let logicalDeviceType: String
  public let activePrimaryDeviceID: String?
  public let activePrimaryDeviceType: String?
  public let opticalRevision: UInt64
  public let adaptiveCaptureEnabled: Bool
  public let reconfiguring: Bool
  public let zoom: Double
  public let minimumZoom: Double
  public let maximumZoom: Double
  public let focusModeRawValue: Int
  public let lensPosition: Double
  public let adjustingFocus: Bool
  public let adjustingExposure: Bool
  public let rampingZoom: Bool
  public let supportsManualFocus: Bool
  public let videoWidth: Int
  public let videoHeight: Int
  public let photoWidth: Int
  public let photoHeight: Int
  public let manualFocusAppliedDeviceTime: Double?

  private enum CodingKeys: String, CodingKey {
    case snapshotTime
    case selection
    case availableChoices
    case logicalDeviceID
    case logicalDeviceType
    case activePrimaryDeviceID
    case activePrimaryDeviceType
    case opticalRevision
    case adaptiveCaptureEnabled
    case reconfiguring = "isReconfiguring"
    case zoom
    case minimumZoom
    case maximumZoom
    case focusModeRawValue
    case lensPosition
    case adjustingFocus = "isAdjustingFocus"
    case adjustingExposure = "isAdjustingExposure"
    case rampingZoom = "isRampingZoom"
    case supportsManualFocus
    case videoWidth
    case videoHeight
    case photoWidth
    case photoHeight
    case manualFocusAppliedDeviceTime
  }
}

protocol CameraSessionDiagnosticsControlling: Sendable {
  func performDiagnostic(
    _ command: DocumentCameraDiagnosticCommand,
    completion:
      @escaping @Sendable (Result<DocumentCameraNativeSnapshot, PhotoCaptureError>) -> Void
  )
}

protocol CameraSessionGeometryEpochProviding: Sendable {
  func setPreviewGeometryInvalidationHandler(
    _ handler: @escaping @MainActor @Sendable (UInt64) -> Void
  )
  @MainActor func updatePreviewGeometry(
    orientation: DocumentCameraOrientation, region: DocumentCameraGuideRegion?,
    sourceGeneration: UInt64
  )
}
