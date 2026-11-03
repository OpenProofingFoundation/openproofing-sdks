import Foundation
import SQLite3
import XCTest
@testable import KenshikiOperationBinding

final class OperationJournalAdversarialTests: XCTestCase {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("operations.sqlite")
    }

    func testExplicitAdmissionSurvivesRestartAndOnlyCoversApprovedPendingIntents() throws {
        let url = try location()
        let journal = try journalFixture(url: url, namespace: "tenant")
        let first = try journal.declare(resourceID: "first", kind: "delete", content: Data("{}".utf8), revoking: true)
        _ = try journal.declare(resourceID: "second", kind: "delete", content: Data("{}".utf8), revoking: true)
        XCTAssertTrue(try journal.requiresExplicitAdmission())
        try journal.grantExplicitAdmission()
        let reopened = try journalFixture(url: url, namespace: "tenant")
        XCTAssertFalse(try reopened.requiresExplicitAdmission())
        try reopened.completeRevocation(first)
        XCTAssertFalse(try journal.requiresExplicitAdmission())
        _ = try journal.declare(resourceID: "second", kind: "delete", content: Data("{\"new\":true}".utf8), revoking: true)
        XCTAssertTrue(try reopened.requiresExplicitAdmission())
    }

    func testErasingPayloadsDoesNotReopenClosedRegistrationAdmission() throws {
        let url = try location()
        let journal = try journalFixture(url: url, namespace: "tenant")
        try journal.closeAdmission()
        _ = try journal.declare(resourceID: "installation", kind: "delete", content: Data("{}".utf8), revoking: true)
        try journal.erase()
        let reopened = try journalFixture(url: url, namespace: "tenant")
        XCTAssertNil(try reopened.current(resourceID: "installation"))
        XCTAssertTrue(try reopened.requiresExplicitAdmission())
        try reopened.grantExplicitAdmission()
        XCTAssertFalse(try journal.requiresExplicitAdmission())
    }

    func testUnavailableRedactionPreservesExistingGrantButInvalidatesOldCallbacks() throws {
        let journal = try journalFixture(url: location(), namespace: "tenant")
        let old = try journal.declare(resourceID: "installation", kind: "delete", content: Data("{}".utf8), revoking: true,
            recoveryData: Data("deletion-only secret".utf8))
        try journal.grantExplicitAdmission()
        try journal.markRevocationUnavailable(old, kind: "delete_unknown", redactedContent: Data("{\"unconfirmed\":true}".utf8))
        XCTAssertFalse(try journal.requiresExplicitAdmission())
        XCTAssertThrowsError(try journal.validate(old))
        let record = try XCTUnwrap(journal.current(resourceID: "installation"))
        XCTAssertNil(record.recoveryData)
        XCTAssertEqual(record.intent.id, old.id)
        _ = try journal.declare(resourceID: "new-installation", kind: "delete", content: Data("{}".utf8), revoking: true)
        XCTAssertTrue(try journal.requiresExplicitAdmission())
    }

    func testNulCannotAliasNamespaceResourceOrKind() throws {
        let url = try location()
        let journal = try journalFixture(url: url, namespace: "tenant")
        let intent = try journal.declare(resourceID: "schedule", kind: "enable", content: Data("{}".utf8), revoking: false)
        XCTAssertThrowsError(try journalFixture(url: url, namespace: "tenant\0other"))
        XCTAssertThrowsError(try journal.declare(resourceID: "schedule\0other", kind: "disable", content: Data("{}".utf8), revoking: true))
        XCTAssertThrowsError(try journal.declare(resourceID: "schedule", kind: "disable\0other", content: Data("{}".utf8), revoking: true))
        XCTAssertEqual(try journal.current(resourceID: "schedule")?.intent, intent)
        try journal.validate(intent)
    }

    func testFailedSchemaInitializationRollsBackVersionAndNewTables() throws {
        let url = try location()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE journal_namespace(namespace TEXT PRIMARY KEY); CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES('preserve');", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try journalFixture(url: url, namespace: "tenant"))
        func scalar(_ sql: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: bytes)
        }
        XCTAssertEqual(scalar("PRAGMA user_version"), "0")
        XCTAssertEqual(scalar("SELECT value FROM sentinel"), "preserve")
        XCTAssertEqual(scalar("SELECT count(*) FROM sqlite_master WHERE name IN ('journal_resource','journal_operation')"), "0")
    }

    func testEraseRejectsLateResultEvenAfterResourceIsRecreated() throws {
        let url = try location()
        let oldHandle = try journalFixture(url: url, namespace: "tenant")
        let otherHandle = try journalFixture(url: url, namespace: "tenant")
        let old = try oldHandle.declare(resourceID: "schedule", kind: "enable", content: Data("private".utf8), revoking: false)
        try otherHandle.erase()
        let current = try otherHandle.declare(resourceID: "schedule", kind: "disable", content: Data("{}".utf8), revoking: true)
        XCTAssertThrowsError(try oldHandle.accepted(old, result: Data("late response".utf8)))
        XCTAssertEqual(try oldHandle.current(resourceID: "schedule")?.intent, current)
        XCTAssertNil(try oldHandle.current(resourceID: "schedule")?.result)
    }

    func testObservedRevocationCannotSettleEnableOrSupersededDelete() throws {
        let journal = try journalFixture(url: location(), namespace: "tenant")
        let enable = try journal.declare(resourceID: "schedule", kind: "enable", content: Data("{}".utf8), revoking: false)
        XCTAssertThrowsError(try journal.observedRevoked(enable, authenticatedState: Data("deleted".utf8)))
        let oldDelete = try journal.declare(resourceID: "schedule", kind: "disable", content: Data("{}".utf8), revoking: true)
        let newEnable = try journal.declare(resourceID: "schedule", kind: "enable", content: Data("{\"new\":true}".utf8), revoking: false)
        XCTAssertThrowsError(try journal.observedRevoked(oldDelete, authenticatedState: Data("deleted".utf8)))
        XCTAssertEqual(try journal.current(resourceID: "schedule")?.intent, newEnable)
        XCTAssertNil(try journal.current(resourceID: "schedule")?.result)
        let currentDelete = try journal.declare(resourceID: "schedule", kind: "disable", content: Data("{}".utf8), revoking: true)
        try journal.observedRevoked(currentDelete, authenticatedState: Data("deleted revision 4".utf8))
        XCTAssertEqual(try journal.current(resourceID: "schedule")?.state, "observed_revoked")
        XCTAssertEqual(try journal.current(resourceID: "schedule")?.result, Data("deleted revision 4".utf8))
    }

    func testRepeatedOwnerChangesCompactOldIntentsWithoutLosingCurrentChoice() throws {
        let url = try location()
        let journal = try journalFixture(url: url, namespace: "tenant")
        let first = try journal.declare(resourceID: "schedule", kind: "enable", content: Data("{}".utf8), revoking: false)
        for index in 0..<1100 {
            _ = try journal.declare(resourceID: "schedule", kind: "enable", content: Data("{\"choice\":\(index)}".utf8), revoking: false)
        }
        let reopened = try journalFixture(url: url, namespace: "tenant")
        let current = try XCTUnwrap(reopened.current(resourceID: "schedule"))
        XCTAssertEqual(current.intent.content, Data("{\"choice\":1099}".utf8))
        XCTAssertThrowsError(try journal.validate(first))
        try journal.validate(current.intent)
        let deletion = try reopened.declare(resourceID: "schedule", kind: "disable", content: Data("{}".utf8), revoking: true)
        try journal.validate(deletion)
    }

    func testFullEnableCapacityStillAllowsProtectiveRevocation() throws {
        let journal = try journalFixture(url: location(), namespace: "tenant")
        for index in 0..<1000 {
            _ = try journal.declare(resourceID: "schedule-\(index)", kind: "enable", content: Data("{}".utf8), revoking: false)
        }
        XCTAssertThrowsError(try journal.declare(resourceID: "new-enable", kind: "enable", content: Data("{}".utf8), revoking: false))
        let deletion = try journal.declare(resourceID: "schedule-0", kind: "disable", content: Data("{}".utf8), revoking: true)
        try journal.validate(deletion)
        XCTAssertTrue(deletion.revoking)
    }
}
