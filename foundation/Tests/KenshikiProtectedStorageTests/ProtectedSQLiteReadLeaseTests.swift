import CryptoKit
import Foundation
import SQLCipher
import XCTest
@_spi(StorageAdapter) @_spi(StorageTestFixture) @testable import KenshikiProtectedStorage

final class ProtectedSQLiteReadLeaseTests: XCTestCase {
    private func identity(_ policy: StoreAccessPolicy = .backgroundAfterFirstUnlock) throws -> StoreKeyIdentity {
        try StoreKeyIdentity(applicationID: "test.read-lease", storeID: "observations", purpose: "sqlite",
            keychainAccessGroup: "TEST.read-lease", accessPolicy: policy)
    }
    private func fixture(_ policy: StoreAccessPolicy = .backgroundAfterFirstUnlock) throws -> ProtectedSQLiteStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try ProtectedSQLiteStore.testing(databaseURL: directory.appendingPathComponent("observations.sqlite"),
            identity: identity(policy), key: Data(repeating: 7, count: 32))
        try store.withConnection { db in
            XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE evidence(id INTEGER PRIMARY KEY); INSERT INTO evidence VALUES(1),(2);", nil, nil, nil), SQLITE_OK)
        }
        return store
    }
    private func count(_ db: OpaquePointer) throws -> String? { try ProtectedSQLiteStore.scalar(db, "SELECT count(*) FROM evidence") }

    func testExistingOnlyPortCannotCreateAfterErasureAndDoesNotNeedHardwareToRefuseMissingFile() throws {
        let store = try fixture()
        let identity = try identity()
        try store.erase()
        XCTAssertThrowsError(try ProtectedSQLiteStore(existingDatabaseURL: store.databaseURL, identity: identity)) {
            XCTAssertEqual($0 as? ProtectedSQLiteError, .unavailable(SQLITE_CANTOPEN))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.databaseURL.path))
        let missing = store.databaseURL.deletingLastPathComponent().appendingPathComponent("never-created/reader.sqlite")
        XCTAssertThrowsError(try ProtectedSQLiteStore(existingDatabaseURL: missing, identity: identity)) {
            XCTAssertEqual($0 as? ProtectedSQLiteError, .unavailable(SQLITE_CANTOPEN))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    func testExistingOnlyReaderQueuedDuringEraseNeverCreatesANewDatabaseGeneration() throws {
        let store = try fixture()
        let identity = try identity()
        let fence = try StoreLifecycleFence(databaseURL: store.databaseURL, identityBinding: identity.account)
        let started = DispatchSemaphore(value: 0)
        let completed = expectation(description: "queued existing reader refuses removed ciphertext")
        try fence.erase(epoch: fence.currentEpoch()) {
            DispatchQueue.global().async {
                defer { completed.fulfill() }
                started.signal()
                do {
                    _ = try ProtectedSQLiteStore.testing(databaseURL: store.databaseURL,
                        identity: identity, key: Data(repeating: 7, count: 32), requiresExisting: true)
                    XCTFail("existing-only reader recreated erased ciphertext")
                } catch {
                    XCTAssertEqual(error as? ProtectedSQLiteError, .unavailable(SQLITE_CANTOPEN))
                }
            }
            XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
            Thread.sleep(forTimeInterval: 0.15)
            for file in ProtectedSQLiteStore.family(store.databaseURL) where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        wait(for: [completed], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.databaseURL.path))
    }

    func testQueuedLeaseBorrowCannotDeadlockAWriterRejectingNestedBorrowOrClosingLease() throws {
        for closeInsideWriter in [false, true] {
            let store = try fixture()
            let lease = try store.makeReadLease(maximumDuration: 5)
            let queued = DispatchSemaphore(value: 0)
            let finished = expectation(description: "writer and queued reader finish")
            finished.expectedFulfillmentCount = 2
            DispatchQueue.global().async {
                defer { finished.fulfill() }
                do {
                    try store.withConnection { _ in
                        DispatchQueue.global().async {
                            defer { finished.fulfill() }
                            queued.signal()
                            do { try lease.withConnection { _ in } }
                            catch {
                                if !closeInsideWriter { XCTFail("queued reader failed: \(error)") }
                            }
                        }
                        XCTAssertEqual(queued.wait(timeout: .now() + 1), .success)
                        Thread.sleep(forTimeInterval: 0.15)
                        if closeInsideWriter {
                            lease.close()
                        } else {
                            XCTAssertThrowsError(try lease.withConnection { _ in }) {
                                XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .nestedAdmission)
                            }
                        }
                    }
                } catch { XCTFail("writer failed: \(error)") }
            }
            wait(for: [finished], timeout: 2)
            lease.close()
            try store.erase()
        }
    }

    func testSnapshotRemainsStableWhileAnotherAdmissionAppendsAndPrunes() throws {
        let store = try fixture()
        let lease = try store.makeReadLease()
        defer { lease.close() }
        XCTAssertEqual(try lease.withConnection(count), "2")
        try store.withConnection { try ProtectedSQLiteStore.execute($0, "DELETE FROM evidence; INSERT INTO evidence VALUES(3)") }
        XCTAssertEqual(try lease.withConnection(count), "2")
        XCTAssertEqual(try store.withConnection(count), "1")
    }

    func testReadLeaseCannotChangeTransactionOrWriteOrWeakenPolicy() throws {
        let store = try fixture()
        let lease = try store.makeReadLease()
        defer { lease.close() }
        try lease.withConnection { db in
            for sql in ["DELETE FROM evidence", "PRAGMA query_only=OFF", "COMMIT", "ATTACH ':memory:' AS other", "PRAGMA temp_store=FILE"] {
                XCTAssertNotEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
            }
            XCTAssertEqual(try count(db), "2")
        }
    }

    func testIdentityProfileAndUnboundedDurationsCannotAcquireALease() throws {
        let foreground = try fixture(.identityWhenUnlocked)
        XCTAssertThrowsError(try foreground.makeReadLease()) { XCTAssertEqual($0 as? ProtectedReadLeaseError, .unsupportedPolicy) }
        let background = try fixture()
        for duration in [0, -1, 121, .infinity, .nan] {
            XCTAssertThrowsError(try background.makeReadLease(maximumDuration: duration)) { XCTAssertEqual($0 as? ProtectedReadLeaseError, .invalidDuration) }
        }
    }

    func testIndependentEraserPublishesPendingThenReaderRefusesAndRetryCompletes() throws {
        let store = try fixture()
        let other = try ProtectedSQLiteStore.testing(databaseURL: store.databaseURL, identity: identity(), key: Data(repeating: 7, count: 32))
        let lease = try store.makeReadLease()
        XCTAssertThrowsError(try other.erase()) { XCTAssertEqual($0 as? ProtectedSQLiteError, .unavailable(SQLITE_BUSY)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.databaseURL.path))
        XCTAssertThrowsError(try lease.withConnection(count)) { XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .erasurePending) }
        try other.erase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.databaseURL.path))
        XCTAssertThrowsError(try store.withConnection(count)) { XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .staleHandle) }
    }

    func testAPageCannotPublishAResultAfterItsContinuousDeadline() throws {
        let store = try fixture()
        let lease = try store.makeReadLease(maximumDuration: 0.02)
        XCTAssertThrowsError(try lease.withConnection { _ in
            Thread.sleep(forTimeInterval: 0.04)
            return "late cached evidence"
        }) { XCTAssertEqual($0 as? ProtectedReadLeaseError, .expired) }
        try store.erase()
    }

    func testIdleDeadlineReleasesLeaseWithoutNeedingAnotherPage() throws {
        let store = try fixture()
        let lease = try store.makeReadLease(maximumDuration: 0.02)
        let retired = expectation(description: "idle lease retired")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { retired.fulfill() }
        wait(for: [retired], timeout: 1)
        try store.erase() // A live lease lock would force BUSY here.
        XCTAssertThrowsError(try lease.withConnection(count)) { XCTAssertEqual($0 as? ProtectedReadLeaseError, .expired) }
    }

    func testOmittedFinalizerClosesLeaseAndNestedBorrowFailsFast() throws {
        let store = try fixture()
        let lease = try store.makeReadLease()
        try lease.withConnection { _ in
            XCTAssertThrowsError(try lease.withConnection(count)) { XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .nestedAdmission) }
        }
        XCTAssertThrowsError(try lease.withConnection { db in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT * FROM evidence", -1, &statement, nil), SQLITE_OK)
        }) { XCTAssertEqual($0 as? ProtectedSQLiteError, .unfinalizedStatements) }
        try store.erase()
    }

    func testReplacingCustodyWithoutAnEpochCannotReadOldCachedPages() throws {
        let records = LeaseKeyRecords()
        let hardware = LeaseHardware()
        let identity = try identity()
        let custody = HardwareBoundStoreKeyCustody(identity: identity, storage: records, hardware: hardware)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try ProtectedSQLiteStore(databaseURL: directory.appendingPathComponent("observations.sqlite"), identity: identity, custody: custody)
        try store.withConnection { try ProtectedSQLiteStore.execute($0, "CREATE TABLE evidence(id INTEGER)") }
        let lease = try store.makeReadLease()
        let replacementRecords = LeaseKeyRecords()
        let replacement = HardwareBoundStoreKeyCustody(identity: identity, storage: replacementRecords, hardware: hardware)
        try replacement.withDatabaseKey(existingCiphertext: false) { _ in }
        records.bytes = replacementRecords.bytes
        XCTAssertThrowsError(try lease.withConnection(count)) { XCTAssertEqual($0 as? ProtectedSQLiteError, .invalidKey) }
        try store.erase()
    }

    func testEveryPageRechecksCustodyBeforeUsingCachedPages() throws {
        let records = LeaseKeyRecords()
        let hardware = LeaseHardware()
        let identity = try identity()
        let custody = HardwareBoundStoreKeyCustody(identity: identity, storage: records, hardware: hardware)
        let fixture = try fixture()
        let directory = fixture.databaseURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try ProtectedSQLiteStore(databaseURL: directory.appendingPathComponent("observations.sqlite"), identity: identity, custody: custody)
        try store.withConnection { try ProtectedSQLiteStore.execute($0, "CREATE TABLE evidence(id INTEGER)") }
        let lease = try store.makeReadLease()
        XCTAssertEqual(try lease.withConnection(count), "0")
        hardware.refuse = true
        XCTAssertThrowsError(try lease.withConnection(count))
        hardware.refuse = false
        try store.erase() // Failed page released the lease; no stale cache remains.
    }
}

private final class LeaseKeyRecords: StoreKeyRecordStorage, @unchecked Sendable {
    var bytes: Data?
    func load() throws -> Data? { bytes }
    func add(_ record: Data) throws -> Bool { guard bytes == nil else { return false }; bytes = record; return true }
    func remove() throws { bytes = nil }
}
private final class LeaseHardware: StoreHardwareAgreement, @unchecked Sendable {
    var refuse = false
    func create() throws -> (opaqueRepresentation: Data, publicKey: Data) {
        let key = P256.KeyAgreement.PrivateKey()
        return (key.rawRepresentation, key.publicKey.x963Representation)
    }
    func agree(opaqueRepresentation: Data, publicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        if refuse { throw ProtectedStoreKeyError.hardwareUnavailable }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: opaqueRepresentation)
            .sharedSecretFromKeyAgreement(with: publicKey)
    }
}
