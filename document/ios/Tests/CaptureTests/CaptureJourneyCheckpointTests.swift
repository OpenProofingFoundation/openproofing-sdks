import CryptoKit
import Foundation
import Testing

@_spi(CaptureTestFixture) @testable import CaptureEvidenceCustody
@testable import DocumentCapture

@Test func checkpointSurvivesReopenAndLateRevisionCannotReplaceSelections() async throws {
  let fixture = try CheckpointFixture()
  defer { fixture.remove() }
  let first = fixture.value(revision: 1, frontID: UUID())
  try await fixture.store.saveJourneyCheckpoint(first, expectedRevision: nil)
  let reopened = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  // Exact replay after a lost acknowledgement succeeds without a new revision.
  try await reopened.saveJourneyCheckpoint(first, expectedRevision: nil)
  #expect(try await reopened.journeyCheckpoint(workflowID: fixture.workflow) == first)
  let retake = fixture.value(revision: 2)
  try await reopened.saveJourneyCheckpoint(retake, expectedRevision: 1)
  await #expect(throws: (any Error).self) {
    try await fixture.store.saveJourneyCheckpoint(
      fixture.value(revision: 2, frontID: first.frontID), expectedRevision: 1)
  }
  #expect(try await fixture.store.journeyCheckpoint(workflowID: fixture.workflow) == retake)
  let disk = try Data(contentsOf: fixture.path)
  #expect(disk.range(of: Data("License front".utf8)) == nil)
}

@Test func concurrentCheckpointWritersHaveOneWinnerAcrossActors() async throws {
  let fixture = try CheckpointFixture()
  defer { fixture.remove() }
  let other = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  let first = fixture.value(revision: 1, frontID: UUID())
  let second = fixture.value(revision: 1, frontID: UUID())
  async let one = saveResult(first, store: fixture.store)
  async let two = saveResult(second, store: other)
  let results = await [one, two]
  #expect(results.filter { $0 }.count == 1)
  let retained = try await fixture.store.journeyCheckpoint(workflowID: fixture.workflow)
  #expect(retained == first || retained == second)
}

@Test func corruptedCheckpointIsNotAbsenceAndResetDeletesIt() async throws {
  let fixture = try CheckpointFixture()
  defer { fixture.remove() }
  #expect(try await fixture.store.journeyCheckpoint(workflowID: fixture.workflow) == nil)
  try await fixture.store.saveJourneyCheckpoint(fixture.value(revision: 1), expectedRevision: nil)
  var bytes = try Data(contentsOf: fixture.path)
  bytes[bytes.count - 1] ^= 1
  try bytes.write(to: fixture.path)
  await #expect(throws: (any Error).self) {
    try await fixture.store.journeyCheckpoint(workflowID: fixture.workflow)
  }
  await #expect(throws: (any Error).self) {
    try await fixture.store.saveJourneyCheckpoint(fixture.value(revision: 1), expectedRevision: nil)
  }
  try await fixture.store.removeAll()
  #expect(try await fixture.store.journeyCheckpoint(workflowID: fixture.workflow) == nil)
}

@Test func checkpointIdentityAndKeyAreBoundAndInvalidRevisionsFail() async throws {
  let fixture = try CheckpointFixture()
  defer { fixture.remove() }
  try await fixture.store.saveJourneyCheckpoint(fixture.value(revision: 1), expectedRevision: nil)
  let otherID = UUID()
  try FileManager.default.copyItem(
    at: fixture.path,
    to: fixture.directory.appendingPathComponent(otherID.uuidString + ".journey"))
  await #expect(throws: (any Error).self) {
    try await fixture.store.journeyCheckpoint(workflowID: otherID)
  }
  let wrong = try CaptureEvidenceStore(
    directory: fixture.directory, key: SymmetricKey(size: .bits256))
  await #expect(throws: (any Error).self) {
    try await wrong.journeyCheckpoint(workflowID: fixture.workflow)
  }
  await #expect(throws: (any Error).self) {
    try await fixture.store.saveJourneyCheckpoint(fixture.value(revision: 4), expectedRevision: 1)
  }
}

@Test func standaloneSelfieProgressSurvivesEncryptedReopenWithoutPortraitAnalysis() async throws {
  let fixture = try CheckpointFixture()
  defer { fixture.remove() }
  let frontID = UUID()
  let pending = CaptureJourneyCheckpoint(
    workflowID: fixture.workflow, revision: 1, profile: "licenseFront",
    nextStage: .selfie, frontID: frontID,
    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
  try await fixture.store.saveJourneyCheckpoint(pending, expectedRevision: nil)
  let reopened = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await reopened.journeyCheckpoint(workflowID: fixture.workflow) == pending)
  let completed = CaptureJourneyCheckpoint(
    workflowID: fixture.workflow, revision: 2, profile: pending.profile,
    nextStage: .results, frontID: frontID, selfieID: UUID(), updatedAt: pending.updatedAt)
  try await reopened.saveJourneyCheckpoint(completed, expectedRevision: 1)
  let secondReopen = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await secondReopen.journeyCheckpoint(workflowID: fixture.workflow) == completed)
}

@Test func comparisonCheckpointStillRequiresDistinctPortraitAndSelfieSources() async throws {
  let fixture = try CheckpointFixture()
  defer { fixture.remove() }
  let frontID = UUID()
  let portraitID = UUID()
  let selfieID = UUID()
  for (portrait, selfie) in [(nil, selfieID), (portraitID, nil), (selfieID, selfieID)]
    as [(UUID?, UUID?)]
  {
    let invalid = CaptureJourneyCheckpoint(
      workflowID: fixture.workflow, revision: 1, profile: "licenseFront",
      nextStage: .results, frontID: frontID, portraitID: portrait,
      selfieID: selfie, comparisonID: UUID(), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    await #expect(throws: CaptureJourneyCheckpointError.invalidCheckpoint) {
      try await fixture.store.saveJourneyCheckpoint(invalid, expectedRevision: nil)
    }
  }
  let valid = CaptureJourneyCheckpoint(
    workflowID: fixture.workflow, revision: 1, profile: "licenseFront",
    nextStage: .results, frontID: frontID, portraitID: portraitID,
    selfieID: selfieID, comparisonID: UUID(), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
  try await fixture.store.saveJourneyCheckpoint(valid, expectedRevision: nil)
  #expect(try await fixture.store.journeyCheckpoint(workflowID: fixture.workflow) == valid)
}

private func saveResult(
  _ value: CaptureJourneyCheckpoint, store: CaptureEvidenceStore
) async -> Bool {
  do {
    try await store.saveJourneyCheckpoint(value, expectedRevision: nil)
    return true
  } catch { return false }
}

private struct CheckpointFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let key = SymmetricKey(size: .bits256)
  let workflow = UUID()
  let store: CaptureEvidenceStore
  var path: URL { directory.appendingPathComponent(workflow.uuidString + ".journey") }
  init() throws { store = try CaptureEvidenceStore(directory: directory, key: key) }
  func value(revision: UInt64, frontID: UUID? = nil) -> CaptureJourneyCheckpoint {
    CaptureJourneyCheckpoint(
      workflowID: workflow, revision: revision, profile: "License front",
      nextStage: frontID == nil ? .front : .review, frontID: frontID,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}
