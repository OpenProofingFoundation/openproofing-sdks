import Foundation
import XCTest
@testable import KenshikiOperationBinding

final class OperationJournalTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("operations.sqlite")
    }
    private func prepare(_ intent: JournalIntent, challenge: String = "challenge-1") throws -> SealedOperation {
        try SealedOperation(applicationID: "synthetic.app", installationID: "installation-1", audience: "pulse-api",
            operationKind: intent.kind, operationID: intent.id, targetID: intent.resourceID, generation: "key-generation",
            expectedRevision: 0, challengeID: challenge, issuedAt: 1_792_267_200, expiresAt: 1_792_267_500,
            contentDigest: SealedOperation.sha256(intent.content), purpose: "scheduled_share", recipient: nil)
    }
    func testRestartRetainsExactPreparationAndResult() throws {
        let url = location()
        let first = try journalFixture(url: url, namespace: "synthetic")
        let intent = try first.declare(resourceID: "schedule-1", kind: "schedule.register", content: Data("{}".utf8), revoking: false)
        let operation = try prepare(intent)
        let request = Data("exact signed request".utf8)
        try first.savePrepared(intent, operation: operation, bytes: request)
        try first.beginDispatch(intent)
        let reopened = try journalFixture(url: url, namespace: "synthetic")
        let recovered = try XCTUnwrap(reopened.current(resourceID: intent.resourceID))
        XCTAssertEqual(recovered.prepared, request)
        XCTAssertEqual(recovered.operation, operation)
        XCTAssertEqual(recovered.state, "dispatching")
        XCTAssertEqual(try reopened.declare(resourceID: intent.resourceID, kind: intent.kind, content: intent.content, revoking: false), intent)
        try reopened.accepted(intent, result: Data("accepted result".utf8))
        XCTAssertEqual(try first.current(resourceID: intent.resourceID)?.result, Data("accepted result".utf8))
    }
    func testIndependentHandleDeleteFencesSuspendedEnableAndLateResult() throws {
        let url = location()
        let old = try journalFixture(url: url, namespace: "synthetic")
        let newer = try journalFixture(url: url, namespace: "synthetic")
        let enable = try old.declare(resourceID: "schedule-1", kind: "schedule.register", content: Data("{}".utf8), revoking: false)
        try old.savePrepared(enable, operation: prepare(enable), bytes: Data("request".utf8))
        try old.beginDispatch(enable)
        let disable = try newer.declare(resourceID: "schedule-1", kind: "schedule.delete", content: Data("{}".utf8), revoking: true)
        XCTAssertThrowsError(try old.validate(enable))
        XCTAssertThrowsError(try old.beginDispatch(enable))
        XCTAssertThrowsError(try old.savePrepared(enable, operation: prepare(enable), bytes: Data("request".utf8)))
        try old.accepted(enable, result: Data("late result".utf8))
        XCTAssertEqual(try newer.current(resourceID: "schedule-1")?.intent, disable)
        XCTAssertNil(try newer.current(resourceID: "schedule-1")?.result)
    }
    func testPreparationCannotBeReplacedAndEnableCannotBeRebased() throws {
        let journal = try journalFixture(url: location(), namespace: "synthetic")
        let intent = try journal.declare(resourceID: "schedule-1", kind: "schedule.register", content: Data("{}".utf8), revoking: false)
        try journal.savePrepared(intent, operation: prepare(intent), bytes: Data("request".utf8))
        XCTAssertThrowsError(try journal.savePrepared(intent, operation: prepare(intent, challenge: "another"), bytes: Data("replacement".utf8)))
        XCTAssertThrowsError(try journal.renewRevocationAfterConflict(intent))
        let disable = try journal.declare(resourceID: "schedule-1", kind: "schedule.delete", content: Data("{}".utf8), revoking: true)
        let renewed = try journal.renewRevocationAfterConflict(disable)
        XCTAssertNotEqual(renewed.id, disable.id)
        XCTAssertEqual(renewed.content, disable.content)
        XCTAssertEqual(renewed.epoch, disable.epoch)
        XCTAssertThrowsError(try journal.validate(disable))
        try journal.validate(renewed)
    }
    func testEraseFencesOtherOpenHandlesAndPreservesNamespaceIsolation() throws {
        let url = location()
        let first = try journalFixture(url: url, namespace: "first")
        let suspended = try journalFixture(url: url, namespace: "first")
        let other = try journalFixture(url: url, namespace: "other")
        let old = try first.declare(resourceID: "schedule-1", kind: "schedule.register", content: Data("{\"private\":true}".utf8), revoking: false)
        let unaffected = try other.declare(resourceID: "schedule-1", kind: "schedule.register", content: Data("{}".utf8), revoking: false)
        try first.erase()
        XCTAssertThrowsError(try suspended.validate(old))
        XCTAssertNil(try suspended.current(resourceID: "schedule-1"))
        try other.validate(unaffected)
        let fresh = try suspended.declare(resourceID: old.resourceID, kind: old.kind, content: old.content, revoking: false)
        XCTAssertGreaterThan(fresh.generation, old.generation)
    }
    func testConcurrentIndependentWritersLeaveOnlyOneDispatchableIntent() async throws {
        let url = location()
        let initial = try journalFixture(url: url, namespace: "synthetic")
        _ = try initial.declare(resourceID: "schedule-1", kind: "schedule.register", content: Data("{}".utf8), revoking: false)
        let intents = try await withThrowingTaskGroup(of: JournalIntent.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let writer = try journalFixture(url: url, namespace: "synthetic")
                    return try writer.declare(resourceID: "schedule-1", kind: "schedule.delete",
                        content: Data("{\"attempt\":\(index)}".utf8), revoking: true)
                }
            }
            var values: [JournalIntent] = []
            for try await value in group { values.append(value) }
            return values
        }
        let current = try XCTUnwrap(initial.current(resourceID: "schedule-1"))
        XCTAssertEqual(intents.filter { $0 == current.intent }.count, 1)
        for intent in intents where intent != current.intent {
            XCTAssertThrowsError(try initial.validate(intent))
        }
        try initial.savePrepared(current.intent, operation: prepare(current.intent), bytes: Data("exact request".utf8))
        try initial.beginDispatch(current.intent)
    }

    func testAuthenticatedRevokedObservationIsDistinctAndCleanupSurvivesRestart() throws {
        let url = location()
        let journal = try journalFixture(url: url, namespace: "synthetic")
        let deletion = try journal.declare(resourceID: "schedule-1", kind: "schedule.delete", content: Data("{}".utf8), revoking: true)
        try journal.observedRevoked(deletion, authenticatedState: Data("{\"status\":\"deleted\"}".utf8))
        XCTAssertEqual(try journal.current(resourceID: deletion.resourceID)?.state, "observed_revoked")
        XCTAssertNil(try journal.current(resourceID: deletion.resourceID)?.prepared)
        let cleanup = try journal.declare(resourceID: "share-1", kind: "presence_share_stop", content: Data("{}".utf8), revoking: true)
        let reopened = try journalFixture(url: url, namespace: "synthetic")
        XCTAssertEqual(try reopened.pendingRevocations(kind: "presence_share_stop"), [cleanup])
        try reopened.completeRevocation(cleanup)
        XCTAssertTrue(try journal.pendingRevocations(kind: "presence_share_stop").isEmpty)
        XCTAssertThrowsError(try journal.validate(cleanup))
    }

    func testCorruptDatabaseFailsWithoutDeletingEvidence() throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let evidence = Data("unreadable existing store".utf8)
        try evidence.write(to: url)
        XCTAssertThrowsError(try journalFixture(url: url, namespace: "synthetic"))
        XCTAssertEqual(try Data(contentsOf: url), evidence)
    }
}
