import CryptoKit
import Foundation
import Testing

@testable import CaptureEvidenceCustody

@Test func indexedLookupFiltersCaptureSessionAndRoleWithoutRepeatedPayloadReads() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let first = UUID()
  let second = UUID()
  let session = UUID()
  let wanted = try await fixture.store(capture: first, session: session, kind: "portraitExtraction")
  _ = try await fixture.store(capture: first, kind: "selfieCapture")
  _ = try await fixture.store(capture: second, kind: "portraitExtraction")
  #expect(
    try await fixture.store.matchingRecordIDs(
      captureID: first, sessionID: session, recordKind: "portraitExtraction") == [wanted])
  let reads = await fixture.store.authenticatedReadCount
  #expect(
    try await fixture.store.matchingRecordIDs(
      captureID: first, recordKind: "portraitExtraction") == [wanted])
  #expect(await fixture.store.authenticatedReadCount == reads)
  try await fixture.store.checkpointMetadataIndex()
  let reopened = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await reopened.matchingRecordIDs(sessionID: session) == [wanted])
  #expect(await reopened.authenticatedReadCount == 0)
  _ = try await reopened.read(id: wanted)
  #expect(await reopened.authenticatedReadCount == 1)
  let disk = try Data(contentsOf: CaptureEvidenceIndex.location(fixture.directory))
  #expect(disk.range(of: Data("portraitExtraction".utf8)) == nil)
  #expect(disk.range(of: Data(first.uuidString.utf8)) == nil)
}

@Test func staleIndexCannotHideEvidencePublishedBeforeIndexUpdate() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let capture = UUID()
  let first = try await fixture.store(capture: capture, kind: "extraction")
  #expect(try await fixture.store.matchingRecordIDs(captureID: capture) == [first])
  // A second actor publishes evidence without ever updating the old on-disk index.
  let other = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  let second = UUID()
  try await other.store(
    id: second, original: Data([9]),
    manifest: fixture.manifest(capture: capture, kind: "extraction"))
  let reopened = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(Set(try await reopened.matchingRecordIDs(captureID: capture)) == [first, second])
  #expect(await reopened.authenticatedReadCount == 0)
  #expect(Set(try await fixture.store.matchingRecordIDs(captureID: capture)) == [first, second])
  try FileManager.default.removeItem(at: fixture.location(first))
  #expect(try await fixture.store.matchingRecordIDs(captureID: capture) == [second])
}

@Test func missingAndCorruptIndexesRebuildFromAuthenticatedEvidence() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let capture = UUID()
  let id = try await fixture.store(capture: capture, kind: "extraction")
  _ = try await fixture.store.matchingRecordIDs(captureID: capture)
  try await fixture.store.checkpointMetadataIndex()
  let path = CaptureEvidenceIndex.location(fixture.directory)
  var bytes = try Data(contentsOf: path)
  bytes[bytes.count - 1] ^= 1
  try bytes.write(to: path)
  let reopened = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await reopened.matchingRecordIDs(captureID: capture) == [id])
  #expect(await reopened.authenticatedReadCount == 0)
  try FileManager.default.removeItem(at: path)
  let missing = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await missing.matchingRecordIDs(captureID: capture) == [id])
  #expect(await missing.authenticatedReadCount == 0)
  let wrongKey = try CaptureEvidenceStore(
    directory: fixture.directory, key: SymmetricKey(size: .bits256))
  await #expect(throws: (any Error).self) {
    try await wrongKey.matchingRecordIDs(captureID: capture)
  }
}

@Test func indexedCandidatesStillRequireAuthenticatedReadAndDeletionClearsIndex() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let capture = UUID()
  let id = try await fixture.store(capture: capture, kind: "selfieCapture")
  try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
    ofItemAtPath: fixture.location(id).path)
  _ = try await fixture.store.matchingRecordIDs(captureID: capture)
  let path = fixture.location(id)
  let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
  var bytes = try Data(contentsOf: path)
  bytes[bytes.count - 1] ^= 1
  // Preserve fingerprint deliberately: metadata lookup is not a ciphertext audit.
  try bytes.write(to: path)
  if let modified = attributes[.modificationDate] {
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
  }
  #expect(try await fixture.store.matchingRecordIDs(captureID: capture) == [id])
  await #expect(throws: (any Error).self) { try await fixture.store.read(id: id) }
  await #expect(throws: (any Error).self) { try await fixture.store.list() }
  try await fixture.store.removeAll()
  #expect(try await fixture.store.matchingRecordIDs(captureID: capture).isEmpty)
}

@Test func changedAndLegacyRecordsCannotDisappearBehindIndex() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let id = UUID()
  try await fixture.store.store(id: id, original: Data([1]), manifest: Data([2]))
  #expect(try await fixture.store.matchingRecordIDs() == [id])
  #expect(try await fixture.store.matchingRecordIDs(captureID: UUID()).isEmpty)
  // Replacing a file outside the immutable API invalidates its metadata entry.
  try Data([0]).write(to: fixture.location(id), options: .atomic)
  await #expect(throws: (any Error).self) { try await fixture.store.matchingRecordIDs() }
}

@Test func indexWriteFailureDoesNotRejectOrHidePublishedEvidence() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let capture = UUID()
  let id = try await fixture.store(capture: capture, kind: "extraction")
  let indexPath = CaptureEvidenceIndex.location(fixture.directory)
  try FileManager.default.createDirectory(at: indexPath, withIntermediateDirectories: false)
  #expect(try await fixture.store.matchingRecordIDs(captureID: capture) == [id])
  #expect(try await fixture.store.read(id: id).id == id)
  let reopened = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await reopened.matchingRecordIDs(captureID: capture) == [id])
  try FileManager.default.removeItem(at: indexPath)
  let recovered = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await recovered.matchingRecordIDs(captureID: capture) == [id])
  try await recovered.checkpointMetadataIndex()
  #expect(CaptureEvidenceIndex.load(directory: fixture.directory, key: fixture.key) != nil)
}

@Test func replacedAuthenticatedRecordRebuildsSelectorsInsteadOfHidingIt() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let firstCapture = UUID()
  let secondCapture = UUID()
  let id = try await fixture.store(capture: firstCapture, kind: "extraction")
  _ = try await fixture.store.matchingRecordIDs(captureID: firstCapture)
  let replacementDirectory = fixture.directory.appendingPathComponent("replacement")
  let replacement = try CaptureEvidenceStore(directory: replacementDirectory, key: fixture.key)
  try await replacement.store(
    id: id, original: Data([8]),
    manifest: fixture.manifest(capture: secondCapture, kind: "selfieCapture"))
  try FileManager.default.removeItem(at: fixture.location(id))
  try FileManager.default.moveItem(
    at: replacementDirectory.appendingPathComponent(id.uuidString + ".evidence"),
    to: fixture.location(id))
  #expect(try await fixture.store.matchingRecordIDs(captureID: firstCapture).isEmpty)
  #expect(
    try await fixture.store.matchingRecordIDs(
      captureID: secondCapture, recordKind: "selfieCapture") == [id])
}

@Test func unknownCorruptEvidenceFailsClosedRatherThanInventingItsScope() async throws {
  let fixture = try IndexFixture()
  defer { fixture.remove() }
  let capture = UUID()
  _ = try await fixture.store(capture: capture, kind: "extraction")
  _ = try await fixture.store.matchingRecordIDs(captureID: capture)
  try Data([1]).write(to: fixture.location(UUID()))
  await #expect(throws: (any Error).self) {
    try await fixture.store.matchingRecordIDs(captureID: capture)
  }
}

struct IndexFixture {
  let directory: URL
  let key: SymmetricKey
  let store: CaptureEvidenceStore

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    key = SymmetricKey(size: .bits256)
    store = try CaptureEvidenceStore(directory: directory, key: key)
  }

  func store(capture: UUID, session: UUID? = nil, kind: String) async throws -> UUID {
    let id = UUID()
    try await store.store(
      id: id, original: Data(repeating: 7, count: 1024),
      manifest: manifest(capture: capture, session: session, kind: kind))
    return id
  }

  func manifest(capture: UUID, session: UUID? = nil, kind: String) throws -> Data {
    var fields: [String: Any] = ["captureID": capture.uuidString, "recordKind": kind]
    if let session { fields["sessionID"] = ["rawValue": session.uuidString] }
    return try JSONSerialization.data(withJSONObject: fields)
  }

  func location(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString + ".evidence")
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
