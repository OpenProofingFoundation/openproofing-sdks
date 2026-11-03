#if os(iOS)
  import Combine
  import Foundation
  import XCTest

  @testable import DocumentCapture
  @testable import DocumentCaptureJournal
  import CaptureEvidenceCustody
  @testable import DocumentCaptureApple

  extension CaptureTiltIntegrationTests {
    func testTerminalFailureStaysVisibleWithoutRearmingAndSurvivesReview() async throws {
      for reason in [
        DocumentTiltReason.observationUnavailable, .evidenceLimit, .observationSilence,
      ] {
        let engine = model(actions: .init(end: { _, _, _ in }))
        activate(engine)
        let id = try XCTUnwrap(engine.tiltGuidance.runID)
        let terminal = DocumentTiltPresentation(
          runID: id, revision: 2,
          phase: reason == .evidenceLimit ? .evidenceLimit : .cancelled,
          reason: reason, baseline: nil, signedDelta: nil, consecutiveObservations: 0,
          dwellSeconds: 0
        )
        engine.receiveTilt(terminal, generation: engine.cameraGeneration)
        await engine.tiltGuidance.controlTask?.value
        XCTAssertTrue(engine.tiltGuidance.needsRetry)
        XCTAssertEqual(engine.tiltGuidance.outcome, .incomplete)
        XCTAssertTrue(engine.tiltDefersAutomaticCapture)
        engine.prepareAutomaticCapture()
        XCTAssertFalse(engine.autoArmed)
        XCTAssertNil(engine.operation)
        let message = try XCTUnwrap(engine.tiltGuidance.reason)
        engine.stopTiltObservation()
        engine.phase = .reviewing
        XCTAssertEqual(engine.tiltGuidance.presentation, terminal)
        XCTAssertEqual(engine.tiltGuidance.reason, message)
        engine.stop()
      }
    }

    func testUnavailableBeginDoesNotSilentlyArmAndExplicitSkipPersists() async throws {
      let engine = model(
        actions: .init(
          begin: { _, _ in throw PhotoCaptureError.cameraNotReady },
          end: { _, _, _ in }))
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      activate(engine)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: fixture.store, clock: .tiltFixture,
        policy: .retainedV1)
      XCTAssertTrue(
        journal.tiltBudgetSnapshot().tiltBudgetAvailable,
        "This fixture must admit optional tilt before testing its lifecycle")
      engine.journeyRecording = journal
      engine.tiltGuidance.lifecycle = .waiting
      engine.startTiltIfRequested(camera: engine.camera, generation: engine.cameraGeneration)
      await engine.tiltGuidance.startTask?.value
      await engine.tiltGuidance.controlTask?.value
      XCTAssertTrue(engine.tiltGuidance.needsRetry)
      XCTAssertFalse(engine.autoArmed)
      XCTAssertEqual(engine.tiltGuidance.reason, .observationUnavailable)
      engine.skipTiltGuidance()
      await engine.tiltGuidance.controlTask?.value
      XCTAssertTrue(engine.autoArmed)
      XCTAssertTrue(engine.tiltGuidance.skipped)
      XCTAssertEqual(engine.tiltGuidance.outcome, .skipped)
      engine.stopTiltObservation()
      XCTAssertTrue(engine.tiltGuidance.skipped)
      XCTAssertEqual(engine.tiltGuidance.reason, .userSkipped)
      engine.resetTiltForCameraStart(recordingOnly: false)
      XCTAssertFalse(engine.tiltGuidance.skipped)
      XCTAssertNil(engine.tiltGuidance.outcome)
      engine.stop()
      await engine.recordingSettlement?.value
    }

    func testLateNativeFailureRefinesBeginErrorWithoutRearming() async throws {
      let engine = model(
        actions: .init(
          begin: { _, _ in throw PhotoCaptureError.cameraNotReady },
          end: { _, _, _ in }))
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      activate(engine)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: fixture.store, clock: .tiltFixture,
        policy: .retainedV1)
      XCTAssertTrue(
        journal.tiltBudgetSnapshot().tiltBudgetAvailable,
        "This fixture must admit optional tilt before testing its lifecycle")
      engine.journeyRecording = journal
      engine.tiltGuidance.lifecycle = .waiting
      engine.startTiltIfRequested(camera: engine.camera, generation: engine.cameraGeneration)
      let failed = try XCTUnwrap(engine.tiltGuidance.runID)
      await engine.tiltGuidance.startTask?.value
      await engine.tiltGuidance.controlTask?.value
      let terminal = DocumentTiltPresentation(
        runID: failed, revision: 2, phase: .cancelled,
        reason: .zoomNotSettled, baseline: nil, signedDelta: nil, consecutiveObservations: 0,
        dwellSeconds: 0)
      engine.receiveTilt(terminal, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltGuidance.presentation, terminal)
      XCTAssertEqual(engine.tiltGuidance.reason, .zoomNotSettled)
      XCTAssertEqual(engine.tiltCaptureGuidance, .retry(.zoomNotSettled))
      XCTAssertTrue(engine.tiltGuidance.needsRetry)
      XCTAssertFalse(engine.autoArmed)
      XCTAssertNil(engine.tiltGuidance.controlTask)
      engine.skipTiltGuidance()
      await engine.tiltGuidance.controlTask?.value
      let skippedMessage = engine.tiltGuidance.reason
      engine.receiveTilt(terminal, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltGuidance.reason, skippedMessage)
      engine.stop()
      await engine.recordingSettlement?.value
    }

    func testRetryWaitsForOldEndAndUsesFreshRunOnExistingStream() async throws {
      let ending = expectation(description: "Old native run ends")
      var endContinuation: CheckedContinuation<Void, Never>?
      var begun: [UUID] = []
      let engine = model(
        actions: .init(
          begin: { camera, id in
            begun.append(id)
            camera.tiltGuidanceDelivery.begin(runID: id)
            return DocumentTiltController(runID: id).presentation
          },
          end: { _, _, _ in
            await withCheckedContinuation {
              endContinuation = $0
              ending.fulfill()
            }
          }))
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      activate(engine)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: fixture.store, clock: .tiltFixture,
        policy: .retainedV1)
      XCTAssertTrue(
        journal.tiltBudgetSnapshot().tiltBudgetAvailable,
        "This fixture must admit optional tilt before testing its lifecycle")
      engine.journeyRecording = journal
      engine.camera.tiltGuidanceDelivery.activate(generation: 0)
      engine.tiltGuidance.lifecycle = .waiting
      engine.startTiltIfRequested(camera: engine.camera, generation: engine.cameraGeneration)
      await engine.tiltGuidance.startTask?.value
      let old = try XCTUnwrap(engine.tiltGuidance.runID)
      let observer = engine.tiltGuidance.observationID
      var oldController = DocumentTiltController(runID: old)
      engine.receiveTilt(
        oldController.cancel(reason: .observationSilence).presentation,
        generation: engine.cameraGeneration)
      let releasing = engine.tiltGuidance.controlTask
      await fulfillment(of: [ending], timeout: 1)
      engine.retryTiltGuidance()
      XCTAssertEqual(begun, [old])
      XCTAssertFalse(engine.autoArmed)
      endContinuation?.resume()
      await releasing?.value
      await engine.tiltGuidance.startTask?.value
      let replacement = try XCTUnwrap(engine.tiltGuidance.runID)
      XCTAssertNotEqual(replacement, old)
      XCTAssertEqual(begun, [old, replacement])
      XCTAssertEqual(engine.tiltGuidance.observationID, observer)
      XCTAssertFalse(engine.tiltGuidance.needsRetry)
      XCTAssertFalse(engine.autoArmed)
      await assertReplacementStream(engine, runID: replacement, old: oldController.presentation)
      engine.stop()
      await engine.recordingSettlement?.value
    }
    private func assertReplacementStream(
      _ engine: CaptureSession, runID: UUID, old: DocumentTiltPresentation
    ) async {
      let seen = expectation(description: "Replacement stream remains usable")
      let observation = engine.tiltGuidance.$presentation.compactMap { $0 }.filter {
        $0.revision == 2
      }.prefix(1)
        .sink { _ in seen.fulfill() }
      let current = DocumentTiltPresentation(
        runID: runID, revision: 2, phase: .baseline,
        reason: .baselineUnstable, baseline: nil, signedDelta: nil, consecutiveObservations: 0,
        dwellSeconds: 0)
      engine.camera.tiltGuidanceDelivery.yield(current, generation: 0)
      await fulfillment(of: [seen], timeout: 1)
      engine.receiveTilt(old, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltGuidance.presentation, current)
      observation.cancel()
    }
  }

#endif
