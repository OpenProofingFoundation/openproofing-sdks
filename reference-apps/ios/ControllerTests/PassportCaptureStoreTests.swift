import CryptoKit
import Foundation
@_spi(StorageAdapter) @_spi(StorageTestFixture) import KenshikiProtectedStorage
import SQLCipher
@testable import PassportSDK
@testable import KenshikiReference
import XCTest

@MainActor final class PassportCaptureStoreTests: XCTestCase {
    func testPresenceIOFailureCannotMasqueradeAsMissingCapture() async {
        let repository = PassportCaptureStore(exists: { throw ProtectedStoreLifecycleError.ioFailure(13) },
            open: { _ in throw PassportCaptureStorageFailure.unavailable }, erase: {})
        await assertThrows { _ = try await repository.load() }
    }

    func testReadingAbsentCheckpointDoesNotCreateDatabase() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let result = try await fixture.repository().load()
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    func testEncryptedReopenPreservesExactEvidenceWithoutPlaintext() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let record = try CaptureStoreFixture.capture()
        let first = fixture.repository()
        try await first.save(record)
        let restored = try await fixture.repository().load()
        let loaded = try XCTUnwrap(restored)
        XCTAssertEqual(loaded.id, record.id)
        XCTAssertEqual(loaded.nfc.portrait, record.nfc.portrait)
        XCTAssertEqual(loaded.nfc.dg2, record.nfc.dg2)
        XCTAssertEqual(loaded.nfc.securityObject, record.nfc.securityObject)
        XCTAssertEqual(loaded.nfc.dataGroups, record.nfc.dataGroups)
        XCTAssertEqual(loaded.localTrustBundleSHA256, record.localTrustBundleSHA256)
        XCTAssertEqual(try loaded.encoded(), try record.encoded())
        for url in try FileManager.default.contentsOfDirectory(at: fixture.url.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: url)
            XCTAssertNil(bytes.range(of: Data("synthetic-passport-portrait-private".utf8)))
            XCTAssertNil(bytes.range(of: Data("SYNTHETIC-HOLDER".utf8)))
        }
    }

    func testWrongKeyAndUnavailableKeyNeverReplaceGoodEvidence() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let record = try CaptureStoreFixture.capture()
        try await fixture.repository().save(record)
        let wrongKey = fixture.repository(key: Data(repeating: 9, count: 32))
        await assertThrows { _ = try await wrongKey.load() }
        let unavailable = PassportCaptureStore(exists: { true }, open: { _ in
            throw ProtectedStoreKeyError.missingKey
        }, erase: {})
        await assertThrows { try await unavailable.save(try CaptureStoreFixture.capture()) }
        let loaded = try await fixture.repository().load()
        XCTAssertEqual(loaded?.id, record.id)
    }

    func testFutureSchemaAndChangedMigrationHistoryAreRefusedWithoutReset() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let record = try CaptureStoreFixture.capture()
        let repository = fixture.repository()
        try await repository.save(record)
        try fixture.handle().withConnection { db in try PassportCaptureSchema.execute(db, "PRAGMA user_version=99") }
        await assertThrows { _ = try await repository.load() }
        try fixture.handle().withConnection { db in
            XCTAssertEqual(try PassportCaptureSchema.integer(db, "PRAGMA user_version"), 99)
            XCTAssertEqual(try PassportCaptureSchema.string(db, "SELECT capture_id FROM passport_checkpoint"), record.id.uuidString)
            try PassportCaptureSchema.execute(db, "PRAGMA user_version=2")
            try PassportCaptureSchema.execute(db, "UPDATE passport_schema_migrations SET migration_sha256=printf('%064d', 0)")
        }
        await assertThrows { try await repository.save(try CaptureStoreFixture.capture()) }
        try fixture.handle().withConnection { db in
            XCTAssertEqual(try PassportCaptureSchema.string(db, "SELECT capture_id FROM passport_checkpoint"), record.id.uuidString)
        }
    }

    func testMigrationFailureAfterFirstDDLLeavesNoPartialSchema() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let handle = try fixture.handle(existing: false)
        try handle.withConnection { db in
            sqlite3_set_authorizer(db, { _, operation, name, _, _, _ in
                if operation == SQLITE_CREATE_TABLE, name.map({ String(cString: $0) }) == "passport_checkpoint" {
                    return SQLITE_DENY
                }
                return SQLITE_OK
            }, nil)
            XCTAssertThrowsError(try PassportCaptureSchema.prepare(db))
            sqlite3_set_authorizer(db, nil, nil)
            XCTAssertEqual(try PassportCaptureSchema.integer(db, "PRAGMA user_version"), 0)
            XCTAssertEqual(try PassportCaptureSchema.integer(db, "SELECT count(*) FROM sqlite_master WHERE name='passport_schema_migrations'"), 0)
        }
        let record = try CaptureStoreFixture.capture()
        try await fixture.repository().save(record)
        let loaded = try await fixture.repository().load()
        XCTAssertEqual(loaded?.id, record.id)
    }

    func testWriteFailurePreservesPreviousCompleteCheckpoint() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let original = try CaptureStoreFixture.capture()
        try await repository.save(original)
        try fixture.handle().withConnection { db in
            try PassportCaptureSchema.execute(db, "CREATE TRIGGER fail_replacement BEFORE UPDATE ON passport_checkpoint BEGIN SELECT RAISE(ABORT, 'synthetic write fault'); END")
        }
        await assertThrows { try await repository.save(try CaptureStoreFixture.capture()) }
        let loaded = try await repository.load()
        XCTAssertEqual(loaded?.id, original.id)
        XCTAssertEqual(loaded?.nfc.portrait, original.nfc.portrait)
        try fixture.handle().withConnection { db in
            XCTAssertEqual(try PassportCaptureSchema.integer(db, "SELECT count(*) FROM passport_checkpoint"), 1)
            try PassportCaptureSchema.execute(db, "DROP TRIGGER fail_replacement")
        }
        let replacement = try CaptureStoreFixture.capture()
        try await repository.save(replacement)
        let retried = try await repository.load()
        XCTAssertEqual(retried?.id, replacement.id)
    }

    func testChangedPayloadAndReboundMetadataCannotRestore() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let original = try CaptureStoreFixture.capture()
        try await repository.save(original)
        try fixture.handle().withConnection { db in
            try PassportCaptureSchema.execute(db, "UPDATE passport_checkpoint SET portrait_sha256=printf('%064d', 0)")
        }
        await assertThrows { _ = try await repository.load() }
        try await repository.save(original)
        try fixture.handle().withConnection { db in
            try PassportCaptureSchema.execute(db, "UPDATE passport_checkpoint SET payload=zeroblob(100)")
        }
        await assertThrows { _ = try await repository.load() }
        // Erasure must work even when the record cannot be decoded.
        try await repository.delete()
        let deleted = try await repository.load()
        XCTAssertNil(deleted)
    }

    func testMissingOrUnsupportedDigestCannotMakeMissingEvidenceCompareEqual() throws {
        let record = try CaptureStoreFixture.capture()
        for algorithm in [nil, "SHA-999"] as [String?] {
            let bytes = try mutated(record) { root in
                var nfc = root["nfc"] as! [String: Any]
                nfc.removeValue(forKey: "dg2Digest")
                nfc["dg2DigestAlgorithm"] = algorithm
                root["nfc"] = nfc
            }
            XCTAssertThrowsError(try SavedPassportCapture.decode(bytes))
        }
    }

    func testWellFormedArchiveCannotBypassInnerEvidenceAndLocalCheckBindings() throws {
        let record = try CaptureStoreFixture.capture()
        for field in ["portrait", "dg2", "securityObject", "countrySigningChain", "documentSignature", "dataGroupHashes"] {
            let bytes = try mutated(record) { root in
                var nfc = root["nfc"] as! [String: Any]
                if ["portrait", "dg2", "securityObject"].contains(field) {
                    nfc[field] = Data("substituted-evidence".utf8)
                } else {
                    nfc[field] = "failed"
                }
                root["nfc"] = nfc
            }
            XCTAssertThrowsError(try SavedPassportCapture.decode(bytes), field)
        }
    }

    func testUnownedVersionZeroDatabaseIsPreservedAndRefused() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        try fixture.handle(existing: false).withConnection { db in
            try PassportCaptureSchema.execute(db, "CREATE TABLE unrelated(value TEXT)")
            try PassportCaptureSchema.execute(db, "INSERT INTO unrelated VALUES('must-survive')")
        }
        await assertThrows { try await fixture.repository().save(try CaptureStoreFixture.capture()) }
        try fixture.handle().withConnection { db in
            XCTAssertEqual(try PassportCaptureSchema.integer(db, "PRAGMA user_version"), 0)
            XCTAssertEqual(try PassportCaptureSchema.string(db, "SELECT value FROM unrelated"), "must-survive")
            XCTAssertEqual(try PassportCaptureSchema.integer(db, "SELECT count(*) FROM sqlite_master WHERE name='passport_checkpoint'"), 0)
        }
    }

    func testIndependentConcurrentWritersCannotMixEvidenceAndBindingColumns() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let first = try CaptureStoreFixture.capture()
        let second = try CaptureStoreFixture.capture(marker: "other")
        try await fixture.repository().save(first)
        let left = fixture.repository()
        let right = fixture.repository()
        async let writeLeft: Void = left.save(first)
        async let writeRight: Void = right.save(second)
        _ = try await (writeLeft, writeRight)
        let restored = try await fixture.repository().load()
        let loaded = try XCTUnwrap(restored)
        XCTAssertTrue(loaded.id == first.id || loaded.id == second.id)
        try loaded.validate()
        XCTAssertEqual(loaded.nfc.portrait, loaded.id == first.id ? first.nfc.portrait : second.nfc.portrait)
    }

    func testEraseRetiresOldHandlesAndAllowsOnlyNewCaptureToRecreateStore() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        try await repository.save(try CaptureStoreFixture.capture())
        let oldHandle = try fixture.handle()
        try await repository.delete()
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path + suffix))
        }
        XCTAssertThrowsError(try oldHandle.withConnection { db in
            try PassportCaptureSchema.execute(db, "CREATE TABLE resurrected(value TEXT)")
        })
        let absent = try await repository.load()
        XCTAssertNil(absent)
        let fresh = try CaptureStoreFixture.capture()
        try await fixture.repository().save(fresh)
        let loaded = try await fixture.repository().load()
        XCTAssertEqual(loaded?.id, fresh.id)
    }

    func testOldRepositoryCannotAdoptNewGenerationForWriteOrErase() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let original = try CaptureStoreFixture.capture()
        let old = fixture.repository()
        try await old.save(original)
        let current = fixture.repository()
        _ = try await current.load()
        try await current.delete()
        let fresh = try CaptureStoreFixture.capture(marker: "new-generation")
        try await current.save(fresh)
        await assertThrows { try await old.save(original) }
        await assertThrows { try await old.delete() }
        let loaded = try await current.load()
        XCTAssertEqual(loaded?.id, fresh.id)
    }

    private func assertThrows(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected refusal", file: file, line: line) }
        catch { }
    }

    private func mutated(_ capture: SavedPassportCapture, change: (inout [String: Any]) -> Void) throws -> Data {
        var root = try XCTUnwrap(PropertyListSerialization.propertyList(from: capture.encoded(), format: nil) as? [String: Any])
        change(&root)
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }
}

struct CaptureStoreFixture: Sendable {
    let directory: URL
    let url: URL
    let identity: StoreKeyIdentity
    let key = Data(repeating: 7, count: 32)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        url = directory.appendingPathComponent("owned/passport.sqlite")
        identity = try StoreKeyIdentity(applicationID: "synthetic.reference", storeID: UUID().uuidString,
            purpose: "passport-test", keychainAccessGroup: "synthetic.reference", accessPolicy: .identityWhenUnlocked)
    }

    func handle(existing: Bool = true, key: Data? = nil) throws -> ProtectedSQLiteStore {
        try ProtectedSQLiteStore.testing(databaseURL: url, identity: identity, key: key ?? self.key, requiresExisting: existing)
    }

    func repository(key: Data? = nil) -> PassportCaptureStore {
        PassportCaptureStore(exists: { FileManager.default.fileExists(atPath: url.path) },
            open: { try handle(existing: $0, key: key) },
            erase: { try ProtectedSQLiteStore.eraseTesting(databaseURL: url, identity: identity) })
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    static func capture(marker: String = "default") throws -> SavedPassportCapture {
        try SavedPassportCapture(accepted(marker: marker), capturedAt: Date(timeIntervalSince1970: 1792600000),
            trustBundleSHA256: String(repeating: "a", count: 64))
    }

    static func accepted(marker: String = "default") -> AcceptedPassportPortrait {
        let portrait = Data(("synthetic-passport-portrait-private-" + marker).utf8)
        let dg2 = Data([0x75, 0x01]) + portrait
        let read = PassportReadObservation(documentNumber: "L898902C3", surname: "SYNTHETIC-HOLDER", givenNames: "TEST",
            nationality: "UTO", issuingState: "UTO", birthDateYYMMDD: "740812", expiryDateYYMMDD: "300101",
            sex: "F", personalNumber: nil, dateOfIssue: nil, issuingAuthority: nil, placeOfBirth: nil,
            basicAccessControl: .succeeded, pace: .notPerformed, activeAuthentication: .notPerformed,
            chipAuthentication: .notPerformed, countrySigningChain: .succeeded, documentSignature: .succeeded,
            dataGroupHashes: .succeeded, documentSigningCertificateDER: Data([1, 2]),
            activeAuthenticationChallenge: nil, activeAuthenticationSignature: nil, securityObject: Data([0x77, 1]),
            dataGroups: ["DG1": Data([0x61, 1])], declaredDataGroups: ["DG1", "DG2"], dg2: dg2,
            portrait: portrait, dg2Digest: SavedPassportCapture.digest(dg2), dg2DigestAlgorithm: "SHA-256",
            chipAuthenticationResponse: nil)
        return AcceptedPassportPortrait(attemptID: UUID(), read: read, printedMRZ: nil)
    }
}
