import Foundation
import SQLCipher
import XCTest
@_spi(StorageAdapter) @_spi(StorageTestFixture) @testable import KenshikiProtectedStorage

final class ProtectedSQLiteAssociatedErasureTests: XCTestCase {
  private func identity(_ purpose: String = "sqlite") throws -> StoreKeyIdentity {
    try .init(applicationID: "synthetic.associated-erasure", storeID: "front", purpose: purpose,
      keychainAccessGroup: "TEAM.synthetic", accessPolicy: .identityWhenUnlocked)
  }
  private func location() -> URL {
    FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("capture.sqlite")
  }
  private func open(_ url: URL) throws -> ProtectedSQLiteStore {
    try .testing(databaseURL: url, identity: identity(), key: Data(repeating: 7, count: 32))
  }
  private func write(_ store: ProtectedSQLiteStore, value: Int = 1) throws {
    try store.withConnection { db in
      XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS evidence(value INTEGER); INSERT INTO evidence VALUES(\(value));",
        nil, nil, nil), SQLITE_OK)
    }
  }

  func testPreparedErasureBlocksOldAndNewOwnersUntilAssociatedCleanupFinishes() throws {
    let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try open(url); try write(store)
    let intent = try store.prepareErasure()
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertTrue(try ProtectedSQLiteStore.hasPendingErasure(databaseURL: url, identity: identity()))
    XCTAssertThrowsError(try store.withConnection { _ in () })
    XCTAssertThrowsError(try open(url)) {
      XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .erasurePending)
    }
    try intent.finish()
    XCTAssertFalse(try ProtectedSQLiteStore.hasPendingErasure(databaseURL: url, identity: identity()))
    try write(open(url), value: 2)
  }

  func testRestartResumesSamePendingIntentAndStaleFinishCannotEraseReplacement() throws {
    let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let old = try open(url); try write(old)
    let suspended = try old.prepareErasure()
    // Associated cleanup failed or the process exited: ordinary reopen must remain refused.
    XCTAssertThrowsError(try open(url))
    let resumed = try ProtectedSQLiteStore.prepareErasureTesting(databaseURL: url, identity: identity())
    try resumed.finish()
    let replacement = try open(url); try write(replacement, value: 3)
    XCTAssertThrowsError(try suspended.finish()) {
      XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .staleHandle)
    }
    try replacement.withConnection { db in
      XCTAssertEqual(try ProtectedSQLiteStore.scalar(db, "SELECT sum(value) FROM evidence"), "3")
    }
    XCTAssertThrowsError(try old.prepareErasure())
  }

  func testCompletedHandleFinishIsIdempotentAndPreservesNewGeneration() throws {
    let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try open(url); try write(store)
    let intent = try store.prepareErasure()
    try intent.finish()
    let replacement = try open(url); try write(replacement, value: 4)
    try intent.finish()
    try replacement.withConnection { db in
      XCTAssertEqual(try ProtectedSQLiteStore.scalar(db, "SELECT sum(value) FROM evidence"), "4")
    }
  }

  func testPendingDiscoveryDoesNotCreateVirginDirectoryOrKey() throws {
    let url = location()
    XCTAssertFalse(try ProtectedSQLiteStore.hasPendingErasure(databaseURL: url, identity: identity()))
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
  }

  func testMalformedOrForeignLifecycleIsNotAbsenceAndRemainsUnchanged() throws {
    let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try open(url); try write(store)
    _ = try store.prepareErasure()
    XCTAssertThrowsError(try ProtectedSQLiteStore.hasPendingErasure(databaseURL: url, identity: identity("foreign")))
    let lifecycle = URL(fileURLWithPath: url.path + ".lifecycle")
    let corrupt = Data("corrupt lifecycle fixture".utf8)
    try corrupt.write(to: lifecycle)
    XCTAssertThrowsError(try ProtectedSQLiteStore.hasPendingErasure(databaseURL: url, identity: identity()))
    XCTAssertEqual(try Data(contentsOf: lifecycle), corrupt)
  }

  func testBoundOwnerCanRetryPreparationForItsOwnPendingEpoch() throws {
    let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try open(url); try write(store)
    _ = try store.prepareErasure()
    let retried = try store.prepareErasure()
    try retried.finish()
    XCTAssertFalse(try ProtectedSQLiteStore.hasPendingErasure(databaseURL: url, identity: identity()))
  }
}
