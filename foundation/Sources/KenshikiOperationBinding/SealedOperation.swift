import CryptoKit
import Foundation

public enum OperationBindingError: Error, Equatable {
  case invalidField(String)
  case contentMismatch
  case responseMismatch
}

/// Immutable common authorization metadata. Product adapters own closed content schemas;
/// the service independently decides evidence authority and applies resource revisions.
public struct SealedOperation: Codable, Equatable, Sendable {
  public static let version = "kenshiki.sealed-operation.v1"
  public static let domain = "kenshiki:sealed-operation:v1"
  public let v: String
  public let applicationID: String
  public let installationID: String
  public let audience: String
  public let operationKind: String
  public let operationID: String
  public let targetID: String
  public let generation: String
  public let expectedRevision: Int64
  public let challengeID: String
  public let issuedAt: Int64
  public let expiresAt: Int64
  public let contentDigest: String
  public let purpose: String
  public let recipient: Recipient?

  public struct Recipient: Codable, Equatable, Sendable {
    public let kind: String
    public let id: String
    public init(kind: String, id: String) {
      self.kind = kind
      self.id = id
    }
  }

  enum CodingKeys: String, CodingKey {
    case v, audience, generation, purpose, recipient
    case applicationID = "application_id"
    case installationID = "installation_id"
    case operationKind = "operation_kind"
    case operationID = "operation_id"
    case targetID = "target_id"
    case expectedRevision = "expected_revision"
    case challengeID = "challenge_id"
    case issuedAt = "issued_at"
    case expiresAt = "expires_at"
    case contentDigest = "content_digest"
  }

  public init(
    applicationID: String, installationID: String, audience: String,
    operationKind: String, operationID: String, targetID: String, generation: String,
    expectedRevision: Int64, challengeID: String, issuedAt: Int64, expiresAt: Int64,
    contentDigest: String, purpose: String, recipient: Recipient?
  ) throws {
    self.v = Self.version
    self.applicationID = applicationID
    self.installationID = installationID
    self.audience = audience
    self.operationKind = operationKind
    self.operationID = operationID
    self.targetID = targetID
    self.generation = generation
    self.expectedRevision = expectedRevision
    self.challengeID = challengeID
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.contentDigest = contentDigest
    self.purpose = purpose
    self.recipient = recipient
    try validate()
  }

  public func validate() throws {
    guard v == Self.version else { throw OperationBindingError.invalidField("v") }
    let fields = [
      "application_id": applicationID, "installation_id": installationID,
      "audience": audience, "operation_kind": operationKind, "operation_id": operationID,
      "target_id": targetID, "generation": generation, "challenge_id": challengeID,
      "purpose": purpose,
    ]
    for (name, value) in fields { try Self.validateIdentifier(value, field: name) }
    if let recipient {
      try Self.validateIdentifier(recipient.kind, field: "recipient.kind")
      try Self.validateIdentifier(recipient.id, field: "recipient.id")
    }
    let safeMaximum: Int64 = 9_007_199_254_740_991
    guard expectedRevision >= 0, expectedRevision < safeMaximum else {
      throw OperationBindingError.invalidField("expected_revision")
    }
    guard issuedAt >= 0, expiresAt > issuedAt, expiresAt <= safeMaximum,
      expiresAt - issuedAt <= 300
    else { throw OperationBindingError.invalidField("expires_at") }
    guard contentDigest.count == 64,
      contentDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else {
      throw OperationBindingError.invalidField("content_digest")
    }
  }

  private static func validateIdentifier(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= 256,
      value.utf8.allSatisfy({ (33...126).contains($0) })
    else {
      throw OperationBindingError.invalidField(field)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(v, forKey: .v)
    try c.encode(applicationID, forKey: .applicationID)
    try c.encode(installationID, forKey: .installationID)
    try c.encode(audience, forKey: .audience)
    try c.encode(operationKind, forKey: .operationKind)
    try c.encode(operationID, forKey: .operationID)
    try c.encode(targetID, forKey: .targetID)
    try c.encode(generation, forKey: .generation)
    try c.encode(expectedRevision, forKey: .expectedRevision)
    try c.encode(challengeID, forKey: .challengeID)
    try c.encode(issuedAt, forKey: .issuedAt)
    try c.encode(expiresAt, forKey: .expiresAt)
    try c.encode(contentDigest, forKey: .contentDigest)
    try c.encode(purpose, forKey: .purpose)
    if let recipient {
      try c.encode(recipient, forKey: .recipient)
    } else {
      try c.encodeNil(forKey: .recipient)
    }
  }

  public func canonicalBytes() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public func clientDataHash() throws -> Data {
    var bytes = Data(Self.domain.utf8)
    bytes.append(0)
    bytes.append(try canonicalBytes())
    return Data(SHA256.hash(data: bytes))
  }

  public static func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}

/// Retain this value across response loss. A retry uses the same operation and content bytes.
/// Persistence and authenticated receipt recovery are adapter responsibilities, not silently
/// replaced with process-local state here.
public struct PreparedOperation: Equatable, Sendable {
  public let operation: SealedOperation
  public let canonicalContent: Data
  public let clientDataHash: Data

  public init(operation: SealedOperation, canonicalContent: Data) throws {
    guard canonicalContent.count <= 262_144,
      operation.contentDigest == SealedOperation.sha256(canonicalContent)
    else {
      throw OperationBindingError.contentMismatch
    }
    self.operation = operation
    self.canonicalContent = canonicalContent
    self.clientDataHash = try operation.clientDataHash()
  }
}
