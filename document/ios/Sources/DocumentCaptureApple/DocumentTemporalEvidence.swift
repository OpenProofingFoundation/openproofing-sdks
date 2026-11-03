import Foundation

/// Opt-in retention of full-scene video observations; not a document validation policy.
public struct DocumentTemporalConfiguration: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var preCaptureDuration: Double
  public var postCaptureDuration: Double
  public var maximumBytes: Int
  public var maximumFrames: Int
  public var maximumMotionSamples: Int
  public var maximumDiagnostics: Int

  public init(
    enabled: Bool = false, preCaptureDuration: Double = DocumentCaptureDefaults.preCaptureDuration,
    postCaptureDuration: Double = DocumentCaptureDefaults.postCaptureDuration, maximumBytes: Int = 134_217_728,
    maximumFrames: Int = 120, maximumMotionSamples: Int = 600,
    maximumDiagnostics: Int = 128
  ) {
    self.enabled = enabled
    self.preCaptureDuration = preCaptureDuration
    self.postCaptureDuration = postCaptureDuration
    self.maximumBytes = maximumBytes
    self.maximumFrames = maximumFrames
    self.maximumMotionSamples = maximumMotionSamples
    self.maximumDiagnostics = maximumDiagnostics
  }

  var valid: Bool {
    preCaptureDuration.isFinite && postCaptureDuration.isFinite
      && preCaptureDuration >= 0 && postCaptureDuration >= 0
      && maximumBytes > 0 && maximumFrames > 0 && maximumMotionSamples > 0
      && maximumDiagnostics > 0
  }
}

public struct DocumentTemporalEvidence: Sendable {
  public let manifest: DocumentTemporalManifest
  public let frames: [DocumentTemporalFrame]
}

public struct DocumentTemporalFrame: Sendable {
  public let metadata: DocumentTemporalFrameMetadata
  public let payload: Data
}

public struct DocumentTemporalPlane: Codable, Equatable, Sendable {
  public let offset: Int
  public let byteCount: Int
  public let width: Int
  public let height: Int
  public let sourceBytesPerRow: Int
  public let packedBytesPerRow: Int
}

public struct DocumentTemporalFrameMetadata: Codable, Equatable, Sendable {
  public let sequenceNumber: Int
  public let timestamp: DocumentCaptureClockTimestamp
  public let hostTimeSeconds: Double?
  public let width: Int
  public let height: Int
  public let pixelFormat: UInt32
  public let planes: [DocumentTemporalPlane]
  public let sha256: String
  public let colorAttachmentsPlist: Data?
  public let geometry: DocumentTemporalGeometry?
  public let camera: DocumentTemporalCameraState?
}

public struct DocumentTemporalGeometry: Codable, Equatable, Sendable {
  public let quadrilateral: DocumentQuadrilateral?
  public let observationTimestamp: DocumentCaptureClockTimestamp
  public let coordinateSpace: String
  public let status: String
  public let confidence: Float?
  public let method: String?
}

public struct DocumentTemporalCameraState: Codable, Equatable, Sendable {
  public let readbackHostTimeSeconds: Double
  public let geometryRevision: UInt64
  public let opticalRevision: UInt64
  public let focusModeRawValue: Int
  public let exposureModeRawValue: Int
  public let deviceUniqueID: String
  public let lensPosition: Float
  public let exposureDurationSeconds: Double
  public let iso: Float
  public let zoomFactor: Double
  public let adjustingFocus: Bool
  public let adjustingExposure: Bool
  public let rotationDegrees: Double
  public let mirrored: Bool
}
