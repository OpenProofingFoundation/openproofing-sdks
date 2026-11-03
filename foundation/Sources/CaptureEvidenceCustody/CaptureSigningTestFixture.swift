#if DEBUG
  import CryptoKit
  import Foundation
  import KenshikiEvidenceManifest

  extension CaptureSigningConfiguration {
    @_spi(CaptureTestFixture)
    public static func testing(applicationID: String, installationID: String,
      workflowEpoch: UInt64 = 1) throws -> CaptureSigningConfiguration
    {
      guard ["synthetic.", "test."].contains(where: applicationID.hasPrefix) else {
        throw CaptureEvidenceStoreError.invalidRecord
      }
      return try CaptureSigningConfiguration(applicationID: applicationID, installationID: installationID,
        workflowEpoch: workflowEpoch, signer: SyntheticCaptureSignerKeys.shared.signer(
          applicationID: applicationID, installationID: installationID))
    }
  }

  private final class SyntheticCaptureSignerKeys: @unchecked Sendable {
    static let shared = SyntheticCaptureSignerKeys()
    private let lock = NSLock()
    private var signers: [String: SyntheticCaptureSigner] = [:]
    func signer(applicationID: String, installationID: String) -> SyntheticCaptureSigner {
      lock.withLock {
        let identity = applicationID + "\0" + installationID
        if let signer = signers[identity] { return signer }
        let signer = SyntheticCaptureSigner(key: P256.Signing.PrivateKey())
        signers[identity] = signer
        return signer
      }
    }
  }

  private struct SyntheticCaptureSigner: EvidenceManifestSigning {
    let key: P256.Signing.PrivateKey
    var keyHash: String {
      SHA256.hash(data: key.publicKey.x963Representation).map { String(format: "%02x", $0) }.joined()
    }
    func prepareSigningPublicKeyHash() async throws -> String { keyHash }
    func existingSigningPublicKeyHash() async throws -> String? { keyHash }
    func sign(_ manifest: CaptureEvidenceManifest) async throws -> EvidenceManifestProof {
      EvidenceManifestProof(schemaVersion: "synthetic.capture-evidence-proof.v1",
        signingPublicKeyHash: keyHash,
        proofBytes: try key.signature(for: manifest.signingBytes()).derRepresentation)
    }
    func verify(_ manifest: CaptureEvidenceManifest, proof: EvidenceManifestProof,
      trustedSigningPublicKeyHash: String) async throws -> Bool
    {
      guard proof.schemaVersion == "synthetic.capture-evidence-proof.v1",
        proof.signingPublicKeyHash == keyHash, trustedSigningPublicKeyHash == keyHash,
        let signature = try? P256.Signing.ECDSASignature(derRepresentation: proof.proofBytes) else { return false }
      return try key.publicKey.isValidSignature(signature, for: manifest.signingBytes())
    }
  }
#endif
