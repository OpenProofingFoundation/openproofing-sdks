import Foundation
import Testing

@testable import CaptureEvidenceCustody

@Test func liveLookupDiscoversOnlyAdmittedSuccessfulPublicationsWithoutDirectoryScans() async throws
{
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let scope = UUID()
  let capture = UUID()
  let otherCapture = UUID()
  // A directory reconciliation would fail; acquisition-local lookup must not perform one.
  try Data([0, 1, 2]).write(to: fixture.location(UUID()))
  try await fixture.store.beginLiveLookupScope(id: scope)
  try await fixture.store.admitLiveCapture(captureID: capture, scopeID: scope)
  let empty = try await fixture.store.liveLookupSnapshot(captureIDs: [capture])
  #expect(empty?.matchingRecordIDs().isEmpty == true)
  let first = try await fixture.store(capture: capture, kind: "usability")
  _ = try await fixture.store(capture: otherCapture, kind: "usability")
  let before = try await fixture.store.liveLookupSnapshot(captureIDs: [capture])
  let second = try await fixture.store(capture: capture, kind: "portraitExtraction")
  #expect(before?.matchingRecordIDs() == [first])
  let after = try await fixture.store.liveLookupSnapshot(captureIDs: [capture])
  #expect(Set(after?.matchingRecordIDs() ?? []) == [first, second])
  #expect(after?.matchingRecordIDs(captureID: otherCapture).isEmpty == true)
  #expect(after?.matchingRecordIDs(recordKind: "portraitExtraction") == [second])
  #expect(await fixture.store.metadataDirectoryScanCount == 0)
  #expect(await fixture.store.authenticatedMetadataReadCount == 0)
  await #expect(throws: (any Error).self) { try await fixture.store.matchingRecordIDs() }
}

@Test func ordinaryLookupStillDiscoversExternalPublicationsDuringLiveScope() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let scope = UUID()
  let capture = UUID()
  try await fixture.store.beginLiveLookupScope(id: scope)
  try await fixture.store.admitLiveCapture(captureID: capture, scopeID: scope)
  let local = try await fixture.store(capture: capture, kind: "usability")
  let other = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  let external = UUID()
  try await other.store(
    id: external, original: Data([7]),
    manifest: fixture.manifest(capture: capture, kind: "usability"))
  let live = try await fixture.store.liveLookupSnapshot(captureIDs: [capture])
  #expect(live?.matchingRecordIDs() == [local])
  #expect(Set(try await fixture.store.matchingRecordIDs(captureID: capture)) == [local, external])
  let stillLive = try await fixture.store.liveLookupSnapshot(captureIDs: [capture])
  #expect(
    stillLive?.matchingRecordIDs() == [local],
    "Ordinary discovery cannot contaminate live ownership")
  await fixture.store.endLiveLookupScope(id: scope)
  #expect(try await fixture.store.liveLookupSnapshot(captureIDs: [capture]) == nil)
  let reconciled = try await fixture.store.lookupSnapshot(captureIDs: [capture])
  #expect(Set(reconciled.matchingRecordIDs()) == [local, external])
}

@Test func liveLookupRequiresFreshExplicitAdmissionAndMatchingScope() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let scope = UUID()
  let capture = UUID()
  let historical = UUID()
  try await fixture.store.store(
    id: historical, original: Data([9]),
    manifest: fixture.manifest(capture: historical, kind: "original"))
  try await fixture.store.beginLiveLookupScope(id: scope)
  await #expect(throws: (any Error).self) {
    try await fixture.store.admitLiveCapture(captureID: historical, scopeID: scope)
  }
  await #expect(throws: (any Error).self) {
    try await fixture.store.admitLiveCapture(captureID: capture, scopeID: UUID())
  }
  await #expect(throws: CaptureEvidenceStoreError.self) {
    try await fixture.store.liveLookupSnapshot(captureIDs: [capture])
  }
  try await fixture.store.admitLiveCapture(captureID: capture, scopeID: scope)
  await #expect(throws: (any Error).self) {
    try await fixture.store.admitLiveCapture(captureID: capture, scopeID: scope)
  }
  await #expect(throws: CaptureEvidenceStoreError.self) {
    try await fixture.store.liveLookupSnapshot(captureIDs: [capture, historical])
  }
  await #expect(throws: (any Error).self) {
    try await fixture.store.beginLiveLookupScope(id: UUID())
  }
  await fixture.store.endLiveLookupScope(id: scope)
  let nextScope = UUID()
  let nextCapture = UUID()
  try await fixture.store.beginLiveLookupScope(id: nextScope)
  try await fixture.store.admitLiveCapture(captureID: nextCapture, scopeID: nextScope)
  await fixture.store.endLiveLookupScope(id: scope)
  #expect(try await fixture.store.liveLookupSnapshot(captureIDs: [nextCapture]) != nil)
  await #expect(throws: CaptureEvidenceStoreError.self) {
    try await fixture.store.liveLookupSnapshot(captureIDs: [capture])
  }
  let reopened = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await reopened.liveLookupSnapshot(captureIDs: [nextCapture]) == nil)
}

@Test func liveLookupCandidatesStillRequireAuthenticatedReadAfterMutationAndDeletion() async throws
{
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let scope = UUID()
  let capture = UUID()
  try await fixture.store.beginLiveLookupScope(id: scope)
  try await fixture.store.admitLiveCapture(captureID: capture, scopeID: scope)
  let changed = try await fixture.store(capture: capture, kind: "usability")
  let deleted = try await fixture.store(capture: capture, kind: "portraitExtraction")
  var bytes = try Data(contentsOf: fixture.location(changed))
  bytes[bytes.count - 1] ^= 1
  try bytes.write(to: fixture.location(changed))
  try FileManager.default.removeItem(at: fixture.location(deleted))
  let snapshot = try await fixture.store.liveLookupSnapshot(captureIDs: [capture])
  #expect(Set(snapshot?.matchingRecordIDs() ?? []) == [changed, deleted])
  await #expect(throws: (any Error).self) { try await fixture.store.read(id: changed) }
  await #expect(throws: (any Error).self) { try await fixture.store.read(id: deleted) }
  #expect(await fixture.store.metadataDirectoryScanCount == 0)
}

@Test func failedPublicationDoesNotEnterLiveLookupAndResetEndsScope() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let scope = UUID()
  let capture = UUID()
  let failed = UUID()
  try await fixture.store.beginLiveLookupScope(id: scope)
  try await fixture.store.admitLiveCapture(captureID: capture, scopeID: scope)
  await #expect(throws: (any Error).self) {
    try await fixture.store.store(
      id: failed, original: Data([7]),
      manifest: fixture.manifest(capture: capture, kind: "usability"),
      expectedSHA256: String(repeating: "0", count: 64))
  }
  let snapshot = try await fixture.store.liveLookupSnapshot(captureIDs: [capture])
  #expect(snapshot?.matchingRecordIDs().isEmpty == true)
  try await fixture.store.removeAll()
  #expect(try await fixture.store.liveLookupSnapshot(captureIDs: [capture]) == nil)
}

@Test func historicalSeedsReconcileOnceThenIncludeLaterLocalPublicationsWithoutRescanning()
  async throws
{
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let scope = UUID()
  let front = UUID()
  let back = UUID()
  let other = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  let historical = UUID()
  try await other.store(
    id: historical, original: Data([4]),
    manifest: fixture.manifest(capture: front, kind: "portraitExtraction"))
  try await fixture.store.beginLiveLookupScope(id: scope, seedCaptureIDs: [front])
  #expect(await fixture.store.metadataDirectoryScanCount == 1)
  try await fixture.store.admitLiveCapture(captureID: back, scopeID: scope)
  let current = try await fixture.store(capture: back, kind: "usability")
  let laterFront = try await fixture.store(capture: front, kind: "extraction")
  // New unrelated invalid metadata would make any later reconciliation fail.
  try Data([0]).write(to: fixture.location(UUID()))
  let snapshot = try await fixture.store.liveLookupSnapshot(captureIDs: [front, back])
  #expect(Set(snapshot?.matchingRecordIDs() ?? []) == [historical, current, laterFront])
  await #expect(throws: CaptureEvidenceStoreError.self) {
    try await fixture.store.liveLookupSnapshot(captureIDs: [UUID()])
  }
  #expect(await fixture.store.metadataDirectoryScanCount == 1)
}

@Test func failedSeedReconciliationDoesNotLeaveAnActiveLookupScope() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  try Data([0]).write(to: fixture.location(UUID()))
  await #expect(throws: (any Error).self) {
    try await fixture.store.beginLiveLookupScope(id: UUID(), seedCaptureIDs: [UUID()])
  }
  #expect(try await fixture.store.liveLookupSnapshot(captureIDs: []) == nil)
  // A new empty acquisition scope remains possible without touching that archive.
  try await fixture.store.beginLiveLookupScope(id: UUID())
  #expect(try await fixture.store.liveLookupSnapshot(captureIDs: []) != nil)
  #expect(await fixture.store.metadataDirectoryScanCount == 1)
}
