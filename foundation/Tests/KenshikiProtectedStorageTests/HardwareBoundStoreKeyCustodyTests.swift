import CryptoKit
import Foundation
import Security
import XCTest
@_spi(CustodyAdapter) @testable import KenshikiProtectedStorage

final class HardwareBoundStoreKeyCustodyTests: XCTestCase {
  private func identity(_ store: String = "identity", purpose: String = "sqlite",
    policy: StoreAccessPolicy = .identityWhenUnlocked) throws -> StoreKeyIdentity
  {
    try StoreKeyIdentity(applicationID: "test.app", storeID: store, purpose: purpose, keychainAccessGroup: "TEAM.test.app",
      accessPolicy: policy)
  }

  func testKeyPersistsWithoutRawKeyOrPrivateKeyExport() throws {
    let memory = MemoryKeyRecord()
    let hardware = AgreementFixture()
    let namespace = try identity()
    let first = HardwareBoundStoreKeyCustody(identity: namespace, storage: memory, hardware: hardware)
    let sealed = try first.seal(Data("fixture".utf8), recordID: "record", existingCiphertext: false)
    let second = HardwareBoundStoreKeyCustody(identity: namespace, storage: memory, hardware: hardware)
    XCTAssertEqual(try second.open(sealed, recordID: "record"), Data("fixture".utf8))
    XCTAssertEqual(hardware.creates, 1)
    let persisted = try XCTUnwrap(memory.bytes)
    let record = try JSONDecoder().decode(StoreHardwareKeyRecord.self, from: persisted)
    XCTAssertEqual(record.envelope.sealedKey.count, 60)
    XCTAssertFalse(persisted.range(of: Data("fixture".utf8)) != nil)
  }

  func testMissingKeyWithRetainedCiphertextNeverGeneratesOrWrites() throws {
    let memory = MemoryKeyRecord()
    let hardware = AgreementFixture()
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: memory, hardware: hardware)
    XCTAssertThrowsError(try vault.withDatabaseKey(existingCiphertext: true) { _ in () }) {
      XCTAssertEqual($0 as? ProtectedStoreKeyError, .missingKey)
    }
    XCTAssertEqual(hardware.creates, 0)
    XCTAssertEqual(memory.adds, 0)
  }

  func testLockedKeychainIsNotMistakenForMissingKey() throws {
    let memory = MemoryKeyRecord()
    memory.loadError = ProtectedStoreKeyError.keychainFailure(errSecInteractionNotAllowed)
    let hardware = AgreementFixture()
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: memory, hardware: hardware)
    XCTAssertThrowsError(try vault.withDatabaseKey(existingCiphertext: false) { _ in () }) {
      XCTAssertEqual($0 as? ProtectedStoreKeyError, .keychainFailure(errSecInteractionNotAllowed))
    }
    XCTAssertEqual(hardware.creates, 0)
    XCTAssertEqual(memory.adds, 0)
  }

  func testHardwareFailureNeverFallsBackToSoftwareOrPersists() throws {
    let memory = MemoryKeyRecord()
    let hardware = AgreementFixture()
    hardware.failure = ProtectedStoreKeyError.hardwareUnavailable
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: memory, hardware: hardware)
    XCTAssertThrowsError(try vault.withDatabaseKey(existingCiphertext: false) { _ in () }) {
      XCTAssertEqual($0 as? ProtectedStoreKeyError, .hardwareUnavailable)
    }
    XCTAssertNil(memory.bytes)
  }

  func testExistingHardwareKeyUnavailablePreservesRecordAndDoesNotRekey() throws {
    let memory = MemoryKeyRecord()
    let hardware = AgreementFixture()
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: memory, hardware: hardware)
    let sealed = try vault.seal(Data([8]), recordID: "evidence", existingCiphertext: false)
    let original = memory.bytes
    hardware.failure = ProtectedStoreKeyError.hardwareUnavailable
    XCTAssertThrowsError(try vault.open(sealed, recordID: "evidence"))
    XCTAssertEqual(memory.bytes, original)
    XCTAssertEqual(memory.adds, 1)
    XCTAssertEqual(hardware.creates, 1)
  }

  func testRecordCiphertextMutationAndUnknownVersionAreRefused() throws {
    let memory = MemoryKeyRecord()
    let hardware = AgreementFixture()
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: memory, hardware: hardware)
    let sealed = try vault.seal(Data("retained".utf8), recordID: "evidence", existingCiphertext: false)
    for index in [0, 1, sealed.count - 1] {
      var altered = sealed
      altered[index] ^= 1
      XCTAssertThrowsError(try vault.open(altered, recordID: "evidence"))
    }
    XCTAssertEqual(try vault.open(sealed, recordID: "evidence"), Data("retained".utf8))
    XCTAssertEqual(hardware.creates, 1)
  }

  func testPurposeApplicationStoreAndPolicySubstitutionRefused() throws {
    let memory = MemoryKeyRecord()
    let hardware = AgreementFixture()
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: memory, hardware: hardware)
    let sealed = try vault.seal(Data([42]), recordID: "a", existingCiphertext: false)
    let alternates = [try identity("other"), try identity(purpose: "signing"),
      try identity(policy: .backgroundAfterFirstUnlock),
      try StoreKeyIdentity(applicationID: "other.app", storeID: "identity", purpose: "sqlite", keychainAccessGroup: "TEAM.test.app",
        accessPolicy: .identityWhenUnlocked),
      try StoreKeyIdentity(applicationID: "test.app", storeID: "identity", purpose: "sqlite",
        keychainAccessGroup: "TEAM.other", accessPolicy: .identityWhenUnlocked)]
    for different in alternates {
      let attacker = HardwareBoundStoreKeyCustody(identity: different, storage: memory, hardware: hardware)
      XCTAssertThrowsError(try attacker.open(sealed, recordID: "a"))
    }
    XCTAssertThrowsError(try vault.open(sealed, recordID: "b"))
    XCTAssertThrowsError(try vault.open(sealed, recordID: "a", context: Data([1])))
  }

  func testEnvelopeAuthenticatesIdentityPublicKeysSaltAndCiphertext() throws {
    let recipient = P256.KeyAgreement.PrivateKey()
    let namespace = try identity()
    let key = Data(repeating: 7, count: 32)
    let wrapped = try StoreKeyEnvelope.wrap(key, identity: namespace, recipient: recipient.publicKey)
    XCTAssertEqual(try wrapped.unwrap(identity: namespace) {
      try recipient.sharedSecretFromKeyAgreement(with: $0)
    }, key)
    XCTAssertThrowsError(try wrapped.unwrap(identity: identity("other")) {
      try recipient.sharedSecretFromKeyAgreement(with: $0)
    })
    let mutate: (Data) -> Data = { data in
      var result = data
      result[result.startIndex] ^= 1
      return result
    }
    let variants = [
      StoreKeyEnvelope(version: 2, recipientPublicKey: wrapped.recipientPublicKey,
        ephemeralPublicKey: wrapped.ephemeralPublicKey, salt: wrapped.salt, sealedKey: wrapped.sealedKey),
      StoreKeyEnvelope(version: 1, recipientPublicKey: mutate(wrapped.recipientPublicKey),
        ephemeralPublicKey: wrapped.ephemeralPublicKey, salt: wrapped.salt, sealedKey: wrapped.sealedKey),
      StoreKeyEnvelope(version: 1, recipientPublicKey: wrapped.recipientPublicKey,
        ephemeralPublicKey: mutate(wrapped.ephemeralPublicKey), salt: wrapped.salt, sealedKey: wrapped.sealedKey),
      StoreKeyEnvelope(version: 1, recipientPublicKey: wrapped.recipientPublicKey,
        ephemeralPublicKey: wrapped.ephemeralPublicKey, salt: mutate(wrapped.salt), sealedKey: wrapped.sealedKey),
      StoreKeyEnvelope(version: 1, recipientPublicKey: wrapped.recipientPublicKey,
        ephemeralPublicKey: wrapped.ephemeralPublicKey, salt: wrapped.salt, sealedKey: mutate(wrapped.sealedKey)),
    ]
    for variant in variants {
      XCTAssertThrowsError(try variant.unwrap(identity: namespace) {
        try recipient.sharedSecretFromKeyAgreement(with: $0)
      })
    }
  }

  func testLegacyImportIsIdempotentAndNeverReplacesAKey() throws {
    let memory = MemoryKeyRecord()
    let hardware = AgreementFixture()
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: memory, hardware: hardware)
    let key = Data(repeating: 3, count: 32)
    try vault.importLegacyKey(key)
    try vault.importLegacyKey(key)
    XCTAssertEqual(hardware.creates, 1)
    XCTAssertEqual(try vault.withDatabaseKey(existingCiphertext: true) { Data($0) }, key)
    XCTAssertThrowsError(try vault.importLegacyKey(Data(repeating: 4, count: 32))) {
      XCTAssertEqual($0 as? ProtectedStoreKeyError, .keyAlreadyExists)
    }
    XCTAssertEqual(try vault.withDatabaseKey(existingCiphertext: true) { Data($0) }, key)
    XCTAssertThrowsError(try vault.importLegacyKey(Data([1])))
  }

  func testLegacyMigrationRequiresOriginalAADAndProducesBoundCiphertext() throws {
    let memory = MemoryKeyRecord()
    let hardware = AgreementFixture()
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: memory, hardware: hardware)
    let key = Data(repeating: 31, count: 32)
    let originalAAD = Data("group\0service\0account".utf8)
    let legacy = try XCTUnwrap(AES.GCM.seal(Data("legacy fixture".utf8),
      using: SymmetricKey(data: key), authenticating: originalAAD).combined)
    XCTAssertThrowsError(try vault.migrateLegacyAESGCM(legacy, legacyAuthenticatedData: originalAAD,
      recordID: "a")) {
      XCTAssertEqual($0 as? ProtectedStoreKeyError, .missingKey)
    }
    XCTAssertEqual(hardware.creates, 0)
    try vault.importLegacyKey(key)
    XCTAssertThrowsError(try vault.migrateLegacyAESGCM(legacy,
      legacyAuthenticatedData: Data("other\0service\0account".utf8), recordID: "a"))
    let migrated = try vault.migrateLegacyAESGCM(legacy, legacyAuthenticatedData: originalAAD,
      recordID: "a", context: Data("generation-1".utf8))
    XCTAssertEqual(try vault.open(migrated, recordID: "a", context: Data("generation-1".utf8)),
      Data("legacy fixture".utf8))
    XCTAssertThrowsError(try vault.open(migrated, recordID: "b", context: Data("generation-1".utf8)))
    XCTAssertThrowsError(try vault.open(migrated, recordID: "a", context: Data("generation-2".utf8)))
    XCTAssertEqual(hardware.creates, 1)
  }

  func testCorruptRetainedRecordNeverRekeys() throws {
    let memory = MemoryKeyRecord()
    memory.bytes = Data("corrupt".utf8)
    let hardware = AgreementFixture()
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: memory, hardware: hardware)
    XCTAssertThrowsError(try vault.withDatabaseKey(existingCiphertext: false) { _ in () })
    XCTAssertEqual(memory.bytes, Data("corrupt".utf8))
    XCTAssertEqual(hardware.creates, 0)
  }

  func testConcurrentKeychainAddUsesWinnerNotUnpersistedCandidate() throws {
    let namespace = try identity()
    let hardware = AgreementFixture()
    let winnerStore = MemoryKeyRecord()
    let winner = HardwareBoundStoreKeyCustody(identity: namespace, storage: winnerStore, hardware: hardware)
    let expected = Data(repeating: 19, count: 32)
    try winner.importLegacyKey(expected)
    let memory = MemoryKeyRecord()
    memory.competingWinner = winnerStore.bytes
    let loser = HardwareBoundStoreKeyCustody(identity: namespace, storage: memory, hardware: hardware)
    XCTAssertEqual(try loser.withDatabaseKey(existingCiphertext: false) { Data($0) }, expected)
  }

  func testAccessPoliciesAreDeviceOnlyWithoutUserPresence() throws {
    XCTAssertEqual(StoreAccessPolicy.identityWhenUnlocked.keychainAccessibility,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    XCTAssertEqual(StoreAccessPolicy.backgroundAfterFirstUnlock.keychainAccessibility,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    XCTAssertNotEqual(try identity().account, try identity(policy: .backgroundAfterFirstUnlock).account)
    XCTAssertThrowsError(try StoreKeyIdentity(applicationID: "", storeID: "s", purpose: "p", keychainAccessGroup: "TEAM.test.app",
      accessPolicy: .identityWhenUnlocked))
  }

  func testEveryKeychainOperationSelectsOneExplicitAccessGroup() throws {
    let query = DeviceOnlyStoreKeychain(identity: try identity()).query
    XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "TEAM.test.app")
    XCTAssertThrowsError(try StoreKeyIdentity(applicationID: "test.app", storeID: "s", purpose: "p",
      keychainAccessGroup: "", accessPolicy: .identityWhenUnlocked))
  }
}

// Software agreement exists only in a test fixture; production construction is hardware-only.
private final class AgreementFixture: StoreHardwareAgreement, @unchecked Sendable {
  var creates = 0
  var failure: Error?
  private var keys: [Data: P256.KeyAgreement.PrivateKey] = [:]
  func create() throws -> (opaqueRepresentation: Data, publicKey: Data) {
    if let failure { throw failure }
    creates += 1
    let key = P256.KeyAgreement.PrivateKey()
    let handle = Data(UUID().uuidString.utf8)
    keys[handle] = key
    return (handle, key.publicKey.x963Representation)
  }
  func agree(opaqueRepresentation: Data, publicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
    if let failure { throw failure }
    guard let key = keys[opaqueRepresentation] else { throw ProtectedStoreKeyError.missingKey }
    return try key.sharedSecretFromKeyAgreement(with: publicKey)
  }
}

private final class MemoryKeyRecord: StoreKeyRecordStorage, @unchecked Sendable {
  var bytes: Data?
  var loadError: Error?
  var competingWinner: Data?
  var adds = 0
  func load() throws -> Data? {
    if let loadError { throw loadError }
    return bytes
  }
  func add(_ record: Data) throws -> Bool {
    adds += 1
    if let competingWinner {
      bytes = competingWinner
      self.competingWinner = nil
      return false
    }
    guard bytes == nil else { return false }
    bytes = record
    return true
  }
  func remove() throws { bytes = nil }
}
