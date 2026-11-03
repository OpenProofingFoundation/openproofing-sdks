import Foundation
import SQLCipher
import XCTest
@_spi(StorageAdapter) @_spi(CustodyAdapter) @testable import KenshikiProtectedStorage

final class LegacySQLiteCutoverTests: XCTestCase {
    private let key = Data(repeating: 0x2b, count: 32)
    private func location(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent(name)
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw ProtectedSQLiteError.unavailable(status) }
    }
    private func legacy() throws -> (URL, OpaquePointer) {
        let url = try location("legacy.sqlite3")
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        try execute(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('initial');")
        return (url, db)
    }
    func testExplicitCutoverRemovesRetainedPlaintextAndWALOnlyAfterVerifiedExport() throws {
        let (source, writer) = try legacy()
        defer { sqlite3_close_v2(writer) }
        let destination = try location("protected.sqlite3")
        let store = try ProtectedSQLiteStore(databaseURL: destination, key: key, legacyPlaintextURL: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path + "-wal"))
        try store.finishLegacyCutover()
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + suffix))
        }
        try store.withConnection { try execute($0, "SELECT value FROM evidence WHERE value='initial';") }
        try store.finishLegacyCutover()
        let reopened = try ProtectedSQLiteStore(databaseURL: destination, key: key)
        try reopened.finishLegacyCutover()
    }
    func testChangedLegacyInputRefusesCutoverAndPreservesBothStores() throws {
        let (source, writer) = try legacy()
        defer { sqlite3_close_v2(writer) }
        let destination = try location("protected.sqlite3")
        let store = try ProtectedSQLiteStore(databaseURL: destination, key: key, legacyPlaintextURL: source)
        try execute(writer, "INSERT INTO evidence VALUES('newer');")
        let wal = try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal"))
        XCTAssertThrowsError(try store.finishLegacyCutover())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(wal, try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }
    func testActiveLegacyWriterIsNeverDeleted() throws {
        let (source, writer) = try legacy()
        defer { sqlite3_close_v2(writer) }
        let destination = try location("protected.sqlite3")
        let store = try ProtectedSQLiteStore(databaseURL: destination, key: key, legacyPlaintextURL: source)
        try execute(writer, "BEGIN IMMEDIATE;")
        XCTAssertThrowsError(try store.finishLegacyCutover())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try execute(writer, "ROLLBACK;")
        try store.finishLegacyCutover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
    func testCrashAfterIntentRecoversPartialDeletionWithoutReexport() throws {
        struct Interrupted: Error {}
        let (source, writer) = try legacy()
        defer { sqlite3_close_v2(writer) }
        let destination = try location("protected.sqlite3")
        let store = try ProtectedSQLiteStore(databaseURL: destination, key: key, legacyPlaintextURL: source)
        XCTAssertThrowsError(try store.withFoundationConnection { db in
            try LegacySQLiteCutover.finish(db: db, destination: destination) { throw Interrupted() }
        })
        try FileManager.default.removeItem(at: source)
        let reopened = try ProtectedSQLiteStore(databaseURL: destination, key: key)
        try reopened.finishLegacyCutover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + "-shm"))
        try reopened.withConnection { try execute($0, "SELECT * FROM evidence;") }
    }
    func testChangedSourceDuringPendingCutoverRemainsIntact() throws {
        struct Interrupted: Error {}
        let (source, writer) = try legacy()
        defer { sqlite3_close_v2(writer) }
        let destination = try location("protected.sqlite3")
        let store = try ProtectedSQLiteStore(databaseURL: destination, key: key, legacyPlaintextURL: source)
        XCTAssertThrowsError(try store.withFoundationConnection { db in
            try LegacySQLiteCutover.finish(db: db, destination: destination) { throw Interrupted() }
        })
        try execute(writer, "INSERT INTO evidence VALUES('newer');")
        let original = try Data(contentsOf: source)
        let wal = try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal"))
        XCTAssertThrowsError(try store.finishLegacyCutover())
        XCTAssertEqual(original, try Data(contentsOf: source))
        XCTAssertEqual(wal, try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal")))
    }
    func testInterruptedEncryptedStagingSidecarsDoNotBlockMigrationRetry() throws {
        let (source, writer) = try legacy()
        defer { sqlite3_close_v2(writer) }
        let destination = try location("protected.sqlite3")
        _ = try StoreLifecycleFence(databaseURL: destination, identityBinding: "test-only", legacySourceURL: source)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try Data("interrupted stage".utf8).write(to: URL(fileURLWithPath: destination.path + ".encrypted-staging" + suffix))
        }
        let store = try ProtectedSQLiteStore(databaseURL: destination, key: key, legacyPlaintextURL: source)
        try store.finishLegacyCutover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
}
