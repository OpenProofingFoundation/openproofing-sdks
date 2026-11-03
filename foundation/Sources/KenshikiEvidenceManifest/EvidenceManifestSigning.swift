import Foundation

/// Proof bytes are adapter-owned and versioned. An embedded key is never a trust anchor.
public struct EvidenceManifestProof: Codable, Equatable, Sendable {
  /// Canonical wire identifier for the native capture proof format. Adapters share this
  /// identifier so creating and checking a proof cannot drift from the published contract.
  public static let captureEvidenceSchemaVersion = "kenshiki.capture-evidence-proof.v1"

  public let schemaVersion: String
  public let signingPublicKeyHash: String
  public let proofBytes: Data
  private enum CodingKeys: String, CodingKey { case schemaVersion, signingPublicKeyHash, proofBytes }
  public init(from decoder: Decoder) throws {
    try requireManifestFields(decoder, required: ["schemaVersion", "signingPublicKeyHash", "proofBytes"])
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(schemaVersion: try values.decode(String.self, forKey: .schemaVersion),
      signingPublicKeyHash: try values.decode(String.self, forKey: .signingPublicKeyHash),
      proofBytes: try values.decode(Data.self, forKey: .proofBytes))
  }

  public init(schemaVersion: String, signingPublicKeyHash: String, proofBytes: Data) {
    self.schemaVersion = schemaVersion; self.signingPublicKeyHash = signingPublicKeyHash
    self.proofBytes = proofBytes
  }
}

/// The selected native SDK adapter owns keys and signing, never the app renderer.
public protocol EvidenceManifestSigning: Sendable {
  /// Resolves the selected native signer's existing key or explicitly provisions its first key.
  /// This is a local custody identity, never server registration or trust from an embedded proof.
  func prepareSigningPublicKeyHash() async throws -> String
  /// Read-only identity check. Historical signed evidence cannot cause replacement key creation.
  func existingSigningPublicKeyHash() async throws -> String?
  func sign(_ manifest: CaptureEvidenceManifest) async throws -> EvidenceManifestProof
  func verify(_ manifest: CaptureEvidenceManifest, proof: EvidenceManifestProof,
    trustedSigningPublicKeyHash: String) async throws -> Bool
}

public struct SignedCaptureEvidenceManifest: Codable, Equatable, Sendable {
  public let manifest: CaptureEvidenceManifest
  public let proof: EvidenceManifestProof
  private enum CodingKeys: String, CodingKey { case manifest, proof }
  public init(from decoder: Decoder) throws {
    try requireManifestFields(decoder, required: ["manifest", "proof"])
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(manifest: try values.decode(CaptureEvidenceManifest.self, forKey: .manifest),
      proof: try values.decode(EvidenceManifestProof.self, forKey: .proof))
  }

  public init(manifest: CaptureEvidenceManifest, proof: EvidenceManifestProof) {
    self.manifest = manifest; self.proof = proof
  }

  public func verify(using signer: any EvidenceManifestSigning,
    trustedSigningPublicKeyHash: String, expectedContext: CapturePublicationContext,
    expectedRecordID: UUID, payload: Data, capabilityManifest: Data) async throws {
    try manifest.requireBinding(context: expectedContext, recordID: expectedRecordID,
      payload: payload, capabilityManifest: capabilityManifest)
    guard !trustedSigningPublicKeyHash.isEmpty,
      proof.signingPublicKeyHash == trustedSigningPublicKeyHash
    else { throw EvidenceManifestError.untrustedSigningKey }
    guard try await signer.verify(manifest, proof: proof,
      trustedSigningPublicKeyHash: trustedSigningPublicKeyHash)
    else { throw EvidenceManifestError.invalidProof }
  }
}
