// Responsibility: Admits a portrait with its original DG2 after recomputing the SOD-named digest.
// Control: The caller verifies SOD trust and extracts the portrait from that DG2; this helper checks the DG2 digest.
// App counterpart: PassportChipRead receives these results through PassportChipReader.
// Specification: RFC-0002 §§4.2–4.3; capability-evidence-and-assurance-plan §3.12.

import CryptoKit
import Foundation

/// A portrait and its original DG2 travel together with the SOD digest that binds them.
/// The caller must first verify the SOD signature and signing chain.
package struct PassportAuthenticatedPortrait: Sendable {
  package let dg2: Data
  package let portrait: Data
  package let digest: String
  package let algorithm: String

  private init(dg2: Data, portrait: Data, digest: String, algorithm: String) {
    self.dg2 = dg2
    self.portrait = portrait
    self.digest = digest
    self.algorithm = algorithm
  }

  package static func admit(
    dg2: Data?, portrait: Data?, sodDigest: String?, reportedMatch: Bool
  ) -> Self? {
    guard reportedMatch, let dg2, !dg2.isEmpty, let portrait, !portrait.isEmpty,
      let sodDigest, let algorithm = PassportDigestAlgorithm.name(hexLength: sodDigest.count)
    else { return nil }
    let computed: Data
    switch algorithm {
    case "SHA-1": computed = Data(Insecure.SHA1.hash(data: dg2))
    case "SHA-256": computed = Data(SHA256.hash(data: dg2))
    case "SHA-384": computed = Data(SHA384.hash(data: dg2))
    case "SHA-512": computed = Data(SHA512.hash(data: dg2))
    default: return nil
    }
    let digest = sodDigest.lowercased()
    guard computed.map({ String(format: "%02x", $0) }).joined() == digest else { return nil }
    return Self(dg2: dg2, portrait: portrait, digest: digest, algorithm: algorithm)
  }
}
