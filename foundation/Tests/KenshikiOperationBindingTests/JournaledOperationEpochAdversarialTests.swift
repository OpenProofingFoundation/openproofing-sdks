import Foundation
import XCTest

@testable import KenshikiOperationBinding

final class JournaledOperationEpochAdversarialTests: XCTestCase {
  func testHeldDispatchCannotPersistAcceptedResultAcrossAnotherHandleCloseAndReopen() async throws {
    try await boundary(.dispatch)
  }
  func testHeldRecoveryInPerformCannotPersistAcceptedResultAcrossAnotherHandleCloseAndReopen()
    async throws {
    try await boundary(.performRecovery)
  }
  func testHeldReadOnlyRecoveryCannotPersistAcceptedResultAcrossAnotherHandleCloseAndReopen()
    async throws {
    try await boundary(.readOnlyRecovery)
  }

  private enum Boundary { case dispatch, performRecovery, readOnlyRecovery }
  private func boundary(_ mode: Boundary) async throws {
    let fixture = try fixture()
    let (url, original, approval, operation, prepared, remote) = (
      fixture.url, fixture.original, fixture.approval, fixture.operation, fixture.prepared, fixture.remote)
    if mode != .dispatch { try original.beginDispatch(approval) }
    let controller = JournaledOperationController(journal: original)
    let gate = EpochResponseGate()
    let ports = JournaledOperationController.Ports(
      prepare: { _ in
        XCTFail("Frozen intent must not prepare again")
        throw EpochProbe.unexpected
      },
      recover: { _ in .completed(await gate.wait()) }, dispatch: { _ in await gate.wait() },
      validateRecord: { record in
        guard record.operation == operation, record.prepared == prepared else {
          throw EpochProbe.unexpected
        }
      },
      validateResult: { _, result, _ in guard result == remote else { throw EpochProbe.unexpected }
      })
    let flight = Task { () async throws -> Data? in
      if mode == .readOnlyRecovery { return try await controller.recover(approval, ports: ports) }
      return try await controller.perform(approval, ports: ports)
    }
    for _ in 0..<2000 {
      if await gate.entered { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let entered = await gate.entered
    XCTAssertTrue(entered)
    // This handle deliberately has no access to the original in-memory controller or task.
    let other = try journalFixture(url: url, namespace: "epoch-adversarial")
    try other.closeAllNamespaces()
    try other.resumeAllNamespacesAfterExplicitAdmission()
    await gate.release(remote)
    do {
      _ = try await flight.value
      XCTFail("Old epoch returned a current success")
    } catch { XCTAssertEqual(error as? OperationJournalError, .staleIntent) }
    let reopened = try journalFixture(url: url, namespace: "epoch-adversarial")
    let retained = try XCTUnwrap(reopened.current(resourceID: approval.resourceID))
    XCTAssertEqual(retained.intent, approval)
    XCTAssertEqual(retained.prepared, prepared)
    XCTAssertNil(retained.result, "Rejecting after saving a late result does not preserve custody")
    XCTAssertEqual(retained.state, "dispatching")
    try await freshRecovery(reopened, approval: approval, operation: operation, prepared: prepared, remote: remote)
  }
  private func freshRecovery(
    _ reopened: OperationJournal, approval: JournalIntent, operation: SealedOperation, prepared: Data, remote: Data
  ) async throws {
    let fresh = JournaledOperationController(journal: reopened)
    let recoveryPorts = JournaledOperationController.Ports(
      prepare: { _ in
        XCTFail("Fresh recovery must preserve the old exact packet")
        throw EpochProbe.unexpected
      },
      recover: { record in
        guard record.prepared == prepared else { throw EpochProbe.unexpected }
        return .completed(remote)
      },
      dispatch: { _ in
        XCTFail("Fresh read-only recovery must not write")
        throw EpochProbe.unexpected
      },
      validateRecord: { record in
        guard record.operation == operation else { throw EpochProbe.unexpected }
      },
      validateResult: { _, result, _ in guard result == remote else { throw EpochProbe.unexpected }
      })
    let result = try await fresh.recover(approval, ports: recoveryPorts)
    XCTAssertEqual(result, remote)
    XCTAssertEqual(try reopened.current(resourceID: approval.resourceID)?.prepared, prepared)
    XCTAssertEqual(try reopened.current(resourceID: approval.resourceID)?.result, remote)
  }
  private struct Fixture {
    let url: URL
    let original: OperationJournal
    let approval: JournalIntent
    let operation: SealedOperation
    let prepared: Data
    let remote: Data
  }
  private func fixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      do { try FileManager.default.removeItem(at: directory) } catch {
        XCTFail("Unexpected temporary journal cleanup failure: \(error)")
      }
    }
    let url = directory.appendingPathComponent("journal.sqlite")
    let original = try journalFixture(url: url, namespace: "epoch-adversarial")
    let approval = try original.declare(
      resourceID: "approved-resource", kind: "approved_write", content: Data("{}".utf8),
      revoking: false)
    let clock = Int64(Date().timeIntervalSince1970)
    let operation = try SealedOperation(
      applicationID: "app", installationID: "original-owner", audience: "service",
      operationKind: approval.kind,
      operationID: approval.id, targetID: approval.resourceID, generation: "original-key",
      expectedRevision: 0,
      challengeID: "approved-challenge", issuedAt: clock, expiresAt: clock + 300,
      contentDigest: SealedOperation.sha256(approval.content), purpose: "approved", recipient: nil)
    let prepared = Data("exact-approved-frozen-packet".utf8)
    let remote = Data("exact-remotely-committed-result".utf8)
    try original.savePrepared(approval, operation: operation, bytes: prepared)
    return Fixture(
      url: url, original: original, approval: approval, operation: operation, prepared: prepared, remote: remote)

  }
}
private enum EpochProbe: Error { case unexpected }
private actor EpochResponseGate {
  private(set) var entered = false
  private var continuation: CheckedContinuation<Data, Never>?
  func wait() async -> Data {
    entered = true
    return await withCheckedContinuation { continuation = $0 }
  }
  func release(_ data: Data) {
    continuation?.resume(returning: data)
    continuation = nil
  }
}
