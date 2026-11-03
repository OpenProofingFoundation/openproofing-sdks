import CryptoKit
import Foundation
import Testing

@testable import CaptureEvidenceCustody

@Test func nativePayloadQueriesAndColdRebuildNeverReadUnrelatedPixels() async throws {
  let fixture = try BinaryFixture()
  defer { fixture.remove() }
  let target = UUID()
  let originalID = UUID()
  let originalManifest = Data(
    "{\"captureID\":\"\(originalID)\",\"profile\":\"front\",\"fidelity\":{}}".utf8)
  try await fixture.store.store(id: originalID, original: Data([1]), manifest: originalManifest)
  let native = Data(repeating: 0x73, count: 18_000_000)
  for _ in 0..<4 {
    let id = UUID()
    try await fixture.store.store(
      id: id, original: native,
      manifest: Data(
        "{\"recordKind\":\"journeyRecordingFrame\",\"recordingID\":\"\(target)\"}".utf8))
    let before = await fixture.store.authenticatedReadCount
    #expect(try await fixture.store.originalRecordIDs() == [originalID])
    #expect(try await fixture.store.matchingRecordIDs(captureID: originalID) == [originalID])
    #expect(await fixture.store.authenticatedReadCount == before)
    let size = try fixture.location(id).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    #expect(size < native.count + 8192)
  }
  try await fixture.store.checkpointMetadataIndex()
  try FileManager.default.removeItem(at: CaptureEvidenceIndex.location(fixture.directory))
  let reopened = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await reopened.originalRecordIDs() == [originalID])
  #expect(await reopened.authenticatedReadCount == 0)
  #expect(await reopened.authenticatedMetadataReadCount == 5)
}

@Test func concurrentNativePublicationAndStillQueriesStayPayloadIndependent() async throws {
  let fixture = try BinaryFixture()
  defer { fixture.remove() }
  let originalID = UUID()
  try await fixture.store.store(
    id: originalID, original: Data([1]),
    manifest: Data("{\"captureID\":\"\(originalID)\",\"profile\":\"front\",\"fidelity\":{}}".utf8))
  let payload = Data(repeating: 6, count: 18_000_000)
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
      for _ in 0..<4 {
        try await fixture.store.store(
          id: UUID(), original: payload,
          manifest: Data("{\"recordKind\":\"journeyRecordingFrame\"}".utf8))
        await Task.yield()
      }
    }
    group.addTask {
      for _ in 0..<20 {
        let candidates = try await fixture.store.originalRecordIDs()
        #expect(candidates == [originalID])
        await Task.yield()
      }
    }
    try await group.waitForAll()
  }
  #expect(await fixture.store.authenticatedReadCount == 5)
}

@Test func binaryMetadataAndPayloadAreBoundAndTruncationFails() async throws {
  let fixture = try BinaryFixture()
  defer { fixture.remove() }
  let id = UUID()
  try await fixture.store.store(
    id: id, original: Data(repeating: 5, count: 128), manifest: Data([7]))
  let path = fixture.location(id)
  let original = try Data(contentsOf: path)
  for corrupted in [Data(original.dropLast()), Data(original.prefix(11))] {
    try corrupted.write(to: path)
    await #expect(throws: (any Error).self) { try await fixture.store.metadata(id: id) }
  }
  var payloadCorruption = original
  payloadCorruption[payloadCorruption.count - 1] ^= 1
  try payloadCorruption.write(to: path)
  #expect(try await fixture.store.metadata(id: id) == Data([7]))
  await #expect(throws: (any Error).self) { try await fixture.store.read(id: id) }
  var metadataCorruption = original
  metadataCorruption[20] ^= 1
  try metadataCorruption.write(to: path)
  await #expect(throws: (any Error).self) { try await fixture.store.metadata(id: id) }
}

@Test func payloadCannotBeSplicedUnderDifferentMetadataForSameIdentity() async throws {
  let fixture = try BinaryFixture()
  defer { fixture.remove() }
  let id = UUID()
  try await fixture.store.store(
    id: id, original: Data(repeating: 1, count: 128), manifest: Data([7]))
  let alternate = fixture.directory.appendingPathComponent("alternate")
  try CaptureEvidenceEnvelope.write(
    record: .init(
      id: id, original: Data(repeating: 2, count: 128),
      manifest: Data([8])), key: fixture.key, to: alternate, expectedSHA256: nil)
  let first = try Data(contentsOf: fixture.location(id))
  let second = try Data(contentsOf: alternate)
  let firstHandle = try FileHandle(forReadingFrom: fixture.location(id))
  let secondHandle = try FileHandle(forReadingFrom: alternate)
  defer {
    try? firstHandle.close()
    try? secondHandle.close()
  }
  let firstDecoded = try CaptureEvidenceEnvelope.header(
    id: id, key: fixture.key, handle: firstHandle)
  let firstHeader = try #require(firstDecoded)
  let secondDecoded = try CaptureEvidenceEnvelope.header(
    id: id, key: fixture.key, handle: secondHandle)
  let secondHeader = try #require(secondDecoded)
  let forged =
    first.prefix(Int(firstHeader.payloadOffset)) + second.dropFirst(Int(secondHeader.payloadOffset))
  try forged.write(to: fixture.location(id))
  #expect(try await fixture.store.metadata(id: id) == Data([7]))
  await #expect(throws: (any Error).self) { try await fixture.store.read(id: id) }
}

@Test func legacyV1RemainsReadableAndColdIndexAuthenticatesIt() async throws {
  let fixture = try BinaryFixture()
  defer { fixture.remove() }
  struct Legacy: Encodable {
    let version = 1
    let id: UUID
    let original: Data
    let manifest: Data
    let digest: String
  }
  let id = UUID()
  let original = Data([1, 2, 3])
  let manifest = Data("{\"captureID\":\"\(id)\"}".utf8)
  let legacy = Legacy(
    id: id, original: original, manifest: manifest,
    digest: CaptureEvidenceEnvelope.hash(original))
  let sealed = try AES.GCM.seal(
    JSONEncoder().encode(legacy), using: fixture.key,
    authenticating: Data(("IdentityEvidenceStorage/v1/" + id.uuidString).utf8))
  try #require(sealed.combined).write(to: fixture.location(id))
  #expect(try await fixture.store.metadata(id: id) == manifest)
  #expect(try await fixture.store.read(id: id).original == original)
  #expect(try await fixture.store.matchingRecordIDs(captureID: id) == [id])
}

@Test func openingAnotherStoreCannotDeleteAnInFlightEncryptedPublication() async throws {
  let fixture = try BinaryFixture()
  defer { fixture.remove() }
  let id = UUID()
  let prepared = fixture.directory.appendingPathComponent("prepared")
  try CaptureEvidenceEnvelope.write(
    record: .init(
      id: id, original: Data(repeating: 3, count: 4096),
      manifest: Data([7])), key: fixture.key, to: prepared, expectedSHA256: nil)
  let bytes = try Data(contentsOf: prepared)
  let staging = fixture.directory.appendingPathComponent(UUID().uuidString + ".staging")
  let half = bytes.count / 2
  try bytes.prefix(half).write(to: staging)
  let writer = try FileHandle(forWritingTo: staging)
  defer { try? writer.close() }
  let other = try CaptureEvidenceStore(directory: fixture.directory, key: fixture.key)
  #expect(try await other.matchingRecordIDs().isEmpty)
  try writer.seekToEnd()
  try writer.write(contentsOf: bytes.dropFirst(half))
  try writer.synchronize()
  try FileManager.default.moveItem(at: staging, to: fixture.location(id))
  #expect(try await other.read(id: id).original == Data(repeating: 3, count: 4096))
}

@Test func declaredFrameHashMismatchRefusesPublication() async throws {
  let fixture = try BinaryFixture()
  defer { fixture.remove() }
  let id = UUID()
  await #expect(throws: (any Error).self) {
    try await fixture.store.store(
      id: id, original: Data([1]), manifest: Data([2]),
      expectedSHA256: String(repeating: "0", count: 64))
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.location(id).path))
}

@Test func declaredFrameHashIsSealedOnlyWhenTrueAndWellFormed() async throws {
  let fixture = try BinaryFixture()
  defer { fixture.remove() }
  let original = Data(repeating: 4, count: 512)
  let digest = CaptureEvidenceEnvelope.hash(original)
  for malformed in [digest.uppercased(), String(digest.dropLast()), digest + "0", ""] {
    let id = UUID()
    await #expect(throws: CaptureEvidenceStoreError.integrityFailure) {
      try await fixture.store.store(
        id: id, original: original, manifest: Data([2]), expectedSHA256: malformed)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.location(id).path))
  }
  let id = UUID()
  try await fixture.store.store(
    id: id, original: original, manifest: Data([2]), expectedSHA256: digest)
  #expect(try await fixture.store.read(id: id).original == original)
  let staged = try FileManager.default.contentsOfDirectory(
    at: fixture.directory, includingPropertiesForKeys: nil)
  #expect(!staged.contains { $0.pathExtension == "staging" })
}

private struct BinaryFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let key = SymmetricKey(size: .bits256)
  let store: CaptureEvidenceStore
  init() throws { store = try CaptureEvidenceStore(directory: directory, key: key) }
  func location(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".evidence") }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}
