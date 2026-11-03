#if os(iOS)
  import Foundation
  import XCTest
  @testable import DocumentCaptureJournal
  @testable import DocumentCaptureApple
  @testable import DocumentCapture

  extension CaptureTiltIntegrationTests {
    func testBudgetReleaseRetainsMeasurementButWithdrawsMovementInstruction() async throws {
      for enforced in [false, true] {
        try await assertBudgetRelease(enforced: enforced)
      }
    }

    private func assertBudgetRelease(enforced: Bool) async throws {
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      let policy = try DocumentPresencePolicy(
        identifier: "guidance-test", attribution: "synthetic test inputs, not a measurement",
        tiltReserveBytes: 1_048_576, tiltReserveSeconds: 1,
        windowBeforeStillSeconds: 1, windowAfterStillSeconds: 0.5,
        windowMaximumBytes: 2_097_152)
      let ending = expectation(description: "Native release held")
      var resume: CheckedContinuation<Void, Never>?
      let engine = makeTiltSession(
        tiltActions: .init(end: { _, _, _ in
          await withCheckedContinuation {
            resume = $0
            ending.fulfill()
          }
        }), presence: enforced ? policy : policy.observed())
      activate(engine)
      let runID = try XCTUnwrap(engine.tiltGuidance.runID)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: fixture.store, clock: .tiltFixture)
      engine.journeyRecording = journal
      XCTAssertTrue(engine.admitTiltBudget(runID: runID, generation: engine.cameraGeneration))
      let movement = guidancePresentation(runID: runID, revision: 2, phase: .leftEdgeCloser)
      engine.receiveTilt(movement, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltCaptureGuidance, .movement(movement, restartingBaseline: false))
      journal.lock.withLock {
        journal.chargedBytes = journal.maximumDiskBytes - policy.tiltReserveBytes
      }
      journal.notifyTiltBudget()
      await fulfillment(of: [ending], timeout: 1)
      XCTAssertEqual(engine.tiltCaptureGuidance, .finishing)
      XCTAssertFalse(engine.autoArmed)
      resume?.resume()
      await engine.tiltGuidance.controlTask?.value
      XCTAssertEqual(engine.autoArmed, !enforced)
      XCTAssertEqual(engine.tiltDefersAutomaticCapture, enforced)
      XCTAssertEqual(engine.issue, enforced ? .documentPresenceUnavailable : nil)
      XCTAssertEqual(engine.tiltCaptureGuidance, enforced ? .unavailable(.recordingBudget) : .idle)
      XCTAssertEqual(engine.tiltGuidance.presentation, movement)
      XCTAssertEqual(engine.tiltGuidance.outcome, .incomplete)
      XCTAssertEqual(engine.tiltGuidance.reason, .recordingBudget)
      XCTAssertEqual(journal.status, "recording")
      engine.stop()
      _ = try await journal.finish(reason: "test_finished")
    }

    func testCompletedMovementOffersPhotoOnlyAfterNativeReleaseAndStopsWithSession() async throws {
      let engine = model(actions: .init(end: { _, _, _ in }))
      activate(engine)
      let runID = try XCTUnwrap(engine.tiltGuidance.runID)
      let completed = guidancePresentation(runID: runID, revision: 9, phase: .readyForStill)
      engine.receiveTilt(completed, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltCaptureGuidance, .finishing)
      await engine.tiltGuidance.controlTask?.value
      XCTAssertEqual(engine.tiltCaptureGuidance, .readyForPhoto)
      XCTAssertTrue(engine.autoArmed)
      engine.enterReview()
      XCTAssertEqual(engine.tiltCaptureGuidance, .idle)
      engine.completeDocumentRecording()
      XCTAssertEqual(engine.tiltCaptureGuidance, .idle)
      engine.stop()
      XCTAssertEqual(engine.tiltCaptureGuidance, .idle)
      XCTAssertEqual(engine.tiltGuidance.presentation, completed)
      XCTAssertEqual(engine.tiltGuidance.outcome, .completed)
    }

    func testRestartSurvivesReasonClearingButRejectsStaleAndOldRunPresentations() throws {
      let engine = model()
      activate(engine)
      let runID = try XCTUnwrap(engine.tiltGuidance.runID)
      let movement = guidancePresentation(runID: runID, revision: 2, phase: .leftEdgeCloser)
      engine.receiveTilt(movement, generation: engine.cameraGeneration)
      let restart = guidancePresentation(
        runID: runID, revision: 3, phase: .baseline, reason: .geometryChanged)
      engine.receiveTilt(restart, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltCaptureGuidance, .movement(restart, restartingBaseline: true))
      let collecting = guidancePresentation(runID: runID, revision: 4, phase: .baseline)
      engine.receiveTilt(collecting, generation: engine.cameraGeneration)
      engine.receiveTilt(movement, generation: engine.cameraGeneration)
      engine.receiveTilt(
        guidancePresentation(runID: UUID(), revision: 99, phase: .leftEdgeCloser),
        generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltCaptureGuidance, .movement(collecting, restartingBaseline: true))
      let nextMovement = guidancePresentation(runID: runID, revision: 5, phase: .leftEdgeCloser)
      engine.receiveTilt(nextMovement, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltCaptureGuidance, .movement(nextMovement, restartingBaseline: false))
      engine.stop()
    }

    func testRestartIsResetForNewCameraRun() throws {
      let engine = model()
      activate(engine)
      let old = try XCTUnwrap(engine.tiltGuidance.runID)
      engine.receiveTilt(
        guidancePresentation(runID: old, revision: 2, phase: .leftEdgeCloser),
        generation: engine.cameraGeneration)
      engine.receiveTilt(
        guidancePresentation(runID: old, revision: 3, phase: .baseline),
        generation: engine.cameraGeneration)
      activate(engine)
      let new = try XCTUnwrap(engine.tiltGuidance.runID)
      let baseline = guidancePresentation(runID: new, revision: 1, phase: .baseline)
      engine.receiveTilt(baseline, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltCaptureGuidance, .movement(baseline, restartingBaseline: false))
      engine.stop()
    }

    func testRetryInstructionUsesFailureReasonAndDisappearsWhenStopped() async throws {
      let engine = model(actions: .init(end: { _, _, _ in }))
      activate(engine)
      let runID = try XCTUnwrap(engine.tiltGuidance.runID)
      let terminal = guidancePresentation(
        runID: runID, revision: 2, phase: .cancelled, reason: .observationSilence)
      engine.receiveTilt(terminal, generation: engine.cameraGeneration)
      await engine.tiltGuidance.controlTask?.value
      XCTAssertEqual(engine.tiltCaptureGuidance, .retry(.observationSilence))
      XCTAssertFalse(engine.autoArmed)
      engine.stop()
      XCTAssertEqual(engine.tiltCaptureGuidance, .idle)
      XCTAssertEqual(engine.tiltGuidance.presentation, terminal)
    }

    func testAcquisitionAndBackLifecycleSuppressMovement() throws {
      let engine = model()
      activate(engine)
      let runID = try XCTUnwrap(engine.tiltGuidance.runID)
      let movement = guidancePresentation(runID: runID, revision: 2, phase: .leftEdgeCloser)
      engine.receiveTilt(movement, generation: engine.cameraGeneration)
      engine.startup = .cameraStart
      XCTAssertEqual(engine.tiltCaptureGuidance, .starting)
      engine.startup = nil
      for state in [CaptureSessionOriginalState.capturing, .retaining] {
        engine.originalState = state
        XCTAssertEqual(engine.tiltCaptureGuidance, .idle)
      }
      engine.originalState = .idle
      engine.profile = .licenseBack
      XCTAssertEqual(engine.tiltCaptureGuidance, .idle)
      engine.stop()
    }

    func testInitialBaselineNoiseIsNotARestartAndRestartNeedsNoReason() throws {
      let engine = model()
      activate(engine)
      let runID = try XCTUnwrap(engine.tiltGuidance.runID)
      let noise = guidancePresentation(
        runID: runID, revision: 2, phase: .baseline, reason: .baselineUnstable)
      engine.receiveTilt(noise, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltCaptureGuidance, .movement(noise, restartingBaseline: false))
      engine.receiveTilt(
        guidancePresentation(runID: runID, revision: 3, phase: .leftEdgeCloser),
        generation: engine.cameraGeneration)
      let restarted = guidancePresentation(runID: runID, revision: 4, phase: .baseline)
      engine.receiveTilt(restarted, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltCaptureGuidance, .movement(restarted, restartingBaseline: true))
      engine.stop()
    }

    private func guidancePresentation(
      runID: UUID, revision: UInt64, phase: DocumentTiltPhase, reason: DocumentTiltReason? = nil
    ) -> DocumentTiltPresentation {
      let movement = phase != .baseline && ![.cancelled, .skipped, .evidenceLimit].contains(phase)
      let noise = DocumentTiltConfiguration.provisionalV2.empiricalNoiseFloor
      let excursion = noise * 6
      let neutral = noise * 2
      let baseline = DocumentTiltBaseline(
        firstTimestamp: .init(
          value: 0, timescale: 1000, flags: 1, epoch: 0,
          clock: .captureSessionSynchronizationClock),
        lastTimestamp: .init(
          value: 800, timescale: 1000, flags: 1, epoch: 0,
          clock: .captureSessionSynchronizationClock),
        observationCount: 5, rawMedianLogRatio: 0, rawMedianAbsoluteDeviation: 0,
        medianLogRatio: 0, medianAbsoluteDeviation: 0, empiricalNoise: noise,
        excursionEnter: excursion, excursionRelease: excursion * 0.75,
        neutralEnter: neutral, neutralRelease: neutral * 1.5)
      let result = DocumentTiltPresentation(
        runID: runID, revision: revision, phase: phase, reason: reason,
        baseline: movement ? baseline : nil, signedDelta: movement ? 0 : nil,
        consecutiveObservations: 0, dwellSeconds: 0)
      XCTAssertTrue(result.valid)
      return result
    }
  }
#endif
