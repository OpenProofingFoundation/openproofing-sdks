import CryptoKit
import Foundation

/// Compatibility header envelope for existing versioned product write contracts.
/// These proofs do not provide durable operation receipt recovery.
public enum InstallationWriteProof {
  public static func clientDataHash(domain: String, canonicalBinding: Data, issuedAt: String) throws
    -> Data
  {
    guard !domain.isEmpty, !domain.contains("\0"), canonicalBinding.count <= 262_144,
      let object = try JSONSerialization.jsonObject(with: canonicalBinding) as? [String: Any],
      object["issued_at"] as? String == issuedAt
    else {
      throw OperationBindingError.invalidField("write_proof_binding")
    }
    var material = Data(domain.utf8)
    material.append(0)
    material.append(canonicalBinding)
    // SealedOperation.sha256 returns hex; signing must receive raw SHA-256 bytes.
    return Data(SHA256.hash(data: material))
  }

  public static func headers(
    domain: String, canonicalBinding: Data, issuedAt: String, keyID: String
  ) async throws -> [String: String] {
    let digest = try clientDataHash(
      domain: domain, canonicalBinding: canonicalBinding, issuedAt: issuedAt)
    let assertion = try await RegisteredAppAttestSigner.shared.assertion(
      keyID: keyID, clientDataHash: digest)
    return [
      "x-pulse-app-attest-key-id": keyID,
      "x-pulse-app-attest-assertion": base64URL(assertion),
      "x-pulse-app-attest-client-data-hash": base64URL(digest),
      "x-pulse-issued-at": issuedAt,
    ]
  }

  public static func base64URL(_ bytes: Data) -> String {
    bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
