import CryptoKit
import Foundation
@testable import CaptureEvidenceCustody
import XCTest

@testable import DocumentCapture

@MainActor
final class CaptureJourneyProgressTests: XCTestCase {
  func testCommittedIntentIsDurableBeforeCallerMayStartCapture() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let store = try CaptureEvidenceStore(directory: directory, key: key)
    let date = Date(timeIntervalSince1970: 123)
    let progress = CaptureJourneyProgress(store: store, now: { date })
    let workflow = UUID()
    let first = try await progress.commit(
      .init(workflowID: workflow, profile: "fixture", stage: .front))
    let reopened = try CaptureEvidenceStore(directory: directory, key: key)
    let saved = try await reopened.journeyCheckpoint(workflowID: workflow)
    XCTAssertEqual(first, saved)
    XCTAssertEqual(first.revision, 1)
    XCTAssertEqual(first.updatedAt, date)
    let front = UUID()
    let second = try await progress.commit(
      .init(workflowID: workflow, profile: "fixture", stage: .back, frontID: front))
    XCTAssertEqual(second.revision, 2)
    XCTAssertEqual(second.frontID, front)
    let readback = try await reopened.journeyCheckpoint(workflowID: workflow)
    XCTAssertEqual(readback, second)
  }

  func testRetryDoesNotManufactureAnotherSnapshotOrTimestamp() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CaptureEvidenceStore(directory: directory, key: .init(size: .bits256))
    let clock = CountingClock()
    let progress = CaptureJourneyProgress(store: store, now: { clock.now() })
    let invalid = CaptureJourneyIntent(
      workflowID: UUID(), profile: "fixture", stage: .front, frontID: UUID())
    do {
      _ = try await progress.commit(invalid)
      XCTFail("Invalid transition accepted")
    } catch CaptureJourneyCheckpointError.invalidCheckpoint {}
    do {
      _ = try await progress.retry()
      XCTFail("Invalid transition accepted on retry")
    } catch CaptureJourneyCheckpointError.invalidCheckpoint {}
    XCTAssertEqual(clock.count, 1)
    XCTAssertEqual(progress.state, .retryRequired)
    do {
      _ = try await progress.commit(.init(workflowID: UUID(), profile: "fixture", stage: .front))
      XCTFail("Unresolved intent was replaced")
    } catch CaptureJourneyProgressError.retryRequired {}
    progress.invalidate()
    _ = try await progress.commit(.init(workflowID: UUID(), profile: "fixture", stage: .front))
    XCTAssertEqual(clock.count, 2)
  }

  func testRevokedCustodyCannotPublishPendingProgress() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CaptureEvidenceStore(directory: directory, key: .init(size: .bits256))
    let progress = CaptureJourneyProgress(store: store, now: { Date(timeIntervalSince1970: 1) })
    try await store.revokeAndRemoveAll()
    do {
      _ = try await progress.commit(.init(workflowID: UUID(), profile: "fixture", stage: .front))
      XCTFail("Erased custody accepted a delayed checkpoint")
    } catch CaptureEvidenceStoreError.custodyRevoked {}
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertFalse(files.contains { $0.hasSuffix(".journey") })
  }
}

private final class CountingClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func now() -> Date {
    lock.withLock {
      value += 1
      return Date(timeIntervalSince1970: Double(value))
    }
  }
}
