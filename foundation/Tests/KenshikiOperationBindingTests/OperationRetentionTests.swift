import Foundation
import SQLCipher
@_spi(StorageAdapter) import KenshikiProtectedStorage
import XCTest

@_spi(ProtectiveRecovery) @testable import KenshikiOperationBinding

final class OperationRetentionTests: XCTestCase {
  private func location() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("retention.sqlite")
  }
  private func prepare(_ journal: OperationJournal, resource: String) throws -> JournalIntent {
    let content = Data("{\"public_token\":\"synthetic-sensitive-token\"}".utf8)
    let intent = try journal.declare(resourceID: resource, kind: "publication", content: content, revoking: false)
    let operation = try SealedOperation(applicationID: "test", installationID: "owner", audience: "service",
      operationKind: intent.kind, operationID: intent.id, targetID: resource, generation: "key",
      expectedRevision: 0, challengeID: "challenge", issuedAt: 1000, expiresAt: 1300,
      contentDigest: SealedOperation.sha256(content), purpose: "share", recipient: nil)
    try journal.savePrepared(intent, operation: operation, bytes: Data("frozen synthetic-sensitive-token".utf8))
    return intent
  }
  func testBusinessAssociationsSurviveAcceptedRowCompactionAndMaterialRetirement() throws {
    let url = try location()
    let journal = try journalFixture(url: url, namespace: "business", now: { 1000 })
    let bytes = Data("{\"body_sha256\":\"original-digest\"}".utf8)
    let upload = try journal.declare(resourceID: "upload-target", kind: "consented_photo_upload", content: bytes,
      revoking: false, approvalID: "parent")
    let operation = try SealedOperation(applicationID: "test", installationID: "owner", audience: "service",
      operationKind: upload.kind, operationID: upload.id, targetID: upload.resourceID, generation: "key",
      expectedRevision: 0, challengeID: "challenge", issuedAt: 1000, expiresAt: 1300,
      contentDigest: SealedOperation.sha256(bytes), purpose: "share", recipient: nil)
    try journal.savePrepared(upload, operation: operation, bytes: Data("frozen".utf8))
    try journal.accepted(upload, result: Data("old-result".utf8))
    _ = try journal.declare(resourceID: upload.resourceID, kind: "consented_photo_upload_retired",
      content: Data("{}".utf8), revoking: true)
    _ = try journal.declare(resourceID: "peer", kind: "peer", content: Data("{}".utf8), revoking: false)
    try journal.maintainRetention(now: 2593000)
    let reopened = try journalFixture(url: url, namespace: "business", now: { 2593001 })
    let associations = try reopened.operationAssociations(approvalID: "parent", kind: "consented_photo_upload")
    XCTAssertEqual(associations.count, 1)
    XCTAssertEqual(associations.first?.operationID, upload.id)
    XCTAssertEqual(associations.first?.targetID, upload.resourceID)
    XCTAssertEqual(associations.first?.contentDigest, SealedOperation.sha256(bytes))
    XCTAssertTrue(try reopened.operationAssociations(approvalID: "other", kind: "consented_photo_upload").isEmpty)
    XCTAssertTrue(try reopened.operationAssociations(approvalID: "parent", kind: "peer").isEmpty)
    try reopened.eraseAllNamespaces()
    XCTAssertTrue(try reopened.operationAssociations(approvalID: "parent", kind: "consented_photo_upload").isEmpty)
  }

  func testAcceptedRetirementScrubsAllRawCapabilityCopiesAndKeepsKnownOutcome() throws {
    let journal = try journalFixture(url: location(), namespace: "ordinary", now: { 1000 })
    let intent = try prepare(journal, resource: "target")
    try journal.accepted(intent, result: Data("https://test.invalid/s/synthetic-sensitive-token".utf8))
    let admitted = try XCTUnwrap(journal.current(resourceID: intent.resourceID))
    XCTAssertEqual(admitted.admittedAt, 1000)
    XCTAssertEqual(admitted.materialExpiresAt, 2593000)
    try journal.maintainRetention(now: 2593000)
    let retired = try XCTUnwrap(journal.current(resourceID: intent.resourceID))
    XCTAssertEqual(retired.retainedOutcome, .accepted)
    XCTAssertEqual(retired.contentDigest, SealedOperation.sha256(intent.content))
    XCTAssertEqual(retired.intent.id, intent.id)
    XCTAssertTrue(retired.intent.content.isEmpty)
    XCTAssertNil(retired.prepared)
    XCTAssertNil(retired.operation)
    XCTAssertNil(retired.result)
    XCTAssertThrowsError(try journal.savePrepared(intent,
      operation: XCTUnwrap(admitted.operation), bytes: Data("late synthetic-sensitive-token".utf8)))
    try journal.maintainRetention(now: 999) // Clock rollback cannot undo retirement.
    XCTAssertEqual(try journal.current(resourceID: intent.resourceID)?.retainedOutcome, .accepted)
    for suffix in ["", "-wal"] {
      let path = URL(fileURLWithPath: journal.url.path + suffix)
      if FileManager.default.fileExists(atPath: path.path) {
        let bytes = try Data(contentsOf: path)
        XCTAssertNil(bytes.range(of: Data("synthetic-sensitive-token".utf8)))
      }
    }
  }
  func testFreshExplicitApprovalIsDistinctFromRetiredContentRetry() throws {
    let journal = try journalFixture(url: location(), namespace: "approval", now: { 1000 })
    let content = Data("{\"public_token\":\"same-approved-content\"}".utf8)
    let original = try journal.declareGeneratedTarget(kind: "publication", content: content, recoveryData: nil,
      expectedGeneration: journal.generationToken(), approvalID: "first-owner-action")
    try journal.maintainRetention(now: 2593000)
    XCTAssertThrowsError(try journal.declareGeneratedTarget(kind: "publication", content: content, recoveryData: nil,
      expectedGeneration: journal.generationToken()))
    XCTAssertThrowsError(try journal.declareGeneratedTarget(kind: "publication", content: content, recoveryData: nil,
      expectedGeneration: journal.generationToken(), approvalID: "first-owner-action"))
    let fresh = try journal.declareGeneratedTarget(kind: "publication", content: content, recoveryData: nil,
      expectedGeneration: journal.generationToken(), approvalID: "second-owner-action")
    XCTAssertNotEqual(fresh.id, original.id)
    XCTAssertEqual(fresh.content, content)
    XCTAssertEqual(try journal.current(resourceID: original.resourceID)?.retainedOutcome, .uncertain)
    XCTAssertTrue(try XCTUnwrap(journal.current(resourceID: original.resourceID)).intent.content.isEmpty)
    // Different product subactions may use one parent approval without sharing content.
    _ = try journal.declare(resourceID: "historical-target", kind: "historical-child",
      content: Data("{\"different\":true}".utf8), revoking: false, approvalID: "second-owner-action")
  }

  func testRevokedFactSurvivesAndOnlyExplicitProtectiveSPIRebuildsTarget() throws {
    let journal = try journalFixture(url: location(), namespace: "protective", now: { 1000 })
    let content = try CanonicalJSON.data(withJSONObject: ["share_id": "target"])
    let original = try journal.declare(resourceID: "target", kind: "presence_share_stop", content: content, revoking: true)
    try journal.observedRevoked(original, authenticatedState: Data("exact authenticated revoked state".utf8))
    try journal.maintainRetention(now: 2593000)
    let retired = try XCTUnwrap(journal.current(resourceID: "target"))
    XCTAssertEqual(retired.retainedOutcome, .revoked)
    XCTAssertThrowsError(try journal.declare(resourceID: "target", kind: "presence_share_stop", content: content, revoking: true))
    XCTAssertThrowsError(try journal.reconstructProtective(retired: retired.intent, kind: "presence_share_stop",
      minimalContent: CanonicalJSON.data(withJSONObject: ["share_id": "foreign"]), expectedAdmissionEpoch: journal.admissionEpoch()))
    let rebuilt = try journal.reconstructProtective(retired: retired.intent, kind: "presence_share_stop",
      minimalContent: content, expectedAdmissionEpoch: journal.admissionEpoch())
    XCTAssertTrue(rebuilt.revoking)
    XCTAssertNotEqual(rebuilt.id, original.id)
    XCTAssertEqual(rebuilt.resourceID, original.resourceID)
    XCTAssertEqual(rebuilt.content, content)
    XCTAssertThrowsError(try journal.validate(retired.intent))
  }

  func testDelegatedCustodyIsNotRetiredByOrdinaryMaintenance() throws {
    let journal = try journalFixture(url: location(), namespace: "delegation", retentionPolicy: .delegated, now: { 1000 })
    let intent = try prepare(journal, resource: "target")
    try journal.maintainRetention(now: 9_000_000)
    let saved = try XCTUnwrap(journal.current(resourceID: intent.resourceID))
    XCTAssertNil(saved.materialExpiresAt)
    XCTAssertNil(saved.retainedOutcome)
    XCTAssertNotNil(saved.prepared)
    try journal.validate(intent)
  }
  func testLegacyBadProofRetiresImmediatelyWhileValidProofUsesOriginalServerExpiry() throws {
    let url = try location()
    do {
      let journal = try journalFixture(url: url, namespace: "legacy", now: { 1000 })
      _ = try prepare(journal, resource: "valid")
      _ = try prepare(journal, resource: "bad")
    }
    try journalStoreFixture(url: url).withConnection { opened in
      XCTAssertEqual(sqlite3_exec(opened, "UPDATE journal_operation SET operation=X'7B' WHERE resource='bad'; DROP TABLE journal_retention; PRAGMA user_version=6", nil, nil, nil), SQLITE_OK)
    }
    let migrated = try journalFixture(url: url, namespace: "legacy", now: { 2000 })
    XCTAssertEqual(try migrated.current(resourceID: "bad")?.retainedOutcome, .uncertain)
    XCTAssertEqual(try migrated.current(resourceID: "valid")?.materialExpiresAt, 2593300)
    XCTAssertNotNil(try migrated.current(resourceID: "valid")?.prepared)
    let restarted = try journalFixture(url: url, namespace: "legacy", now: { 3000 })
    XCTAssertEqual(try restarted.current(resourceID: "valid")?.materialExpiresAt, 2593300)
    XCTAssertEqual(try restarted.current(resourceID: "bad")?.retainedOutcome, .uncertain)
  }
}
