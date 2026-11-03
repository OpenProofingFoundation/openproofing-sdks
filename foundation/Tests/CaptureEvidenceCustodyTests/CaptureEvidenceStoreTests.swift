import CryptoKit
import Foundation
import Testing

@testable import CaptureEvidenceCustody

@Test func encryptedArtifactSurvivesReopeningWithoutPlaintextOnDisk() async throws {
  let dir = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let key = SymmetricKey(size: .bits256)
  let id = UUID()
  let original = Data("synthetic-document-image-unique-payload".utf8)
  let manifest = Data("{\"role\":\"original\"}".utf8)
  let store = try CaptureEvidenceStore(directory: dir, key: key)
  try await store.store(id: id, original: original, manifest: manifest)
  let disk = try Data(contentsOf: dir.appendingPathComponent(id.uuidString + ".evidence"))
  #expect(disk.range(of: original) == nil)
  #expect(disk.range(of: manifest) == nil)
  let reopened = try CaptureEvidenceStore(directory: dir, key: key)
  let read = try await reopened.read(id: id)
  #expect(read.original == original && read.manifest == manifest)
  #expect(try await reopened.list() == [id])
}

@Test func wrongKeyAndModifiedCiphertextFailAuthentication() async throws {
  let dir = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let key = SymmetricKey(size: .bits256)
  let id = UUID()
  let store = try CaptureEvidenceStore(directory: dir, key: key)
  try await store.store(id: id, original: Data([1, 2, 3]), manifest: Data([4]))
  let wrong = try CaptureEvidenceStore(directory: dir, key: SymmetricKey(size: .bits256))
  await #expect(throws: (any Error).self) { try await wrong.read(id: id) }
  let path = dir.appendingPathComponent(id.uuidString + ".evidence")
  var bytes = try Data(contentsOf: path)
  bytes[bytes.count - 1] ^= 1
  try bytes.write(to: path)
  await #expect(throws: (any Error).self) { try await store.read(id: id) }
  await #expect(throws: (any Error).self) { try await store.list() }
}

@Test func artifactIdentityCannotBeSwappedAndDuplicatesCannotOverwrite() async throws {
  let dir = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let store = try CaptureEvidenceStore(directory: dir, key: SymmetricKey(size: .bits256))
  let first = UUID()
  let second = UUID()
  try await store.store(id: first, original: Data([1]), manifest: Data([2]))
  await #expect(throws: (any Error).self) {
    try await store.store(id: first, original: Data([3]), manifest: Data([4]))
  }
  #expect(try await store.read(id: first).original == Data([1]))
  try FileManager.default.copyItem(
    at: dir.appendingPathComponent(first.uuidString + ".evidence"),
    to: dir.appendingPathComponent(second.uuidString + ".evidence")
  )
  await #expect(throws: (any Error).self) { try await store.read(id: second) }
}

@Test func deletionAndUnknownIDNegativeControl() async throws {
  let dir = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let store = try CaptureEvidenceStore(directory: dir, key: SymmetricKey(size: .bits256))
  let id = UUID()
  try await store.store(id: id, original: Data([1]), manifest: Data([2]))
  await #expect(throws: (any Error).self) { try await store.read(id: UUID()) }
  try await store.removeAll()
  #expect(try await store.list().isEmpty)
  await #expect(throws: (any Error).self) { try await store.read(id: id) }
}

@Test func interruptedStagingIsNotPublished() async throws {
  let dir = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let staging = dir.appendingPathComponent(UUID().uuidString + ".staging")
  try Data([0, 1]).write(to: staging)
  let store = try CaptureEvidenceStore(directory: dir, key: SymmetricKey(size: .bits256))
  #expect(try await store.list().isEmpty)
  #expect(FileManager.default.fileExists(atPath: staging.path))
  try await store.removeAll()
  #expect(!FileManager.default.fileExists(atPath: staging.path))
}

private func temporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("capture-test-" + UUID().uuidString)
}
