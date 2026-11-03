import CryptoKit
import Foundation
import Security
import Testing

@testable import CaptureEvidenceCustody

@Test func failedErasureFencesEveryReadAndRecoveryAcrossReopenUntilExplicitRetry() async throws {
  let fixture = try ErasureFixture()
  defer { fixture.cleanup() }
  let key = SymmetricKey(size: .bits256)
  let store = try CaptureEvidenceStore(directory: fixture.directory, key: key)
  let id = UUID()
  let workflowID = UUID()
  try await store.store(
    id: id, original: Data("synthetic-erasure-audit".utf8),
    manifest: Data(("{\"captureID\":\"" + id.uuidString + "\"}").utf8))
  try await store.saveCheckpoint(
    try checkpointRecord(workflowID: workflowID, revision: 1), expectedRevision: nil)
  try await store.beginLiveLookupScope(id: UUID(), seedCaptureIDs: [id])
  _ = try await store.matchingRecordIDs(captureID: id) // Warm index must not bypass revocation.
  try fixture.lockDirectory()
  await #expect(throws: (any Error).self) { try await store.revokeAndRemoveAll() }
  #expect(try CaptureCustodyErasureState.pending(directory: fixture.directory, fileManager: FileManager.default))
  #expect(FileManager.default.fileExists(
    atPath: fixture.directory.appendingPathComponent(id.uuidString + ".evidence").path))
  for closed in [store, try CaptureEvidenceStore(directory: fixture.directory, key: key)] {
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) { try await closed.read(id: id) }
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) { try await closed.metadata(id: id) }
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) { try await closed.list() }
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await closed.matchingRecordIDs(captureID: id)
    }
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await closed.originalRecordIDs()
    }
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await closed.lookupSnapshot(captureIDs: [id])
    }
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await closed.liveLookupSnapshot(captureIDs: [id])
    }
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await closed.checkpoint(workflowID: workflowID)
    }
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await closed.availableCapacityForRecording()
    }
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await closed.store(id: UUID(), original: Data([1]), manifest: Data([2]))
    }
  }
  // Exercise the supported runtime opening path while the directory still refuses writes.
  let pendingRuntime = try CaptureCustodyRuntime(
    configuration: fixture.configuration,
    loadKey: { _ in
      Issue.record("Erase-only runtime reopening tried to access a key")
      throw CaptureEvidenceKey.Failure(status: errSecDecode)
    }, removeKey: {})
  #expect(pendingRuntime.erasurePendingOnOpen)
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
    try await pendingRuntime.store.read(id: id)
  }
  try fixture.unlockDirectory()
  try await store.revokeAndRemoveAll()
  #expect(try CaptureCustodyErasureState.pending(directory: fixture.directory, fileManager: FileManager.default))
  #expect(try FileManager.default.contentsOfDirectory(
    at: fixture.directory, includingPropertiesForKeys: nil)
    .allSatisfy { ["lock", "erasure"].contains($0.pathExtension) })
  try await pendingRuntime.erase()
}

@Test func pendingRuntimeSkipsKeyLoadingAndRetainsIntentAndLeaseAfterKeyDeletionFailure() async throws {
  let fixture = try ErasureFixture()
  defer { fixture.cleanup() }
  let key = SymmetricKey(size: .bits256)
  let store = try CaptureEvidenceStore(directory: fixture.directory, key: key)
  try await store.store(id: UUID(), original: Data([1]), manifest: Data([2]))
  try await store.prepareErasure()
  let removals = ErasureKeyRemover()
  var runtime: CaptureCustodyRuntime? = try CaptureCustodyRuntime(
    configuration: fixture.configuration,
    loadKey: { _ in
      Issue.record("Pending erasure tried to load or create a durable key")
      throw CaptureEvidenceKey.Failure(status: errSecDecode)
    }, removeKey: { try removals.remove() })
  #expect(runtime?.erasurePendingOnOpen == true)
  await #expect(throws: ErasureInjectedFailure.self) { try await runtime?.erase() }
  #expect(try CaptureCustodyErasureState.pending(directory: fixture.directory, fileManager: FileManager.default))
  #expect(throws: CaptureEvidenceStoreError.custodyInUse) {
    try CaptureCustodyRuntime(
      configuration: fixture.configuration, loadKey: { _ in key }, removeKey: {})
  }
  // Drop the old runtime just as process shutdown drops the lease; durable intent survives.
  runtime = nil
  removals.allowRemoval()
  let reopened = try CaptureCustodyRuntime(
    configuration: fixture.configuration,
    loadKey: { _ in
      Issue.record("Erase-only reopen accessed a missing/corrupt key")
      throw CaptureEvidenceKey.Failure(status: errSecItemNotFound)
    }, removeKey: { try removals.remove() })
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) { try await reopened.store.list() }
  try await reopened.erase()
  #expect(!FileManager.default.fileExists(atPath: CaptureCustodyErasureState.location(fixture.directory).path))
  let replacement = try CaptureCustodyRuntime(
    configuration: fixture.configuration, loadKey: { _ in key }, removeKey: {})
  let replacementID = UUID()
  try await replacement.store.store(id: replacementID, original: Data([3]), manifest: Data([4]))
  try await reopened.erase()
  try await reopened.store.revokeAndRemoveAll()
  #expect(try await replacement.store.read(id: replacementID).original == Data([3]))
  try await replacement.erase()
}

@Test func recordOnlyMaintenanceReopensOnSuccessButFencesOnFailure() async throws {
  let fixture = try ErasureFixture()
  defer { fixture.cleanup() }
  let key = SymmetricKey(size: .bits256)
  let store = try CaptureEvidenceStore(directory: fixture.directory, key: key)
  try await store.store(id: UUID(), original: Data([1]), manifest: Data([2]))
  try await store.removeAll()
  #expect(try await store.list().isEmpty)
  #expect(try !CaptureCustodyErasureState.pending(directory: fixture.directory, fileManager: FileManager.default))
  let id = UUID()
  try await store.store(id: id, original: Data([3]), manifest: Data([4]))
  try fixture.lockDirectory()
  await #expect(throws: (any Error).self) { try await store.removeAll() }
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) { try await store.read(id: id) }
  let reopened = try CaptureEvidenceStore(directory: fixture.directory, key: key)
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) { try await reopened.list() }
  try fixture.unlockDirectory()
  try await reopened.revokeAndRemoveAll()
}

@Test func corruptErasureMarkerFailsIntegrityInsteadOfInventingEraseIntent() throws {
  let fixture = try ErasureFixture()
  defer { fixture.cleanup() }
  _ = try CaptureEvidenceStore(directory: fixture.directory, key: SymmetricKey(size: .bits256))
  for bytes in [Data(), Data([2]), Data([0, 1])] {
    try bytes.write(to: CaptureCustodyErasureState.location(fixture.directory))
    #expect(throws: CaptureEvidenceStoreError.integrityFailure) {
      try CaptureCustodyRuntime(
        configuration: fixture.configuration,
        loadKey: { _ in
          Issue.record("Corrupt state reached Keychain")
          return SymmetricKey(size: .bits256)
        }, removeKey: {})
    }
  }
}

@Test func unpersistableEraseIntentFailsBeforeDeletingAnyEvidence() async throws {
  let fixture = try ErasureFixture()
  defer { fixture.cleanup() }
  let store = try CaptureEvidenceStore(directory: fixture.directory, key: SymmetricKey(size: .bits256))
  let id = UUID()
  try await store.store(id: id, original: Data([1]), manifest: Data([2]))
  let marker = CaptureCustodyErasureState.location(fixture.directory)
  try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: marker.path)
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path) }
  await #expect(throws: (any Error).self) { try await store.revokeAndRemoveAll() }
  #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(id.uuidString + ".evidence").path))
  #expect(try !CaptureCustodyErasureState.pending(directory: fixture.directory, fileManager: FileManager.default))
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) { try await store.read(id: id) }
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
  try await store.revokeAndRemoveAll()
}

private struct ErasureFixture {
  let directory: URL
  let configuration: CaptureCustodyConfiguration
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    configuration = try .init(applicationID: "capture-sdk.fixture", directory: directory, keychainService: UUID().uuidString, keychainAccount: "test", accessGroup: "TEAM.capture-sdk.fixture")
  }
  func lockDirectory() throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
  }
  func unlockDirectory() throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }
  func cleanup() {
    try? unlockDirectory()
    try? FileManager.default.removeItem(at: directory)
  }
}
private enum ErasureInjectedFailure: Error { case keyRemoval }
private final class ErasureKeyRemover: @unchecked Sendable {
  private let lock = NSLock()
  private var shouldFail = true
  func allowRemoval() { lock.withLock { shouldFail = false } }
  func remove() throws {
    try lock.withLock { if shouldFail { throw ErasureInjectedFailure.keyRemoval } }
  }
}
