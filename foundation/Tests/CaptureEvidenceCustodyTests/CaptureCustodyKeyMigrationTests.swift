import CryptoKit
import Foundation
import KenshikiProtectedStorage
import Security
import Testing
@testable import CaptureEvidenceCustody

@Suite struct CaptureCustodyKeyMigrationTests {
  @Test func freshCustodyWritesIntentBeforeCreationAndCompletesBeforeLegacyCleanup() throws {
    let fixture = try Fixture()
    try fixture.execute(retained: false)
    #expect(fixture.events == ["marker:pending", "prepare:create", "verify", "marker:complete", "delete"])
    #expect(try fixture.marker()?.phase == .complete)
  }

  @Test func legacyKeyIsImportedAndRetainedEvidenceVerifiedBeforeOldKeyRemoval() throws {
    let fixture = try Fixture()
    fixture.legacy = Data(repeating: 18, count: 32)
    try fixture.execute(retained: true)
    #expect(fixture.events == ["marker:pending", "import", "prepare:existing", "verify", "marker:complete", "delete"])
    #expect(fixture.legacy == nil)
    #expect(fixture.wrapped == Data(repeating: 18, count: 32))
  }

  @Test func interruptionAfterImportResumesSameKeyWithoutRecreatingEvidence() throws {
    let fixture = try Fixture()
    fixture.legacy = Data(repeating: 18, count: 32)
    fixture.failVerification = true
    #expect(throws: Fixture.Interrupted.self) { try fixture.execute(retained: true) }
    #expect(try fixture.marker()?.phase == .pending)
    #expect(fixture.legacy != nil)
    let imported = fixture.wrapped
    fixture.failVerification = false
    try fixture.execute(retained: true)
    #expect(fixture.wrapped == imported)
    #expect(fixture.events.filter { $0 == "prepare:create" }.isEmpty)
  }

  @Test func completedMigrationWithWrappedKeyLossNeverImportsLeftoverRawKey() throws {
    let fixture = try Fixture()
    fixture.legacy = Data(repeating: 18, count: 32)
    fixture.failDeletion = true
    #expect(throws: Fixture.Interrupted.self) { try fixture.execute(retained: true) }
    #expect(try fixture.marker()?.phase == .complete)
    #expect(fixture.legacy != nil)
    fixture.wrapped = nil
    fixture.failDeletion = false
    fixture.events = []
    fixture.legacyReads = 0
    #expect(throws: ProtectedStoreKeyError.missingKey) { try fixture.execute(retained: true) }
    #expect(fixture.legacyReads == 0)
    #expect(fixture.events == ["prepare:existing"])
    #expect(fixture.wrapped == nil)
  }

  @Test func corruptedOrWrongNamespaceMarkerNeverFallsBackToRawCustody() throws {
    let fixture = try Fixture()
    fixture.legacy = Data(repeating: 18, count: 32)
    fixture.saved = Data("invalid".utf8)
    #expect(throws: CaptureEvidenceStoreError.integrityFailure) { try fixture.execute(retained: true) }
    #expect(fixture.legacyReads == 0)
    let other = try StoreKeyIdentity(applicationID: "other.app", storeID: "store", purpose: "capture",
      keychainAccessGroup: "TEAM.fixture.app",
      accessPolicy: .identityWhenUnlocked)
    fixture.saved = try JSONEncoder().encode(CaptureCustodyKeyMigration.Marker(
      version: 1, identity: other, origin: .legacy, phase: .pending))
    #expect(throws: CaptureEvidenceStoreError.integrityFailure) { try fixture.execute(retained: true) }
    #expect(fixture.legacyReads == 0)
    #expect(fixture.wrapped == nil)
  }

  @Test func pendingLegacyMigrationCannotGenerateKeyAfterBothCopiesDisappear() throws {
    let fixture = try Fixture()
    fixture.saved = try JSONEncoder().encode(CaptureCustodyKeyMigration.Marker(
      version: 1, identity: fixture.identity, origin: .legacy, phase: .pending))
    #expect(throws: ProtectedStoreKeyError.missingKey) { try fixture.execute(retained: true) }
    #expect(fixture.events == ["prepare:existing"])
    #expect(try fixture.marker()?.phase == .pending)
  }

  @Test func verificationActuallyAuthenticatesBothMetadataAndOriginalPayload() async throws {
    let fixture = try Fixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = SymmetricKey(size: .bits256)
    let store = try CaptureEvidenceStore(directory: directory, key: key)
    let id = UUID()
    try await store.store(id: id, original: Data("original".utf8), manifest: Data("manifest".utf8))
    try CaptureEvidenceStore.verifyRetainedCiphertext(directory: directory, cipher: CaptureEvidenceCipher(key: key))
    let url = directory.appendingPathComponent(id.uuidString + ".evidence")
    var corrupted = try Data(contentsOf: url)
    corrupted[corrupted.count - 1] ^= 1
    try corrupted.write(to: url)
    #expect(throws: (any Error).self) {
      try CaptureEvidenceStore.verifyRetainedCiphertext(directory: directory, cipher: CaptureEvidenceCipher(key: key))
    }
    #expect(try Data(contentsOf: url) == corrupted)
    #expect(fixture.wrapped == nil)
  }

  @Test func unknownRetainedArtifactCannotAuthorizeReplacementKeyOrPrematureRetirement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("retained quarantined ciphertext".utf8).write(to: directory.appendingPathComponent("old.quarantine"))
    let configuration = try CaptureCustodyConfiguration(applicationID: "fixture.app", directory: directory,
      keychainService: UUID().uuidString, keychainAccount: "capture", accessGroup: "TEAM.capture-sdk.fixture")
    let removed = RemovalObservation()
    let runtime = try CaptureCustodyRuntime(configuration: configuration, loadKey: { creation in
      #expect(creation == .forbidden)
      throw CaptureEvidenceKey.Failure(status: errSecItemNotFound)
    }, removeKey: { removed.record() })
    #expect(runtime.keyMissingOnOpen)
    await #expect(throws: CaptureEvidenceStoreError.integrityFailure) { try await runtime.erase() }
    #expect(!removed.didRemove)
    #expect(try CaptureCustodyErasureState.pending(directory: directory, fileManager: .default))
  }

  @Test func explicitEraseRecoversCorruptIntentWithoutDecryptingAndOldOwnerCannotEraseReplacement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([7, 8]).write(to: CaptureCustodyErasureState.location(directory))
    let artifact = UUID()
    try Data("unreadable encrypted artifact".utf8)
      .write(to: directory.appendingPathComponent(artifact.uuidString + ".evidence"))
    let configuration = try CaptureCustodyConfiguration(applicationID: "fixture.app", directory: directory,
      keychainService: UUID().uuidString, keychainAccount: "capture", accessGroup: "TEAM.fixture.app")
    let removed = RemovalObservation()
    let erasing = try CaptureCustodyRuntime(erasing: configuration, removeKey: { removed.record() })
    #expect(erasing.erasurePendingOnOpen)
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await erasing.store.read(id: artifact)
    }
    try await erasing.erase()
    #expect(removed.didRemove)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    let key = SymmetricKey(size: .bits256)
    let replacement = try CaptureCustodyRuntime(configuration: configuration, loadKey: { _ in key }, removeKey: {})
    try await replacement.store.store(id: artifact, original: Data([1]), manifest: Data([2]))
    try await erasing.erase()
    #expect(try await replacement.store.read(id: artifact).original == Data([1]))
  }

  private final class RemovalObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var didRemove: Bool { lock.withLock { value } }
    func record() { lock.withLock { value = true } }
  }

  private final class Fixture {
    struct Interrupted: Error {}
    let identity: StoreKeyIdentity
    var saved: Data?
    var legacy: Data?
    var wrapped: Data?
    var events: [String] = []
    var legacyReads = 0
    var failVerification = false
    var failDeletion = false
    init() throws {
      identity = try StoreKeyIdentity(applicationID: "fixture.app", storeID: "store", purpose: "capture",
      keychainAccessGroup: "TEAM.fixture.app",
        accessPolicy: .identityWhenUnlocked)
    }
    func marker() throws -> CaptureCustodyKeyMigration.Marker? {
      try saved.map { try JSONDecoder().decode(CaptureCustodyKeyMigration.Marker.self, from: $0) }
    }
    func execute(retained: Bool) throws {
      try CaptureCustodyKeyMigration.execute(identity: identity, retainedCiphertext: retained,
        ports: .init(loadMarker: { self.saved }, saveMarker: { bytes in
          let marker = try JSONDecoder().decode(CaptureCustodyKeyMigration.Marker.self, from: bytes)
          self.events.append("marker:" + marker.phase.rawValue)
          self.saved = bytes
        }, loadLegacy: {
          self.legacyReads += 1
          return self.legacy
        }, removeLegacy: {
          self.events.append("delete")
          if self.failDeletion { throw Interrupted() }
          self.legacy = nil
        }, importLegacy: {
          self.events.append("import")
          if let existing = self.wrapped, existing != $0 { throw ProtectedStoreKeyError.keyAlreadyExists }
          self.wrapped = $0
        }, prepare: { retained in
          self.events.append(retained ? "prepare:existing" : "prepare:create")
          if self.wrapped == nil {
            guard !retained else { throw ProtectedStoreKeyError.missingKey }
            self.wrapped = Data(repeating: 11, count: 32)
          }
        }, verifyRetained: {
          self.events.append("verify")
          if self.failVerification { throw Interrupted() }
        }))
    }
  }
}
