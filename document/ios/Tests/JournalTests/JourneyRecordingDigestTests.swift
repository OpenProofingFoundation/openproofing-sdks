import Foundation
import XCTest

@testable import DocumentCaptureJournal
@testable import DocumentCaptureApple
@testable import CaptureEvidenceCustody

/// Counts SHA-256 work over one frame's bytes on the journal write path. The frame arrives already
/// digested (DocumentTemporalPixelCopy computes metadata.sha256 at copy time), so the only digest
/// the write path may compute over those bytes is the post-publication disk read-back fence.
@MainActor
final class JourneyRecordingDigestTests: XCTestCase {
  /// Distinct from every manifest, sealed-metadata, event, motion and seal size in this recording,
  /// so the observer's byte count identifies frame-payload digests exactly.
  private static let frameBytes = 16_411

  func testAppendedFrameIsDigestedOnlyByTheDiskReadbackFence() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let value = frame()
    let readsBefore = await fixture.store.authenticatedReadCount
    let digests = DigestCounter()
    let receipt = try await CaptureEvidenceEnvelope.$digestObserver.withValue(digests.observe) {
      let token = try XCTUnwrap(journal.reserveFrame(byteCount: value.payload.count))
      journal.appendFrame(value, reservation: token)
      return try await journal.finish(reason: "operator_stop")
    }
    XCTAssertEqual(receipt.frameCount, 1)
    // Before: 2 (CaptureEvidenceEnvelope.write re-hashed the in-memory bytes to compare with
    // expectedSHA256, then CaptureEvidenceEnvelope.payload hashed the decrypted read-back).
    XCTAssertEqual(digests.count(ofByteCount: Self.frameBytes), 1)
    // One deliberate read-back per published record (frame and seal): the publication fence.
    let readsAfter = await fixture.store.authenticatedReadCount
    XCTAssertEqual(readsAfter - readsBefore, 2)
  }

  func testUndeclaredPublicationStillDigestsOnWrite() async throws {
    // The nil-expectation path is unchanged: the envelope has no digest to carry, so it computes
    // one, and the read-back verifies it. This is the per-frame cost the journal paid before.
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let payload = Data(repeating: 9, count: Self.frameBytes)
    let digests = DigestCounter()
    try await CaptureEvidenceEnvelope.$digestObserver.withValue(digests.observe) {
      try await fixture.store.store(id: UUID(), original: payload, manifest: Data([1]))
    }
    XCTAssertEqual(digests.count(ofByteCount: Self.frameBytes), 2)
  }

  func testRecordWrittenWithDeclaredDigestVerifiesAndCorruptionIsRejected() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let value = frame()
    journal.appendFrame(
      value, reservation: try XCTUnwrap(journal.reserveFrame(byteCount: value.payload.count)))
    _ = try await journal.finish(reason: "operator_stop")
    let result = try await CaptureRecordingVerification.verify(
      journal.reference, store: fixture.reopen())
    XCTAssertEqual(result.status, "partial")
    XCTAssertEqual(result.ids.count, 3)

    let frameIDs = try await fixture.store.matchingRecordIDs(
      recordKind: "journeyRecordingFrame", recordingID: journal.recordingID)
    let id = try XCTUnwrap(frameIDs.first)
    let location = fixture.directory.appendingPathComponent(id.uuidString + ".evidence")
    let intact = try Data(contentsOf: location)
    let stored = try await fixture.store.read(id: id)
    XCTAssertEqual(stored.original, value.payload)

    // Ciphertext corruption: the envelope's authenticated decrypt refuses it.
    var flipped = intact
    flipped[flipped.count - 20] ^= 1
    try flipped.write(to: location)
    await assertVerificationFails(journal.reference, store: try fixture.reopen())

    // A well-formed envelope under the same identity and manifest carrying different bytes: the
    // envelope is self-consistent, so only the journal's manifest digest can reject it.
    try FileManager.default.removeItem(at: location)
    var substituted = value.payload
    substituted[0] ^= 0xFF
    try CaptureEvidenceEnvelope.write(
      record: .init(id: id, original: substituted, manifest: stored.manifest),
      key: fixture.key, to: location, expectedSHA256: nil)
    await assertVerificationFails(journal.reference, store: try fixture.reopen())

    try intact.write(to: location)
    _ = try await CaptureRecordingVerification.verify(journal.reference, store: fixture.reopen())
  }

  func testFrameWhoseDeclaredDigestIsFalseIsNeverPublished() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let honest = frame()
    let lying = DocumentTemporalFrame(
      metadata: honest.metadata,
      payload: Data(repeating: 1, count: honest.payload.count))
    journal.appendFrame(
      lying, reservation: try XCTUnwrap(journal.reserveFrame(byteCount: lying.payload.count)))
    do {
      _ = try await journal.finish(reason: "operator_stop")
      XCTFail("A frame whose bytes do not match its declared digest was published")
    } catch {}
    XCTAssertEqual(journal.status, "failed")
    let frames = try await fixture.store.matchingRecordIDs(
      recordKind: "journeyRecordingFrame", recordingID: journal.recordingID)
    XCTAssertTrue(frames.isEmpty)
    let staging = try FileManager.default.contentsOfDirectory(
      at: fixture.directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "staging" }
    XCTAssertTrue(staging.isEmpty)
  }

  private func assertVerificationFails(
    _ reference: CaptureRecordingReference, store: CaptureEvidenceStore,
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      _ = try await CaptureRecordingVerification.verify(reference, store: store)
      XCTFail("Corrupted frame payload accepted", file: file, line: line)
    } catch {}
  }

  private func frame() -> DocumentTemporalFrame {
    var payload = Data(count: Self.frameBytes)
    for index in payload.indices { payload[index] = UInt8(truncatingIfNeeded: index &* 31) }
    let metadata = DocumentTemporalFrameMetadata(
      sequenceNumber: 0,
      timestamp: .init(
        value: 1, timescale: 1, flags: 1, epoch: 0, clock: .captureSessionSynchronizationClock),
      hostTimeSeconds: 1, width: Self.frameBytes, height: 1, pixelFormat: 1,
      planes: [
        .init(
          offset: 0, byteCount: Self.frameBytes, width: Self.frameBytes, height: 1,
          sourceBytesPerRow: Self.frameBytes, packedBytesPerRow: Self.frameBytes)
      ],
      sha256: CapturePayloadIntegrity.sha256(payload), colorAttachmentsPlist: nil, geometry: nil,
      camera: nil)
    return .init(metadata: metadata, payload: payload)
  }
}

private final class DigestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var sizes: [Int] = []
  var observe: @Sendable (Int) -> Void { { [self] size in lock.withLock { sizes.append(size) } } }
  func count(ofByteCount size: Int) -> Int { lock.withLock { sizes.filter { $0 == size }.count } }
}
