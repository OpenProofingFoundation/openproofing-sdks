import Foundation
import XCTest

@testable import KenshikiOperationBinding

final class ProtectiveExpiryAdversarialTests: XCTestCase {
  func testRestartRenewsExactProtectiveContentOnceAndInvalidatesOriginalHandles() throws {
    let url = try location()
    let first = try journal(url)
    let (intent, operation) = try prepared(first, deadline: 1400)
    try first.beginDispatch(intent)
    let reopened = try journal(url)
    let epoch = try reopened.admissionEpoch()
    let replacement = try reopened.renewProtectiveAfterExpiredUncommitted(
      intent, refusal: refusal(operation), expectedAdmissionEpoch: epoch)
    XCTAssertNotEqual(replacement.id, intent.id)
    XCTAssertEqual(replacement.content, intent.content)
    XCTAssertEqual(replacement.resourceID, intent.resourceID)
    XCTAssertEqual(replacement.kind, intent.kind)
    XCTAssertEqual(replacement.generation, intent.generation)
    XCTAssertEqual(replacement.epoch, intent.epoch + 1)
    XCTAssertTrue(replacement.revoking)
    XCTAssertThrowsError(try first.beginDispatch(intent))
    XCTAssertThrowsError(
      try first.renewProtectiveAfterExpiredUncommitted(
        intent, refusal: refusal(operation), expectedAdmissionEpoch: epoch))
    let saved = try XCTUnwrap(first.current(resourceID: intent.resourceID))
    XCTAssertEqual(saved.intent, replacement)
    XCTAssertEqual(saved.recoveryExpiresAt, 1400)
    XCTAssertNil(saved.prepared)
    XCTAssertNil(saved.result)
    XCTAssertNil(saved.recoveryData)
  }

  func testConcurrentIndependentHandlesProduceExactlyOneProtectiveReplacement() async throws {
    let url = try location()
    let first = try journal(url)
    let (intent, operation) = try prepared(first)
    let evidence = try refusal(operation)
    let epoch = try first.admissionEpoch()
    let winners = await withTaskGroup(of: String?.self) { group in
      for _ in 0..<8 {
        group.addTask {
          do {
            return try journalFixture(url: url, namespace: "protective-adversarial")
              .renewProtectiveAfterExpiredUncommitted(
                intent, refusal: evidence, expectedAdmissionEpoch: epoch
              ).id
          } catch { return nil }
        }
      }
      var ids: [String] = []
      for await id in group { if let id { ids.append(id) } }
      return ids
    }
    XCTAssertEqual(winners.count, 1)
    XCTAssertEqual(try first.current(resourceID: intent.resourceID)?.intent.id, winners.first)
  }

  func testAcceptedResultDelegationAndPositiveIntentCannotBeRenewed() throws {
    for mode in ["accepted", "delegated", "positive"] {
      let journal = try journal(location())
      let (intent, operation) = try prepared(
        journal, revoking: mode != "positive",
        recovery: mode == "delegated" ? Data("narrow delegation".utf8) : nil)
      if mode == "accepted" {
        try journal.accepted(intent, result: Data("exact accepted result".utf8))
      }
      let original = try journal.current(resourceID: intent.resourceID)
      XCTAssertThrowsError(
        try journal.renewProtectiveAfterExpiredUncommitted(
          intent, refusal: refusal(operation), expectedAdmissionEpoch: journal.admissionEpoch()))
      assertUnchanged(try journal.current(resourceID: intent.resourceID), original)
    }
  }

  func testHeldRefusalCannotCrossCloseReopenSupersessionOrErasure() throws {
    for mode in ["admission", "superseded", "positive", "erased"] {
      let journal = try journal(location())
      let (intent, operation) = try prepared(journal)
      let epoch = try journal.admissionEpoch()
      let evidence = try refusal(operation)
      if mode == "admission" {
        try journal.closeAllNamespaces()
        try journal.resumeAllNamespacesAfterExplicitAdmission()
      } else if mode == "superseded" {
        _ = try journal.declare(
          resourceID: intent.resourceID, kind: "historical_moment_stop",
          content: Data("different protective content".utf8), revoking: true)
      } else if mode == "positive" {
        _ = try journal.declare(
          resourceID: intent.resourceID, kind: "historical_moment_create",
          content: Data("{}".utf8), revoking: false)
      } else {
        try journal.erase()
      }
      let current = try journal.current(resourceID: intent.resourceID)
      XCTAssertThrowsError(
        try journal.renewProtectiveAfterExpiredUncommitted(
          intent, refusal: evidence, expectedAdmissionEpoch: epoch))
      assertUnchanged(try journal.current(resourceID: intent.resourceID), current)
    }
  }

  func testCapacityFailurePreservesOriginalPreparedProtectiveCustody() throws {
    let journal = try journal(location())
    let (intent, operation) = try prepared(journal)
    for index in 1..<2000 {
      _ = try journal.declare(
        resourceID: "other-protective-\(index)", kind: "historical_moment_stop",
        content: Data("{}".utf8), revoking: true)
    }
    let original = try journal.current(resourceID: intent.resourceID)
    XCTAssertThrowsError(
      try journal.renewProtectiveAfterExpiredUncommitted(
        intent, refusal: refusal(operation), expectedAdmissionEpoch: journal.admissionEpoch()))
    assertUnchanged(try journal.current(resourceID: intent.resourceID), original)
    try journal.validate(intent)
  }

  func testRefusalBindsEveryIdentityAndStrictExpiryAndRejectsDuplicateOrUnknownFields() throws {
    let journal = try journal(location())
    let (_, operation) = try prepared(journal)
    let valid = try fields(operation)
    for key in [
      "audience", "application_id", "installation_id", "operation_kind", "operation_id",
      "target_id", "generation", "request_digest", "v", "status"
    ] {
      var changed = valid
      changed[key] = "other"
      XCTAssertThrowsError(
        try ExpiredUncommittedRefusal(
          authenticatedResponse: JSONSerialization.data(withJSONObject: changed), for: operation),
        key)
    }
    for value in [operation.expiresAt - 1, operation.expiresAt] {
      var changed = valid
      changed["server_time"] = value
      XCTAssertThrowsError(
        try ExpiredUncommittedRefusal(
          authenticatedResponse: JSONSerialization.data(withJSONObject: changed), for: operation))
    }
    var wrongExpiry = valid
    wrongExpiry["original_expires_at"] = operation.expiresAt - 1
    XCTAssertThrowsError(
      try ExpiredUncommittedRefusal(
        authenticatedResponse: JSONSerialization.data(withJSONObject: wrongExpiry), for: operation))
    var extra = valid
    extra["renew"] = true
    XCTAssertThrowsError(
      try ExpiredUncommittedRefusal(
        authenticatedResponse: JSONSerialization.data(withJSONObject: extra), for: operation))
    let bytes = try JSONSerialization.data(withJSONObject: valid)
    var duplicate = Data("{\"status\":\"expired_uncommitted\",".utf8)
    duplicate.append(bytes.dropFirst())
    XCTAssertThrowsError(
      try ExpiredUncommittedRefusal(authenticatedResponse: duplicate, for: operation))
    _ = try ExpiredUncommittedRefusal(authenticatedResponse: bytes, for: operation)
  }

  private func assertUnchanged(_ actual: JournalRecord?, _ expected: JournalRecord?) {
    XCTAssertEqual(actual?.intent, expected?.intent)
    XCTAssertEqual(actual?.operation, expected?.operation)
    XCTAssertEqual(actual?.prepared, expected?.prepared)
    XCTAssertEqual(actual?.result, expected?.result)
    XCTAssertEqual(actual?.recoveryData, expected?.recoveryData)
    XCTAssertEqual(actual?.authorization, expected?.authorization)
    XCTAssertEqual(actual?.state, expected?.state)
  }

  private func journal(_ url: URL) throws -> OperationJournal {
    try journalFixture(url: url, namespace: "protective-adversarial")
  }
  private func prepared(
    _ journal: OperationJournal, revoking: Bool = true, recovery: Data? = nil,
    deadline: Int64? = nil
  ) throws -> (JournalIntent, SealedOperation) {
    let intent = try journal.declare(
      resourceID: "pmv2s_target", kind: "historical_moment_stop",
      content: Data("{\"share_id\":\"pmv2s_target\"}".utf8), revoking: revoking,
      recoveryData: recovery, recoveryExpiresAt: deadline)
    let operation = try SealedOperation(
      applicationID: "synthetic.app", installationID: "synthetic-owner", audience: "pulse-api",
      operationKind: intent.kind, operationID: intent.id, targetID: intent.resourceID,
      generation: "synthetic-key-generation",
      expectedRevision: 1, challengeID: "synthetic-challenge", issuedAt: 1000, expiresAt: 1300,
      contentDigest: SealedOperation.sha256(intent.content), purpose: "historical_moment_share",
      recipient: nil)
    try journal.savePrepared(
      intent, operation: operation, bytes: Data("exact frozen signed request".utf8))
    return (intent, operation)
  }
  private func fields(_ operation: SealedOperation) throws -> [String: Any] {
    [
      "v": "kenshiki.protective-expiry-refusal.v1", "status": "expired_uncommitted",
      "audience": operation.audience,
      "application_id": operation.applicationID, "installation_id": operation.installationID,
      "operation_kind": operation.operationKind,
      "operation_id": operation.operationID, "target_id": operation.targetID,
      "generation": operation.generation,
      "request_digest": try operation.clientDataHash().map { String(format: "%02x", $0) }.joined(),
      "original_expires_at": operation.expiresAt, "server_time": operation.expiresAt + 1
    ]
  }
  private func refusal(_ operation: SealedOperation) throws -> ExpiredUncommittedRefusal {
    try .init(
      authenticatedResponse: JSONSerialization.data(withJSONObject: fields(operation)),
      for: operation)
  }
  private func location() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      do { try FileManager.default.removeItem(at: directory) } catch let error as CocoaError
        where error.code == .fileNoSuchFile
        && !FileManager.default.fileExists(atPath: directory.path) {
        // A prior erase may already have removed this synthetic test directory.
      }
    }
    return directory.appendingPathComponent("protective.sqlite")
  }
}
