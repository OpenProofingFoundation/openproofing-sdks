import Foundation

/// A bound receipt is accepted only over the configured authenticated service transport.
/// Metadata equality alone does not authenticate the service or prove document provenance.
public struct OperationReceipt: Codable, Equatable, Sendable {
  public let v: String
  public let audience: String
  public let applicationID: String
  public let installationID: String
  public let operationKind: String
  public let operationID: String
  public let targetID: String
  public let generation: String
  public let requestDigest: String
  public let contentDigest: String
  public let resultDigest: String
  public let resultRevision: Int64
  public let expiresAt: Int64

  enum CodingKeys: String, CodingKey {
    case v, audience, generation
    case applicationID = "application_id"
    case installationID = "installation_id"
    case operationKind = "operation_kind"
    case operationID = "operation_id"
    case targetID = "target_id"
    case requestDigest = "request_digest"
    case contentDigest = "content_digest"
    case resultDigest = "result_digest"
    case resultRevision = "result_revision"
    case expiresAt = "expires_at"
  }

  public func validate(for operation: SealedOperation, canonicalResult: Data, now: Int64) throws {
    try validateBinding(for: operation, canonicalResult: canonicalResult)
    guard expiresAt > now else { throw OperationBindingError.responseMismatch }
  }

  /// Local accepted custody preserves the original authenticated result beyond receipt freshness.
  /// Call only for an accepted journal entry whose current identity/preparation was validated.
  public func validatePreviouslyAccepted(for operation: SealedOperation, canonicalResult: Data) throws {
    try validateBinding(for: operation, canonicalResult: canonicalResult)
  }
  private func validateBinding(for operation: SealedOperation, canonicalResult: Data) throws {
    try operation.validate()
    let requestHash = try operation.clientDataHash().map({ String(format: "%02x", $0) }).joined()
    guard v == "kenshiki.operation-receipt.v1", audience == operation.audience,
      applicationID == operation.applicationID, installationID == operation.installationID,
      operationKind == operation.operationKind, operationID == operation.operationID,
      targetID == operation.targetID, generation == operation.generation,
      contentDigest == operation.contentDigest,
      requestDigest == requestHash,
      resultDigest == SealedOperation.sha256(canonicalResult),
      resultRevision == operation.expectedRevision + 1,
      expiresAt > 0, expiresAt <= 9_007_199_254_740_991
    else {
      throw OperationBindingError.responseMismatch
    }
  }
}
