import Foundation
import XCTest
@_spi(CustodyAdapter) @testable import KenshikiProtectedStorage

final class StoreLifecycleFenceTests: XCTestCase {
  private func location() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("evidence.sqlite3")
  }

  func testEraseInvalidatesOtherHandlesAndNeverAllowsOldHandleToEraseNewGeneration() throws {
    let url = try location()
    let first = try StoreLifecycleFence(databaseURL: url, identityBinding: "test")
    let second = try StoreLifecycleFence(databaseURL: url, identityBinding: "test")
    let epoch = try first.currentEpoch()
    var executed = false
    try second.withAdmission(epoch: epoch) { executed = true }
    XCTAssertTrue(executed)
    try first.erase(epoch: epoch) {}
    XCTAssertEqual(try second.currentEpoch(), epoch + 1)
    XCTAssertThrowsError(try second.withAdmission(epoch: epoch) { XCTFail("stale publication") }) {
      XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .staleHandle)
    }
    XCTAssertThrowsError(try second.erase(epoch: epoch) { XCTFail("stale erase") })
    try second.withAdmission(epoch: epoch + 1) {}
  }

  func testFailedEraseIsDurableAndExplicitlyRecoverableAcrossRestart() throws {
    struct Interrupted: Error {}
    let url = try location()
    let first = try StoreLifecycleFence(databaseURL: url, identityBinding: "test")
    let epoch = try first.currentEpoch()
    XCTAssertThrowsError(try first.erase(epoch: epoch) { throw Interrupted() })
    let reopened = try StoreLifecycleFence(databaseURL: url, identityBinding: "test")
    XCTAssertThrowsError(try reopened.currentEpoch()) {
      XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .erasurePending)
    }
    XCTAssertThrowsError(try reopened.withAdmission(epoch: epoch) { XCTFail("pending admission") })
    var cleaned = false
    try reopened.resumePendingErasure { cleaned = true }
    XCTAssertTrue(cleaned)
    XCTAssertEqual(try reopened.currentEpoch(), epoch + 1)
    XCTAssertThrowsError(try reopened.resumePendingErasure { XCTFail("invented erase") })
  }

  func testAnotherNamespaceCannotOpenOrResumePendingErasure() throws {
    struct Interrupted: Error {}
    let url = try location()
    let first = try StoreLifecycleFence(databaseURL: url, identityBinding: "app-one/store-one")
    let epoch = try first.currentEpoch()
    XCTAssertThrowsError(try first.erase(epoch: epoch) { throw Interrupted() })
    XCTAssertThrowsError(try StoreLifecycleFence(databaseURL: url, identityBinding: "app-two/store-one")) {
      XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .invalidLifecycle)
    }
    let reopened = try StoreLifecycleFence(databaseURL: url, identityBinding: "app-one/store-one")
    try reopened.resumePendingErasure {}
    XCTAssertEqual(try reopened.currentEpoch(), epoch + 1)
  }

  func testStartupRecoveryNeverInventsAnEraseOrAdvancesAnIdleGeneration() throws {
    let fence = try StoreLifecycleFence(databaseURL: location(), identityBinding: "test")
    let epoch = try fence.currentEpoch()
    XCTAssertFalse(try fence.recoverPendingErasure { XCTFail("No authorized deletion") })
    XCTAssertEqual(try fence.currentEpoch(), epoch)
  }

  func testStartupRecoveryFinishesInterruptedEraseOnceAndKeepsOldWritersRetired() throws {
    struct Interrupted: Error {}
    let url = try location()
    let first = try StoreLifecycleFence(databaseURL: url, identityBinding: "test")
    let oldEpoch = try first.currentEpoch()
    XCTAssertThrowsError(try first.erase(epoch: oldEpoch) { throw Interrupted() })
    let reopened = try StoreLifecycleFence(databaseURL: url, identityBinding: "test")
    var cleanupCount = 0
    XCTAssertTrue(try reopened.recoverPendingErasure { cleanupCount += 1 })
    XCTAssertFalse(try reopened.recoverPendingErasure { cleanupCount += 1 })
    XCTAssertEqual(cleanupCount, 1)
    XCTAssertThrowsError(try first.withAdmission(epoch: oldEpoch) { XCTFail("Deleted capture resurrected") })
    XCTAssertEqual(try reopened.currentEpoch(), oldEpoch + 1)
  }

  func testRepeatedEraseRetryKeepsOneEpochAndNeverAdmitsUntilCleanupSucceeds() throws {
    struct Interrupted: Error {}
    let fence = try StoreLifecycleFence(databaseURL: location(), identityBinding: "test")
    let epoch = try fence.currentEpoch()
    for _ in 0..<3 {
      XCTAssertThrowsError(try fence.erase(epoch: epoch) { throw Interrupted() })
      XCTAssertThrowsError(try fence.currentEpoch())
    }
    try fence.erase(epoch: epoch) {}
    XCTAssertEqual(try fence.currentEpoch(), epoch + 1)
  }

  func testMissingOrCorruptLifecycleWithRetainedCiphertextNeverCreatesNewEpoch() throws {
    let url = try location()
    try Data("retained ciphertext".utf8).write(to: url)
    XCTAssertThrowsError(try StoreLifecycleFence(databaseURL: url, identityBinding: "test")) {
      XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .invalidLifecycle)
    }
    let metadata = URL(fileURLWithPath: url.path + ".lifecycle")
    XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
    try Data("corrupt".utf8).write(to: metadata)
    XCTAssertThrowsError(try StoreLifecycleFence(databaseURL: url, identityBinding: "test"))
    XCTAssertEqual(try Data(contentsOf: metadata), Data("corrupt".utf8))
    XCTAssertEqual(try Data(contentsOf: url), Data("retained ciphertext".utf8))
  }

  /// iOS gives an app a new data container on every install. The store and its legacy source move
  /// together; the fence must still open there. A different legacy family at the new place must not.
  func testStoreSurvivesContainerRelocationWhenTheLegacyFamilyKeepsItsPlace() throws {
    let containerA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let containerB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: containerA); try? FileManager.default.removeItem(at: containerB) }
    try FileManager.default.createDirectory(at: containerA.appendingPathComponent("Protected"), withIntermediateDirectories: true)
    let legacyA = containerA.appendingPathComponent("workflow.sqlite")
    try Data("legacy plaintext".utf8).write(to: legacyA)
    let fence = try StoreLifecycleFence(databaseURL: containerA.appendingPathComponent("Protected/workflow.sqlite"),
      identityBinding: "test", legacySourceURL: legacyA)
    XCTAssertEqual(try fence.retainedLegacySource()?.standardizedFileURL, legacyA.standardizedFileURL)
    let record = try Data(contentsOf: containerA.appendingPathComponent("Protected/workflow.sqlite.lifecycle"))
    XCTAssertFalse(String(decoding: record, as: UTF8.self).contains(containerA.path), "no absolute path is recorded")

    try FileManager.default.moveItem(at: containerA, to: containerB)
    let legacyB = containerB.appendingPathComponent("workflow.sqlite")
    let moved = try StoreLifecycleFence(databaseURL: containerB.appendingPathComponent("Protected/workflow.sqlite"),
      identityBinding: "test", legacySourceURL: legacyB)
    XCTAssertEqual(try moved.retainedLegacySource()?.standardizedFileURL, legacyB.standardizedFileURL)
    XCTAssertEqual(try moved.currentEpoch(), 0)

    let other = containerB.appendingPathComponent("other.sqlite")
    try Data("another family".utf8).write(to: other)
    XCTAssertThrowsError(try StoreLifecycleFence(databaseURL: containerB.appendingPathComponent("Protected/workflow.sqlite"),
      identityBinding: "test", legacySourceURL: other)) {
      XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .invalidLifecycle)
    }
  }

  func testAdmissionAndEraseSerializeAcrossIndependentHandles() throws {
    let url = try location()
    let first = try StoreLifecycleFence(databaseURL: url, identityBinding: "test")
    let second = try StoreLifecycleFence(databaseURL: url, identityBinding: "test")
    let epoch = try first.currentEpoch()
    let admitted = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let eraseEntered = DispatchSemaphore(value: 0)
    let finished = expectation(description: "admission completes before erase")
    DispatchQueue.global().async {
      defer { finished.fulfill() }
      do {
        try first.withAdmission(epoch: epoch) {
          admitted.signal()
          XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
      } catch { XCTFail("unexpected admission failure") }
    }
    XCTAssertEqual(admitted.wait(timeout: .now() + 5), .success)
    let erased = expectation(description: "erase completes")
    DispatchQueue.global().async {
      defer { erased.fulfill() }
      do { try second.erase(epoch: epoch) { eraseEntered.signal() } }
      catch { XCTFail("unexpected erase failure") }
    }
    XCTAssertEqual(eraseEntered.wait(timeout: .now() + 0.05), .timedOut)
    release.signal()
    wait(for: [finished, erased], timeout: 5)
    XCTAssertEqual(eraseEntered.wait(timeout: .now() + 1), .success)
    XCTAssertThrowsError(try first.withAdmission(epoch: epoch) { XCTFail("late publish") })
  }
}
