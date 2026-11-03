import CryptoKit
import Foundation
import Security

/// Reviewed signing adapters only. Uses the existing device-only Keychain mechanism, with a
/// separate service, account domain, record format and Secure Enclave key from database ECDH.
@_spi(CustodyAdapter)
public final class HardwareBoundSigningKeyCustody: @unchecked Sendable {
  private let identity: StoreKeyIdentity
  private let storage: StoreKeyRecordStorage
  private let hardware: StoreHardwareSigning
  private let lock = NSLock()
  private var boundHash: String?
  private var revoked = false
  private var erasureComplete = false

  public init(identity: StoreKeyIdentity) throws {
    guard identity.accessPolicy == .identityWhenUnlocked else { throw ProtectedStoreKeyError.invalidIdentity }
    self.identity = identity
    storage = Self.keychain(identity)
    hardware = SecureEnclaveStoreSigning()
  }

  init(identity: StoreKeyIdentity, storage: StoreKeyRecordStorage, hardware: StoreHardwareSigning) throws {
    guard identity.accessPolicy == .identityWhenUnlocked else { throw ProtectedStoreKeyError.invalidIdentity }
    self.identity = identity; self.storage = storage; self.hardware = hardware
  }

  static func keychain(_ identity: StoreKeyIdentity) -> DeviceOnlyStoreKeychain {
    DeviceOnlyStoreKeychain(identity: identity, service: "com.kenshiki.capture-evidence-signing.v1",
      accountPrefix: "p256-signing.v1.")
  }

  /// Explicit first provisioning only. The adapter must refuse this path when retained evidence
  /// names a missing key. Existing malformed, locked or unavailable custody never permits creation.
  public func preparePublicKeyHash() throws -> String {
    try lock.withLock {
      try requireActive()
      if let record = try existing() { return record.publicKeyHash }
      guard boundHash == nil else { throw ProtectedStoreKeyError.missingKey }
      let opaque = try hardware.create()
      let hash = try publicKeyHash(opaque)
      let record = SigningKeyRecord(version: 1, algorithm: Self.algorithm, identity: identity,
        hardwareKey: opaque, publicKeyHash: hash)
      let bytes = try JSONEncoder().encode(record)
      if try storage.add(bytes) { boundHash = hash; return hash }
      // A concurrent creator's durable winner is authoritative, never our unretained candidate.
      guard let winner = try existing() else { throw ProtectedStoreKeyError.missingKey }
      return winner.publicKeyHash
    }
  }

  public func existingPublicKeyHash() throws -> String? {
    try lock.withLock { try requireActive(); return try existing()?.publicKeyHash }
  }

  /// Signing never implicitly provisions a missing key.
  public func sign(_ data: Data) throws -> (publicKeyHash: String, signature: Data) {
    try lock.withLock {
      try requireActive()
      guard !data.isEmpty, data.count <= 1_048_576 else { throw ProtectedStoreKeyError.invalidEnvelope }
      guard let record = try existing() else { throw ProtectedStoreKeyError.missingKey }
      return (record.publicKeyHash, try hardware.sign(data, opaqueRepresentation: record.hardwareKey))
    }
  }

  /// Resolves local custody independently. A proof's carried hash never supplies the trusted key.
  public func verify(_ signature: Data, data: Data, trustedPublicKeyHash: String) throws -> Bool {
    try lock.withLock {
      try requireActive()
      guard !data.isEmpty, data.count <= 1_048_576, !signature.isEmpty, signature.count <= 80,
        let record = try existing(), record.publicKeyHash == trustedPublicKeyHash else { return false }
      let key = try P256.Signing.PublicKey(x963Representation: hardware.publicKey(record.hardwareKey))
      guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
      return key.isValidSignature(signature, for: data)
    }
  }

  /// The typed owner must first drain publishers and durably erase all associated ciphertext.
  /// This instance is permanently retired, including after a failed deletion. Successful retry
  /// is idempotent and cannot remove a replacement key installed after completed erasure.
  public func eraseKeyAfterCiphertextErasure() throws {
    try lock.withLock {
      guard !erasureComplete else { return }
      revoked = true
      // Deletion does not need to reconstruct a hardware key. An unreadable Keychain still
      // fails, but malformed opaque bytes may be erased after their owner's ciphertext is gone.
      if let bytes = try storage.load(), let boundHash,
        let record = try? JSONDecoder().decode(SigningKeyRecord.self, from: bytes),
        record.publicKeyHash != boundHash {
        throw ProtectedStoreKeyError.keyAlreadyExists
      }
      try storage.remove()
      guard try storage.load() == nil else { throw ProtectedStoreKeyError.keyAlreadyExists }
      erasureComplete = true
    }
  }

  private static let algorithm = "p256-signing-sha256.v1"
  private func requireActive() throws {
    guard !revoked else { throw ProtectedStoreKeyError.missingKey }
  }
  private func publicKeyHash(_ opaque: Data) throws -> String {
    SHA256.hash(data: try hardware.publicKey(opaque)).map { String(format: "%02x", $0) }.joined()
  }
  private func existing() throws -> SigningKeyRecord? {
    guard let bytes = try storage.load() else { return nil }
    guard bytes.count <= 16_384,
      let record = try? JSONDecoder().decode(SigningKeyRecord.self, from: bytes),
      record.version == 1, record.algorithm == Self.algorithm, record.identity == identity,
      !record.hardwareKey.isEmpty, record.hardwareKey.count <= 8_192,
      try publicKeyHash(record.hardwareKey) == record.publicKeyHash else {
      throw ProtectedStoreKeyError.invalidEnvelope
    }
    guard boundHash == nil || boundHash == record.publicKeyHash else { throw ProtectedStoreKeyError.keyAlreadyExists }
    boundHash = record.publicKeyHash
    return record
  }
}

struct SigningKeyRecord: Codable {
  let version: Int
  let algorithm: String
  let identity: StoreKeyIdentity
  let hardwareKey: Data
  let publicKeyHash: String
}

protocol StoreHardwareSigning: Sendable {
  func create() throws -> Data
  func publicKey(_ opaqueRepresentation: Data) throws -> Data
  func sign(_ data: Data, opaqueRepresentation: Data) throws -> Data
}

struct SecureEnclaveStoreSigning: StoreHardwareSigning {
  func create() throws -> Data {
    guard SecureEnclave.isAvailable else { throw ProtectedStoreKeyError.hardwareUnavailable }
    var error: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      .privateKeyUsage, &error) else { throw ProtectedStoreKeyError.hardwareUnavailable }
    return try SecureEnclave.P256.Signing.PrivateKey(accessControl: access).dataRepresentation
  }
  func publicKey(_ opaqueRepresentation: Data) throws -> Data {
    guard SecureEnclave.isAvailable else { throw ProtectedStoreKeyError.hardwareUnavailable }
    return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: opaqueRepresentation).publicKey.x963Representation
  }
  func sign(_ data: Data, opaqueRepresentation: Data) throws -> Data {
    guard SecureEnclave.isAvailable else { throw ProtectedStoreKeyError.hardwareUnavailable }
    return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: opaqueRepresentation)
      .signature(for: data).derRepresentation
  }
}
