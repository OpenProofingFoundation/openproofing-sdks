import CryptoKit
import Foundation

/// Exact-byte artifact references. Lineage ordering is significant and never sorted away.
public struct EvidenceArtifactReference: Codable, Equatable, Sendable {
  public let recordID: UUID
  public let role: String
  public let sha256: String
  private enum CodingKeys: String, CodingKey { case recordID, role, sha256 }
  public init(from decoder: Decoder) throws {
    try requireManifestFields(decoder, required: ["recordID", "role", "sha256"])
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(recordID: try values.decode(UUID.self, forKey: .recordID),
      role: try values.decode(String.self, forKey: .role), sha256: try values.decode(String.self, forKey: .sha256))
  }

  public init(recordID: UUID, role: String, sha256: String) {
    self.recordID = recordID; self.role = role; self.sha256 = sha256
  }
}

public struct EvidenceLineageStep: Codable, Equatable, Sendable {
  public let inputRecordID: UUID
  public let outputRecordID: UUID
  /// Digest of the exact declared crop/warp/preprocessing description, not invented geometry.
  public let transformationSHA256: String
  private enum CodingKeys: String, CodingKey { case inputRecordID, outputRecordID, transformationSHA256 }
  public init(from decoder: Decoder) throws {
    try requireManifestFields(decoder, required: ["inputRecordID", "outputRecordID", "transformationSHA256"])
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(inputRecordID: try values.decode(UUID.self, forKey: .inputRecordID),
      outputRecordID: try values.decode(UUID.self, forKey: .outputRecordID),
      transformationSHA256: try values.decode(String.self, forKey: .transformationSHA256))
  }
  public init(inputRecordID: UUID, outputRecordID: UUID, transformationSHA256: String) {
    self.inputRecordID = inputRecordID; self.outputRecordID = outputRecordID
    self.transformationSHA256 = transformationSHA256
  }
}

/// Canonical, versioned commitment around an existing capability manifest and exact payload.
/// This does not reinterpret or replace the capability's own versioned manifest schema.
public struct CaptureEvidenceManifest: Codable, Equatable, Sendable {
  public let schemaVersion: String
  public let context: CapturePublicationContext
  public let recordID: UUID
  public let recordKind: String
  public let payloadSHA256: String
  public let capabilityManifestSHA256: String
  public let sources: [EvidenceArtifactReference]
  public let derivatives: [EvidenceArtifactReference]
  public let lineage: [EvidenceLineageStep]
  public let modelIDs: [String]
  public let policyIDs: [String]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, context, recordID, recordKind, payloadSHA256, capabilityManifestSHA256,
      sources, derivatives, lineage, modelIDs, policyIDs
  }

  public init(from decoder: Decoder) throws {
    try requireManifestFields(decoder, required: ["schemaVersion", "context", "recordID", "recordKind",
      "payloadSHA256", "capabilityManifestSHA256", "sources", "derivatives", "lineage", "modelIDs", "policyIDs"])
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(String.self, forKey: .schemaVersion)
    context = try values.decode(CapturePublicationContext.self, forKey: .context)
    recordID = try values.decode(UUID.self, forKey: .recordID)
    recordKind = try values.decode(String.self, forKey: .recordKind)
    payloadSHA256 = try values.decode(String.self, forKey: .payloadSHA256)
    capabilityManifestSHA256 = try values.decode(String.self, forKey: .capabilityManifestSHA256)
    sources = try values.decode([EvidenceArtifactReference].self, forKey: .sources)
    derivatives = try values.decode([EvidenceArtifactReference].self, forKey: .derivatives)
    lineage = try values.decode([EvidenceLineageStep].self, forKey: .lineage)
    modelIDs = try values.decode([String].self, forKey: .modelIDs)
    policyIDs = try values.decode([String].self, forKey: .policyIDs)
    try validate()
  }

  public init(context: CapturePublicationContext, recordID: UUID, recordKind: String,
    payloadSHA256: String, capabilityManifestSHA256: String,
    sources: [EvidenceArtifactReference], derivatives: [EvidenceArtifactReference] = [],
    lineage: [EvidenceLineageStep] = [], modelIDs: [String] = [], policyIDs: [String]) throws {
    schemaVersion = "kenshiki.capture-evidence-manifest.v1"
    self.context = context; self.recordID = recordID; self.recordKind = recordKind
    self.payloadSHA256 = payloadSHA256; self.capabilityManifestSHA256 = capabilityManifestSHA256
    self.sources = sources; self.derivatives = derivatives; self.lineage = lineage
    self.modelIDs = modelIDs; self.policyIDs = policyIDs
    try validate()
  }

  public func validate() throws {
    try context.validate()
    let artifacts = sources + derivatives
    guard schemaVersion == "kenshiki.capture-evidence-manifest.v1",
      CapturePublicationContext.identifier(recordKind), Self.digest(payloadSHA256),
      Self.digest(capabilityManifestSHA256), !sources.isEmpty, sources.count <= 64,
      derivatives.count <= 64, lineage.count <= 128, modelIDs.count <= 32,
      !policyIDs.isEmpty, policyIDs.count <= 32,
      Set(artifacts.map(\.recordID)).count == artifacts.count,
      artifacts.allSatisfy({ Self.digest($0.sha256) && CapturePublicationContext.identifier($0.role) }),
      modelIDs.allSatisfy(CapturePublicationContext.identifier),
      policyIDs.allSatisfy(CapturePublicationContext.identifier),
      Set(modelIDs).count == modelIDs.count, Set(policyIDs).count == policyIDs.count
    else { throw EvidenceManifestError.invalidManifest }
    // A source can be the publication itself (an original), while every derivative declares
    // one preceding input and cannot reuse a prior identity or create a cycle.
    var available = Set(sources.map(\.recordID))
    let outputs = Set(derivatives.map(\.recordID))
    var derived: Set<UUID> = []
    for step in lineage {
      guard available.contains(step.inputRecordID), outputs.contains(step.outputRecordID),
        !available.contains(step.outputRecordID), Self.digest(step.transformationSHA256)
      else { throw EvidenceManifestError.invalidManifest }
      available.insert(step.outputRecordID); derived.insert(step.outputRecordID)
    }
    guard derived == outputs, let published = artifacts.first(where: { $0.recordID == recordID }),
      published.sha256 == payloadSHA256
    else { throw EvidenceManifestError.invalidManifest }
  }

  /// Sorted-key JSON, integer clocks only, no optional nulls, Foundation UUID spelling.
  /// Domain separation prevents interpreting another signed claim as a capture manifest.
  public func signingBytes() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var bytes = Data("kenshiki:capture-evidence-manifest:v1\0".utf8)
    bytes.append(try encoder.encode(self))
    return bytes
  }

  public func requireBinding(context expected: CapturePublicationContext, recordID expectedID: UUID,
    payload: Data, capabilityManifest: Data) throws {
    guard context == expected, recordID == expectedID,
      payloadSHA256 == Self.sha256(payload), capabilityManifestSHA256 == Self.sha256(capabilityManifest)
    else { throw EvidenceManifestError.bindingMismatch }
    try validate()
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func digest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
