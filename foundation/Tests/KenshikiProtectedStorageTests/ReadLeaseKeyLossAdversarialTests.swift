import CryptoKit
import Foundation
import SQLCipher
import XCTest
@_spi(StorageAdapter) @testable import KenshikiProtectedStorage

/// Independent review fixtures use real SQLCipher/AEAD without claiming a hardware-device gate.
final class ReadLeaseKeyLossAdversarialTests: XCTestCase {
    private func fixture() throws -> (ProtectedSQLiteStore, HardwareBoundStoreKeyCustody, ReviewLeaseRecords, ReviewLeaseHardware) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let identity = try StoreKeyIdentity(applicationID: "synthetic.lease.review", storeID: "read", purpose: "sqlite",
            keychainAccessGroup: "TEST.synthetic.lease.review", accessPolicy: .backgroundAfterFirstUnlock)
        let records = ReviewLeaseRecords(), hardware = ReviewLeaseHardware()
        let custody = HardwareBoundStoreKeyCustody(identity: identity, storage: records, hardware: hardware)
        let store = try ProtectedSQLiteStore(databaseURL: directory.appendingPathComponent("observations.sqlite"),
            identity: identity, custody: custody)
        try store.withConnection { try ProtectedSQLiteStore.execute($0, "CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('synthetic-retained')") }
        return (store, custody, records, hardware)
    }

    func testMissingOrCorruptKeyRetiresCachedLeaseWithoutProvisioningAReplacement() throws {
        for corrupt in [false, true] {
            let (store, _, records, hardware) = try fixture()
            let lease = try store.makeReadLease()
            XCTAssertEqual(try lease.withConnection { try ProtectedSQLiteStore.scalar($0, "SELECT value FROM evidence") }, "synthetic-retained")
            let originalKey = records.bytes
            let originalFile = try Data(contentsOf: store.databaseURL)
            records.bytes = corrupt ? Data("corrupt wrapped custody".utf8) : nil
            XCTAssertThrowsError(try lease.withConnection { _ in XCTFail("cached data admitted without custody") })
            XCTAssertEqual(hardware.creates, 1)
            XCTAssertEqual(try Data(contentsOf: store.databaseURL), originalFile)
            records.bytes = originalKey
            XCTAssertThrowsError(try lease.withConnection { _ in XCTFail("failed lease reopened cached pages") }) {
                XCTAssertEqual($0 as? ProtectedReadLeaseError, .closed)
            }
            try store.withConnection { XCTAssertEqual(try ProtectedSQLiteStore.scalar($0, "SELECT value FROM evidence"), "synthetic-retained") }
            try store.erase()
        }
    }

    func testBusyEraseSurvivesRestartThenExplicitRecoveryRemovesTheSameGeneration() throws {
        let (store, custody, _, hardware) = try fixture()
        let lease = try store.makeReadLease()
        XCTAssertThrowsError(try store.erase()) { XCTAssertEqual($0 as? ProtectedSQLiteError, .unavailable(SQLITE_BUSY)) }
        XCTAssertThrowsError(try ProtectedSQLiteStore(databaseURL: store.databaseURL, identity: custody.identity, custody: custody)) {
            XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .erasurePending)
        }
        XCTAssertThrowsError(try lease.withConnection { _ in XCTFail("pending erase exposed cached evidence") }) {
            XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .erasurePending)
        }
        try ProtectedSQLiteStore.erasePersisted(databaseURL: store.databaseURL, identity: custody.identity, custody: custody)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.databaseURL.path))
        let replacement = try ProtectedSQLiteStore(databaseURL: store.databaseURL, identity: custody.identity, custody: custody)
        XCTAssertEqual(hardware.creates, 2)
        try replacement.withConnection { try ProtectedSQLiteStore.execute($0, "CREATE TABLE replacement(value INTEGER)") }
        XCTAssertThrowsError(try store.withConnection { _ in XCTFail("stale owner reopened new generation") })
    }

    func testReentrantExplicitCloseDrainsBorrowAndCannotAdmitAnotherPage() throws {
        let (store, _, _, _) = try fixture()
        let lease = try store.makeReadLease()
        let value: String? = try lease.withConnection { db in
            lease.close()
            return try ProtectedSQLiteStore.scalar(db, "SELECT value FROM evidence")
        }
        XCTAssertEqual(value, "synthetic-retained")
        XCTAssertThrowsError(try lease.withConnection { _ in XCTFail("closed lease reopened") }) {
            XCTAssertEqual($0 as? ProtectedReadLeaseError, .closed)
        }
        try store.erase()
    }
}

private final class ReviewLeaseRecords: StoreKeyRecordStorage, @unchecked Sendable {
    var bytes: Data?
    func load() throws -> Data? { bytes }
    func add(_ record: Data) throws -> Bool { guard bytes == nil else { return false }; bytes = record; return true }
    func remove() throws { bytes = nil }
}
private final class ReviewLeaseHardware: StoreHardwareAgreement, @unchecked Sendable {
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
