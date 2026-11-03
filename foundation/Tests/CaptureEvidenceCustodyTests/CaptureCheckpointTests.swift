import CryptoKit
import Foundation
import Testing

@testable import CaptureEvidenceCustody

func checkpointRecord(workflowID: UUID, revision: UInt64, value: String = "selection") throws -> CaptureCheckpointRecord {
  struct Payload: Codable { let workflowID: UUID; let revision: UInt64; let value: String }
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return try CaptureCheckpointRecord(workflowID: workflowID, revision: revision,
    payload: encoder.encode(Payload(workflowID: workflowID, revision: revision, value: value)))
}

@Test func checkpointRestoresExactOpaqueBytesAndRefusesStaleRevision() async throws {
  let fixture = try OpaqueCheckpointFixture()
  defer { fixture.remove() }
  let first = try checkpointRecord(workflowID: fixture.workflow, revision: 1)
  try await fixture.store.saveCheckpoint(first, expectedRevision: nil)
  let reopened = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  try await reopened.saveCheckpoint(first, expectedRevision: nil)
  #expect(try await reopened.checkpoint(workflowID: fixture.workflow) == first)
  let next = try checkpointRecord(workflowID: fixture.workflow, revision: 2, value: "retake")
  try await reopened.saveCheckpoint(next, expectedRevision: 1)
  await #expect(throws: CaptureCheckpointError.staleRevision) {
    try await fixture.store.saveCheckpoint(first, expectedRevision: nil)
  }
  #expect(try await fixture.store.checkpoint(workflowID: fixture.workflow) == next)
  #expect(try Data(contentsOf: fixture.path).range(of: next.payload) == nil)
}

@Test func concurrentCheckpointFacadesAdmitOnlyOneExactRevision() async throws {
  let fixture = try OpaqueCheckpointFixture()
  defer { fixture.remove() }
  let other = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  let one = try checkpointRecord(workflowID: fixture.workflow, revision: 1, value: "one")
  let two = try checkpointRecord(workflowID: fixture.workflow, revision: 1, value: "two")
  async let first = checkpointWrite(one, store: fixture.store)
  async let second = checkpointWrite(two, store: other)
  let admitted = await [first, second]
  #expect(admitted.filter { $0 }.count == 1)
  let retained = try await fixture.store.checkpoint(workflowID: fixture.workflow)
  #expect(retained == one || retained == two)
}

@Test func corruptedCheckpointCannotBecomeAbsenceAndErasureRemovesIt() async throws {
  let fixture = try OpaqueCheckpointFixture()
  defer { fixture.remove() }
  #expect(try await fixture.store.checkpoint(workflowID: fixture.workflow) == nil)
  let record = try checkpointRecord(workflowID: fixture.workflow, revision: 1)
  try await fixture.store.saveCheckpoint(record, expectedRevision: nil)
  var bytes = try Data(contentsOf: fixture.path)
  bytes[bytes.count - 1] ^= 1
  try bytes.write(to: fixture.path)
  await #expect(throws: (any Error).self) { try await fixture.store.checkpoint(workflowID: fixture.workflow) }
  await #expect(throws: (any Error).self) { try await fixture.store.saveCheckpoint(record, expectedRevision: nil) }
  try await fixture.store.removeAll()
  #expect(try await fixture.store.checkpoint(workflowID: fixture.workflow) == nil)
}

@Test func oldCheckpointDomainAndExactBytesRemainReadable() async throws {
  let fixture = try OpaqueCheckpointFixture()
  defer { fixture.remove() }
  // This is the historical typed payload, with deliberately retained whitespace and ordering.
  let bytes = Data("{ \"workflowID\": \"\(fixture.workflow.uuidString)\", \"revision\": 1, \"profile\": \"License front\", \"nextStage\": \"front\", \"updatedAt\": 0 }".utf8)
  let encrypted = try AES.GCM.seal(bytes, using: fixture.key,
    authenticating: Data(("IdentityEvidenceStorage/journey-checkpoint/v1/" + fixture.workflow.uuidString).utf8))
  try #require(encrypted.combined).write(to: fixture.path)
  let storedBytes = try Data(contentsOf: fixture.path)
  let retained = try #require(await fixture.store.checkpoint(workflowID: fixture.workflow))
  #expect(retained.payload == bytes)
  try await fixture.store.saveCheckpoint(retained, expectedRevision: nil)
  #expect(try Data(contentsOf: fixture.path) == storedBytes)
}

@Test func checkpointOwnerRevisionAndCipherKeyRemainBound() async throws {
  let fixture = try OpaqueCheckpointFixture()
  defer { fixture.remove() }
  let record = try checkpointRecord(workflowID: fixture.workflow, revision: 1)
  try await fixture.store.saveCheckpoint(record, expectedRevision: nil)
  let copiedID = UUID()
  try FileManager.default.copyItem(at: fixture.path,
    to: fixture.directory.appendingPathComponent(copiedID.uuidString + ".journey"))
  await #expect(throws: (any Error).self) { try await fixture.store.checkpoint(workflowID: copiedID) }
  let wrongKey = try CaptureEvidenceStore(directory: fixture.directory, key: SymmetricKey(size: .bits256))
  await #expect(throws: (any Error).self) { try await wrongKey.checkpoint(workflowID: fixture.workflow) }
  #expect(throws: CaptureCheckpointError.invalidCheckpoint) {
    try CaptureCheckpointRecord(workflowID: UUID(), revision: 1, payload: record.payload)
  }
  #expect(throws: CaptureCheckpointError.invalidCheckpoint) {
    try CaptureCheckpointRecord(workflowID: fixture.workflow, revision: 2, payload: record.payload)
  }
  #expect(throws: CaptureCheckpointError.invalidCheckpoint) {
    try CaptureCheckpointRecord(workflowID: fixture.workflow, revision: 0, payload: Data())
  }
  let skipped = try checkpointRecord(workflowID: fixture.workflow, revision: 4)
  await #expect(throws: CaptureCheckpointError.invalidCheckpoint) {
    try await fixture.store.saveCheckpoint(skipped, expectedRevision: 1)
  }
}

private func checkpointWrite(_ value: CaptureCheckpointRecord, store: CaptureEvidenceStore) async -> Bool {
  do { try await store.saveCheckpoint(value, expectedRevision: nil); return true }
  catch { return false }
}

private struct OpaqueCheckpointFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let key = SymmetricKey(size: .bits256)
  let workflow = UUID()
  let store: CaptureEvidenceStore
  var path: URL { directory.appendingPathComponent(workflow.uuidString + ".journey") }
  init() throws { store = try CaptureEvidenceStore(directory: directory, key: key) }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}
