import CryptoKit
import Foundation
import Security
import XCTest
@_spi(CustodyAdapter) @testable import KenshikiProtectedStorage

final class HardwareBoundSigningKeyCustodyTests: XCTestCase {
  private func identity(_ purpose: String = "capture-signing") throws -> StoreKeyIdentity {
    try .init(applicationID: "test.app", storeID: "front", purpose: purpose,
      keychainAccessGroup: "TEAM.test.app", accessPolicy: .identityWhenUnlocked)
  }
  private func custody(_ storage: SigningMemory, _ hardware: SigningHardware) throws -> HardwareBoundSigningKeyCustody {
    try .init(identity: identity(), storage: storage, hardware: hardware)
  }

  func testHistoricalLookupSignAndVerificationNeverProvision() throws {
    let storage = SigningMemory(); let hardware = SigningHardware()
    let key = try custody(storage, hardware)
    XCTAssertNil(try key.existingPublicKeyHash())
    XCTAssertThrowsError(try key.sign(Data([1])))
    XCTAssertFalse(try key.verify(Data([1]), data: Data([2]), trustedPublicKeyHash: "missing"))
    XCTAssertEqual(hardware.creates, 0); XCTAssertEqual(storage.adds, 0)
  }

  func testOpaqueKeyReopensAndCryptographicallyVerifiesExactBytes() throws {
    let storage = SigningMemory(); let hardware = SigningHardware()
    let first = try custody(storage, hardware)
    let hash = try first.preparePublicKeyHash()
    let message = Data("synthetic capture manifest".utf8)
    let signed = try first.sign(message)
    let reopened = try custody(storage, hardware)
    XCTAssertEqual(try reopened.existingPublicKeyHash(), hash)
    XCTAssertTrue(try reopened.verify(signed.signature, data: message, trustedPublicKeyHash: hash))
    XCTAssertFalse(try reopened.verify(signed.signature, data: Data([0]), trustedPublicKeyHash: hash))
    XCTAssertFalse(try reopened.verify(signed.signature, data: message, trustedPublicKeyHash: "other"))
    XCTAssertFalse(try reopened.verify(Data(repeating: 0, count: 81), data: message, trustedPublicKeyHash: hash))
    XCTAssertEqual(hardware.creates, 1); XCTAssertEqual(storage.adds, 1)
    XCTAssertNil(try XCTUnwrap(storage.bytes).range(of: message))
  }

  func testCorruptLockedAndUnavailableCustodyNeverReplacesKey() throws {
    let storage = SigningMemory(); let hardware = SigningHardware()
    let key = try custody(storage, hardware)
    _ = try key.preparePublicKeyHash()
    let original = storage.bytes
    hardware.failure = ProtectedStoreKeyError.hardwareUnavailable
    XCTAssertThrowsError(try key.preparePublicKeyHash())
    XCTAssertEqual(storage.bytes, original)
    hardware.failure = nil
    storage.failure = ProtectedStoreKeyError.keychainFailure(errSecInteractionNotAllowed)
    XCTAssertThrowsError(try key.preparePublicKeyHash())
    storage.failure = nil; storage.bytes = Data("corrupt".utf8)
    XCTAssertThrowsError(try key.preparePublicKeyHash())
    XCTAssertEqual(storage.bytes, Data("corrupt".utf8))
    XCTAssertEqual(hardware.creates, 1); XCTAssertEqual(storage.adds, 1)
  }

  func testSigningStorageCannotAliasDatabaseEvenWithSameHostIdentity() throws {
    let namespace = try identity()
    let signing = HardwareBoundSigningKeyCustody.keychain(namespace).query
    let database = DeviceOnlyStoreKeychain(identity: namespace).query
    XCTAssertEqual(database[kSecAttrService as String] as? String, "com.kenshiki.protected-storage.v1")
    XCTAssertEqual(database[kSecAttrAccount as String] as? String, namespace.account)
    XCTAssertEqual(signing[kSecAttrService as String] as? String, "com.kenshiki.capture-evidence-signing.v1")
    XCTAssertEqual(signing[kSecAttrAccount as String] as? String, "p256-signing.v1." + namespace.account)
    XCTAssertEqual(signing[kSecAttrAccessGroup as String] as? String, "TEAM.test.app")
    XCTAssertEqual(signing[kSecAttrSynchronizable as String] as? Bool, false)
    XCTAssertEqual(signing[kSecUseDataProtectionKeychain as String] as? Bool, true)
  }

  func testCrossScopeRecordAndUnknownVersionAreRejectedWithoutCreation() throws {
    let storage = SigningMemory(); let hardware = SigningHardware()
    let key = try custody(storage, hardware)
    _ = try key.preparePublicKeyHash()
    let other = try HardwareBoundSigningKeyCustody(identity: identity("database"), storage: storage, hardware: hardware)
    XCTAssertThrowsError(try other.existingPublicKeyHash())
    var record = try JSONSerialization.jsonObject(with: XCTUnwrap(storage.bytes)) as! [String: Any]
    record["version"] = 2
    storage.bytes = try JSONSerialization.data(withJSONObject: record)
    XCTAssertThrowsError(try key.preparePublicKeyHash())
    XCTAssertEqual(hardware.creates, 1)
  }

  func testErasureRetiresInstanceAndRepeatedErasePreservesReplacement() throws {
    let storage = SigningMemory(); let hardware = SigningHardware()
    let old = try custody(storage, hardware)
    let oldHash = try old.preparePublicKeyHash()
    try old.eraseKeyAfterCiphertextErasure()
    XCTAssertNil(storage.bytes)
    let replacement = try custody(storage, hardware)
    let newHash = try replacement.preparePublicKeyHash()
    XCTAssertNotEqual(oldHash, newHash)
    try old.eraseKeyAfterCiphertextErasure()
    XCTAssertEqual(try replacement.existingPublicKeyHash(), newHash)
    XCTAssertThrowsError(try old.preparePublicKeyHash())
    XCTAssertThrowsError(try old.sign(Data([1])))
    XCTAssertEqual(storage.removes, 1)
  }

  func testStaleFirstErasureRefusesAnotherKeyAndFailedEraseCanRetry() throws {
    let storage = SigningMemory(); let hardware = SigningHardware()
    let old = try custody(storage, hardware)
    _ = try old.preparePublicKeyHash()
    storage.removeFailure = ProtectedStoreKeyError.keychainFailure(errSecInteractionNotAllowed)
    XCTAssertThrowsError(try old.eraseKeyAfterCiphertextErasure())
    XCTAssertThrowsError(try old.sign(Data([1])))
    storage.removeFailure = nil
    try old.eraseKeyAfterCiphertextErasure()
    let fresh = try custody(storage, hardware)
    _ = try fresh.preparePublicKeyHash()
    let observer = try custody(storage, hardware)
    _ = try observer.existingPublicKeyHash()
    storage.bytes = nil
    let replacement = try custody(storage, hardware)
    let replacementHash = try replacement.preparePublicKeyHash()
    XCTAssertThrowsError(try observer.eraseKeyAfterCiphertextErasure())
    XCTAssertEqual(try replacement.existingPublicKeyHash(), replacementHash)
  }

  func testMissingPreviouslyObservedKeyAndInitialHardwareFailureNeverRekey() throws {
    let storage = SigningMemory(); let hardware = SigningHardware()
    let key = try custody(storage, hardware)
    hardware.failure = ProtectedStoreKeyError.hardwareUnavailable
    XCTAssertThrowsError(try key.preparePublicKeyHash())
    XCTAssertNil(storage.bytes); XCTAssertEqual(storage.adds, 0)
    hardware.failure = nil
    _ = try key.preparePublicKeyHash()
    storage.bytes = nil
    XCTAssertThrowsError(try key.preparePublicKeyHash())
    XCTAssertEqual(hardware.creates, 1)
  }

  func testForegroundOnlyAndCorruptOpaqueRecordCanBeExplicitlyErased() throws {
    let background = try StoreKeyIdentity(applicationID: "test.app", storeID: "front", purpose: "capture-signing",
      keychainAccessGroup: "TEAM.test.app", accessPolicy: .backgroundAfterFirstUnlock)
    XCTAssertThrowsError(try HardwareBoundSigningKeyCustody(identity: background))
    let storage = SigningMemory(); let hardware = SigningHardware()
    storage.bytes = Data("corrupt".utf8)
    try custody(storage, hardware).eraseKeyAfterCiphertextErasure()
    XCTAssertNil(storage.bytes); XCTAssertEqual(hardware.creates, 0)
  }

  func testConcurrentCreationUsesDurableWinnerInsteadOfLocalCandidate() throws {
    let winnerMemory = SigningMemory(); let hardware = SigningHardware()
    let winnerHash = try custody(winnerMemory, hardware).preparePublicKeyHash()
    let competing = SigningMemory()
    competing.competingWinner = winnerMemory.bytes
    let contender = try custody(competing, hardware)
    XCTAssertEqual(try contender.preparePublicKeyHash(), winnerHash)
    XCTAssertEqual(try contender.existingPublicKeyHash(), winnerHash)
    XCTAssertEqual(hardware.creates, 2)
  }
}

private final class SigningMemory: StoreKeyRecordStorage, @unchecked Sendable {
  var bytes: Data?
  var failure: Error?
  var removeFailure: Error?
  var competingWinner: Data?
  var adds = 0
  var removes = 0
  func load() throws -> Data? { if let failure { throw failure }; return bytes }
  func add(_ record: Data) throws -> Bool {
    adds += 1
    if let competingWinner { bytes = competingWinner; self.competingWinner = nil; return false }
    guard bytes == nil else { return false }
    bytes = record; return true
  }
  func remove() throws {
    removes += 1
    if let removeFailure { throw removeFailure }
    bytes = nil
  }
}

// Explicit software fixture only: production construction selects SecureEnclaveStoreSigning.
private final class SigningHardware: StoreHardwareSigning, @unchecked Sendable {
  var creates = 0
  var failure: Error?
  private var keys: [Data: P256.Signing.PrivateKey] = [:]
  func create() throws -> Data {
    if let failure { throw failure }
    creates += 1
    let handle = Data(UUID().uuidString.utf8)
    keys[handle] = P256.Signing.PrivateKey(); return handle
  }
  func publicKey(_ opaqueRepresentation: Data) throws -> Data {
    if let failure { throw failure }
    guard let key = keys[opaqueRepresentation] else { throw ProtectedStoreKeyError.missingKey }
    return key.publicKey.x963Representation
  }
  func sign(_ data: Data, opaqueRepresentation: Data) throws -> Data {
    if let failure { throw failure }
    guard let key = keys[opaqueRepresentation] else { throw ProtectedStoreKeyError.missingKey }
    return try key.signature(for: data).derRepresentation
  }
}
