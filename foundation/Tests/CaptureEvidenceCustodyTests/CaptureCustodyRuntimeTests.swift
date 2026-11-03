import CryptoKit
import Foundation
import Security
import Testing

@testable import CaptureEvidenceCustody

@Suite struct CaptureCustodyErasurePreparationTests {
  @Test func publicPreparationPersistsRevocationBeforeSettlementAndDeletion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = try CaptureCustodyConfiguration(
      applicationID: "synthetic.capture.fixture", directory: directory,
      keychainService: UUID().uuidString, keychainAccount: "synthetic",
      accessGroup: "TEAM.synthetic.capture.fixture")
    let key = SymmetricKey(data: Data(repeating: 37, count: 32))
    // Explicit synthetic custody exercises lifecycle ordering without claiming hardware acceptance.
    let runtime = try CaptureCustodyRuntime(configuration: configuration,
      loadKey: { _ in key }, removeKey: {})
    let id = UUID()
    try await runtime.store.store(id: id, original: Data([1]), manifest: Data([2]))
    let ciphertext = directory.appendingPathComponent(id.uuidString + ".evidence")
    #expect(FileManager.default.fileExists(atPath: ciphertext.path))

    try await runtime.prepareErasure()

    #expect(try CaptureCustodyErasureState.pending(directory: directory, fileManager: .default))
    #expect(FileManager.default.fileExists(atPath: ciphertext.path))
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await runtime.store.read(id: id)
    }
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await runtime.store.store(id: UUID(), original: Data([3]), manifest: Data([4]))
    }
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await runtime.store.checkpoint(workflowID: id)
    }
    let reopened = try CaptureEvidenceStore(directory: directory, key: key)
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await reopened.list()
    }
    // Repeated preparation remains a durable fence while native settlement is still pending.
    try await runtime.prepareErasure()
    #expect(FileManager.default.fileExists(atPath: ciphertext.path))
    try await runtime.erase()
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }
}

@Test func runtimeResourceLeasesRejectAliasAndNestedLocationsButPermitIndependentProfiles() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let one = try CaptureCustodyConfiguration(
      applicationID: "capture-sdk.fixture", directory: root.appendingPathComponent("one"),
    keychainService: UUID().uuidString, keychainAccount: "one", accessGroup: "TEAM.capture-sdk.fixture")
  let lease = try CaptureCustodyLease.acquire(one)
  defer { lease.release() }
  #expect(throws: CaptureEvidenceStoreError.custodyInUse) { try CaptureCustodyLease.acquire(one) }
  let sharedKey = try CaptureCustodyConfiguration(
      applicationID: "capture-sdk.fixture", directory: root.appendingPathComponent("two"),
    keychainService: one.keychainService, keychainAccount: one.keychainAccount, accessGroup: "TEAM.capture-sdk.fixture")
  #expect(throws: CaptureEvidenceStoreError.custodyInUse) {
    try CaptureCustodyLease.acquire(sharedKey)
  }
  let nested = try CaptureCustodyConfiguration(
      applicationID: "capture-sdk.fixture", directory: one.directory.appendingPathComponent("nested"),
    keychainService: "different-service", keychainAccount: "different-account", accessGroup: "TEAM.capture-sdk.fixture")
  #expect(throws: CaptureEvidenceStoreError.custodyInUse) {
    try CaptureCustodyLease.acquire(nested)
  }
  let two = try CaptureCustodyConfiguration(
      applicationID: "capture-sdk.fixture", directory: root.appendingPathComponent("two"),
    keychainService: UUID().uuidString, keychainAccount: "two", accessGroup: "TEAM.capture-sdk.fixture")
  let other = try CaptureCustodyLease.acquire(two)
  other.release()
  lease.release()
  let reopened = try CaptureCustodyLease.acquire(one)
  reopened.release()
}

@Test func sameExplicitAccessGroupLeaseConflictsInEitherOrder() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let service = UUID().uuidString
  let wildcard = try CaptureCustodyConfiguration(
      applicationID: "capture-sdk.fixture", directory: root.appendingPathComponent("one"),
    keychainService: service, keychainAccount: "same", accessGroup: "group.capture.test")
  let explicit = try CaptureCustodyConfiguration(
      applicationID: "capture-sdk.fixture", directory: root.appendingPathComponent("two"),
    keychainService: service, keychainAccount: "same", accessGroup: "group.capture.test")
  for (first, second) in [(wildcard, explicit), (explicit, wildcard)] {
    let lease = try CaptureCustodyLease.acquire(first)
    defer { lease.release() }
    #expect(throws: CaptureEvidenceStoreError.custodyInUse) {
      try CaptureCustodyLease.acquire(second)
    }
  }
  let explicitOther = try CaptureCustodyConfiguration(
      applicationID: "capture-sdk.fixture", directory: root.appendingPathComponent("three"),
    keychainService: service, keychainAccount: "same", accessGroup: "group.capture.other")
  let lease = try CaptureCustodyLease.acquire(explicit)
  defer { lease.release() }
  let other = try CaptureCustodyLease.acquire(explicitOther)
  other.release()
}

// Explicit synthetic keys exercise lifecycle and persisted ciphertext on every platform.
// Production hardware Keychain/Secure Enclave acceptance requires a separately entitled device host.
@Test func runtimeProfilesAndRepeatedOldEraseCannotDeleteNewGenerationKey() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let oneConfig = try CaptureCustodyConfiguration(
    applicationID: "synthetic.capture.fixture", directory: root.appendingPathComponent("one"),
    keychainService: "synthetic." + UUID().uuidString, keychainAccount: "one",
    accessGroup: "TEST.synthetic.capture.fixture")
  let twoConfig = try CaptureCustodyConfiguration(
    applicationID: "synthetic.capture.fixture", directory: root.appendingPathComponent("two"),
    keychainService: "synthetic." + UUID().uuidString, keychainAccount: "two",
    accessGroup: "TEST.synthetic.capture.fixture")
  let oneKeys = SyntheticRuntimeKeys(seed: 17)
  let twoKeys = SyntheticRuntimeKeys(seed: 41)
  let one = try oneKeys.runtime(oneConfig)
  let two = try twoKeys.runtime(twoConfig)
  let id = UUID()
  try await one.store.store(id: id, original: Data([1]), manifest: Data([2]))
  try await two.store.store(id: id, original: Data([3]), manifest: Data([4]))
  try await one.erase()
  #expect(oneKeys.creations == 1 && oneKeys.removals == 1)
  #expect(!oneKeys.hasKey)
  #expect(twoKeys.hasKey && twoKeys.removals == 0)
  #expect(try await two.store.read(id: id).original == Data([3]))

  let replacement = try oneKeys.runtime(oneConfig)
  try await replacement.store.store(id: id, original: Data([5]), manifest: Data([6]))
  #expect(oneKeys.creations == 2)
  try await one.erase()
  try await one.store.revokeAndRemoveAll()
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
    try await one.store.removeAll()
  }
  #expect(oneKeys.hasKey && oneKeys.creations == 2 && oneKeys.removals == 1)
  #expect(try await replacement.store.read(id: id).original == Data([5]))
  // Reload the retained key independently: cached plaintext/key material in the runtime cannot
  // make this pass if an old generation removed or replaced the current namespace's key.
  let independentReadback = try CaptureEvidenceStore(
    directory: oneConfig.directory, key: oneKeys.load(.forbidden))
  #expect(try await independentReadback.read(id: id).original == Data([5]))
  try await replacement.erase()
  #expect(!oneKeys.hasKey && oneKeys.removals == 2)
  #expect(twoKeys.hasKey && twoKeys.removals == 0)
  try await two.erase()
  #expect(!twoKeys.hasKey && twoKeys.removals == 1)
}

@Test func missingCustodyKeyWithRetainedCiphertextDoesNotCreateReplacementKeyAndStillErases()
  async throws
{
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let id = UUID()
  let priorStore = try CaptureEvidenceStore(
    directory: directory, key: SymmetricKey(data: Data(repeating: 71, count: 32)))
  try await priorStore.store(id: id, original: Data([1, 2]), manifest: Data([3]))
  let retained = directory.appendingPathComponent(id.uuidString + ".evidence")
  let ciphertext = try Data(contentsOf: retained)
  let configuration = try CaptureCustodyConfiguration(
    applicationID: "synthetic.capture.fixture", directory: directory,
    keychainService: "synthetic." + UUID().uuidString, keychainAccount: "missing",
    accessGroup: "TEST.synthetic.capture.fixture")
  let keys = SyntheticRuntimeKeys(seed: 53)
  let runtime = try keys.runtime(configuration)
  #expect(runtime.keyMissingOnOpen)
  await #expect(throws: CaptureEvidenceStoreError.custodyKeyMissing) { try await runtime.store.list() }
  await #expect(throws: CaptureEvidenceStoreError.custodyKeyMissing) {
    try await runtime.store.store(id: UUID(), original: Data([4]), manifest: Data([5]))
  }
  #expect(try Data(contentsOf: retained) == ciphertext)
  #expect(!keys.hasKey && keys.permittedLoads == 0 && keys.creations == 0)
  try await runtime.erase()
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  #expect(!keys.hasKey && keys.permittedLoads == 0 && keys.creations == 0 && keys.removals == 1)
  #expect(throws: CaptureEvidenceKey.Failure.self) { try keys.load(.forbidden) }
  try await runtime.erase()
  #expect(keys.removals == 1 && keys.permittedLoads == 0)
}

/// Isolated deterministic test namespace, injected only through the internal test initializer.
private final class SyntheticRuntimeKeys: @unchecked Sendable {
  private let lock = NSLock()
  private let seed: UInt8
  private var key: SymmetricKey?
  private var created = 0
  private var removed = 0
  private var permitted = 0
  init(seed: UInt8) { self.seed = seed }
  var hasKey: Bool { lock.withLock { key != nil } }
  var creations: Int { lock.withLock { created } }
  var removals: Int { lock.withLock { removed } }
  var permittedLoads: Int { lock.withLock { permitted } }

  func runtime(_ configuration: CaptureCustodyConfiguration) throws -> CaptureCustodyRuntime {
    try CaptureCustodyRuntime(configuration: configuration,
      loadKey: { try self.load($0) }, removeKey: { self.remove() })
  }
  func load(_ creation: CaptureEvidenceKey.KeyCreation) throws -> SymmetricKey {
    try lock.withLock {
      if creation == .permitted { permitted += 1 }
      if let key { return key }
      guard creation == .permitted else { throw CaptureEvidenceKey.Failure(status: errSecItemNotFound) }
      created += 1
      let value = SymmetricKey(data: Data(repeating: seed &+ UInt8(created), count: 32))
      key = value
      return value
    }
  }
  private func remove() {
    lock.withLock { removed += 1; key = nil }
  }
}
