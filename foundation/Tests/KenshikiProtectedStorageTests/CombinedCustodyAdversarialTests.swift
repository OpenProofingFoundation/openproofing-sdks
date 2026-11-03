import CryptoKit
import Foundation
import Security
import XCTest
@_spi(CustodyAdapter) @testable import KenshikiProtectedStorage

final class CombinedCustodyAdversarialTests: XCTestCase {
  private func identity(_ application: String = "synthetic.capture") throws -> StoreKeyIdentity {
    try StoreKeyIdentity(applicationID: application, storeID: "capture", purpose: "capture-evidence-v1", keychainAccessGroup: "TEAM.test.app",
      accessPolicy: .identityWhenUnlocked)
  }

  func testCombinedSealNeverCreatesMissingCustodyEvenWithoutExistingFiles() throws {
    let records = CombinedRecords()
    let hardware = CombinedHardware()
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: records, hardware: hardware)
    XCTAssertThrowsError(try vault.sealCombined(Data("retained".utf8), authenticating: Data("bound-record".utf8))) {
      XCTAssertEqual($0 as? ProtectedStoreKeyError, .missingKey)
    }
    XCTAssertEqual(records.adds, 0)
    XCTAssertEqual(hardware.creates, 0)
  }

  func testCombinedRoundTripIsExactLegacyAESGCMAndDoesNotCacheAnUnlockedKey() throws {
    let records = CombinedRecords()
    let hardware = CombinedHardware()
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: records, hardware: hardware)
    let key = Data(repeating: 0x67, count: 32)
    try vault.importLegacyKey(key)
    let payload = Data("synthetic capture pixels".utf8)
    let aad = Data("IdentityEvidenceStorage/v2/metadata/record-one".utf8)
    let sealed = try vault.sealCombined(payload, authenticating: aad)
    XCTAssertEqual(try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: key),
      authenticating: aad), payload)
    XCTAssertEqual(try vault.openCombined(sealed, authenticating: aad), payload)
    XCTAssertThrowsError(try vault.openCombined(sealed, authenticating: Data("different-record".utf8)))
    records.failure = ProtectedStoreKeyError.keychainFailure(errSecInteractionNotAllowed)
    XCTAssertThrowsError(try vault.sealCombined(payload, authenticating: aad))
    XCTAssertThrowsError(try vault.openCombined(sealed, authenticating: aad))
    records.failure = nil
    XCTAssertEqual(try vault.openCombined(sealed, authenticating: aad), payload)
    records.bytes = nil
    XCTAssertThrowsError(try vault.sealCombined(payload, authenticating: aad)) {
      XCTAssertEqual($0 as? ProtectedStoreKeyError, .missingKey)
    }
    XCTAssertThrowsError(try vault.openCombined(sealed, authenticating: aad))
    XCTAssertEqual(records.adds, 1)
    XCTAssertEqual(hardware.creates, 1)
  }

  func testCombinedProofRejectsMutationAndWrongStoreIdentity() throws {
    let records = CombinedRecords()
    let hardware = CombinedHardware()
    let vault = HardwareBoundStoreKeyCustody(identity: try identity(), storage: records, hardware: hardware)
    try vault.prepare(existingCiphertext: false)
    let sealed = try vault.sealCombined(Data("synthetic".utf8), authenticating: Data("context".utf8))
    for offset in [0, sealed.count / 2, sealed.count - 1] {
      var changed = sealed; changed[offset] ^= 1
      XCTAssertThrowsError(try vault.openCombined(changed, authenticating: Data("context".utf8)))
    }
    let other = HardwareBoundStoreKeyCustody(identity: try identity("different.app"), storage: records, hardware: hardware)
    XCTAssertThrowsError(try other.openCombined(sealed, authenticating: Data("context".utf8)))
    XCTAssertEqual(hardware.creates, 1)
  }
}

private final class CombinedRecords: StoreKeyRecordStorage, @unchecked Sendable {
  var bytes: Data?
  var failure: Error?
  var adds = 0
  func load() throws -> Data? { if let failure { throw failure }; return bytes }
  func add(_ record: Data) throws -> Bool { adds += 1; guard bytes == nil else { return false }; bytes = record; return true }
  func remove() throws { bytes = nil }
}

private final class CombinedHardware: StoreHardwareAgreement, @unchecked Sendable {
  var creates = 0
  func create() throws -> (opaqueRepresentation: Data, publicKey: Data) {
    creates += 1
    let key = P256.KeyAgreement.PrivateKey()
    return (key.rawRepresentation, key.publicKey.x963Representation)
  }
  func agree(opaqueRepresentation: Data, publicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
    try P256.KeyAgreement.PrivateKey(rawRepresentation: opaqueRepresentation).sharedSecretFromKeyAgreement(with: publicKey)
  }
}
