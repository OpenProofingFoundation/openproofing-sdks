import CryptoKit
import Foundation
@_spi(CustodyAdapter) import KenshikiProtectedStorage
import Security

/// Migration intent is kept in device-only Keychain custody, not alongside rollbackable capture
/// files. Completion forbids legacy fallback permanently, even if an obsolete raw key still exists.
enum CaptureCustodyKeyMigration {
  struct Marker: Codable, Equatable {
    enum Phase: String, Codable { case pending, complete, erasing, erased }
    enum Origin: String, Codable { case legacy, fresh }
    let version: Int
    let identity: StoreKeyIdentity
    let origin: Origin
    let phase: Phase
  }

  struct Ports {
    let loadMarker: () throws -> Data?
    let saveMarker: (Data) throws -> Void
    let loadLegacy: () throws -> Data?
    let removeLegacy: () throws -> Void
    let importLegacy: (Data) throws -> Void
    let prepare: (Bool) throws -> Void
    let verifyRetained: () throws -> Void
  }

  static func execute(identity: StoreKeyIdentity, retainedCiphertext: Bool, ports: Ports) throws {
    let original: Marker?
    if let bytes = try ports.loadMarker() {
      guard bytes.count <= 4096, let marker = try? JSONDecoder().decode(Marker.self, from: bytes),
        marker.version == 1, marker.identity == identity else {
        throw CaptureEvidenceStoreError.integrityFailure
      }
      original = marker
    } else { original = nil }
    if original?.phase == .erasing { throw CaptureEvidenceStoreError.custodyRevoked }
    if original?.phase == .erased {
      guard !retainedCiphertext else { throw CaptureEvidenceStoreError.integrityFailure }
      // A completed erase may start a new generation, but never inspect/import obsolete raw keys.
      try ports.saveMarker(JSONEncoder().encode(Marker(version: 1, identity: identity, origin: .fresh, phase: .complete)))
      try ports.prepare(false)
      return
    }
    if original?.phase == .complete {
      // Crucially, this path never reads/imports obsolete raw material on any custody failure.
      try ports.prepare(retainedCiphertext)
      try ports.removeLegacy()
      return
    }
    var legacy = try ports.loadLegacy()
    defer { if legacy != nil { legacy!.resetBytes(in: 0..<legacy!.count) } }
    let origin = original?.origin ?? (legacy == nil ? .fresh : .legacy)
    let pending = Marker(version: 1, identity: identity, origin: origin, phase: .pending)
    if original == nil { try ports.saveMarker(JSONEncoder().encode(pending)) }
    if origin == .legacy {
      if let legacy {
        guard legacy.count == 32 else { throw CaptureEvidenceStoreError.integrityFailure }
        try ports.importLegacy(legacy)
      }
      // A pending legacy import may resume from the wrapped key, but cannot create a new key.
      try ports.prepare(true)
    } else {
      guard legacy == nil else { throw CaptureEvidenceStoreError.integrityFailure }
      try ports.prepare(retainedCiphertext)
    }
    try ports.verifyRetained()
    try ports.saveMarker(JSONEncoder().encode(
      Marker(version: 1, identity: identity, origin: origin, phase: .complete)))
    // Completion precedes deletion: a failed delete cannot authorize importing this key again.
    try ports.removeLegacy()
  }
}

extension CaptureEvidenceKey {
  static func sealedErasureMarker(_ configuration: CaptureCustodyConfiguration,
    identity: StoreKeyIdentity, completed: Bool) throws {
    try CaptureMigrationMarkerStorage(configuration: configuration, accessPolicy: identity.accessPolicy).save(
      JSONEncoder().encode(CaptureCustodyKeyMigration.Marker(version: 1, identity: identity,
        origin: .fresh, phase: completed ? .erased : .erasing)))
  }
  static func sealedCompletionMarker(_ configuration: CaptureCustodyConfiguration,
    identity: StoreKeyIdentity) throws -> Data? {
    try CaptureMigrationMarkerStorage(configuration: configuration, accessPolicy: identity.accessPolicy).load()
  }

  static func markExplicitErasureComplete(_ configuration: CaptureCustodyConfiguration,
    identity: StoreKeyIdentity) throws
  {
    // Completion prevents a stranded legacy key from ever becoming a fallback after explicit erase.
    try CaptureMigrationMarkerStorage(configuration: configuration, accessPolicy: identity.accessPolicy).save(JSONEncoder().encode(
      CaptureCustodyKeyMigration.Marker(version: 1, identity: identity, origin: .fresh, phase: .complete)))
  }
  static func hardwareVault(_ configuration: CaptureCustodyConfiguration,
    purpose: String = "capture-evidence-v1",
    accessPolicy: StoreAccessPolicy = .identityWhenUnlocked) throws -> HardwareBoundStoreKeyCustody
  {
    let names = [configuration.keychainService, configuration.keychainAccount, configuration.accessGroup]
    let encoded = try JSONEncoder().encode(names)
    let name = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    return HardwareBoundStoreKeyCustody(identity: try StoreKeyIdentity(
      applicationID: configuration.applicationID, storeID: name, purpose: purpose,
      keychainAccessGroup: configuration.accessGroup,
      accessPolicy: accessPolicy))
  }

  static func hardwareCipher(_ configuration: CaptureCustodyConfiguration,
    vault: HardwareBoundStoreKeyCustody, retainedCiphertext: Bool,
    verifyRetained: ((CaptureEvidenceCipher) throws -> Void)? = nil,
    legacyReader: (() throws -> Data?)? = nil, legacyRemover: (() throws -> Void)? = nil,
    serializedByCaller: Bool = false) throws -> CaptureEvidenceCipher
  {
    let manager = configuration.files
    #if os(iOS)
      let attributes: [FileAttributeKey: Any] = [.protectionKey:
        vault.identity.accessPolicy == .identityWhenUnlocked ? FileProtectionType.complete
          : FileProtectionType.completeUntilFirstUserAuthentication]
    #else
      let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    #endif
    try manager.createDirectory(at: configuration.directory, withIntermediateDirectories: true,
      attributes: attributes)
    let cipher = CaptureEvidenceCipher(vault: vault)
    let verify = verifyRetained ?? {
      try CaptureEvidenceStore.verifyRetainedCiphertext(directory: configuration.directory, cipher: $0)
    }
    let marker = CaptureMigrationMarkerStorage(configuration: configuration, accessPolicy: vault.identity.accessPolicy)
    let migrate = {
      try CaptureCustodyKeyMigration.execute(identity: vault.identity,
        retainedCiphertext: retainedCiphertext, ports: .init(
          loadMarker: { try marker.load() }, saveMarker: { try marker.save($0) },
          loadLegacy: { if let legacyReader { return try legacyReader() }; return try legacyBytes(configuration) },
          removeLegacy: {
            if let legacyRemover { try legacyRemover() }
            else { try remove(service: configuration.keychainService,
              account: configuration.keychainAccount, accessGroup: configuration.accessGroup) }
          },
          importLegacy: {
            // Prove the legacy key opens ALL retained records before importing it into hardware.
            try verify(CaptureEvidenceCipher(key: SymmetricKey(data: $0)))
            try vault.importLegacyKey($0)
          },
          prepare: { try vault.prepare(existingCiphertext: $0) },
          verifyRetained: { try verify(cipher) }))
    }
    if serializedByCaller { try migrate() }
    else { try CaptureCheckpointCodec.withLock(directory: configuration.directory, operation: migrate) }
    return cipher
  }

  private static func legacyBytes(_ configuration: CaptureCustodyConfiguration) throws -> Data? {
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: configuration.keychainService,
      kSecAttrAccount as String: configuration.keychainAccount,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    query[kSecAttrAccessGroup as String] = configuration.accessGroup
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let bytes = result as? Data, bytes.count == 32 else {
      throw Failure(status: status == errSecSuccess ? errSecDecode : status)
    }
    return bytes
  }
}

private struct CaptureMigrationMarkerStorage {
  let configuration: CaptureCustodyConfiguration
  var accessPolicy: StoreAccessPolicy = .identityWhenUnlocked
  var query: [String: Any] {
    var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: configuration.keychainService,
      kSecAttrAccount as String: configuration.keychainAccount + ".hardware-cutover.v1",
      kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true]
    result[kSecAttrAccessGroup as String] = configuration.accessGroup
    return result
  }
  func load() throws -> Data? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let bytes = value as? Data else {
      throw CaptureEvidenceKey.Failure(status: status)
    }
    return bytes
  }
  func save(_ bytes: Data) throws {
    var insertion = query
    insertion[kSecValueData as String] = bytes
    insertion[kSecAttrAccessible as String] = accessPolicy == .identityWhenUnlocked
      ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(insertion as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
      guard updated == errSecSuccess else { throw CaptureEvidenceKey.Failure(status: updated) }
    } else if status != errSecSuccess { throw CaptureEvidenceKey.Failure(status: status) }
  }
}
