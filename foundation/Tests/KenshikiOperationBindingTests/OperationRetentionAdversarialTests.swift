import Foundation
import SQLCipher
@_spi(StorageAdapter) import KenshikiProtectedStorage
import XCTest
@testable import KenshikiOperationBinding

final class OperationRetentionAdversarialTests: XCTestCase {
  private func location() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("journal.sqlite")
  }
  private func sql(_ url: URL, _ statement: String) throws {
    try journalStoreFixture(url: url).withConnection { database in
      guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw TestFailure.database }
    }
  }
  private func prepared(_ journal: OperationJournal, resource: String, revoking: Bool = false) throws -> JournalIntent {
    let content = Data("{\"private\":\"retention-independent-sensitive-marker\"}".utf8)
    let intent = try journal.declare(resourceID: resource, kind: "opaque_action", content: content, revoking: revoking,
      recoveryData: Data("retention-independent-sensitive-marker".utf8))
    let operation = try SealedOperation(applicationID: "test", installationID: "owner", audience: "service",
      operationKind: intent.kind, operationID: intent.id, targetID: resource, generation: "key", expectedRevision: 0,
      challengeID: "challenge", issuedAt: 1000, expiresAt: 1300, contentDigest: SealedOperation.sha256(content), purpose: "share", recipient: nil)
    try journal.savePrepared(intent, operation: operation, bytes: Data("retention-independent-sensitive-marker".utf8))
    return intent
  }
  func testIndependentHandlesCannotRepopulateRetiredAcceptedOrUncertainMaterial() throws {
    let url = try location()
    let first = try journalFixture(url: url, namespace: "ordinary", now: { 1000 })
    let accepted = try prepared(first, resource: "accepted")
    let uncertain = try prepared(first, resource: "uncertain")
    try first.accepted(accepted, result: Data("retention-independent-sensitive-marker".utf8))
    try first.beginDispatch(uncertain)
    let frozen = try XCTUnwrap(first.current(resourceID: "uncertain"))
    let second = try journalFixture(url: url, namespace: "ordinary", now: { 999 })
    try second.maintainRetention(now: 2_593_000)
    XCTAssertThrowsError(try first.accepted(uncertain, result: Data("late-result".utf8)))
    XCTAssertThrowsError(try first.savePrepared(uncertain, operation: XCTUnwrap(frozen.operation), bytes: XCTUnwrap(frozen.prepared)))
    let restarted = try journalFixture(url: url, namespace: "ordinary", now: { 1 })
    for (target, outcome) in [("accepted", JournalRetainedOutcome.accepted), ("uncertain", .uncertain)] {
      let record = try XCTUnwrap(restarted.current(resourceID: target))
      XCTAssertEqual(record.retainedOutcome, outcome)
      XCTAssertTrue(record.intent.content.isEmpty)
      XCTAssertNil(record.recoveryData)
      XCTAssertNil(record.result)
      XCTAssertNil(record.prepared)
      XCTAssertNil(record.operation)
      XCTAssertEqual(record.materialExpiresAt, 2_593_000)
    }
  }
  func testBusinessAssociationCannotMoveResourceOrRegenerateRetiredPositive() throws {
    let journal = try journalFixture(url: location(), namespace: "ordinary", now: { 1000 })
    let content = Data("{\"value\":1}".utf8)
    let original = try journal.declare(resourceID: "target", kind: "create", content: content, revoking: false, approvalID: "business")
    let retried = try journal.declare(resourceID: "target", kind: "create", content: content, revoking: false,
      operationID: UUID().uuidString.lowercased(), approvalID: "business")
    XCTAssertEqual(original.id, retried.id)
    XCTAssertThrowsError(try journal.declare(resourceID: "different", kind: "create", content: content, revoking: false, approvalID: "business"))
    _ = try journal.declare(resourceID: "photo", kind: "upload", content: Data("{\"value\":2}".utf8), revoking: false, approvalID: "business")
    try journal.maintainRetention(now: 2_593_000)
    XCTAssertThrowsError(try journal.declareGeneratedTarget(kind: "create", content: content, recoveryData: nil,
      expectedGeneration: original.generation, approvalID: "business"))
    XCTAssertThrowsError(try journal.declareGeneratedTarget(kind: "create", content: content, recoveryData: nil,
      expectedGeneration: original.generation))
  }
  func testMixedLegacyNamespacePoliciesAreIndependentOfFirstOpenerOrder() throws {
    for firstDelegated in [false, true] {
      let url = try location()
      do {
        let ordinary = try journalFixture(url: url, namespace: "ordinary", now: { 1000 })
        let delegated = try journalFixture(url: url, namespace: "delegated", retentionPolicy: .delegated, now: { 1000 })
        _ = try prepared(ordinary, resource: "ordinary-target")
        _ = try prepared(delegated, resource: "delegated-target")
      }
      try sql(url, "DROP TABLE journal_retention; UPDATE journal_namespace SET retention_policy=NULL; PRAGMA user_version=6")
      let firstName = firstDelegated ? "delegated" : "ordinary"
      let secondName = firstDelegated ? "ordinary" : "delegated"
      let first = try journalFixture(url: url, namespace: firstName,
        retentionPolicy: firstDelegated ? .delegated : .ordinary, now: { 9_000_000 })
      XCTAssertEqual(try first.pendingRetentionNamespaces(), [secondName])
      let second = try journalFixture(url: url, namespace: secondName,
        retentionPolicy: firstDelegated ? .ordinary : .delegated, now: { 9_000_000 })
      XCTAssertTrue(try second.pendingRetentionNamespaces().isEmpty)
      let ordinary = try journalFixture(url: url, namespace: "ordinary", now: { 9_000_000 })
      let delegated = try journalFixture(url: url, namespace: "delegated", retentionPolicy: .delegated, now: { 9_000_000 })
      try ordinary.maintainRetention(now: 9_000_000)
      XCTAssertEqual(try ordinary.current(resourceID: "ordinary-target")?.retainedOutcome, .uncertain)
      XCTAssertNil(try delegated.current(resourceID: "delegated-target")?.materialExpiresAt)
      XCTAssertNotNil(try delegated.current(resourceID: "delegated-target")?.prepared)
    }
  }
  private enum TestFailure: Error { case database }
}
