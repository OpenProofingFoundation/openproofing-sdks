import Foundation
import CaptureEvidenceCustody
import XCTest

@testable import DocumentCaptureJournal
@testable import DocumentCaptureApple

@MainActor
final class JourneyRecordingJournalTests: XCTestCase {
  func testReservedFrameDrainsBeforeFinishAndReopens() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let frame = frame()
    let token = try XCTUnwrap(journal.reserveFrame(byteCount: frame.payload.count))
    let finish = Task { try await journal.finish(reason: "operator_stop") }
    await Task.yield()
    journal.appendFrame(frame, reservation: token)
    let receipt = try await finish.value
    XCTAssertEqual(receipt.frameCount, 1)
    XCTAssertEqual(receipt.status, "partial")
    let reopened = try fixture.reopen()
    let result = try await CaptureRecordingVerification.verify(journal.reference, store: reopened)
    XCTAssertEqual(result.status, "partial")
    XCTAssertEqual(result.ids.count, 3)
  }

  func testBackpressureIsNonterminalAndExplicit() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture, maximumPendingBytes: 3)
    XCTAssertNil(journal.reserveFrame(byteCount: 4))
    XCTAssertEqual(journal.status, "recording")
    let receipt = try await journal.finish(reason: "completed")
    XCTAssertEqual(receipt.status, "partial")
    let result = try await CaptureRecordingVerification.verify(
      journal.reference, store: fixture.store)
    XCTAssertEqual(result.status, "partial")
  }

  func testUnsealedJournalRecoversAsInterrupted() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let result = try await CaptureRecordingVerification.verify(
      journal.reference, store: fixture.store)
    XCTAssertEqual(result.status, "interrupted")
    _ = try await journal.finish(reason: "test_cleanup")
  }

  func testMissingChainRecordFailsVerification() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let frame = frame()
    journal.appendFrame(
      frame, reservation: try XCTUnwrap(journal.reserveFrame(byteCount: frame.payload.count)))
    _ = try await journal.finish(reason: "operator_stop")
    let ids = try await fixture.store.matchingRecordIDs(
      recordKind: "journeyRecordingFrame",
      recordingID: journal.recordingID)
    let id = try XCTUnwrap(ids.first)
    try FileManager.default.removeItem(
      at: fixture.directory.appendingPathComponent(id.uuidString + ".evidence"))
    do {
      _ = try await CaptureRecordingVerification.verify(journal.reference, store: fixture.store)
      XCTFail("Missing chain entry accepted")
    } catch {}
  }

  func testDuplicateSubmissionNeverReleasesOwnedReservation() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let frame = frame()
    let token = try XCTUnwrap(journal.reserveFrame(byteCount: frame.payload.count))
    journal.appendFrame(frame, reservation: token)
    journal.appendFrame(frame, reservation: token)
    let result = try await journal.finish(reason: "completed")
    XCTAssertEqual(result.frameCount, 1)
    XCTAssertEqual(result.status, "partial")
    _ = try await CaptureRecordingVerification.verify(journal.reference, store: fixture.store)
  }

  func testForgedCompleteWithoutObservationsRejected() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let seal = CaptureRecordingSeal(
      status: "complete", reason: "completed",
      frameCount: 0, motionSampleCount: 0, issueCount: 0, retainedStillCount: 0,
      refusedFrames: 0, refusedMotionSamples: 0)
    let data = try JSONEncoder().encode(seal)
    let link = CaptureRecordingLink(
      schemaVersion: 1, recordKind: "journeyRecordingSeal",
      recordingID: journal.recordingID, workflowID: journal.reference.workflowID, ordinal: 1,
      previousID: journal.recordingID, previousSHA256: journal.reference.startSHA256,
      payloadSHA256: CapturePayloadIntegrity.sha256(data), frame: nil)
    try await fixture.store.store(id: UUID(), original: data, manifest: JSONEncoder().encode(link))
    do {
      _ = try await CaptureRecordingVerification.verify(journal.reference, store: fixture.store)
      XCTFail("Empty complete seal accepted")
    } catch {}
  }

  func testCompleteJournalIncludesEveryRetainedStillForExport() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let workflow = UUID()
    let journal = try await CaptureRecordingJournal.start(
      workflowID: workflow, store: fixture.store, clock: .fixture)
    var originals: Set<UUID> = []
    for profile in [RecordingFixture.Profile.licenseFront, .licenseFront, .licenseBack] {
      var manifest = try fixture.manifest(profile: profile, workflowID: workflow)
      manifest.journeyRecording = journal.reference
      try await fixture.retain(manifest)
      originals.insert(manifest.captureID)
      journal.appendEvent(
        .init(
          kind: "still_retained", hostTimeSeconds: 1,
          binding: .init(
            sessionID: manifest.sessionID.rawValue.uuidString,
            attemptID: manifest.captureID.uuidString, side: profile.side.rawValue,
            stillSHA256: manifest.fidelity.sha256, stillTimestamp: manifest.captureTimestamp,
            stillHostTimeSeconds: 1)))
    }
    let value = frame()
    journal.appendFrame(
      value, reservation: try XCTUnwrap(journal.reserveFrame(byteCount: value.payload.count)))
    journal.appendMotion(
      .init(
        bootTimeSeconds: 1, attitude: .init(x: 0, y: 0, z: 0, w: 1),
        rotationRate: .init(x: 0, y: 0, z: 0), gravity: .init(x: 0, y: 0, z: -1),
        userAcceleration: .init(x: 0, y: 0, z: 0), referenceFrame: "fixture"))
    let receipt = try await journal.finish(reason: "completed")
    XCTAssertEqual(receipt.status, "complete")
    let verified = try await CaptureRecordingVerification.verify(
      journal.reference, store: fixture.store)
    XCTAssertEqual(verified.stillIDs, originals)
    XCTAssertTrue(originals.isSubset(of: verified.ids))

  }

  func testWriterCannotParkAfterFinishArrivesAndSubmittedCancelKeepsBytes() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    journal.lock.withLock {
      XCTAssertTrue(journal.canParkWriter())
      journal.terminalReason = "operator_stop"
      XCTAssertFalse(journal.canParkWriter())
    }
    _ = try await journal.finish(reason: "operator_stop")
    let other = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let token = try XCTUnwrap(other.reserveFrame(byteCount: 4))
    other.lock.withLock { _ = other.submitted.insert(token) }
    other.cancelReservation(token, reason: "cancelled")
    other.lock.withLock {
      XCTAssertEqual(other.pendingBytes, 4)
      XCTAssertEqual(other.reservations[token], 4)
      other.submitted.remove(token)
    }
    other.cancelReservation(token, reason: "cancelled")
    _ = try await other.finish(reason: "operator_stop")
  }

  func testDiskAndDurationCapsSealPartial() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let disk = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture, maximumDiskBytes: 65_537)
    let value = frame()
    disk.appendFrame(
      value, reservation: try XCTUnwrap(disk.reserveFrame(byteCount: value.payload.count)))
    let diskReceipt = try await disk.finish(reason: "completed")
    XCTAssertEqual(diskReceipt.status, "partial")
    XCTAssertEqual(diskReceipt.frameCount, 0)
    let seals = try await fixture.store.matchingRecordIDs(
      recordKind: "journeyRecordingSeal",
      recordingID: disk.recordingID)
    let storedSeal = try await fixture.store.read(id: XCTUnwrap(seals.first))
    let loss = try JSONDecoder().decode(CaptureRecordingSeal.self, from: storedSeal.original)
    XCTAssertEqual(loss.firstLossTimestamp, value.metadata.timestamp)
    XCTAssertEqual(loss.firstLossHostTimeSeconds, value.metadata.hostTimeSeconds)
    XCTAssertEqual(loss.firstLossReason, "frame_write_failed:disk_limit")
    XCTAssertEqual(loss.acquisitionDiagnostics?.frameRefusals["diskCapacity"], 1)
    XCTAssertNil(loss.acquisitionDiagnostics?.storeAwaitCalls["frame"])
    _ = try await CaptureRecordingVerification.verify(disk.reference, store: fixture.store)
    let timed = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture, maximumDuration: 0.001)
    try await Task.sleep(for: .milliseconds(5))
    XCTAssertNil(timed.reserveFrame(byteCount: 4))
    let timedReceipt = try await timed.finish(reason: "completed")
    XCTAssertEqual(timedReceipt.status, "partial")
  }

  func testStorageFailureCannotPublishSeal() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let value = frame()
    let token = try XCTUnwrap(journal.reserveFrame(byteCount: value.payload.count))
    try FileManager.default.removeItem(at: fixture.directory)
    try Data([1]).write(to: fixture.directory)
    journal.appendFrame(value, reservation: token)
    do {
      _ = try await journal.finish(reason: "completed")
      XCTFail("Failed storage published a successful seal")
    } catch {}
    XCTAssertEqual(journal.status, "failed")
  }

  func testIdleDeadlineSealsWithoutAnyCameraOrMotionCallbacks() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture, maximumDuration: 0.005)
    for _ in 0..<100 where journal.status != "partial" {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(journal.status, "partial")
    let result = try await CaptureRecordingVerification.verify(
      journal.reference, store: fixture.store)
    XCTAssertEqual(result.status, "partial")
  }

  func testSessionIssueTerminatesWithPartialSeal() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    journal.appendEvent(.init(kind: "session_issue", hostTimeSeconds: 1, contextCode: "interrupted"))
    let receipt = try await journal.finish(reason: "completed")
    XCTAssertEqual(receipt.status, "partial")
    let result = try await CaptureRecordingVerification.verify(
      journal.reference, store: fixture.store)
    XCTAssertEqual(result.status, "partial")
  }
}

extension JourneyRecordingJournalTests {
  func testTerminalEventFloodCannotExtendDrainAndMilestoneCanBeCancelled() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let milestone = try XCTUnwrap(journal.reserveMilestone())
    let pending = Task { try await journal.finish(reason: "operator_stop") }
    for _ in 0..<100 where journal.status == "recording" { await Task.yield() }
    XCTAssertEqual(journal.status, "stopping")
    for _ in 0..<1000 {
      journal.appendEvent(.init(kind: "frame_admission_failed", hostTimeSeconds: 1))
      journal.appendEvent(.init(kind: "geometry", hostTimeSeconds: 1))
    }
    journal.lock.withLock {
      XCTAssertTrue(journal.queue.isEmpty)
      XCTAssertEqual(journal.milestones, [milestone])
    }
    journal.cancelMilestone(milestone)
    let receipt = try await pending.value
    XCTAssertEqual(receipt.status, "partial")
    let ids = try await fixture.store.matchingRecordIDs(recordingID: journal.recordingID)
    XCTAssertEqual(ids.count, 3)
  }

  func testAlreadyReservedStillBindingPublishesAfterTerminalCutoff() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let workflow = UUID()
    let journal = try await CaptureRecordingJournal.start(
      workflowID: workflow, store: fixture.store, clock: .fixture)
    let token = try XCTUnwrap(journal.reserveMilestone())
    let pending = Task { try await journal.finish(reason: "operator_stop") }
    for _ in 0..<100 where journal.status == "recording" { await Task.yield() }
    var manifest = try fixture.manifest(profile: .licenseFront, workflowID: workflow)
    manifest.journeyRecording = journal.reference
    try await fixture.retain(manifest)
    try await journal.appendStillRetained(
      .init(
        kind: "still_retained", hostTimeSeconds: 1,
        binding: .init(
          sessionID: manifest.sessionID.rawValue.uuidString,
          attemptID: manifest.captureID.uuidString, side: manifest.profile.side.rawValue,
          stillSHA256: manifest.fidelity.sha256, stillTimestamp: manifest.captureTimestamp,
          stillHostTimeSeconds: 1)), reservation: token)
    _ = try await pending.value
    let result = try await CaptureRecordingVerification.verify(
      journal.reference, store: fixture.store)
    XCTAssertEqual(result.stillIDs, [manifest.captureID])
    XCTAssertEqual(result.status, "partial")
  }

  func testSealedCountersAndReceiptIgnoreAllLateCallbacks() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let receipt = try await journal.finish(reason: "operator_stop")
    let counts = journal.lock.withLock {
      [journal.refusedFrames, journal.refusedMotion, journal.issueCount]
    }
    for _ in 0..<100 {
      XCTAssertNil(journal.reserveFrame(byteCount: 4))
      journal.appendFrame(frame(), reservation: UUID())
      journal.cancelReservation(UUID(), reason: "late")
      journal.appendEvent(.init(kind: "geometry", hostTimeSeconds: 1))
      journal.appendMotion(
        .init(
          bootTimeSeconds: 1, attitude: .init(x: 0, y: 0, z: 0, w: 1),
          rotationRate: .init(x: 0, y: 0, z: 0), gravity: .init(x: 0, y: 0, z: -1),
          userAcceleration: .init(x: 0, y: 0, z: 0), referenceFrame: "fixture"))
    }
    XCTAssertEqual(
      journal.lock.withLock { [journal.refusedFrames, journal.refusedMotion, journal.issueCount] },
      counts)
    let repeated = try await journal.finish(reason: "completed")
    XCTAssertEqual(repeated, receipt)
  }

  private func frame() -> DocumentTemporalFrame {
    let payload = Data([1, 2, 3, 4])
    let metadata = DocumentTemporalFrameMetadata(
      sequenceNumber: 0,
      timestamp: .init(
        value: 1, timescale: 1, flags: 1, epoch: 0, clock: .captureSessionSynchronizationClock),
      hostTimeSeconds: 1, width: 1, height: 1, pixelFormat: 1,
      planes: [
        .init(
          offset: 0, byteCount: 4, width: 1, height: 1,
          sourceBytesPerRow: 4, packedBytesPerRow: 4)
      ],
      sha256: CapturePayloadIntegrity.sha256(payload), colorAttachmentsPlist: nil, geometry: nil,
      camera: nil)
    return .init(metadata: metadata, payload: payload)
  }
}
