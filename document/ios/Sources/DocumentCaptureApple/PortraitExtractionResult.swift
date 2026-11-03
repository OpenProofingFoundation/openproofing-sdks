import Foundation
import DocumentSDK

public enum PortraitExtractionError: String, Error, Codable, Sendable {
  case sourceIntegrityMismatch
  case imageUndecodable
  case sourceDimensionsMismatch
  case sourceMustBeUpright
  case detectionResultsUnavailable
  case cropFailed
  case encodingFailed
}

/// Describes a face-region crop. It does not claim the complete printed photo.
public struct PortraitImageDerivation: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sourceSHA256: String
  public let implementationVersion: String
  public let geometry: PortraitCropCandidate
  public let outputSHA256: String
  public let outputPixelWidth: Int
  public let outputPixelHeight: Int
  public let outputUniformTypeIdentifier: String
}

public struct PortraitImageCandidate: Sendable {
  public let data: Data
  public let metadata: PortraitImageDerivation
}

public struct PortraitExtractionMetadata: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sourceSHA256: String
  public let sourcePixelWidth: Int
  public let sourcePixelHeight: Int
  public let implementationVersion: String
  public let faceRequestRevision: Int
  public let observations: [PortraitFaceObservation]
  public let assessment: PortraitCropAssessment
}

public struct PortraitExtractionResult: Sendable {
  public let metadata: PortraitExtractionMetadata
  public let candidates: [PortraitImageCandidate]
}
