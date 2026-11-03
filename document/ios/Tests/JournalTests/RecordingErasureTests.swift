import Foundation
import CaptureEvidenceCustody
import XCTest

@testable import DocumentCaptureJournal
@testable import DocumentCaptureApple

@MainActor
final class RecordingErasureTests: XCTestCase {
  func testAdmittedFrameCannotResurrectAfterCustodyRevocation() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store,
      clock: .fixture)
    let payload = Data([1, 2, 3, 4])
    let token = try XCTUnwrap(journal.reserveFrame(byteCount: payload.count))
    try await fixture.store.revokeAndRemoveAll()
    let frame = DocumentTemporalFrame(
      metadata: .init(
        sequenceNumber: 0,
        timestamp: .init(
          value: 1, timescale: 1, flags: 1, epoch: 0,
          clock: .captureSessionSynchronizationClock), hostTimeSeconds: 1,
        width: 1, height: 1, pixelFormat: 1,
        planes: [
          .init(
            offset: 0, byteCount: 4, width: 1, height: 1,
            sourceBytesPerRow: 4, packedBytesPerRow: 4)
        ],
        sha256: CapturePayloadIntegrity.sha256(payload), colorAttachmentsPlist: nil,
        geometry: nil, camera: nil), payload: payload)
    journal.appendFrame(frame, reservation: token)
    do {
      _ = try await journal.finish(reason: "completed")
      XCTFail("Revoked custody accepted delayed frame publication")
    } catch {}
    XCTAssertEqual(journal.status, "failed")
    do {
      _ = try await fixture.store.list()
      XCTFail("Revoked custody enumerated evidence")
    } catch CaptureEvidenceStoreError.custodyRevoked {}
  }

  func testAdmittedStillWaiterFailsAfterErasureInsteadOfAcknowledgingPublication() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store,
      clock: .fixture)
    let token = try XCTUnwrap(journal.reserveMilestone())
    try await fixture.store.revokeAndRemoveAll()
    do {
      try await journal.appendStillRetained(
        .init(kind: "still_retained", hostTimeSeconds: 1),
        reservation: token)
      XCTFail("Revoked custody acknowledged a still milestone")
    } catch {}
    XCTAssertEqual(journal.status, "failed")
    do {
      _ = try await fixture.store.list()
      XCTFail("Revoked custody enumerated evidence")
    } catch CaptureEvidenceStoreError.custodyRevoked {}
  }
}
