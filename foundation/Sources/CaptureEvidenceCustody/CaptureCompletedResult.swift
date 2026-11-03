import Foundation

public enum CaptureCompletedResultError: Error, Equatable {
  case invalidResult, staleRevision, invalidArtifact
}

/// Native bytes admitted explicitly by the caller. This type deliberately has no Codable
/// conformance: bridge results carry artifact references, never these bytes by default.
public struct CaptureResultArtifact: Sendable {
  public let id: UUID
  public let role: String
  public let mediaType: String
  public let data: Data

  public init(id: UUID, role: String, mediaType: String, data: Data) throws {
    guard !role.isEmpty, !mediaType.isEmpty, !data.isEmpty else {
      throw CaptureCompletedResultError.invalidArtifact
    }
    self.id = id
    self.role = role
    self.mediaType = mediaType
    self.data = data
  }
}

/// Safe routing metadata. Retrieval requires the result identity and this exact digest.
public struct CaptureResultArtifactReference: Codable, Equatable, Sendable {
  public let id: UUID
  public let role: String
  public let mediaType: String
  public let sha256: String
  public let byteCount: Int
}

/// A completed publication, not an acceptance verdict or a fresh capture admission.
public struct CaptureCompletedResultDescriptor: Codable, Equatable, Sendable {
  public let id: UUID
  public let workflowID: UUID
  public let kind: String
  public let revision: UInt64
  public let previousResultID: UUID?
  public let recordedAt: Date
  public let artifacts: [CaptureResultArtifactReference]
}

/// The typed observation is restored independently of native image access.
public struct CaptureCompletedResult<Payload: Sendable>: Sendable {
  public let descriptor: CaptureCompletedResultDescriptor
  public let payload: Payload
}

struct CaptureCompletedResultEnvelope: Codable {
  static let recordKind = "completedCaptureResult"
  struct Manifest: Codable {
    let schemaVersion: Int
    let recordKind: String
    let captureID: UUID
    let descriptor: CaptureCompletedResultDescriptor
  }
  struct Artifact: Codable {
    let reference: CaptureResultArtifactReference
    let data: Data
  }
  let descriptor: CaptureCompletedResultDescriptor
  let payload: Data
  let artifacts: [Artifact]

  func validate() throws {
    guard descriptor.revision > 0, !descriptor.kind.isEmpty,
      descriptor.recordedAt.timeIntervalSince1970.isFinite, !payload.isEmpty,
      descriptor.artifacts == artifacts.map(\.reference),
      Set(artifacts.map(\.reference.id)).count == artifacts.count,
      Set(artifacts.map(\.reference.role)).count == artifacts.count
    else { throw CaptureCompletedResultError.invalidResult }
    for artifact in artifacts {
      guard !artifact.reference.role.isEmpty, !artifact.reference.mediaType.isEmpty,
        !artifact.data.isEmpty, artifact.data.count == artifact.reference.byteCount,
        CaptureEvidenceEnvelope.hash(artifact.data) == artifact.reference.sha256
      else { throw CaptureCompletedResultError.invalidArtifact }
    }
  }
}
