import CryptoKit
import Foundation
import Testing

@testable import CaptureEvidenceCustody

@Test func erasureRevokesQueuedOriginalDerivativeCheckpointAndCachePublications() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try CaptureEvidenceStore(directory: directory, key: SymmetricKey(size: .bits256))
  try await store.store(id: UUID(), original: Data([1]), manifest: Data([2]))
  let gate = DelayedPublicationGate()
  let delayed = Task {
    await gate.wait()
    try await store.store(id: UUID(), original: Data([3]), manifest: Data([4]))
  }
  try await store.revokeAndRemoveAll()
  await gate.release()
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) { try await delayed.value }
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
    try await store.saveCheckpoint(
      try checkpointRecord(workflowID: UUID(), revision: 1),
      expectedRevision: nil)
  }
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
    try await store.checkpointMetadataIndex()
  }
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
    try await store.beginLiveLookupScope(id: UUID())
  }
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) { try await store.list() }
  #expect(
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter { !["lock", "erasure"].contains($0.pathExtension) }.isEmpty)
}

@Test func independentCustodyProfilesRemainWritableWhenOtherProfileErases() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let one = try CaptureEvidenceStore(
    directory: root.appendingPathComponent("one"),
    key: SymmetricKey(size: .bits256))
  let two = try CaptureEvidenceStore(
    directory: root.appendingPathComponent("two"),
    key: SymmetricKey(size: .bits256))
  let id = UUID()
  try await one.store(id: id, original: Data([1]), manifest: Data([2]))
  try await two.store(id: id, original: Data([3]), manifest: Data([4]))
  try await one.revokeAndRemoveAll()
  #expect(try await two.read(id: id).original == Data([3]))
  try await two.store(id: UUID(), original: Data([5]), manifest: Data([6]))
  #expect(try await two.list().count == 2)
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) { try await one.list() }
}

@Test func eraseSerializesAgainstAdmittedStoreWritesWithoutResurrection() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try CaptureEvidenceStore(directory: directory, key: SymmetricKey(size: .bits256))
  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<20 {
      group.addTask {
        do {
          try await store.store(
            id: UUID(), original: Data(repeating: 7, count: 4096), manifest: Data([8]))
        } catch CaptureEvidenceStoreError.custodyRevoked {
        } catch { Issue.record(error) }
      }
    }
    group.addTask {
      do { try await store.revokeAndRemoveAll() } catch { Issue.record(error) }
    }
  }
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) { try await store.list() }
  await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
    try await store.store(id: UUID(), original: Data([1]), manifest: Data([2]))
  }
}

private actor DelayedPublicationGate {
  var released = false
  var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
