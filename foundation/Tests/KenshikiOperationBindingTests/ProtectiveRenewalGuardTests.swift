import Foundation
import XCTest

@testable import KenshikiOperationBinding

final class ProtectiveRenewalGuardTests: XCTestCase {
  func testActualWorkerRefusalGoldenBindsExactOperationAndContent() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let bytes = try Data(contentsOf: root.appendingPathComponent("contracts/protective-expiry-refusal-v1.vectors.json"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let operation = try JSONDecoder().decode(SealedOperation.self,
      from: CanonicalJSON.data(withJSONObject: XCTUnwrap(fixture["operation"])))
    let content = try CanonicalJSON.data(withJSONObject: XCTUnwrap(fixture["content"]))
    XCTAssertEqual(SealedOperation.sha256(content), operation.contentDigest)
    let refusal = try ExpiredUncommittedRefusal(authenticatedResponse:
      CanonicalJSON.data(withJSONObject: XCTUnwrap(fixture["refusal"])), for: operation)
    XCTAssertEqual(refusal.requestDigest, "f0ead9e7b338ea9a06386c41dcb6ac42a0b2bae40fffa6de5b02e97f8ce678b9")
    XCTAssertEqual(refusal.serverTime, 1792267501)
  }

  func testDefaultConflictRenewalRefusesClosedCustodyAndOldEpochAfterReopen() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      do { try FileManager.default.removeItem(at: directory) }
      catch { XCTFail("Unable to remove isolated journal: \(error)") }
    }
    let location = directory.appendingPathComponent("journal.sqlite")
    let journal = try journalFixture(url: location, namespace: "closed-renewal")
    let intent = try journal.declare(resourceID: "target", kind: "protective", content: Data("{}".utf8), revoking: true)
    let epoch = try journal.admissionEpoch()
    try journal.closeAllNamespaces()
    let reopened = try journalFixture(url: location, namespace: "closed-renewal")
    XCTAssertThrowsError(try reopened.renewRevocationAfterConflict(intent))
    XCTAssertEqual(try reopened.current(resourceID: intent.resourceID)?.intent, intent)
    try reopened.resumeAllNamespacesAfterExplicitAdmission()
    XCTAssertThrowsError(try journal.renewRevocationAfterConflict(intent, expectedAdmissionEpoch: epoch))
    XCTAssertEqual(try reopened.current(resourceID: intent.resourceID)?.intent, intent)
    // A freshly admitted caller can continue the unchanged protective intent.
    let renewed = try reopened.renewRevocationAfterConflict(intent, expectedAdmissionEpoch: reopened.admissionEpoch())
    XCTAssertNotEqual(renewed.id, intent.id)
    XCTAssertEqual(renewed.content, intent.content)
  }

  func testConflictCannotRenewAcceptedObservedOrAuthorizedRevocation() throws {
    for state in ["accepted", "observed", "authorized"] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Unable to remove isolated journal: \(error)") }
      }
      let journal = try journalFixture(url: directory.appendingPathComponent("journal.sqlite"), namespace: "guard")
      let intent = try journal.declare(resourceID: "target", kind: "protective", content: Data("{}".utf8), revoking: true, recoveryData: state == "authorized" ? Data("secret".utf8) : nil)
      let operation = try SealedOperation(applicationID: "test", installationID: "owner", audience: "service",
        operationKind: intent.kind, operationID: intent.id, targetID: intent.resourceID, generation: "key",
        expectedRevision: 0, challengeID: "challenge", issuedAt: 1000, expiresAt: 1300,
        contentDigest: SealedOperation.sha256(intent.content), purpose: "erase", recipient: nil)
      try journal.savePrepared(intent, operation: operation, bytes: Data("prepared".utf8))
      if state == "accepted" { try journal.accepted(intent, result: Data("{}".utf8)) }
      else if state == "observed" { try journal.observedRevoked(intent, authenticatedState: Data("{}".utf8)) }
      else { try journal.authorized(intent, acknowledgement: Data("{}".utf8)) }
      let original = try journal.current(resourceID: intent.resourceID)
      XCTAssertThrowsError(try journal.renewRevocationAfterConflict(intent, expectedAdmissionEpoch: journal.admissionEpoch()))
      XCTAssertEqual(try journal.current(resourceID: intent.resourceID)?.intent, original?.intent)
      XCTAssertEqual(try journal.current(resourceID: intent.resourceID)?.state, original?.state)
    }
  }
}
