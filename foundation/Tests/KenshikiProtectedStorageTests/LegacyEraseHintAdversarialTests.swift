import Foundation
import XCTest
@_spi(StorageTestFixture) @testable import KenshikiProtectedStorage

/// Reproduces the host adapter sequence: a fresh store opens with no legacy main,
/// while its registered eraser later supplies the historical filename unconditionally.
final class LegacyEraseHintAdversarialTests: XCTestCase {
    func testAbsentLegacyHintCannotPreventExplicitErasureOfAFreshStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.appendingPathComponent("Protected/contacts/store.sqlite")
        let legacy = root.appendingPathComponent("contacts.sqlite")
        let identity = try StoreKeyIdentity(applicationID: "test.legacy-erase-hint", storeID: "contacts",
            purpose: "sqlite", keychainAccessGroup: "TEST.legacy-erase-hint", accessPolicy: .backgroundAfterFirstUnlock)
        _ = try ProtectedSQLiteStore.testing(databaseURL: canonical, identity: identity, key: Data(repeating: 1, count: 32))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        try ProtectedSQLiteStore.eraseTesting(databaseURL: canonical, identity: identity, legacyPlaintextURL: legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
    }
    func testAbsentHintOnFreshOpenNormalizesWithoutReadingOrCreatingALegacyFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = root.appendingPathComponent("protected/store.sqlite")
        let legacy = root.appendingPathComponent("legacy.sqlite")
        let identity = try fixtureIdentity()
        let store = try ProtectedSQLiteStore.testing(databaseURL: canonical, identity: identity,
            key: Data(repeating: 2, count: 32), legacyPlaintextURL: legacy)
        XCTAssertNil(store.retainedLegacySourceURL)
        try Data("damaged ciphertext, deliberately not decrypted during erasure".utf8).write(to: canonical)
        try ProtectedSQLiteStore.eraseTesting(databaseURL: canonical, identity: identity, legacyPlaintextURL: legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testUnexpectedRetainedLegacyFamilyCannotReplaceNilInventory() throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let canonical = root.appendingPathComponent("protected/store.sqlite")
            let legacy = root.appendingPathComponent("legacy.sqlite")
            let identity = try fixtureIdentity()
            _ = try ProtectedSQLiteStore.testing(databaseURL: canonical, identity: identity,
                key: Data(repeating: 2, count: 32))
            let unexpected = URL(fileURLWithPath: legacy.path + suffix)
            let retained = Data("retained legacy evidence".utf8)
            try retained.write(to: unexpected)
            XCTAssertThrowsError(try ProtectedSQLiteStore.eraseTesting(databaseURL: canonical,
                identity: identity, legacyPlaintextURL: legacy)) {
                XCTAssertEqual($0 as? ProtectedStoreLifecycleError, .invalidLifecycle)
            }
            XCTAssertEqual(try Data(contentsOf: unexpected), retained)
            XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))
        }
    }

    func testOrphanedLegacySidecarCannotProduceAFreshEncryptedStore() throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let canonical = root.appendingPathComponent("protected/store.sqlite")
            let legacy = root.appendingPathComponent("legacy.sqlite")
            let retainedURL = URL(fileURLWithPath: legacy.path + suffix)
            let retained = Data("unrecovered legacy sidecar".utf8)
            try retained.write(to: retainedURL)
            XCTAssertThrowsError(try ProtectedSQLiteStore.testing(databaseURL: canonical,
                identity: fixtureIdentity(), key: Data(repeating: 2, count: 32), legacyPlaintextURL: legacy))
            XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
            XCTAssertEqual(try Data(contentsOf: retainedURL), retained)
        }
    }

    private func fixtureIdentity() throws -> StoreKeyIdentity {
        try StoreKeyIdentity(applicationID: "test.legacy-hint", storeID: "observations", purpose: "sqlite",
            keychainAccessGroup: "TEST.legacy-hint", accessPolicy: .backgroundAfterFirstUnlock)
    }

}
