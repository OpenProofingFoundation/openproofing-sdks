import Foundation
import XCTest

@testable import KenshikiOperationBinding

final class RevocationCachedResultAdversarialTests: XCTestCase {
  func testCachedWrongResultIsValidatedOnBothEntryPointsWithoutDroppingDelegation() async throws {
    for execute in [false, true] {
      let fixture = try fixture()
      try fixture.journal.beginDispatch(fixture.intent)
      try fixture.journal.accepted(fixture.intent, result: Data("unbound-cached-result".utf8))
      let before = try fixture.journal.current(resourceID: fixture.intent.resourceID)
      let controller = RevocationRecoveryController(journal: fixture.journal)
      do {
        if execute {
          _ = try await controller.executeAuthorized(fixture.intent, ports: ports())
        } else {
          _ = try await controller.authorize(fixture.intent, ports: ports())
        }
        XCTFail("Unvalidated cached success must not report completion")
      } catch {}
      let after = try fixture.journal.current(resourceID: fixture.intent.resourceID)
      XCTAssertEqual(after?.recoveryData, before?.recoveryData)
      XCTAssertEqual(after?.prepared, before?.prepared)
      XCTAssertEqual(after?.authorization, before?.authorization)
      XCTAssertEqual(after?.result, before?.result)
    }
  }
  func testCachedWrongAuthorizationCannotBecomeOrdinaryCredentialErasePermission() async throws {
    for execute in [false, true] {
      let fixture = try fixture()
      let controller = RevocationRecoveryController(journal: fixture.journal)
      do {
        if execute {
          _ = try await controller.executeAuthorized(fixture.intent, ports: ports())
        } else {
          _ = try await controller.authorize(fixture.intent, ports: ports())
        }
        XCTFail("Unbound authorization must not advance either phase")
      } catch {}
      let retained = try XCTUnwrap(fixture.journal.current(resourceID: fixture.intent.resourceID))
      XCTAssertNotNil(retained.recoveryData)
      XCTAssertEqual(retained.authorization, Data("unbound-cached-authorization".utf8))
      XCTAssertNil(retained.result)
    }
  }
  private struct Fixture {
    let journal: OperationJournal
    let intent: JournalIntent
  }
  private func fixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      do { try FileManager.default.removeItem(at: directory) } catch {
        XCTFail("Cleanup failed: \(error)")
      }
    }
    let journal = try journalFixture(
      url: directory.appendingPathComponent("delegation.sqlite"), namespace: "deletion",
      retentionPolicy: .delegated)
    let intent = try journal.declare(
      resourceID: "original-owner", kind: "installation_delete", content: Data("{}".utf8),
      revoking: true, recoveryData: Data("exact-deletion-only-capability".utf8))
    let now = Int64(Date().timeIntervalSince1970)
    let operation = try SealedOperation(
      applicationID: "app", installationID: "original-owner", audience: "service",
      operationKind: intent.kind,
      operationID: intent.id, targetID: intent.resourceID, generation: "key", expectedRevision: 0,
      challengeID: "challenge",
      issuedAt: now, expiresAt: now + 300, contentDigest: SealedOperation.sha256(intent.content),
      purpose: "installation_erasure", recipient: nil)
    try journal.savePrepared(intent, operation: operation, bytes: Data("exact-frozen-request".utf8))
    try journal.beginAuthorization(intent)
    try journal.authorized(intent, acknowledgement: Data("unbound-cached-authorization".utf8))
    return Fixture(journal: journal, intent: intent)
  }
  private func ports() -> RevocationRecoveryController.Ports {
    .init(
      prepare: { _ in
        XCTFail("No fresh preparation")
        throw CachedProbe.unexpected
      },
      authorize: { _ in
        XCTFail("No fresh authorization")
        throw CachedProbe.unexpected
      },
      recover: { _ in
        XCTFail("No network recovery")
        throw CachedProbe.unexpected
      },
      execute: { _ in
        XCTFail("No external effect")
        throw CachedProbe.unexpected
      },
      validateAuthorization: { _, _ in throw CachedProbe.unbound },
      validateCompletion: { _, _ in false })
  }
}
private enum CachedProbe: Error { case unexpected, unbound }
