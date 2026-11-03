import CryptoKit
import Foundation
import Testing

@testable import CaptureEvidenceCustody

@Test func scopedSnapshotFiltersWithoutAdditionalScansOrAuthenticationReads() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let selected = UUID()
  let unrelated = UUID()
  let wanted = try await fixture.store(capture: selected, kind: "portraitExtraction")
  _ = try await fixture.store(capture: unrelated, kind: "portraitExtraction")
  let snapshot = try await fixture.store.lookupSnapshot(captureIDs: [selected])
  #expect(await fixture.store.metadataDirectoryScanCount == 1)
  let reads = await fixture.store.authenticatedReadCount
  let metadataReads = await fixture.store.authenticatedMetadataReadCount
  for _ in 0..<7 {
    #expect(
      snapshot.matchingRecordIDs(captureID: selected, recordKind: "portraitExtraction") == [wanted])
    #expect(snapshot.matchingRecordIDs(captureID: unrelated).isEmpty)
  }
  #expect(snapshot.matchingRecordIDs() == [wanted])
  #expect(await fixture.store.metadataDirectoryScanCount == 1)
  #expect(await fixture.store.authenticatedReadCount == reads)
  #expect(await fixture.store.authenticatedMetadataReadCount == metadataReads)
  for _ in 0..<3 { _ = try await fixture.store.matchingRecordIDs(captureID: selected) }
  #expect(await fixture.store.metadataDirectoryScanCount == 4)
}

@Test func snapshotDoesNotInventLaterPublicationsAndNextSnapshotDiscoversAnotherWriter()
  async throws
{
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let capture = UUID()
  let first = try await fixture.store(capture: capture, kind: "extraction")
  let before = try await fixture.store.lookupSnapshot(captureIDs: [capture])
  let other = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  let second = UUID()
  try await other.store(
    id: second, original: Data([7]),
    manifest: fixture.manifest(capture: capture, kind: "extraction"))
  #expect(before.matchingRecordIDs(captureID: capture) == [first])
  let after = try await fixture.store.lookupSnapshot(captureIDs: [capture])
  #expect(Set(after.matchingRecordIDs()) == [first, second])
  #expect(await fixture.store.metadataDirectoryScanCount == 2)
}

@Test func snapshotCandidatesDoNotBypassSelectedMutationOrDeletionChecks() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let capture = UUID()
  let changed = try await fixture.store(capture: capture, kind: "extraction")
  let deleted = try await fixture.store(capture: capture, kind: "portraitExtraction")
  let snapshot = try await fixture.store.lookupSnapshot(captureIDs: [capture])
  var bytes = try Data(contentsOf: fixture.location(changed))
  bytes[bytes.count - 1] ^= 1
  try bytes.write(to: fixture.location(changed))
  try FileManager.default.removeItem(at: fixture.location(deleted))
  #expect(Set(snapshot.matchingRecordIDs()) == [changed, deleted])
  await #expect(throws: (any Error).self) { try await fixture.store.read(id: changed) }
  await #expect(throws: (any Error).self) { try await fixture.store.read(id: deleted) }
}

@Test func snapshotCreationStillRejectsUnknownCorruptRecordOutsideRequestedScope() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let capture = UUID()
  _ = try await fixture.store(capture: capture, kind: "extraction")
  try Data([0, 1, 2]).write(to: fixture.location(UUID()))
  await #expect(throws: (any Error).self) {
    try await fixture.store.lookupSnapshot(captureIDs: [capture])
  }
}
