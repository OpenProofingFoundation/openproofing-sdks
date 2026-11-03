import Foundation
import XCTest
@testable import KenshikiOperationBinding

final class RecoveryPayloadRetentionTests: XCTestCase {
    func testDeadlineDoesNotRefreshAndMaintenancePreservesUnknownRequestAcrossNamespaces() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("Fixture cleanup failed: \(error)") } }
        let url = directory.appendingPathComponent("journal.sqlite")
        let journal = try journalFixture(url: url, namespace: "photo"), control = try journalFixture(url: url, namespace: "control")
        let bytes = Data(repeating: 7, count: 600_000), content = Data("{}".utf8)
        let intent = try journal.declareGeneratedTarget(kind: "consented_photo_upload", content: content, recoveryData: bytes, expectedGeneration: 0, recoveryExpiresAt: 100)
        let operation = try SealedOperation(applicationID: "synthetic.app", installationID: "owner", audience: "pulse-api", operationKind: intent.kind, operationID: intent.id, targetID: intent.resourceID, generation: "key", expectedRevision: 0, challengeID: "challenge", issuedAt: 1, expiresAt: 100, contentDigest: SealedOperation.sha256(content), purpose: "share", recipient: nil)
        try journal.savePrepared(intent, operation: operation, bytes: Data("frozen request".utf8))
        try journal.beginDispatch(intent)
        XCTAssertEqual(try journal.declareGeneratedTarget(kind: intent.kind, content: content, recoveryData: bytes, expectedGeneration: 0, recoveryExpiresAt: 999), intent)
        XCTAssertEqual(try journal.current(resourceID: intent.resourceID)?.recoveryExpiresAt, 100)
        try control.releaseExpiredPayloads(now: 99)
        XCTAssertEqual(try journal.current(resourceID: intent.resourceID)?.recoveryData, bytes)
        try control.releaseExpiredPayloads(now: 100)
        let record = try XCTUnwrap(journal.current(resourceID: intent.resourceID))
        XCTAssertNil(record.recoveryData); XCTAssertNil(record.result)
        XCTAssertEqual(record.prepared, Data("frozen request".utf8)); XCTAssertEqual(record.state, "dispatching")
        XCTAssertEqual(try journal.declareGeneratedTarget(kind: intent.kind, content: content, recoveryData: bytes, expectedGeneration: 0, recoveryExpiresAt: 999), intent)
        XCTAssertNil(try journal.current(resourceID: intent.resourceID)?.recoveryData)
        XCTAssertEqual(try journal.current(resourceID: intent.resourceID)?.recoveryExpiresAt, 100)
        let delegation = try journal.declare(resourceID: "installation", kind: "installation_delete", content: content, revoking: true, recoveryData: Data("narrow capability".utf8))
        try control.releaseExpiredPayloads(now: 99_999)
        XCTAssertNotNil(try journal.current(resourceID: delegation.resourceID)?.recoveryData)
    }
}
