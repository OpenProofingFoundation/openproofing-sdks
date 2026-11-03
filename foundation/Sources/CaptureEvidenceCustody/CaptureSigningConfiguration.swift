import Foundation
import KenshikiEvidenceManifest

/// Host-named local workflow ownership, deliberately separate from a BFF enrollment generation.
/// The installation identity must be stable across reopening; no identity is generated here.
public struct CaptureSigningConfiguration: Sendable {
  public let applicationID: String
  private let installationIDProvider: @Sendable () async throws -> String
  public let workflowEpoch: UInt64
  public let signer: any EvidenceManifestSigning

  public init(applicationID: String, installationID: String, workflowEpoch: UInt64,
    signer: any EvidenceManifestSigning) throws {
    // Validate names without minting or retaining a workflow/attempt identity.
    let validationID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    _ = try CapturePublicationContext(applicationID: applicationID, installationID: installationID,
      workflowID: validationID, generation: workflowEpoch, attemptID: validationID, observedAtMilliseconds: 1)
    self.applicationID = applicationID
    self.installationIDProvider = { installationID }
    self.workflowEpoch = workflowEpoch; self.signer = signer
  }

  /// The host supplies its actor-owned retained installation identity. The SDK never invents an
  /// identity or stores it in mutable ambient state. Reads must resolve retained credentials only.
  public init(applicationID: String, installationIDProvider: @escaping @Sendable () async throws -> String,
    workflowEpoch: UInt64, signer: any EvidenceManifestSigning) throws {
    let validationID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    _ = try CapturePublicationContext(applicationID: applicationID, installationID: "pending-installation",
      workflowID: validationID, generation: workflowEpoch, attemptID: validationID, observedAtMilliseconds: 1)
    self.applicationID = applicationID; self.installationIDProvider = installationIDProvider
    self.workflowEpoch = workflowEpoch; self.signer = signer
  }

  public func context(workflowID: UUID, attemptID: UUID, observedAt: Date) async throws -> CapturePublicationContext {
    let milliseconds = observedAt.timeIntervalSince1970 * 1000
    guard milliseconds.isFinite, milliseconds > 0, milliseconds <= 9_007_199_254_740_991
    else { throw EvidenceManifestError.invalidContext }
    let installationID = try await installationIDProvider()
    return try .init(applicationID: applicationID, installationID: installationID,
      workflowID: workflowID, generation: workflowEpoch, attemptID: attemptID,
      observedAtMilliseconds: Int64(milliseconds))
  }

  func requireScope(_ context: CapturePublicationContext, workflowID: UUID, attemptID: UUID) async throws {
    let currentInstallationID = try await installationIDProvider()
    guard context.applicationID == applicationID, context.installationID == currentInstallationID,
      context.workflowID == workflowID, context.generation == workflowEpoch,
      context.attemptID == attemptID else { throw EvidenceManifestError.bindingMismatch }
  }
}

public struct SignedCaptureEvidenceRecord: Sendable {
  public let record: CaptureEvidenceRecord
  public let publication: SignedCaptureEvidenceManifest
}
