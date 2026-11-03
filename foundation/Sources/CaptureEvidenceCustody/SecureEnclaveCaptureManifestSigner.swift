import Foundation
import KenshikiEvidenceManifest
@_spi(CustodyAdapter) import KenshikiProtectedStorage

/// Local hardware-key evidence signatures. This is neither App Attest nor a camera, sensor,
/// identity or server-authentication claim. No backend registration is required.
public struct SecureEnclaveCaptureManifestSigner: EvidenceManifestSigning {
  public static let proofSchemaVersion = "kenshiki.capture-evidence-p256-sha256.v1"
  private let applicationID: String
  private let custody: HardwareBoundSigningKeyCustody

  public init(identity: StoreKeyIdentity) throws {
    applicationID = identity.applicationID
    custody = try HardwareBoundSigningKeyCustody(identity: identity)
  }

  init(applicationID: String, custody: HardwareBoundSigningKeyCustody) {
    self.applicationID = applicationID; self.custody = custody
  }

  /// Explicit first provisioning. Retained evidence owners must first resolve their independently
  /// retained key hash; missing historical custody must never enter this creation path.
  public func prepareSigningPublicKeyHash() async throws -> String {
    try Task.checkCancellation()
    return try custody.preparePublicKeyHash()
  }
  public func existingSigningPublicKeyHash() async throws -> String? { try custody.existingPublicKeyHash() }

  public func sign(_ manifest: CaptureEvidenceManifest) async throws -> EvidenceManifestProof {
    guard manifest.context.applicationID == applicationID else { throw EvidenceManifestError.bindingMismatch }
    try Task.checkCancellation()
    let signed = try custody.sign(manifest.signingBytes())
    return .init(schemaVersion: Self.proofSchemaVersion,
      signingPublicKeyHash: signed.publicKeyHash, proofBytes: signed.signature)
  }

  public func verify(_ manifest: CaptureEvidenceManifest, proof: EvidenceManifestProof,
    trustedSigningPublicKeyHash: String) async throws -> Bool {
    guard manifest.context.applicationID == applicationID,
      proof.schemaVersion == Self.proofSchemaVersion,
      proof.signingPublicKeyHash == trustedSigningPublicKeyHash else { return false }
    return try custody.verify(proof.proofBytes, data: manifest.signingBytes(),
      trustedPublicKeyHash: trustedSigningPublicKeyHash)
  }

  /// Call only after the typed owner drains publication and durably erases its protected database.
  /// Retires this signer permanently; no read, sign or prepare call can recreate its key afterward.
  public func eraseKeyAfterCiphertextErasure() async throws { try custody.eraseKeyAfterCiphertextErasure() }
}
