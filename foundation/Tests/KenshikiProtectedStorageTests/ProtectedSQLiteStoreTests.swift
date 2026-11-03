import Foundation
import SQLCipher
import XCTest
@_spi(StorageAdapter) @_spi(CustodyAdapter) @testable import KenshikiProtectedStorage

final class ProtectedSQLiteStoreTests: XCTestCase {
    private let key = Data(repeating: 0x4b, count: 32)
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw ProtectedSQLiteError.unavailable(result) }
    }
    private func scalar(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProtectedSQLiteError.unavailable(sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE { return nil }
            throw ProtectedSQLiteError.unavailable(step)
        }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }
    func testDatabaseAndRetainedWALNeverContainPlaintext() throws {
        let url = try directory().appendingPathComponent("evidence.sqlite3")
        let store = try ProtectedSQLiteStore(databaseURL: url, key: key)
        try store.withConnection { db in
            XCTAssertNotNil(try scalar(db, "PRAGMA cipher_version"))
            try execute(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('synthetic-identity-SECRET-734829');")
            for suffix in ["", "-wal"] {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: url.path + suffix))
                XCTAssertNil(bytes.range(of: Data("synthetic-identity-SECRET-734829".utf8)), suffix)
            }
        }
        XCTAssertFalse(try Data(contentsOf: url).starts(with: Data("SQLite format 3".utf8)))
    }
    func testWrongKeyFailsWithoutReplacingOriginalDatabase() throws {
        let url = try directory().appendingPathComponent("evidence.sqlite3")
        do {
            let store = try ProtectedSQLiteStore(databaseURL: url, key: key)
            try store.withConnection { try execute($0, "CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('retained');") }
        }
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try ProtectedSQLiteStore(databaseURL: url, key: Data(repeating: 0x31, count: 32)))
        XCTAssertEqual(original, try Data(contentsOf: url))
    }

    func testTamperedPageIsRefusedAndPreservedForRecovery() throws {
        let url = try directory().appendingPathComponent("evidence.sqlite3")
        do {
            let store = try ProtectedSQLiteStore(databaseURL: url, key: key)
            try store.withConnection { try execute($0, "CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('retained');") }
        }
        var corrupted = try Data(contentsOf: url)
        corrupted[2000] ^= 0x20
        try corrupted.write(to: url)
        XCTAssertThrowsError(try ProtectedSQLiteStore(databaseURL: url, key: key))
        XCTAssertEqual(corrupted, try Data(contentsOf: url))
    }

    func testAdaptersCannotDisableEncryptionMemoryTempsOrAttachPlaintext() throws {
        let url = try directory().appendingPathComponent("evidence.sqlite3")
        let store = try ProtectedSQLiteStore(databaseURL: url, key: key)
        try store.withConnection { db in
            for sql in ["PRAGMA rekey='';", "PRAGMA cipher_use_hmac=OFF;", "PRAGMA temp_store=FILE;",
                "PRAGMA journal_mode=DELETE;", "PRAGMA synchronous=OFF;", "PRAGMA secure_delete=OFF;",
                "ATTACH DATABASE ':memory:' AS escape;", "PRAGMA writable_schema=ON;",
                "DELETE FROM _kenshiki_protected_store;", "DROP TABLE _kenshiki_protected_store;"] {
                XCTAssertThrowsError(try execute(db, sql), sql)
            }
            XCTAssertEqual(try scalar(db, "PRAGMA temp_store"), "2")
            XCTAssertEqual(try scalar(db, "PRAGMA synchronous"), "2")
            XCTAssertEqual(try scalar(db, "PRAGMA secure_delete"), "1")
        }
    }

    func testLegacyMigrationReadsRetainedWALAndPreservesOriginal() throws {
        let source = try directory().appendingPathComponent("legacy.sqlite3")
        var plain: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(source.path, &plain, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let reader = try XCTUnwrap(plain)
        defer { sqlite3_close_v2(reader) }
        try execute(reader, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE evidence(value TEXT); PRAGMA user_version=17; INSERT INTO evidence VALUES('synthetic-retained-wal');")
        let before = try Data(contentsOf: source)
        let walBefore = try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal"))
        let destination = try directory().appendingPathComponent("protected.sqlite3")
        do {
            let store = try ProtectedSQLiteStore(databaseURL: destination, key: key, legacyPlaintextURL: source)
            XCTAssertEqual(store.retainedLegacySourceURL, source)
            try store.withConnection { db in
                XCTAssertEqual(try scalar(db, "SELECT value FROM evidence"), "synthetic-retained-wal")
                XCTAssertEqual(try scalar(db, "PRAGMA user_version"), "17")
            }
        }
        XCTAssertEqual(before, try Data(contentsOf: source))
        XCTAssertEqual(walBefore, try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal")))
        let reopened = try ProtectedSQLiteStore(databaseURL: destination, key: key, legacyPlaintextURL: source)
        XCTAssertEqual(try reopened.withConnection { try scalar($0, "SELECT count(*) FROM evidence") }, "1")
        XCTAssertFalse(try Data(contentsOf: destination).starts(with: Data("SQLite format 3".utf8)))
    }

    func testCorruptLegacyMigrationLeavesNoCanonicalDestination() throws {
        let source = try directory().appendingPathComponent("legacy.sqlite3")
        let original = Data("SQLite format 3\0bad synthetic content".utf8)
        try original.write(to: source)
        let destination = try directory().appendingPathComponent("protected.sqlite3")
        XCTAssertThrowsError(try ProtectedSQLiteStore(databaseURL: destination, key: key, legacyPlaintextURL: source))
        XCTAssertEqual(original, try Data(contentsOf: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPlaintextCanonicalDatabaseIsNeverSilentlyAccepted() throws {
        let url = try directory().appendingPathComponent("legacy.sqlite3")
        var plain: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &plain, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(plain)
        try execute(handle, "CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('retained');")
        sqlite3_close_v2(handle)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try ProtectedSQLiteStore(databaseURL: url, key: key))
        XCTAssertEqual(before, try Data(contentsOf: url))
    }

    func testTransactionFailureRollsBackAndOtherHandleCanReopen() throws {
        let url = try directory().appendingPathComponent("evidence.sqlite3")
        do {
            let store = try ProtectedSQLiteStore(databaseURL: url, key: key)
            try store.withConnection { db in
                try execute(db, "CREATE TABLE evidence(value TEXT UNIQUE); BEGIN IMMEDIATE; INSERT INTO evidence VALUES('first');")
                XCTAssertThrowsError(try execute(db, "INSERT INTO evidence VALUES('first');"))
                try execute(db, "ROLLBACK;")
                XCTAssertEqual(try scalar(db, "SELECT count(*) FROM evidence"), "0")
            }
        }
        let reopened = try ProtectedSQLiteStore(databaseURL: url, key: key)
        XCTAssertEqual(try reopened.withConnection { try scalar($0, "SELECT count(*) FROM evidence") }, "0")
    }

    func testDedicatedDirectoryCannotWeakenUnrelatedFiles() throws {
        let root = try directory()
        let unrelated = root.appendingPathComponent("other-sensitive-store")
        try Data("private".utf8).write(to: unrelated)
        XCTAssertThrowsError(try ProtectedSQLiteStore(databaseURL: root.appendingPathComponent("protected.sqlite3"), key: key))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("private".utf8))
    }

    func testRollbackJournalPagesAreEncryptedToo() throws {
        let url = try directory().appendingPathComponent("rollback.sqlite3")
        let db = try ProtectedSQLiteStore.open(url)
        defer { sqlite3_close_v2(db) }
        try key.withUnsafeBytes { try ProtectedSQLiteStore.applyKey($0, to: db) }
        try execute(db, "PRAGMA journal_mode=DELETE; CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('synthetic-rollback-SECRET-9321'); BEGIN IMMEDIATE; UPDATE evidence SET value='replacement';")
        let journal = try Data(contentsOf: URL(fileURLWithPath: url.path + "-journal"))
        XCTAssertGreaterThan(journal.count, 512)
        XCTAssertNil(journal.range(of: Data("synthetic-rollback-SECRET-9321".utf8)))
        try execute(db, "ROLLBACK;")
        XCTAssertEqual(try scalar(db, "SELECT value FROM evidence"), "synthetic-rollback-SECRET-9321")
    }

    func testSQLiteFullPreservesExistingDataAndAllowsLaterReopen() throws {
        let url = try directory().appendingPathComponent("full.sqlite3")
        let store = try ProtectedSQLiteStore(databaseURL: url, key: key)
        try store.withConnection { db in
            try execute(db, "CREATE TABLE evidence(value BLOB); INSERT INTO evidence VALUES('retained');")
            let pages = try XCTUnwrap(scalar(db, "PRAGMA page_count"))
            try execute(db, "PRAGMA max_page_count=\(pages);")
            XCTAssertThrowsError(try execute(db, "INSERT INTO evidence VALUES(zeroblob(1000000));"))
            XCTAssertEqual(try scalar(db, "SELECT count(*) FROM evidence"), "1")
        }
        let reopened = try ProtectedSQLiteStore(databaseURL: url, key: key)
        XCTAssertEqual(try reopened.withConnection { try scalar($0, "SELECT value FROM evidence") }, "retained")
    }

    func testAnOmittedStatementFinalizerIsRejectedAndCannotKeepTheKeyedConnectionAlive() throws {
        let url = try directory().appendingPathComponent("omitted-finalizer.sqlite3")
        let store = try ProtectedSQLiteStore(databaseURL: url, key: key)
        var statement: OpaquePointer?
        var rejected = false
        do {
            try store.withConnection { db in
                XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT 1", -1, &statement, nil), SQLITE_OK)
                XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
                // Deliberately omit finalize; foundation must clean it before releasing custody.
            }
        } catch {
            rejected = true
            XCTAssertEqual(error as? ProtectedSQLiteError, .unfinalizedStatements)
        }
        // The red baseline defers close while this statement remains alive. Only that branch may
        // finalize it here; the hardened branch already destroyed it and must never touch it again.
        if !rejected { sqlite3_finalize(statement) }
        XCTAssertTrue(rejected, "A retained statement must not silently keep keyed pages alive")
        try store.withConnection { db in XCTAssertEqual(try scalar(db, "SELECT 2"), "2") }
    }
}
