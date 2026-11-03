import Foundation
import DocumentSDK

public struct DocumentCameraTelemetry: Sendable {
  private let handler: @Sendable (DocumentCameraTelemetryEvent) -> Void

  public init(
    handler: @escaping @Sendable (DocumentCameraTelemetryEvent) -> Void
  ) {
    self.handler = handler
  }

  public static let disabled = Self { _ in }

  func record(_ event: DocumentCameraTelemetryEvent) {
    handler(event)
  }
}

public struct DocumentCameraTelemetryEvent: Codable, Equatable, Sendable {
  public enum Name: String, Codable, Sendable {
    case previewAttached
    case previewGeometry
    case sessionStartRequested
    case authorizationResolved
    case cameraSelected
    case sessionStarted
    case sessionStartFailed
    case captureRequested
    case captureCompleted
    case captureFailed
    case sessionStopped
  }

  public enum Authorization: String, Codable, Sendable {
    case authorized
    case denied
    case indeterminate
  }

  public struct PhotoFacts: Codable, Equatable, Sendable {
    public let origin: MediaOrigin
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let encodedByteCount: Int
    public let uniformTypeIdentifier: String
    public let orientation: Int?
    public let cameraModel: String?
    public let lensModel: String?
    public let exposureTimeSeconds: Double?
    public let fNumber: Double?
    public let isoSpeed: Double?

    init(photo: CapturedDocumentPhoto) {
      origin = photo.origin
      pixelWidth = photo.fidelity.pixelWidth
      pixelHeight = photo.fidelity.pixelHeight
      encodedByteCount = photo.fidelity.fileByteCount
      uniformTypeIdentifier = photo.fidelity.uniformTypeIdentifier
      orientation = photo.fidelity.orientation
      cameraModel = photo.fidelity.cameraModel
      lensModel = photo.fidelity.lensModel
      exposureTimeSeconds = photo.fidelity.exposureTimeSeconds
      fNumber = photo.fidelity.fNumber
      isoSpeed = photo.fidelity.isoSpeed
    }
  }

  public let schemaVersion: Int
  public let timestamp: Date
  public let sessionID: CaptureSessionID
  public let name: Name
  public let side: DocumentSide?
  public let captureAttemptID: UUID?
  public let qualityGate: DocumentCaptureQualityGate?
  public let permissionState: Authorization?
  public let errorCode: String?
  public let photo: PhotoFacts?
  public let cameraSelection: DocumentCameraHardwareSelection?
  public let previewGeometry: DocumentCameraPreviewGeometryDiagnostic?

  init(
    timestamp: Date,
    sessionID: CaptureSessionID,
    name: Name,
    side: DocumentSide? = nil,
    captureAttemptID: UUID? = nil,
    qualityGate: DocumentCaptureQualityGate? = nil,
    permissionState: Authorization? = nil,
    errorCode: String? = nil,
    photo: PhotoFacts? = nil,
    cameraSelection: DocumentCameraHardwareSelection? = nil,
    previewGeometry: DocumentCameraPreviewGeometryDiagnostic? = nil
  ) {
    schemaVersion = 2
    self.timestamp = timestamp
    self.sessionID = sessionID
    self.name = name
    self.side = side
    self.captureAttemptID = captureAttemptID
    self.qualityGate = qualityGate
    self.permissionState = permissionState
    self.errorCode = errorCode
    self.photo = photo
    self.cameraSelection = cameraSelection
    self.previewGeometry = previewGeometry
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case timestamp
    case sessionID
    case name
    case side
    case captureAttemptID
    case qualityGate
    case permissionState = "authorization"
    case errorCode
    case photo
    case cameraSelection
    case previewGeometry
  }
}
