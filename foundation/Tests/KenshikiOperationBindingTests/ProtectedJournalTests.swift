import Foundation
import SQLCipher
import XCTest
@_spi(StorageAdapter) import KenshikiOperationBinding
@_spi(StorageAdapter) import KenshikiProtectedStorage

final class ProtectedJournalTests: XCTestCase {
    func testLiveJournalIsCiphertextAndKeylessReadFails() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try journalFixture(url: url, namespace: "owner")
        _ = try journal.declare(resourceID: "target", kind: "action",
            content: Data("sensitive-journal-fixture".utf8), revoking: false)
        let bytes = try Data(contentsOf: journal.url)
        XCTAssertFalse(bytes.starts(with: Data("SQLite format 3\0".utf8)))
        XCTAssertNil(bytes.range(of: Data("sensitive-journal-fixture".utf8)))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(journal.url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, "SELECT content FROM journal_operation", nil, nil, nil), SQLITE_NOTADB)
    }

    func testPhysicalErasureFencesPreviouslyOpenedJournal() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try journalFixture(url: url, namespace: "owner")
        let protectedStore = try journalStoreFixture(url: url)
        try protectedStore.erase()
        XCTAssertThrowsError(try journal.declare(resourceID: "late", kind: "action",
            content: Data("late-private-payload".utf8), revoking: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))
    }

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("journal.sqlite")
    }
}
