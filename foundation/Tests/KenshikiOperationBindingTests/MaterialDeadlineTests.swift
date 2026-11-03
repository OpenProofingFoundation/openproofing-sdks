import Foundation
import XCTest
@testable import KenshikiOperationBinding

final class MaterialDeadlineTests: XCTestCase {
    func testShortDeadlineCannotBeExtendedAndSurvivesDiskReopenAndClockRollback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("Cleanup failed: \(error)") } }
        let url = directory.appendingPathComponent("journal.sqlite")
        let first = try journalFixture(url: url, namespace: "short-lived", now: { 1000 })
        let content = Data("{\"approved\":true}".utf8)
        let approval = try first.declare(resourceID: "target", kind: "evidence", content: content,
            revoking: false, materialExpiresAt: 1300)
        let retry = try journalFixture(url: url, namespace: "short-lived", now: { 1100 })
        let same = try retry.declare(resourceID: "target", kind: "evidence", content: content,
            revoking: false, materialExpiresAt: 9999)
        XCTAssertEqual(same, approval)
        XCTAssertEqual(try retry.current(resourceID: "target")?.materialExpiresAt, 1300)
        let expired = try journalFixture(url: url, namespace: "short-lived", now: { 1301 })
        XCTAssertEqual(try expired.current(resourceID: "target")?.retainedOutcome, .uncertain)
        XCTAssertEqual(try expired.current(resourceID: "target")?.intent.content, Data())
        XCTAssertThrowsError(try first.validateAdmitted(approval))
        let rollback = try journalFixture(url: url, namespace: "short-lived", now: { 1000 })
        XCTAssertThrowsError(try rollback.declare(resourceID: "target", kind: "evidence", content: content,
            revoking: false, materialExpiresAt: 9999))
        XCTAssertEqual(try rollback.current(resourceID: "target")?.retainedOutcome, .uncertain)
    }
}
