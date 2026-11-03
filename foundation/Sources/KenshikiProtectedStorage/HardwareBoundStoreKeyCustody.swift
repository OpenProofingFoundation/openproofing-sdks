import CryptoKit
import Foundation
import Security

/// The Secure Enclave performs P-256 agreement; the recovered AES key necessarily enters RAM while
/// SQLite or record encryption uses it. No raw key or private key is exposed by the public API.
public final class HardwareBoundStoreKeyCustody: @unchecked Sendable {
  public let identity: StoreKeyIdentity
  private let lock = NSLock()
  private let storage: StoreKeyRecordStorage
  private let hardware: StoreHardwareAgreement

  public init(identity: StoreKeyIdentity) {
    self.identity = identity
    storage = DeviceOnlyStoreKeychain(identity: identity)
    hardware = SecureEnclaveStoreAgreement(policy: identity.accessPolicy)
  }

  /// Establishes usable custody without returning any key material. A caller must inventory all
  /// retained ciphertext before allowing creation; keychain/hardware errors are never absence.
  public func prepare(existingCiphertext: Bool) throws {
    try withDatabaseKey(existingCiphertext: existingCiphertext) { _ in () }
  }

  /// Opaque AES-GCM primitive for registered SDK formats whose versioned authenticated-data
  /// contract already binds their record identities. It preserves those exact formats and never
  /// invents a new key. New ordinary record stores should use `seal(_:recordID:context:...)`.
  public func sealCombined(_ plaintext: Data, authenticating authenticatedData: Data) throws -> Data {
    try withDatabaseKey(existingCiphertext: true) {
      guard let result = try AES.GCM.seal(plaintext, using: SymmetricKey(data: $0),
        authenticating: authenticatedData).combined else {
        throw ProtectedStoreKeyError.invalidEnvelope
      }
      return result
    }
  }

  public func openCombined(_ ciphertext: Data, authenticating authenticatedData: Data) throws -> Data {
    try withDatabaseKey(existingCiphertext: true) {
      try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: $0),
        authenticating: authenticatedData)
    }
  }

  // Test injection is deliberately unavailable to clients selecting a production security policy.
  init(identity: StoreKeyIdentity, storage: StoreKeyRecordStorage, hardware: StoreHardwareAgreement) {
    self.identity = identity
    self.storage = storage
    self.hardware = hardware
  }

  /// Import-only bridge for a verified legacy 256-bit key. The caller must first verify that this key
  /// opens the retained legacy ciphertext. Existing custody is never replaced by this operation.
  @_spi(CustodyAdapter)
  public func importLegacyKey(_ key: Data) throws {
    guard key.count == 32 else { throw ProtectedStoreKeyError.invalidKeySize }
    lock.lock()
    defer { lock.unlock() }
    if let existing = try storage.load() {
      var recovered = try recover(existing)
      defer { recovered.resetBytes(in: 0..<recovered.count) }
      guard recovered == key else { throw ProtectedStoreKeyError.keyAlreadyExists }
      return
    }
    let candidate = try makeRecord(key)
    if try !storage.add(candidate) {
      guard let winner = try storage.load() else { throw ProtectedStoreKeyError.missingKey }
      var recovered = try recover(winner)
      defer { recovered.resetBytes(in: 0..<recovered.count) }
      guard recovered == key else { throw ProtectedStoreKeyError.keyAlreadyExists }
    }
  }

  /// Caller-owned ciphertext determines whether creation is allowed. Retained ciphertext with no
  /// key is a recovery error, never an invitation to create a replacement key.
  func withDatabaseKey<T>(existingCiphertext: Bool,
    _ body: (UnsafeRawBufferPointer) throws -> T) throws -> T
  {
    lock.lock()
    defer { lock.unlock() }
    var key = try loadKey(existingCiphertext: existingCiphertext)
    defer { key.resetBytes(in: 0..<key.count) }
    return try key.withUnsafeBytes(body)
  }

  /// Authenticated record encryption also binds the record identity and caller's immutable context.
  /// Use a separate purpose/store identity for independent classes of retained data.
  public func seal(_ plaintext: Data, recordID: String, context: Data = Data(),
    existingCiphertext: Bool) throws -> Data
  {
    let aad = try recordBinding(recordID: recordID, context: context)
    return try withDatabaseKey(existingCiphertext: existingCiphertext) {
      let key = SymmetricKey(data: $0)
      guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined else {
        throw ProtectedStoreKeyError.invalidEnvelope
      }
      return Data([1]) + combined
    }
  }

  public func open(_ ciphertext: Data, recordID: String, context: Data = Data()) throws -> Data {
    guard ciphertext.first == 1, ciphertext.count >= 29 else {
      throw ProtectedStoreKeyError.invalidEnvelope
    }
    let aad = try recordBinding(recordID: recordID, context: context)
    return try withDatabaseKey(existingCiphertext: true) {
      try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext.dropFirst()),
        using: SymmetricKey(data: $0), authenticating: aad)
    }
  }

  /// A one-time, adapter-journaled migration bridge for a recognized legacy AES-GCM format. The
  /// adapter strips only its known old prefix and supplies the exact original authenticated data.
  /// This method does not authorize importing/recreating a missing key or indefinite legacy reads.
  public func migrateLegacyAESGCM(_ combined: Data, legacyAuthenticatedData: Data,
    recordID: String, context: Data = Data()) throws -> Data
  {
    let aad = try recordBinding(recordID: recordID, context: context)
    return try withDatabaseKey(existingCiphertext: true) {
      let key = SymmetricKey(data: $0)
      var plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key,
        authenticating: legacyAuthenticatedData)
      defer { plaintext.resetBytes(in: 0..<plaintext.count) }
      guard let migrated = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined else {
        throw ProtectedStoreKeyError.invalidEnvelope
      }
      return Data([1]) + migrated
    }
  }

  // The owning encrypted store calls this only after durable ciphertext erasure. Erasure ordering
  // and restart intent are responsibilities of the store, not an unverified host Boolean.
  func destroyAfterCiphertextErasure() throws {
    lock.lock()
    defer { lock.unlock() }
    try storage.remove()
  }

  /// Registered SDK adapters call only after their durable erase intent, publication drain,
  /// ciphertext/sidecar deletion and verified inventory readback. This is not an app escape hatch.
  @_spi(CustodyAdapter)
  public func retireAfterVerifiedCiphertextErasure() throws {
    try destroyAfterCiphertextErasure()
  }

  private func recordBinding(recordID: String, context: Data) throws -> Data {
    guard !recordID.isEmpty, recordID.utf8.count <= 1024, context.count <= 1_048_576 else {
      throw ProtectedStoreKeyError.invalidIdentity
    }
    return StoreKeyIdentity.frame([Data("kenshiki/record-aead/v1".utf8), identity.binding,
      Data(recordID.utf8), context])
  }

  private func loadKey(existingCiphertext: Bool) throws -> Data {
    if let record = try storage.load() { return try recover(record) }
    guard !existingCiphertext else { throw ProtectedStoreKeyError.missingKey }
    var key = Data(count: 32)
    defer { key.resetBytes(in: 0..<key.count) }
    let randomStatus = key.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
    }
    guard randomStatus == errSecSuccess else {
      throw ProtectedStoreKeyError.keychainFailure(randomStatus)
    }
    let record = try makeRecord(key)
    if try storage.add(record) { return try recover(record) }
    // Cross-process creation races use the atomically persisted winner, never a local candidate.
    guard let winner = try storage.load() else { throw ProtectedStoreKeyError.missingKey }
    return try recover(winner)
  }

  private func makeRecord(_ key: Data) throws -> Data {
    let recipient = try hardware.create()
    let envelope = try StoreKeyEnvelope.wrap(key, identity: identity,
      recipient: P256.KeyAgreement.PublicKey(x963Representation: recipient.publicKey))
    return try JSONEncoder().encode(StoreHardwareKeyRecord(version: 1, identity: identity,
      hardwareKey: recipient.opaqueRepresentation, envelope: envelope))
  }

  private func recover(_ bytes: Data) throws -> Data {
    guard bytes.count <= 16_384,
      let record = try? JSONDecoder().decode(StoreHardwareKeyRecord.self, from: bytes),
      record.version == 1, record.identity == identity
    else { throw ProtectedStoreKeyError.invalidEnvelope }
    return try record.envelope.unwrap(identity: identity) { publicKey in
      try hardware.agree(opaqueRepresentation: record.hardwareKey, publicKey: publicKey)
    }
  }
}

struct StoreHardwareKeyRecord: Codable {
  let version: Int
  let identity: StoreKeyIdentity
  let hardwareKey: Data
  let envelope: StoreKeyEnvelope
}

struct StoreKeyEnvelope: Codable {
  let version: Int
  let recipientPublicKey: Data
  let ephemeralPublicKey: Data
  let salt: Data
  let sealedKey: Data

  static func wrap(_ key: Data, identity: StoreKeyIdentity,
    recipient: P256.KeyAgreement.PublicKey) throws -> Self
  {
    guard key.count == 32 else { throw ProtectedStoreKeyError.invalidKeySize }
    let ephemeral = P256.KeyAgreement.PrivateKey()
    let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let aad = binding(identity, recipient.x963Representation, ephemeral.publicKey.x963Representation)
    let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
    let wrapping = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
      sharedInfo: aad, outputByteCount: 32)
    guard let sealed = try AES.GCM.seal(key, using: wrapping, authenticating: aad).combined else {
      throw ProtectedStoreKeyError.invalidEnvelope
    }
    return Self(version: 1, recipientPublicKey: recipient.x963Representation,
      ephemeralPublicKey: ephemeral.publicKey.x963Representation, salt: salt, sealedKey: sealed)
  }

  func unwrap(identity: StoreKeyIdentity,
    agreement: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> Data
  {
    guard version == 1, salt.count == 32, sealedKey.count == 60,
      recipientPublicKey.count == 65, ephemeralPublicKey.count == 65 else {
      throw ProtectedStoreKeyError.invalidEnvelope
    }
    let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKey)
    let shared = try agreement(publicKey)
    let aad = Self.binding(identity, recipientPublicKey, ephemeralPublicKey)
    let wrapping = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
      sharedInfo: aad, outputByteCount: 32)
    let key = try AES.GCM.open(AES.GCM.SealedBox(combined: sealedKey), using: wrapping,
      authenticating: aad)
    guard key.count == 32 else { throw ProtectedStoreKeyError.invalidKeySize }
    return key
  }

  private static func binding(_ identity: StoreKeyIdentity, _ recipient: Data, _ ephemeral: Data)
    -> Data
  {
    StoreKeyIdentity.frame([Data("kenshiki/store-key-wrap/p256-hkdf-sha256-aes256gcm/v1".utf8),
      identity.binding, recipient, ephemeral])
  }
}

protocol StoreKeyRecordStorage: Sendable {
  func load() throws -> Data?
  func add(_ record: Data) throws -> Bool
  func remove() throws
}

protocol StoreHardwareAgreement: Sendable {
  func create() throws -> (opaqueRepresentation: Data, publicKey: Data)
  func agree(opaqueRepresentation: Data, publicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret
}

struct SecureEnclaveStoreAgreement: StoreHardwareAgreement {
  let policy: StoreAccessPolicy

  func create() throws -> (opaqueRepresentation: Data, publicKey: Data) {
    guard SecureEnclave.isAvailable else { throw ProtectedStoreKeyError.hardwareUnavailable }
    var error: Unmanaged<CFError>?
    guard let control = SecAccessControlCreateWithFlags(nil, policy.keychainAccessibility,
      .privateKeyUsage, &error) else { throw ProtectedStoreKeyError.hardwareUnavailable }
    let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: control)
    return (key.dataRepresentation, key.publicKey.x963Representation)
  }

  func agree(opaqueRepresentation: Data, publicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
    guard SecureEnclave.isAvailable else { throw ProtectedStoreKeyError.hardwareUnavailable }
    let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: opaqueRepresentation)
    return try key.sharedSecretFromKeyAgreement(with: publicKey)
  }
}

extension StoreAccessPolicy {
  var keychainAccessibility: CFString {
    switch self {
    case .identityWhenUnlocked: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    case .backgroundAfterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
  }
}

struct DeviceOnlyStoreKeychain: StoreKeyRecordStorage {
  let identity: StoreKeyIdentity
  private let service: String
  private let account: String

  init(identity: StoreKeyIdentity, service: String = "com.kenshiki.protected-storage.v1",
    accountPrefix: String = "") {
    self.identity = identity; self.service = service; account = accountPrefix + identity.account
  }

  var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
      kSecAttrAccessGroup as String: identity.keychainAccessGroup,
      kSecUseDataProtectionKeychain as String: true]
  }
  func load() throws -> Data? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let bytes = result as? Data else {
      throw ProtectedStoreKeyError.keychainFailure(status)
    }
    return bytes
  }
  func add(_ record: Data) throws -> Bool {
    var request = query
    request[kSecAttrAccessible as String] = identity.accessPolicy.keychainAccessibility
    request[kSecValueData as String] = record
    let status = SecItemAdd(request as CFDictionary, nil)
    if status == errSecDuplicateItem { return false }
    guard status == errSecSuccess else { throw ProtectedStoreKeyError.keychainFailure(status) }
    return true
  }
  func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ProtectedStoreKeyError.keychainFailure(status)
    }
  }
}
