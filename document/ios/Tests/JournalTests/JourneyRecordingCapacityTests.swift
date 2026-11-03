import Foundation
import CaptureEvidenceCustody
import XCTest

@testable import DocumentCaptureJournal
@testable import DocumentCaptureApple

@MainActor
final class JourneyRecordingCapacityTests: XCTestCase {
  func testTransientPressurePreservesFirstLossAndAcceptsLaterFrames() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture, maximumPendingBytes: 6)
    let held = try XCTUnwrap(journal.reserveFrame(byteCount: 6))
    XCTAssertNil(journal.reserveFrame(byteCount: 6))
    let timestamp = DocumentCaptureClockTimestamp(
      value: 123, timescale: 60, flags: 1,
      epoch: 0, clock: .captureSessionSynchronizationClock)
    journal.appendEvent(
      .init(
        kind: "frame_admission_failed", hostTimeSeconds: 2,
        timestamp: timestamp, contextCode: "sink_capacity_or_termination"))
    XCTAssertEqual(journal.status, "recording")
    journal.cancelReservation(held, reason: "test_release")
    let later = try XCTUnwrap(journal.reserveFrame(byteCount: 6))
    XCTAssertEqual(journal.status, "recording")
    journal.cancelReservation(later, reason: "test_release")
    let receipt = try await journal.finish(reason: "completed")
    XCTAssertEqual(receipt.status, "partial")
    let ids = try await fixture.store.matchingRecordIDs(
      recordKind: "journeyRecordingSeal",
      recordingID: journal.recordingID)
    let record = try await fixture.store.read(id: XCTUnwrap(ids.first))
    let seal = try JSONDecoder().decode(CaptureRecordingSeal.self, from: record.original)
    XCTAssertEqual(seal.firstLossTimestamp, timestamp)
    XCTAssertEqual(seal.refusedFrames, 3)
    _ = try await CaptureRecordingVerification.verify(journal.reference, store: fixture.store)
  }

  func testLastReservationCancellationAtomicallyRetainsLossBeforeSeal() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let token = try XCTUnwrap(journal.reserveFrame(byteCount: 6))
    let pending = Task { try await journal.finish(reason: "operator_stop") }
    for _ in 0..<100 where journal.status == "recording" { await Task.yield() }
    let timestamp = DocumentCaptureClockTimestamp(
      value: 77, timescale: 60, flags: 1,
      epoch: 0, clock: .captureSessionSynchronizationClock)
    journal.cancelReservation(
      token,
      failure: .init(
        kind: "frame_copy_failed", hostTimeSeconds: 2,
        timestamp: timestamp, contextCode: "injected_failure"))
    _ = try await pending.value
    let ids = try await fixture.store.matchingRecordIDs(
      recordKind: "journeyRecordingSeal",
      recordingID: journal.recordingID)
    let record = try await fixture.store.read(id: XCTUnwrap(ids.first))
    let seal = try JSONDecoder().decode(CaptureRecordingSeal.self, from: record.original)
    XCTAssertEqual(seal.firstLossTimestamp, timestamp)
    XCTAssertEqual(seal.firstLossReason, "frame_copy_failed:injected_failure")
    XCTAssertEqual(seal.refusedFrames, 1)
  }

  func testReservedMilestoneSurvivesOrdinaryDiskExhaustion() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let workflow = UUID()
    let journal = try await CaptureRecordingJournal.start(
      workflowID: workflow,
      store: fixture.store, clock: .fixture, maximumDiskBytes: 200_000)
    let token = try XCTUnwrap(journal.reserveMilestone())
    var original = try fixture.manifest(profile: .licenseFront, workflowID: workflow)
    original.journeyRecording = journal.reference
    try await fixture.retain(original)
    journal.appendEvent(
      .init(
        kind: "configuration_changed", hostTimeSeconds: 1,
        contextCode: String(repeating: "x", count: 40_000)))
    try await journal.appendStillRetained(event(original), reservation: token)
    let receipt = try await journal.finish(reason: "completed")
    XCTAssertEqual(receipt.status, "partial")
    let result = try await CaptureRecordingVerification.verify(
      journal.reference, store: fixture.store)
    XCTAssertTrue(result.stillIDs.contains(original.captureID))
    XCTAssertTrue(journal.lock.withLock { journal.milestones.isEmpty })
  }

  func testOversizeMilestoneFailsAcknowledgementInsteadOfSilentlyDropping() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let token = try XCTUnwrap(journal.reserveMilestone())
    do {
      try await journal.appendStillRetained(
        .init(
          kind: "still_retained", hostTimeSeconds: 1,
          contextCode: String(repeating: "x", count: 40_000)), reservation: token)
      XCTFail("Oversized reserved binding was silently acknowledged")
    } catch {}
    XCTAssertEqual(journal.status, "failed")
    XCTAssertTrue(journal.lock.withLock { journal.milestones.isEmpty })
  }

  func testStorageFailureResumesMilestoneWaiter() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let token = try XCTUnwrap(journal.reserveMilestone())
    try FileManager.default.removeItem(at: fixture.directory)
    try Data([1]).write(to: fixture.directory)
    do {
      try await journal.appendStillRetained(
        .init(kind: "still_retained", hostTimeSeconds: 1), reservation: token)
      XCTFail("Storage failure was acknowledged as durable")
    } catch {}
    XCTAssertEqual(journal.status, "failed")
  }

  func testExpiredMilestoneAdmissionImmediatelyNotifiesAndSchedules() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = CaptureRecordingJournal(
      reference: .init(recordingID: UUID(), workflowID: UUID(), startSHA256: "fixture"),
      store: fixture.store, clock: .fixture, maximumDuration: -1, maximumDiskBytes: 200_000,
      maximumPendingBytes: 6, startCharge: 0)
    let notified = expectation(description: "Terminal admission notified synchronously")
    journal.setStatusHandler { status in if status == "stopping" { notified.fulfill() } }
    XCTAssertNil(journal.reserveMilestone())
    await fulfillment(of: [notified], timeout: 1)
    _ = try await journal.finish(reason: "cleanup")
  }

  func testRepeatedLossesCannotReplenishPriorityQueueAheadOfAdmittedMilestone() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let token = try XCTUnwrap(journal.reserveMilestone())
    journal.appendEvent(.init(kind: "frame_admission_failed", hostTimeSeconds: 1))
    // Observe the first gap consumed, then emulate callbacks arriving between writer turns.
    for _ in 0..<1000 where journal.lock.withLock({ journal.pendingGap != nil }) {
      await Task.yield()
    }
    XCTAssertNil(journal.lock.withLock { journal.pendingGap })
    for _ in 0..<1000 {
      journal.appendEvent(.init(kind: "frame_admission_failed", hostTimeSeconds: 2))
      XCTAssertNil(journal.lock.withLock { journal.pendingGap })
    }
    try await journal.appendStillRetained(
      .init(kind: "still_retained", hostTimeSeconds: 3), reservation: token)
    XCTAssertEqual(journal.lock.withLock { journal.retainedStillCount }, 1)
    XCTAssertEqual(journal.lock.withLock { journal.coalescedGapEvents }, 1000)
    _ = try await journal.finish(reason: "cleanup")
  }

  func testAdmissionDiagnosticsSeparateBoundsAndPreserveFirstTimestamp() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture, maximumPendingBytes: 6)
    XCTAssertNil(journal.reserveFrame(byteCount: 0))
    let held = try XCTUnwrap(journal.reserveFrame(byteCount: 6))
    let timestamp = DocumentCaptureClockTimestamp(
      value: 7, timescale: 60, flags: 1,
      epoch: 0, clock: .captureSessionSynchronizationClock)
    XCTAssertNil(
      journal.reserveFrame(
        byteCount: 6,
        failure: .init(
          kind: "frame_admission_failed", hostTimeSeconds: 2, timestamp: timestamp,
          contextCode: "sink_capacity_or_termination")))
    journal.cancelReservation(
      held,
      failure: .init(
        kind: "frame_copy_failed",
        hostTimeSeconds: 3, timestamp: timestamp, contextCode: "injected_failure"))
    let recovered = try XCTUnwrap(journal.reserveFrame(byteCount: 6))
    journal.cancelReservation(
      recovered,
      failure: .init(
        kind: "frame_copy_cancelled",
        hostTimeSeconds: 4, timestamp: timestamp, contextCode: "generation_changed"))
    _ = try await journal.finish(reason: "completed")
    let ids = try await fixture.store.matchingRecordIDs(
      recordKind: "journeyRecordingSeal",
      recordingID: journal.recordingID)
    let record = try await fixture.store.read(id: XCTUnwrap(ids.first))
    let seal = try JSONDecoder().decode(CaptureRecordingSeal.self, from: record.original)
    let metrics = try XCTUnwrap(seal.acquisitionDiagnostics)
    XCTAssertEqual(
      metrics.frameRefusals,
      [
        "invalidSize": 1, "pendingByteCapacity": 1,
        "copyFailed": 1, "copyCancelled": 1,
      ])
    XCTAssertEqual(metrics.pendingByteHighWaterMark, 6)
    XCTAssertGreaterThanOrEqual(metrics.queuedRecordHighWaterMark, 1)
    XCTAssertEqual(seal.refusedFrames, 4)
    XCTAssertEqual(seal.firstLossTimestamp, timestamp)
    XCTAssertEqual(seal.firstLossReason, "frame_admission_failed:pendingByteCapacity")
    XCTAssertEqual(seal.status, "partial")
    _ = try await CaptureRecordingVerification.verify(journal.reference, store: fixture.store)
  }

  func testQueueAndTerminalRefusalsRemainDistinctAndLateCallsDoNotMutate() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    // Hold the pump to deterministically exercise admission against a full control queue.
    let parked = Task<Void, Never> {}
    journal.lock.withLock {
      journal.pump = parked
      journal.queue = Array(
        repeating: .event(.init(kind: "geometry", hostTimeSeconds: 1)), count: 256)
    }
    XCTAssertNil(journal.reserveFrame(byteCount: 6))
    journal.lock.withLock {
      journal.queue.removeAll()
      journal.pump = nil
      journal.terminalReason = "operator_stop"
    }
    XCTAssertNil(journal.reserveFrame(byteCount: 6))
    _ = try await journal.finish(reason: "operator_stop")
    let before = journal.lock.withLock { journal.acquisitionDiagnostics }
    XCTAssertEqual(before.frameRefusals, ["queuedRecordCapacity": 1, "terminalAdmission": 1])
    XCTAssertEqual(before.queuedRecordHighWaterMark, 256)
    XCTAssertEqual(journal.lock.withLock { journal.refusedFrames }, 1)
    XCTAssertNil(journal.reserveFrame(byteCount: 6))
    XCTAssertEqual(
      journal.lock.withLock { journal.acquisitionDiagnostics.frameRefusals }, before.frameRefusals)
  }

  func testStoreAwaitTimingsPersistByKindAndLegacySealRemainsReadable() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    let payload = Data([1, 2, 3, 4, 5, 6])
    let frame = DocumentTemporalFrame(
      metadata: .init(
        sequenceNumber: 1,
        timestamp: .init(
          value: 1, timescale: 30, flags: 1, epoch: 0,
          clock: .captureSessionSynchronizationClock),
        hostTimeSeconds: 1, width: 2, height: 2, pixelFormat: 875_704_422,
        planes: [
          .init(
            offset: 0, byteCount: 4, width: 2, height: 2, sourceBytesPerRow: 2, packedBytesPerRow: 2
          ),
          .init(
            offset: 4, byteCount: 2, width: 1, height: 1, sourceBytesPerRow: 2, packedBytesPerRow: 2
          ),
        ],
        sha256: CapturePayloadIntegrity.sha256(payload), colorAttachmentsPlist: nil, geometry: nil,
        camera: nil),
      payload: payload)
    journal.appendFrame(
      frame, reservation: try XCTUnwrap(journal.reserveFrame(byteCount: payload.count)))
    journal.appendMotion(
      .init(
        bootTimeSeconds: 1, attitude: .init(x: 0, y: 0, z: 0, w: 1),
        rotationRate: .init(x: 0, y: 0, z: 0), gravity: .init(x: 0, y: 0, z: -1),
        userAcceleration: .init(x: 0, y: 0, z: 0), referenceFrame: "fixture"))
    journal.appendEvent(.init(kind: "configuration_changed", hostTimeSeconds: 1, contextCode: "fixture"))
    _ = try await journal.finish(reason: "completed")
    let ids = try await fixture.store.matchingRecordIDs(
      recordKind: "journeyRecordingSeal",
      recordingID: journal.recordingID)
    let record = try await fixture.store.read(id: XCTUnwrap(ids.first))
    let seal = try JSONDecoder().decode(CaptureRecordingSeal.self, from: record.original)
    let diagnostics = try XCTUnwrap(seal.acquisitionDiagnostics)
    XCTAssertEqual(Set(diagnostics.storeAwaitCalls.keys), ["frame", "motion", "event"])
    for timing in diagnostics.storeAwaitCalls.values {
      XCTAssertEqual(timing.attempts, 1)
      XCTAssertEqual(timing.failures, 0)
      XCTAssertGreaterThan(timing.totalSeconds, 0)
      XCTAssertEqual(timing.maximumSeconds, timing.totalSeconds)
    }
    let diagnosticJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(diagnostics)) as? [String: Any])
    XCTAssertEqual(
      Set(diagnosticJSON.keys),
      [
        "schemaVersion", "pendingByteHighWaterMark",
        "queuedRecordHighWaterMark", "frameRefusals", "storeAwaitCalls",
      ])
    var legacy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: record.original) as? [String: Any])
    legacy.removeValue(forKey: "acquisitionDiagnostics")
    let decoded = try JSONDecoder().decode(
      CaptureRecordingSeal.self,
      from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertNil(decoded.acquisitionDiagnostics)
    XCTAssertEqual(decoded.frameCount, 1)
    _ = try await CaptureRecordingVerification.verify(journal.reference, store: fixture.store)
  }

  func testFailedStoreAwaitIsCountedWithoutPublishingASeal() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    try FileManager.default.removeItem(at: fixture.directory)
    try Data([1]).write(to: fixture.directory)
    journal.appendEvent(.init(kind: "configuration_changed", hostTimeSeconds: 1))
    do {
      _ = try await journal.finish(reason: "completed")
      XCTFail("Storage failure was accepted")
    } catch {}
    let timing = try XCTUnwrap(
      journal.lock.withLock { journal.acquisitionDiagnostics.storeAwaitCalls["event"] })
    XCTAssertEqual(timing.attempts, 1)
    XCTAssertEqual(timing.failures, 1)
    XCTAssertGreaterThan(timing.totalSeconds, 0)
    XCTAssertEqual(journal.status, "failed")
    XCTAssertNil(journal.lock.withLock { journal.sealed })
  }

  func testDiagnosticsRejectMalformedValuesWithoutChangingLegacyCounterSemantics() {
    var value = RecordingAcquisitionDiagnostics()
    XCTAssertTrue(value.valid)
    value.frameRefusals["terminalAdmission"] = 1
    XCTAssertTrue(value.valid)
    value.frameRefusals["unknown"] = 1
    XCTAssertFalse(value.valid)
    value.frameRefusals.removeValue(forKey: "unknown")
    value.frameRefusals["copyFailed"] = -1
    XCTAssertFalse(value.valid)
    value.frameRefusals.removeValue(forKey: "copyFailed")
    for duration in [-1.0, .infinity, .nan] {
      value.storeAwaitCalls["frame"] = .init(
        attempts: 1, failures: 0,
        totalSeconds: duration, maximumSeconds: duration)
      XCTAssertFalse(value.valid)
    }
    value.storeAwaitCalls["frame"] = .init(
      attempts: 1, failures: 2,
      totalSeconds: 1, maximumSeconds: 1)
    XCTAssertFalse(value.valid)
    value.storeAwaitCalls["frame"] = .init(
      attempts: 1, failures: 0,
      totalSeconds: 1, maximumSeconds: 2)
    XCTAssertFalse(value.valid)
    value.storeAwaitCalls.removeAll()
    value.pendingByteHighWaterMark = -1
    XCTAssertFalse(value.valid)
    value.pendingByteHighWaterMark = 0
    value.schemaVersion = 2
    XCTAssertFalse(value.valid)
  }

  func testAuthenticatedSealWithMalformedDiagnosticsFailsVerification() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    var diagnostics = RecordingAcquisitionDiagnostics()
    diagnostics.queuedRecordHighWaterMark = -1
    let seal = CaptureRecordingSeal(
      status: "partial", reason: "operator_stop",
      frameCount: 0, motionSampleCount: 0, issueCount: 0, retainedStillCount: 0,
      refusedFrames: 0, refusedMotionSamples: 0, acquisitionDiagnostics: diagnostics)
    let data = try JSONEncoder().encode(seal)
    let link = CaptureRecordingLink(
      schemaVersion: 1, recordKind: "journeyRecordingSeal",
      recordingID: journal.recordingID, workflowID: journal.reference.workflowID, ordinal: 1,
      previousID: journal.recordingID, previousSHA256: journal.reference.startSHA256,
      payloadSHA256: CapturePayloadIntegrity.sha256(data), frame: nil)
    try await fixture.store.store(id: UUID(), original: data, manifest: JSONEncoder().encode(link))
    do {
      _ = try await CaptureRecordingVerification.verify(journal.reference, store: fixture.store)
      XCTFail("Authenticated malformed diagnostics accepted")
    } catch {}
  }

  private func event(_ original: RecordingFixture.Manifest) -> DocumentJourneyRecordingEvent {
    .init(
      kind: "still_retained", hostTimeSeconds: 1,
      binding: .init(
        sessionID: original.sessionID.rawValue.uuidString,
        attemptID: original.captureID.uuidString, side: original.profile.side.rawValue,
        stillSHA256: original.fidelity.sha256, stillTimestamp: original.captureTimestamp,
        stillHostTimeSeconds: nil))
  }
}
