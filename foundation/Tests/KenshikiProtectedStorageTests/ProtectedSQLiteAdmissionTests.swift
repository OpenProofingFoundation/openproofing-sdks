import CryptoKit
import Foundation
import SQLCipher
import XCTest
@_spi(StorageAdapter) @_spi(CustodyAdapter) @testable import KenshikiProtectedStorage

final class ProtectedSQLiteAdmissionTests: XCTestCase {
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("evidence.sqlite3")
    }
    private func identity(_ policy: StoreAccessPolicy = .identityWhenUnlocked) throws -> StoreKeyIdentity {
        try StoreKeyIdentity(applicationID: "synthetic.app", storeID: "evidence", purpose: "database", keychainAccessGroup: "TEAM.test.app", accessPolicy: policy)
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw ProtectedSQLiteError.unavailable(status) }
    }
    func testEachBorrowRequiresCurrentHardwareCustodyAndMissingKeyCannotRekey() throws {
        let records = AdmissionKeyRecords()
        let hardware = AdmissionHardware()
        let namespace = try identity()
        let vault = HardwareBoundStoreKeyCustody(identity: namespace, storage: records, hardware: hardware)
        let url = try location()
        let store = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        try store.withConnection { try Self.execute($0, "CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('retained');") }
        let before = try Data(contentsOf: url)
        let savedKey = records.bytes
        records.bytes = nil
        XCTAssertThrowsError(try store.withConnection { _ in XCTFail("borrow without a key") }) {
            XCTAssertEqual($0 as? ProtectedStoreKeyError, .missingKey)
        }
        XCTAssertEqual(hardware.creates, 1)
        XCTAssertNil(records.bytes)
        XCTAssertEqual(before, try Data(contentsOf: url))
        records.bytes = savedKey
        try store.withConnection { try Self.execute($0, "SELECT * FROM evidence;") }
        XCTAssertEqual(hardware.agreements, 3)
    }
    func testLockPolicyIsReevaluatedOnExistingStoreRatherThanCachedPages() throws {
        let records = AdmissionKeyRecords()
        let hardware = AdmissionHardware()
        let namespace = try identity()
        let vault = HardwareBoundStoreKeyCustody(identity: namespace, storage: records, hardware: hardware)
        let url = try location()
        let store = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        try store.withConnection { try Self.execute($0, "CREATE TABLE evidence(value TEXT);") }
        records.failure = ProtectedStoreKeyError.keychainFailure(-25308)
        XCTAssertThrowsError(try store.withConnection { _ in XCTFail("borrow while protected key is unavailable") })
        records.failure = nil
        try store.withConnection { try Self.execute($0, "INSERT INTO evidence VALUES('after unlock');") }
    }
    func testEraseFencesAllHandlesAndRemovesFilesBeforeTheKey() throws {
        let records = AdmissionKeyRecords()
        let hardware = AdmissionHardware()
        let namespace = try identity()
        let vault = HardwareBoundStoreKeyCustody(identity: namespace, storage: records, hardware: hardware)
        let url = try location()
        let first = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        let second = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        try first.withConnection { try Self.execute($0, "CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('private');") }
        records.beforeRemove = {
            for suffix in ["", "-wal", "-shm", "-journal", ".encrypted-staging"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix))
            }
        }
        try first.erase()
        XCTAssertNil(records.bytes)
        XCTAssertThrowsError(try first.withConnection { _ in XCTFail("stale writer") })
        XCTAssertThrowsError(try second.withConnection { _ in XCTFail("other stale writer") })
        XCTAssertThrowsError(try second.erase())
        let replacement = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        try replacement.withConnection { try Self.execute($0, "CREATE TABLE replacement(value TEXT);") }
        XCTAssertEqual(hardware.creates, 2)
        XCTAssertThrowsError(try first.withConnection { _ in XCTFail("old generation writer") })
    }
    func testKeyDeletionFailureKeepsDurablePendingEraseUntilExplicitRetry() throws {
        let records = AdmissionKeyRecords()
        let hardware = AdmissionHardware()
        let namespace = try identity()
        let vault = HardwareBoundStoreKeyCustody(identity: namespace, storage: records, hardware: hardware)
        let url = try location()
        let store = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        records.removeFailure = ProtectedStoreKeyError.keychainFailure(-25308)
        XCTAssertThrowsError(try store.erase())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(records.bytes)
        XCTAssertThrowsError(try store.withConnection { _ in XCTFail("pending erase writer") })
        XCTAssertThrowsError(try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault))
        records.removeFailure = nil
        try store.erase()
        XCTAssertNil(records.bytes)
        XCTAssertThrowsError(try store.withConnection { _ in XCTFail("erased writer") })
    }
    func testStoreAndAccessPolicySubstitutionCannotEraseAnotherNamespace() throws {
        let records = AdmissionKeyRecords()
        let hardware = AdmissionHardware()
        let namespace = try identity()
        let url = try location()
        let vault = HardwareBoundStoreKeyCustody(identity: namespace, storage: records, hardware: hardware)
        let store = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        let other = try identity(.backgroundAfterFirstUnlock)
        let otherVault = HardwareBoundStoreKeyCustody(identity: other, storage: records, hardware: hardware)
        XCTAssertThrowsError(try ProtectedSQLiteStore(databaseURL: url, identity: other, custody: otherVault))
        XCTAssertNotNil(records.bytes)
        try store.withConnection { try Self.execute($0, "SELECT count(*) FROM sqlite_master;") }
    }
    func testExplicitEraseNeedsNeitherDatabaseDecryptionNorAnExistingDataKey() throws {
        let records = AdmissionKeyRecords()
        let hardware = AdmissionHardware()
        let namespace = try identity()
        let vault = HardwareBoundStoreKeyCustody(identity: namespace, storage: records, hardware: hardware)
        let url = try location()
        let store = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        try store.withConnection { try Self.execute($0, "CREATE TABLE evidence(value TEXT);") }
        records.bytes = nil
        try Data("damaged ciphertext".utf8).write(to: url)
        XCTAssertThrowsError(try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault))
        try ProtectedSQLiteStore.erasePersisted(databaseURL: url, identity: namespace, custody: vault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(hardware.creates, 1)
        XCTAssertThrowsError(try store.withConnection { _ in XCTFail("stale original writer") })
        let replacement = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        try replacement.withConnection { try Self.execute($0, "CREATE TABLE replacement(value TEXT);") }
        XCTAssertEqual(hardware.creates, 2)
    }

    func testNestedAdmissionsAndEraseFailFastForSameAndIndependentStoreHandles() throws {
        let records = AdmissionKeyRecords()
        let hardware = AdmissionHardware()
        let namespace = try identity()
        let vault = HardwareBoundStoreKeyCustody(identity: namespace, storage: records, hardware: hardware)
        let url = try location()
        let first = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        let second = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        try first.withConnection { _ in
            XCTAssertThrowsError(try first.withConnection { _ in XCTFail("nested same handle") }) {
                XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .nestedAdmission)
            }
            XCTAssertThrowsError(try second.withConnection { _ in XCTFail("nested independent handle") }) {
                XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .nestedAdmission)
            }
            XCTAssertThrowsError(try first.erase()) {
                XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .nestedAdmission)
            }
        }
        try second.withConnection { try Self.execute($0, "CREATE TABLE usable_after_refusal(value TEXT);") }
    }

    func testConcurrentOpenersSurviveTransientSidecarCreationAndRemoval() throws {
        let records = AdmissionKeyRecords()
        let hardware = AdmissionHardware()
        let namespace = try identity()
        let vault = HardwareBoundStoreKeyCustody(identity: namespace, storage: records, hardware: hardware)
        let url = try location()
        let finished = expectation(description: "concurrent protected writers")
        finished.expectedFulfillmentCount = 20
        let failures = AdmissionFailures()
        for index in 0..<20 {
            DispatchQueue.global().async {
                defer { finished.fulfill() }
                do {
                    let store = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
                    try store.withConnection { db in
                        try Self.execute(db, "CREATE TABLE IF NOT EXISTS evidence(id INTEGER PRIMARY KEY); INSERT INTO evidence VALUES(\(index));")
                    }
                } catch { failures.record(error) }
            }
        }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(failures.count, 0, failures.description)
        let store = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
        try store.withConnection { db in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM evidence", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 20)
        }
    }

    #if os(iOS)
    func testForegroundAndBackgroundDirectoryAndRecreatedWALProtection() throws {
        // Diagnose API support independently of the store: the simulator filesystem can
        // accept this attribute without exposing any Data Protection class on readback.
        let controlURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: controlURL) }
        XCTAssertTrue(FileManager.default.createFile(atPath: controlURL.path, contents: Data(),
            attributes: [.protectionKey: FileProtectionType.complete]))
        let control = try FileManager.default.attributesOfItem(atPath: controlURL.path)[.protectionKey]
        #if targetEnvironment(simulator)
        if control == nil {
            throw XCTSkip("Simulator also omits protectionKey for an independent FileManager Complete-protection control; actual classes require a physical iOS device.")
        }
        #endif
        XCTAssertEqual(control as? FileProtectionType, .complete)
        for policy in [StoreAccessPolicy.identityWhenUnlocked, .backgroundAfterFirstUnlock] {
            let records = AdmissionKeyRecords()
            let hardware = AdmissionHardware()
            let namespace = try identity(policy)
            let vault = HardwareBoundStoreKeyCustody(identity: namespace, storage: records, hardware: hardware)
            let url = try location()
            let store = try ProtectedSQLiteStore(databaseURL: url, identity: namespace, custody: vault)
            let expected = policy == .identityWhenUnlocked ? FileProtectionType.complete
                : FileProtectionType.completeUntilFirstUserAuthentication
            for _ in 0..<2 {
                try store.withConnection { db in
                    try Self.execute(db, "CREATE TABLE IF NOT EXISTS evidence(value TEXT); INSERT INTO evidence VALUES('synthetic');")
                    for file in [url.deletingLastPathComponent(), url, URL(fileURLWithPath: url.path + "-wal"),
                        URL(fileURLWithPath: url.path + "-shm"), URL(fileURLWithPath: url.path + ".lifecycle")] {
                        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, expected, "file=\(file.lastPathComponent), raw=\(String(describing: attributes[.protectionKey])), type=\(String(describing: attributes[.protectionKey].map { type(of: $0) }))")
                    }
                }
            }
        }
    }
    #endif

}

private final class AdmissionKeyRecords: StoreKeyRecordStorage, @unchecked Sendable {
    var bytes: Data?
    var failure: Error?
    var removeFailure: Error?
    var beforeRemove: (() -> Void)?
    func load() throws -> Data? { if let failure { throw failure }; return bytes }
    func add(_ record: Data) throws -> Bool { guard bytes == nil else { return false }; bytes = record; return true }
    func remove() throws { if let removeFailure { throw removeFailure }; beforeRemove?(); bytes = nil }
}

private final class AdmissionHardware: StoreHardwareAgreement, @unchecked Sendable {
    var creates = 0
    var agreements = 0
    private var keys: [Data: P256.KeyAgreement.PrivateKey] = [:]
    func create() throws -> (opaqueRepresentation: Data, publicKey: Data) {
        creates += 1
        let key = P256.KeyAgreement.PrivateKey()
        let opaque = Data(UUID().uuidString.utf8)
        keys[opaque] = key
        return (opaque, key.publicKey.x963Representation)
    }
    func agree(opaqueRepresentation: Data, publicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        agreements += 1
        guard let key = keys[opaqueRepresentation] else { throw ProtectedStoreKeyError.hardwareUnavailable }
        return try key.sharedSecretFromKeyAgreement(with: publicKey)
    }
}

private final class AdmissionFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; messages.append(String(describing: error)) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return messages.count }
    var description: String { lock.lock(); defer { lock.unlock() }; return messages.joined(separator: "; ") }
}
