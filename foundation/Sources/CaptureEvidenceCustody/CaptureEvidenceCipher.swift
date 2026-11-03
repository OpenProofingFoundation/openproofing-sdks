import CryptoKit
import Foundation
import KenshikiProtectedStorage

/// Opaque encryption port. Production unwraps its hardware-bound key only within the foundation
/// operation; the capture actor never caches raw AES key material while the phone is locked.
struct CaptureEvidenceCipher: Sendable {
  let seal: @Sendable (Data, Data) throws -> Data
  let open: @Sendable (Data, Data) throws -> Data

  init(vault: HardwareBoundStoreKeyCustody) {
    seal = { try vault.sealCombined($0, authenticating: $1) }
    open = { try vault.openCombined($0, authenticating: $1) }
  }

  // Internal codec fixtures retain exact historical formats without exposing a production fallback.
  init(key: SymmetricKey) {
    seal = { plaintext, aad in
      guard let bytes = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined else {
        throw CaptureEvidenceStoreError.integrityFailure
      }
      return bytes
    }
    open = { try AES.GCM.open(AES.GCM.SealedBox(combined: $0), using: key, authenticating: $1) }
  }

  static var unavailable: Self {
    Self(seal: { _, _ in throw CaptureEvidenceStoreError.custodyRevoked },
      open: { _, _ in throw CaptureEvidenceStoreError.custodyRevoked })
  }

  private init(seal: @escaping @Sendable (Data, Data) throws -> Data,
    open: @escaping @Sendable (Data, Data) throws -> Data)
  {
    self.seal = seal
    self.open = open
  }
}
