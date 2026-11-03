import CryptoKit
import Foundation
import Testing

@testable import CaptureEvidenceCustody

@Suite struct CaptureCompletedResultTests {
  @Test func restartRestoresTypedResultAndNativeArtifactsWithoutPlaintextIndex() async throws {
    let fixture = try ResultFixture()
    defer { fixture.remove() }
    let bytes = Data("sensitive-native-portrait".utf8)
    let artifact = try CaptureResultArtifact(
      id: UUID(), role: "portrait", mediaType: "image/png", data: bytes)
    let saved = try await fixture.commit("original", artifacts: [artifact])
    let reopened = try fixture.reopen()
    let restored = try #require(
      try await reopened.completedResult(
        workflowID: fixture.workflowID, kind: "test-result-v1", as: String.self))
    #expect(restored.descriptor == saved.descriptor)
    #expect(restored.payload == "original")
    let link = try #require(restored.descriptor.artifacts.first)
    #expect(
      try await reopened.completedResultArtifact(
        resultID: restored.descriptor.id, artifactID: link.id, expectedSHA256: link.sha256) == bytes
    )
    #expect(try await reopened.completedResults() == [saved.descriptor])
    let files = try FileManager.default.contentsOfDirectory(
      at: fixture.directory, includingPropertiesForKeys: nil)
    for file in files {
      let disk = try Data(contentsOf: file)
      #expect(disk.range(of: bytes) == nil)
      #expect(disk.range(of: Data("original".utf8)) == nil)
    }
  }

  @Test func twoFacadesCannotPublishTheSameRevision() async throws {
    let fixture = try ResultFixture()
    defer { fixture.remove() }
    _ = try await fixture.commit("original")
    let other = try fixture.reopen()
    async let first = tryPublish(fixture.store, fixture: fixture, value: "one")
    async let second = tryPublish(other, fixture: fixture, value: "two")
    let outcomes = await [first, second]
    #expect(outcomes.filter { $0 }.count == 1)
    let latest = try #require(
      try await other.completedResult(
        workflowID: fixture.workflowID, kind: "test-result-v1", as: String.self))
    #expect(latest.descriptor.revision == 2)
    #expect(["one", "two"].contains(latest.payload))
  }

  @Test func cancelledRetryBeforePublicationPreservesCompletedResult() async throws {
    let fixture = try ResultFixture()
    defer { fixture.remove() }
    let previous = try await fixture.commit("original")
    let retry = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await fixture.commit("cancelled", expectedRevision: 1)
    }
    await #expect(throws: CancellationError.self) { try await retry.value }
    #expect(try await fixture.store.completedResults() == [previous.descriptor])
  }

  @Test func cancellationAfterPublicationRecoversCommittedResultAfterLostReply() async throws {
    let fixture = try ResultFixture()
    defer { fixture.remove() }
    _ = try await fixture.commit("original")
    let retry = Task {
      _ = try await fixture.commit("committed-before-cancellation", expectedRevision: 1)
      withUnsafeCurrentTask { $0?.cancel() }
      try Task.checkCancellation()
    }
    await #expect(throws: CancellationError.self) { try await retry.value }
    let reopened = try fixture.reopen()
    let latest = try #require(
      try await reopened.completedResult(
        workflowID: fixture.workflowID, kind: "test-result-v1", as: String.self))
    #expect(latest.descriptor.revision == 2)
    #expect(latest.payload == "committed-before-cancellation")
  }

  @Test func failedPublicationHasNoOrphanOrNewLatestRevision() async throws {
    let fixture = try ResultFixture()
    defer { fixture.remove() }
    let previous = try await fixture.commit("original")
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
    }
    await #expect(throws: (any Error).self) {
      try await fixture.store.commitCompletedResult(
        workflowID: fixture.workflowID, kind: "test-result-v1",
        payload: WriteDeniedPayload(directory: fixture.directory), artifacts: [],
        recordedAt: fixture.date, expectedRevision: 1)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
    #expect(try await fixture.store.completedResults() == [previous.descriptor])
    #expect(try await fixture.store.list() == [previous.descriptor.id])
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: fixture.directory, includingPropertiesForKeys: nil
      ).allSatisfy { $0.pathExtension != "staging" })
  }

  @Test func tamperingCannotFallBackToOlderSuccessOrSubstituteArtifact() async throws {
    let fixture = try ResultFixture()
    defer { fixture.remove() }
    let artifact = try CaptureResultArtifact(
      id: UUID(), role: "selfie", mediaType: "image/png", data: Data([1, 2]))
    _ = try await fixture.commit("original")
    let latest = try await fixture.commit("latest", artifacts: [artifact], expectedRevision: 1)
    await #expect(throws: CaptureCompletedResultError.invalidArtifact) {
      try await fixture.store.completedResultArtifact(
        resultID: latest.descriptor.id, artifactID: artifact.id,
        expectedSHA256: String(repeating: "0", count: 64))
    }
    let path = fixture.directory.appendingPathComponent(
      latest.descriptor.id.uuidString + ".evidence")
    var bytes = try Data(contentsOf: path)
    bytes[bytes.count - 1] ^= 1
    try bytes.write(to: path)
    await #expect(throws: (any Error).self) {
      try await fixture.store.completedResult(
        workflowID: fixture.workflowID, kind: "test-result-v1", as: String.self)
    }
  }

  @Test func clearRetainsGenerationButEraseRevokesDelayedCompletions() async throws {
    let fixture = try ResultFixture()
    defer { fixture.remove() }
    _ = try await fixture.commit("original")
    try await fixture.store.removeAll()
    #expect(try await fixture.store.completedResults().isEmpty)
    _ = try await fixture.commit("after-clear")
    try await fixture.store.revokeAndRemoveAll()
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await fixture.commit("late-publisher")
    }
    let reopened = try fixture.reopen()
    await #expect(throws: CaptureEvidenceStoreError.custodyRevoked) {
      try await reopened.completedResults()
    }
  }

  private func tryPublish(_ store: CaptureEvidenceStore, fixture: ResultFixture, value: String)
    async -> Bool
  {
    do {
      _ = try await store.commitCompletedResult(
        workflowID: fixture.workflowID, kind: "test-result-v1", payload: value, artifacts: [],
        recordedAt: fixture.date, expectedRevision: 1)
      return true
    } catch { return false }
  }
}

private struct ResultFixture: Sendable {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let key = SymmetricKey(size: .bits256)
  let workflowID = UUID()
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let store: CaptureEvidenceStore
  init() throws { store = try CaptureEvidenceStore(directory: directory, key: key) }
  func reopen() throws -> CaptureEvidenceStore {
    try CaptureEvidenceStore(directory: directory, key: key)
  }
  func commit(
    _ value: String, artifacts: [CaptureResultArtifact] = [], expectedRevision: UInt64? = nil
  )
    async throws -> CaptureCompletedResult<String>
  {
    try await store.commitCompletedResult(
      workflowID: workflowID, kind: "test-result-v1", payload: value, artifacts: artifacts,
      recordedAt: date, expectedRevision: expectedRevision)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private struct WriteDeniedPayload: Codable, Sendable {
  let directory: URL
  func encode(to encoder: Encoder) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    var value = encoder.singleValueContainer()
    try value.encode("write-denied")
  }
}
