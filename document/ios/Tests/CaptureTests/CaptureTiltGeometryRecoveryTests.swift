#if os(iOS)
  import Foundation
  import XCTest
  @testable import DocumentCaptureJournal
  @testable import DocumentCaptureApple
  @testable import DocumentCapture

  extension CaptureTiltIntegrationTests {
    func testGeometryRecoveryCannotRenewExhaustedRecordingReserve() async throws {
      for observed in [false, true] {
        let enforced = try DocumentPresencePolicy(
          identifier: "geometry-recovery-test", attribution: "synthetic test values",
          tiltReserveBytes: 1_048_576, tiltReserveSeconds: 1,
          windowBeforeStillSeconds: 1, windowAfterStillSeconds: 0.5,
          windowMaximumBytes: 2_097_152)
        let presence = observed ? enforced.observed() : enforced
        var begins = 0
        let engine = makeTiltSession(
          tiltActions: .init(
            begin: { _, id in
              begins += 1
              return DocumentTiltController(runID: id).presentation
            }, end: { _, _, _ in }), presence: presence)
        let storage = try TiltMechanismFixture()
        activate(engine)
        let journal = try await CaptureRecordingJournal.start(
          workflowID: engine.workflowID, store: storage.store, clock: .tiltFixture)
        engine.journeyRecording = journal
        journal.lock.withLock {
          journal.chargedBytes = journal.maximumDiskBytes - presence.tiltReserveBytes
        }
        var controller = DocumentTiltController(runID: try XCTUnwrap(engine.tiltGuidance.runID))
        engine.receiveTilt(
          controller.cancel(reason: .geometryChanged).presentation,
          generation: engine.generation)
        await engine.tiltGuidance.controlTask?.value
        await engine.tiltGuidance.controlTask?.value
        XCTAssertEqual(begins, 0)
        XCTAssertTrue(engine.journeyRecording === journal)
        XCTAssertEqual(engine.tiltGuidance.reason, .recordingBudget)
        XCTAssertEqual(engine.tiltGuidance.outcome, .incomplete)
        XCTAssertEqual(engine.autoArmed, observed)
        XCTAssertEqual(engine.issue, observed ? nil : .documentPresenceUnavailable)
        engine.stop()
        await engine.recordingSettlement?.value
        storage.cleanup()
      }
    }

    func testGeometryRecoveryCannotBeOverwrittenByOldBeginAcknowledgment() async throws {
      let pending = expectation(description: "First begin pending")
      var continuation: CheckedContinuation<DocumentTiltPresentation, Error>?
      var begun: [UUID] = []
      let engine = model(
        actions: .init(
          begin: { camera, id in
            begun.append(id)
            camera.tiltGuidanceDelivery.begin(runID: id)
            if begun.count == 1 {
              return try await withCheckedThrowingContinuation {
                continuation = $0
                pending.fulfill()
              }
            }
            return DocumentTiltController(runID: id).presentation
          }, end: { _, _, _ in }))
      let storage = try TiltMechanismFixture()
      defer { storage.cleanup() }
      activate(engine)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: storage.store, clock: .tiltFixture,
        policy: .retainedV1)
      engine.journeyRecording = journal
      engine.camera.tiltGuidanceDelivery.activate(generation: 0)
      engine.tiltGuidance.lifecycle = .waiting
      engine.startTiltIfRequested(camera: engine.camera, generation: engine.generation)
      let firstTask = engine.tiltGuidance.startTask
      await fulfillment(of: [pending], timeout: 1)
      let old = try XCTUnwrap(engine.tiltGuidance.runID)
      var controller = DocumentTiltController(runID: old)
      let initial = controller.presentation
      engine.receiveTilt(
        controller.cancel(reason: .geometryChanged).presentation,
        generation: engine.generation)
      await engine.tiltGuidance.controlTask?.value
      await engine.tiltGuidance.startTask?.value
      let replacement = engine.tiltGuidance.runID
      continuation?.resume(returning: initial)
      await firstTask?.value
      XCTAssertEqual(begun.count, 2)
      XCTAssertNotEqual(replacement, old)
      XCTAssertEqual(engine.tiltGuidance.runID, replacement)
      XCTAssertEqual(engine.tiltGuidance.presentation?.runID, replacement)
      XCTAssertFalse(engine.autoArmed)
      engine.stop()
      await engine.recordingSettlement?.value
    }

    func testStopDuringGeometryReleasePreventsAutomaticRestart() async throws {
      let ending = expectation(description: "Geometry release pending")
      var continuation: CheckedContinuation<Void, Never>?
      var begins = 0
      let engine = model(
        actions: .init(
          begin: { _, id in
            begins += 1
            return DocumentTiltController(runID: id).presentation
          },
          end: { _, _, _ in
            await withCheckedContinuation {
              continuation = $0
              ending.fulfill()
            }
          }))
      activate(engine)
      var controller = DocumentTiltController(runID: try XCTUnwrap(engine.tiltGuidance.runID))
      engine.receiveTilt(
        controller.cancel(reason: .geometryChanged).presentation,
        generation: engine.generation)
      let release = engine.tiltGuidance.controlTask
      await fulfillment(of: [ending], timeout: 1)
      engine.stop()
      continuation?.resume()
      await release?.value
      XCTAssertEqual(begins, 0)
      XCTAssertNil(engine.tiltGuidance.runID)
      XCTAssertFalse(engine.autoArmed)
      XCTAssertEqual(engine.phase, .inactive)
    }

    func testGeometryChangeReacquiresFreshBaselineAfterReleaseOnSameRecording() async throws {
      let ending = expectation(description: "Old measurement releases")
      var continuation: CheckedContinuation<Void, Never>?
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
              continuation = $0
              ending.fulfill()
            }
          }))
      let storage = try TiltMechanismFixture()
      defer { storage.cleanup() }
      activate(engine)
      let old = try XCTUnwrap(engine.tiltGuidance.runID)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: storage.store, clock: .tiltFixture,
        policy: .retainedV1)
      engine.journeyRecording = journal
      engine.camera.tiltGuidanceDelivery.activate(generation: 0)
      let camera = engine.camera
      let generation = engine.generation
      var controller = DocumentTiltController(runID: old)
      let terminal = controller.cancel(reason: .geometryChanged).presentation
      engine.receiveTilt(terminal, generation: generation)
      let release = engine.tiltGuidance.controlTask
      await fulfillment(of: [ending], timeout: 1)
      XCTAssertEqual(engine.tiltCaptureGuidance, .starting)
      XCTAssertTrue(begun.isEmpty, "No replacement before native release")
      XCTAssertFalse(engine.autoArmed)
      continuation?.resume()
      await release?.value
      await engine.tiltGuidance.startTask?.value
      XCTAssertEqual(begun.count, 1, "Geometry recovery requires no user retry")
      if let replacement = engine.tiltGuidance.runID,
        let baseline = engine.tiltGuidance.presentation
      {
        XCTAssertNotEqual(replacement, old)
        XCTAssertEqual(baseline.phase, .baseline)
        XCTAssertNil(baseline.baseline)
        XCTAssertEqual(baseline.consecutiveObservations, 0)
        XCTAssertEqual(engine.tiltCaptureGuidance, .movement(baseline, restartingBaseline: true))
        engine.receiveTilt(terminal, generation: generation)
        XCTAssertEqual(
          engine.tiltGuidance.runID, replacement, "Old evidence cannot cancel the replacement")
      } else {
        XCTFail("Expected a fresh baseline")
      }
      XCTAssertTrue(engine.camera === camera)
      XCTAssertEqual(engine.generation, generation)
      XCTAssertTrue(
        engine.journeyRecording === journal, "Recovery must not restart the recording budget")
      XCTAssertFalse(engine.autoArmed)
      engine.stop()
      await engine.recordingSettlement?.value
    }

    func testLateGeometryReceiptRecoversAfterGenericBeginFailure() async throws {
      for awaitingRelease in [false, true] {
        var begun: [UUID] = []
        let engine = model(
          actions: .init(
            begin: { camera, id in
              begun.append(id)
              camera.tiltGuidanceDelivery.begin(runID: id)
              return DocumentTiltController(runID: id).presentation
            }, end: { _, _, _ in }))
        let storage = try TiltMechanismFixture()
        activate(engine)
        let old = try XCTUnwrap(engine.tiltGuidance.runID)
        let journal = try await CaptureRecordingJournal.start(
          workflowID: engine.workflowID, store: storage.store, clock: .tiltFixture,
          policy: .retainedV1)
        engine.journeyRecording = journal
        engine.camera.tiltGuidanceDelivery.activate(generation: 0)
        let result = CaptureSessionTiltState.Result(
          runID: old, outcome: .incomplete, reason: .observationUnavailable)
        if awaitingRelease {
          // Deliver the generic error through the real release path before its task runs.
          var failed = DocumentTiltController(runID: old)
          engine.receiveTilt(
            failed.cancel(reason: .observationUnavailable).presentation,
            generation: engine.generation)
        } else {
          engine.tiltGuidance.lifecycle = .retryable(result)
        }
        let geometry = DocumentTiltPresentation(
          runID: old, revision: 3, phase: .cancelled, reason: .geometryChanged,
          baseline: nil, signedDelta: nil, consecutiveObservations: 0, dwellSeconds: 0)
        engine.receiveTilt(geometry, generation: engine.generation)
        await engine.tiltGuidance.controlTask?.value
        await engine.tiltGuidance.startTask?.value
        XCTAssertEqual(begun.count, 1)
        XCTAssertNotEqual(engine.tiltGuidance.runID, old)
        XCTAssertFalse(engine.autoArmed)
        XCTAssertFalse(engine.tiltGuidance.needsRetry)
        engine.stop()
        await engine.recordingSettlement?.value
        storage.cleanup()
      }
    }
  }
#endif
