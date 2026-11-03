import Foundation

public enum EvidenceManifestError: Error, Equatable, Sendable {
  case invalidContext, invalidManifest, invalidProof, bindingMismatch, untrustedSigningKey
}

/// Device-asserted context, not a server freshness or sensor authenticity guarantee.
/// No policy switch permits an unsigned publication through this contract.
public struct CapturePublicationContext: Codable, Equatable, Sendable {
  public let applicationID: String
  public let installationID: String
  public let workflowID: UUID
  public let generation: UInt64
  public let attemptID: UUID
  public let observedAtMilliseconds: Int64
  public let monotonicNanoseconds: UInt64?

  private enum CodingKeys: String, CodingKey {
    case applicationID, installationID, workflowID, generation, attemptID, observedAtMilliseconds, monotonicNanoseconds
  }

  public init(from decoder: Decoder) throws {
    try requireManifestFields(decoder, required: ["applicationID", "installationID", "workflowID",
      "generation", "attemptID", "observedAtMilliseconds"], optional: ["monotonicNanoseconds"])
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(applicationID: values.decode(String.self, forKey: .applicationID),
      installationID: values.decode(String.self, forKey: .installationID),
      workflowID: values.decode(UUID.self, forKey: .workflowID),
      generation: values.decode(UInt64.self, forKey: .generation),
      attemptID: values.decode(UUID.self, forKey: .attemptID),
      observedAtMilliseconds: values.decode(Int64.self, forKey: .observedAtMilliseconds),
      monotonicNanoseconds: values.decodeIfPresent(UInt64.self, forKey: .monotonicNanoseconds))
  }

  public init(applicationID: String, installationID: String, workflowID: UUID,
    generation: UInt64, attemptID: UUID, observedAtMilliseconds: Int64,
    monotonicNanoseconds: UInt64? = nil) throws {
    self.applicationID = applicationID
    self.installationID = installationID
    self.workflowID = workflowID
    self.generation = generation
    self.attemptID = attemptID
    self.observedAtMilliseconds = observedAtMilliseconds
    self.monotonicNanoseconds = monotonicNanoseconds
    try validate()
  }

  public func validate() throws {
    guard Self.identifier(applicationID), Self.identifier(installationID),
      generation <= 9_007_199_254_740_991, observedAtMilliseconds > 0,
      observedAtMilliseconds <= 9_007_199_254_740_991,
      monotonicNanoseconds.map({ $0 <= 9_007_199_254_740_991 }) ?? true
    else { throw EvidenceManifestError.invalidContext }
  }

  static func identifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || [45, 46, 58, 95].contains($0)
    }
  }
}
