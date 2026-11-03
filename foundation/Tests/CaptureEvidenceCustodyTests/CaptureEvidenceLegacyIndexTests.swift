import CryptoKit
import Foundation
import Testing

@testable import CaptureEvidenceCustody

@Test func authenticatedV2IndexKeepsLargeLegacyPayloadsOutOfStartupQueries() async throws {
  let fixture = try LegacyIndexFixture()
  defer { fixture.remove() }
  let capture = UUID()
  let recording = UUID()
  let first = try fixture.publishLegacy(capture: capture, recording: nil, original: true)
  let frame = try fixture.publishLegacy(capture: nil, recording: recording, original: false)
  try fixture.index(version: 2, entries: [first.0: first.1, frame.0: frame.1])
  let store = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await store.matchingRecordIDs(captureID: capture) == [first.0])
  #expect(try await store.matchingRecordIDs(recordingID: recording) == [frame.0])
  #expect(try await store.originalRecordIDs() == [first.0])
  #expect(await store.authenticatedReadCount == 0)
  #expect(await store.authenticatedMetadataReadCount == 0)
  _ = try await store.read(id: first.0)
  #expect(await store.authenticatedReadCount == 1)
}

@Test func v1IndexPreservesKnownFieldsAndEnrichesRecordingSelectorOnlyWhenRequested() async throws {
  let fixture = try LegacyIndexFixture()
  defer { fixture.remove() }
  let capture = UUID()
  let recording = UUID()
  let record = try fixture.publishLegacy(capture: capture, recording: recording, original: false)
  var old = record.1
  old.recordingID = nil
  try fixture.index(version: 1, entries: [record.0: old])
  let store = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await store.matchingRecordIDs(captureID: capture) == [record.0])
  #expect(await store.authenticatedReadCount == 0)
  #expect(try await store.matchingRecordIDs(recordingID: recording) == [record.0])
  #expect(await store.authenticatedReadCount == 1)
}

private struct LegacyIndexFixture {
  // Historical entries are write-only fixtures; absent sessionID must remain omitted.
  struct Entry: Encodable {
    let fingerprint: CaptureEvidenceIndex.Fingerprint
    let captureID: UUID?
    let sessionID: UUID? = nil
    let recordKind: String?
    var recordingID: UUID?
  }
  struct Index: Encodable {
    let version: Int
    let entries: [UUID: Entry]
  }
  struct Envelope: Encodable {
    let version = 1
    let id: UUID
    let original: Data
    let manifest: Data
    let digest: String
  }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let key = SymmetricKey(size: .bits256)
  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func publishLegacy(capture: UUID?, recording: UUID?, original: Bool) throws -> (UUID, Entry) {
    let id = original ? capture ?? UUID() : UUID()
    var fields: [String: Any] = [:]
    if let capture { fields["captureID"] = capture.uuidString }
    if let recording { fields["recordingID"] = recording.uuidString }
    if original {
      fields["profile"] = "front"
      fields["fidelity"] = [:] as [String: String]
    } else {
      fields["recordKind"] = "journeyRecordingFrame"
    }
    let manifest = try JSONSerialization.data(withJSONObject: fields)
    let payload = Data(repeating: 0x51, count: 18_000_000)
    let value = Envelope(
      id: id, original: payload, manifest: manifest, digest: CaptureEvidenceEnvelope.hash(payload))
    let box = try AES.GCM.seal(
      JSONEncoder().encode(value), using: key,
      authenticating: Data(("IdentityEvidenceStorage/v1/" + id.uuidString).utf8))
    let encoded = try #require(box.combined)
    let path = directory.appendingPathComponent(id.uuidString + ".evidence")
    try encoded.write(to: path)
    return (
      id,
      Entry(
        fingerprint: try .init(url: path), captureID: capture,
        recordKind: original ? nil : "journeyRecordingFrame", recordingID: recording)
    )
  }

  func index(version: Int, entries: [UUID: Entry]) throws {
    for entry in entries.values {
      let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
      #expect(object["sessionID"] == nil)
    }
    let box = try AES.GCM.seal(
      JSONEncoder().encode(Index(version: version, entries: entries)), using: key,
      authenticating: Data("IdentityEvidenceStorage/metadata-index/v1".utf8))
    let encoded = try #require(box.combined)
    try encoded.write(to: CaptureEvidenceIndex.location(directory))
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
