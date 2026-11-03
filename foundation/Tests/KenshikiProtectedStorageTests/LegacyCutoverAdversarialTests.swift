import Foundation
import SQLCipher
import XCTest
@_spi(StorageAdapter) @_spi(CustodyAdapter) @testable import KenshikiProtectedStorage

final class LegacyCutoverAdversarialTests: XCTestCase {
  private func root() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func closedWALSource(_ directory: URL) throws -> URL {
    let source = directory.appendingPathComponent("legacy.sqlite3")
    var pointer: OpaquePointer?
    XCTAssertEqual(sqlite3_open(source.path, &pointer), SQLITE_OK)
    let writer = try XCTUnwrap(pointer)
    XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE evidence(value TEXT); INSERT INTO evidence VALUES('retained');", nil, nil, nil), SQLITE_OK)
    XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + "-wal"))
    return source
  }

  func testClosedCleanWALSourceCanCompleteExclusiveStartupCutover() throws {
    let directory = try root()
    let source = try closedWALSource(directory)
    let encrypted = directory.appendingPathComponent("encrypted")
    let store = try ProtectedSQLiteStore(databaseURL: encrypted.appendingPathComponent("protected.sqlite3"),
      key: Data(repeating: 0x38, count: 32), legacyPlaintextURL: source)
    try store.finishLegacyCutover()
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  func testClosedSourceRecoversAfterCutoverIntentWithoutAConcurrentLegacyConnection() throws {
    struct Interrupted: Error {}
    let directory = try root()
    let source = try closedWALSource(directory)
    let destination = directory.appendingPathComponent("encrypted/protected.sqlite3")
    let key = Data(repeating: 0x38, count: 32)
    let store = try ProtectedSQLiteStore(databaseURL: destination, key: key, legacyPlaintextURL: source)
    XCTAssertThrowsError(try store.withFoundationConnection { db in
      try LegacySQLiteCutover.finish(db: db, destination: destination) { throw Interrupted() }
    }) { XCTAssertTrue($0 is Interrupted, "The failure must occur after the durable intent") }
    let reopened = try ProtectedSQLiteStore(databaseURL: destination, key: key)
    try reopened.finishLegacyCutover()
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  func testReopenedStoreErasesTheLegacySourceRecordedByItsMigration() throws {
    let directory = try root()
    let source = try closedWALSource(directory)
    let destination = directory.appendingPathComponent("encrypted/protected.sqlite3")
    let key = Data(repeating: 0x38, count: 32)
    _ = try ProtectedSQLiteStore(databaseURL: destination, key: key, legacyPlaintextURL: source)
    let reopened = try ProtectedSQLiteStore(databaseURL: destination, key: key)
    try reopened.erase()
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
      "Restart cannot forget retained plaintext from the persisted migration record")
  }
}
