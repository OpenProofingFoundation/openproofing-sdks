#if os(iOS)
  import Foundation
  import XCTest

  @testable import DocumentCapture
  @testable import DocumentCaptureJournal
  import CaptureEvidenceCustody
  @testable import DocumentCaptureApple

  @MainActor
  final class CaptureTiltBudgetTests: XCTestCase {
    func testNativeSizedPendingFramesEndOptionalWorkBeforeHardLimit() async throws {
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      let journal = makeJournal(fixture: fixture)
      let frameBytes = 3_484_800  // Retained 1320×1760 NV12, not a fabricated tiny budget.
      let reserve = CaptureTiltBudgetPolicy.provisionalV1.coreReserveBytes
      journal.chargedBytes = journal.maximumDiskBytes - reserve - frameBytes * 10
      let ended = expectation(description: "Optional allowance exhausted once")
      ended.assertForOverFulfill = true
      let owner = UUID()
      XCTAssertTrue(
        journal.watchTiltBudget(owner: owner) { snapshot in
          XCTAssertFalse(snapshot.tiltBudgetAvailable)
          XCTAssertTrue(snapshot.recording)
          XCTAssertGreaterThan(snapshot.maximumDiskBytes - snapshot.chargedBytes, reserve)
          ended.fulfill()
        }.tiltBudgetAvailable)
      var held: [UUID] = []
      for _ in 0..<6 { held.append(try XCTUnwrap(journal.reserveFrame(byteCount: frameBytes))) }
      XCTAssertNil(journal.tiltBudgetWatch)
      XCTAssertEqual(journal.status, "recording")
      XCTAssertEqual(journal.refusedFrames, 0)
      XCTAssertNotNil(journal.reserveMilestone(), "Core shutter binding still has room")
      // No source buffers or writer tasks were created. Clear synthetic admissions before teardown.
      journal.reservations.removeAll()
      journal.milestones.removeAll()
      journal.pendingBytes = 0
      XCTAssertEqual(held.count, 6)
      await fulfillment(of: [ended], timeout: 1)
    }

    func testInFlightChargeIsConservativelyCountedAndRetriesCannotResetBudget() throws {
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      let journal = makeJournal(fixture: fixture)
      let policy = CaptureTiltBudgetPolicy.provisionalV1
      journal.chargedBytes = journal.maximumDiskBytes - policy.coreReserveBytes - 1_000_000
      journal.pendingBytes = 3_484_800
      let first = journal.watchTiltBudget(owner: UUID()) { _ in
        XCTFail("Declined watch cannot fire")
      }
      XCTAssertFalse(first.tiltBudgetAvailable)
      XCTAssertGreaterThan(first.conservativePendingCharge, 2 * journal.pendingBytes)
      let retry = journal.watchTiltBudget(owner: UUID()) { _ in
        XCTFail("Retry cannot create capacity")
      }
      XCTAssertFalse(retry.tiltBudgetAvailable)
      XCTAssertEqual(first.chargedBytes, retry.chargedBytes)
      XCTAssertEqual(journal.status, "recording")
      XCTAssertNotNil(journal.reserveMilestone())
    }

    func testDurationLowDiskTerminalAndStaleWatchAreDistinct() throws {
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      let journal = makeJournal(fixture: fixture)
      XCTAssertFalse(journal.tiltBudgetSnapshot(now: journal.deadline - 29).tiltBudgetAvailable)
      XCTAssertTrue(journal.tiltBudgetSnapshot(now: journal.deadline - 29).recording)
      XCTAssertFalse(
        makeJournal(fixture: fixture, disk: 1_073_741_824).tiltBudgetSnapshot().tiltBudgetAvailable)
      let old = UUID()
      let current = UUID()
      XCTAssertTrue(
        journal.watchTiltBudget(owner: old) { _ in XCTFail("Old callback") }.tiltBudgetAvailable)
      XCTAssertTrue(
        journal.watchTiltBudget(owner: current) { _ in XCTFail("Cleared callback") }.tiltBudgetAvailable)
      journal.clearTiltBudgetWatch(owner: old)
      XCTAssertEqual(journal.tiltBudgetWatch?.owner, current)
      journal.clearTiltBudgetWatch(owner: current)
      journal.terminalReason = "operator_stop"
      let terminal = journal.tiltBudgetSnapshot()
      XCTAssertFalse(terminal.recording)
      XCTAssertFalse(terminal.tiltBudgetAvailable)
      journal.notifyTiltBudget()
    }

    func testBudgetStopsFailedAttemptWaitAndRestoresOrdinaryCapture() async throws {
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      let engine = makeTiltSession(
        tiltActions: .init(
          begin: { _, id in DocumentTiltController(runID: id).presentation },
          end: { _, _, _ in }))
      engine.profile = .licenseFront
      engine.phase = .capturing
      engine.ready = true
      engine.tiltGuidance.requestedForFront = true
      engine.resetTiltForCameraStart(recordingOnly: false)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: fixture.store, clock: .tiltFixture,
        policy: .retainedV1)
      XCTAssertTrue(
        journal.tiltBudgetSnapshot().tiltBudgetAvailable,
        "This fixture must admit optional tilt before testing reserve exhaustion")
      engine.journeyRecording = journal
      let runID = UUID()
      XCTAssertTrue(engine.admitTiltBudget(runID: runID, generation: engine.cameraGeneration))
      // A previous incomplete attempt has already released native controls, but the UI awaits retry.
      engine.tiltGuidance.lifecycle = .retryable(
        .init(runID: runID, outcome: .incomplete, reason: .observationSilence))
      journal.lock.withLock {
        journal.chargedBytes =
          journal.maximumDiskBytes - CaptureTiltBudgetPolicy.provisionalV1.coreReserveBytes
      }
      journal.notifyTiltBudget()
      for _ in 0..<100 where engine.tiltGuidance.needsRetry { await Task.yield() }
      await engine.tiltGuidance.controlTask?.value
      XCTAssertEqual(engine.tiltGuidance.outcome, .incomplete)
      XCTAssertFalse(engine.tiltGuidance.needsRetry)
      XCTAssertFalse(engine.tiltDefersAutomaticCapture)
      XCTAssertTrue(engine.autoArmed)
      XCTAssertTrue(engine.ready)
      XCTAssertEqual(journal.status, "recording")
      engine.stop()
      await engine.recordingSettlement?.value
    }

    func testSkipDuringPendingFailureReleaseCannotBecomeBudgetFailure() async throws {
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      let ending = expectation(description: "Native release held")
      var resume: CheckedContinuation<Void, Never>?
      let engine = makeTiltSession(
        tiltActions: .init(end: { _, _, _ in
          await withCheckedContinuation {
            resume = $0
            ending.fulfill()
          }
        }))
      engine.profile = .licenseFront
      engine.phase = .capturing
      engine.ready = true
      engine.tiltGuidance.requestedForFront = true
      engine.resetTiltForCameraStart(recordingOnly: false)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: fixture.store, clock: .tiltFixture,
        policy: .retainedV1)
      XCTAssertTrue(
        journal.tiltBudgetSnapshot().tiltBudgetAvailable,
        "This fixture must admit optional tilt before testing reserve exhaustion")
      engine.journeyRecording = journal
      let runID = UUID()
      engine.tiltGuidance.lifecycle = .measuring(.init(runID: runID))
      XCTAssertTrue(engine.admitTiltBudget(runID: runID, generation: engine.cameraGeneration))
      var controller = DocumentTiltController(runID: runID)
      engine.receiveTilt(
        controller.cancel(reason: .observationSilence).presentation,
        generation: engine.cameraGeneration)
      await fulfillment(of: [ending], timeout: 1)
      engine.skipTiltGuidance()
      XCTAssertNil(journal.tiltBudgetWatch)
      XCTAssertNil(engine.tiltGuidance.budgetWatchID)
      journal.lock.withLock {
        journal.chargedBytes =
          journal.maximumDiskBytes - CaptureTiltBudgetPolicy.provisionalV1.coreReserveBytes
      }
      journal.notifyTiltBudget()
      resume?.resume()
      await engine.tiltGuidance.controlTask?.value
      XCTAssertEqual(engine.tiltGuidance.outcome, .skipped)
      XCTAssertFalse(engine.tiltGuidance.needsRetry)
      XCTAssertTrue(engine.autoArmed)
      XCTAssertEqual(journal.status, "recording")
      engine.stop()
      await engine.recordingSettlement?.value
    }

    func testDurationWatchFiresWithoutAnotherCameraCallback() async throws {
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      let journal = CaptureRecordingJournal(
        reference: .init(recordingID: UUID(), workflowID: UUID(), startSHA256: "fixture"),
        store: fixture.store, clock: .tiltFixture, maximumDuration: 30.1,
        maximumDiskBytes: 8_589_934_592,
        maximumPendingBytes: 67_108_864, startCharge: 0)
      let ended = expectation(description: "Duration reserve reached without frames")
      XCTAssertTrue(
        journal.watchTiltBudget(owner: UUID()) { snapshot in
          XCTAssertTrue(snapshot.recording)
          XCTAssertLessThanOrEqual(snapshot.remainingSeconds, 30)
          ended.fulfill()
        }.tiltBudgetAvailable)
      await fulfillment(of: [ended], timeout: 2)
      XCTAssertEqual(journal.status, "recording")
      XCTAssertNil(journal.tiltBudgetWatch)
      XCTAssertNil(journal.tiltBudgetDeadline)
    }

    func testQueuedOldBudgetCallbackCannotReleaseReplacementCamera() async throws {
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      let engine = makeTiltSession(
        tiltActions: .init(end: { _, _, _ in XCTFail("Stale callback ended current run") }))
      engine.profile = .licenseFront
      engine.phase = .capturing
      engine.ready = true
      engine.tiltGuidance.requestedForFront = true
      engine.resetTiltForCameraStart(recordingOnly: false)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: fixture.store, clock: .tiltFixture,
        policy: .retainedV1)
      XCTAssertTrue(
        journal.tiltBudgetSnapshot().tiltBudgetAvailable,
        "This fixture must admit optional tilt before testing reserve exhaustion")
      engine.journeyRecording = journal
      XCTAssertTrue(engine.admitTiltBudget(runID: UUID(), generation: engine.cameraGeneration))
      journal.lock.withLock {
        journal.chargedBytes =
          journal.maximumDiskBytes - CaptureTiltBudgetPolicy.provisionalV1.coreReserveBytes
      }
      journal.notifyTiltBudget()
      engine.cameraGeneration += 1
      for _ in 0..<20 { await Task.yield() }
      XCTAssertNil(engine.tiltGuidance.outcome)
      XCTAssertNil(engine.tiltGuidance.controlTask)
      XCTAssertTrue(engine.tiltDefersAutomaticCapture)
      engine.stop()
      await engine.recordingSettlement?.value
    }

    func testDefaultRecordingBudgetRefusesOptionalTiltBeforeNativeBegin() async throws {
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      var beginCalls = 0
      let engine = makeTiltSession(
        tiltActions: .init(
          begin: { _, _ in
            beginCalls += 1
            XCTFail("Insufficient recording budget must refuse tilt before native begin")
            throw PhotoCaptureError.cameraNotReady
          },
          end: { _, _, _ in XCTFail("A refused run has no native controls to release") }))
      engine.profile = .licenseFront
      engine.phase = .capturing
      engine.ready = true
      engine.tiltGuidance.requestedForFront = true
      engine.resetTiltForCameraStart(recordingOnly: false)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: fixture.store, clock: .tiltFixture)
      engine.journeyRecording = journal
      XCTAssertFalse(journal.tiltBudgetSnapshot().tiltBudgetAvailable)
      XCTAssertEqual(journal.status, "recording")

      engine.startTiltIfRequested(camera: engine.camera, generation: engine.cameraGeneration)
      await engine.tiltGuidance.startTask?.value
      await engine.tiltGuidance.controlTask?.value

      XCTAssertEqual(beginCalls, 0)
      XCTAssertNil(engine.tiltGuidance.runID)
      XCTAssertNil(engine.tiltGuidance.startTask)
      XCTAssertNil(engine.tiltGuidance.controlTask)
      XCTAssertEqual(engine.tiltGuidance.reason, .recordingBudget)
      XCTAssertEqual(engine.tiltGuidance.outcome, .incomplete)
      XCTAssertFalse(engine.tiltGuidance.needsRetry)
      XCTAssertFalse(engine.tiltDefersAutomaticCapture)
      XCTAssertTrue(engine.autoArmed)
      XCTAssertTrue(engine.ready)
      XCTAssertEqual(journal.status, "recording")
      engine.stop()
      await engine.recordingSettlement?.value
    }

    private func makeJournal(
      fixture: TiltMechanismFixture, disk: Int = 8_589_934_592
    ) -> CaptureRecordingJournal {
      .init(
        reference: .init(recordingID: UUID(), workflowID: UUID(), startSHA256: "fixture"),
        store: fixture.store, clock: .tiltFixture, maximumDuration: 120, maximumDiskBytes: disk,
        maximumPendingBytes: 67_108_864, startCharge: 0)
    }
  }

#endif
