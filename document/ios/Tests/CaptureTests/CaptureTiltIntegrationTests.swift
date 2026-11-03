#if os(iOS)
  import CoreLocation
  import Foundation
  import XCTest

  @testable import DocumentCapture
  @testable import DocumentCaptureJournal
  import CaptureEvidenceCustody
  @testable import DocumentCaptureApple

  @MainActor
  final class CaptureTiltIntegrationTests: XCTestCase {
    func testOptInDefersAutomaticCaptureBeforeStartupTaskCanRun() async {
      let engine = model()
      engine.beginJourney(.licenseFront, workflowID: UUID(), includeTiltPractice: true)
      let opening = engine.operation
      XCTAssertTrue(engine.tiltDefersAutomaticCapture)
      XCTAssertFalse(engine.autoArmed)
      engine.prepareAutomaticCapture()
      XCTAssertFalse(engine.autoArmed)
      engine.stop()
      await opening?.value
    }

    func testOrdinaryAndBackCaptureNeverWaitForTilt() async {
      for profile in [CaptureRecords.Profile.licenseFront, .licenseBack] {
        let engine = model()
        engine.beginJourney(profile, workflowID: UUID(), includeTiltPractice: profile.backSide)
        let opening = engine.operation
        XCTAssertFalse(engine.tiltDefersAutomaticCapture)
        XCTAssertTrue(engine.autoArmed)
        engine.stop()
        await opening?.value
      }
    }

    func testSkipReleasesNativeHoldBeforeArmingOrdinaryCapture() async {
      let released = expectation(description: "Native end requested")
      var continuation: CheckedContinuation<Void, Never>?
      let engine = model(
        actions: .init(end: { _, _, reason in
          XCTAssertEqual(reason, .userSkipped)
          await withCheckedContinuation { value in
            continuation = value
            released.fulfill()
          }
        }))
      activate(engine)
      engine.skipTiltGuidance()
      let task = engine.tiltGuidance.controlTask
      await fulfillment(of: [released], timeout: 1)
      XCTAssertFalse(engine.autoArmed)
      XCTAssertTrue(engine.tiltDefersAutomaticCapture)
      continuation?.resume()
      await task?.value
      XCTAssertTrue(engine.autoArmed)
      XCTAssertFalse(engine.tiltDefersAutomaticCapture)
      XCTAssertNil(engine.tiltGuidance.runID)
      engine.stop()
    }

    func testStopDuringReleaseCannotRearmReplacementSession() async {
      let ending = expectation(description: "Native end requested")
      var continuation: CheckedContinuation<Void, Never>?
      let engine = model(
        actions: .init(end: { _, _, _ in
          await withCheckedContinuation { value in
            continuation = value
            ending.fulfill()
          }
        }))
      activate(engine)
      engine.skipTiltGuidance()
      let task = engine.tiltGuidance.controlTask
      await fulfillment(of: [ending], timeout: 1)
      engine.stop()
      continuation?.resume()
      await task?.value
      XCTAssertFalse(engine.autoArmed)
      XCTAssertEqual(engine.phase, .inactive)
      XCTAssertNil(engine.tiltGuidance.runID)
    }

    func testManualCaptureReleasesGuidanceBeforeAdmittingStill() async throws {
      try await exerciseManualCapture(duringRelease: false)
    }

    func testCaptureNowDuringBlockedSkipIsPreserved() async throws {
      try await exerciseManualCapture(duringRelease: true)
    }

    func testCaptureNowRemainsAvailableWhileSupplementaryBeginWaits() async throws {
      try await exerciseManualCapture(duringRelease: false, pendingBegin: true)
    }

    func testManualCaptureRemainsUsableDuringFailureRelease() async throws {
      try await exerciseManualCapture(duringRelease: false, failedGuidance: true)
    }

    private func exerciseManualCapture(
      duringRelease: Bool, pendingBegin: Bool = false, failedGuidance: Bool = false
    ) async throws {
      var order: [String] = []
      let ending = expectation(description: "Native end began")
      let beginning = pendingBegin ? expectation(description: "Native begin waits") : nil
      var beginContinuation: CheckedContinuation<DocumentTiltPresentation, Error>?
      var continuation: CheckedContinuation<Void, Never>?
      let engine = makeTiltSession(
        capturePhoto: { _, request in
          order.append("capture")
          XCTAssertEqual(request.qualityGate, .operatorInitiatedAdvisory)
          throw PhotoCaptureError.cameraNotReady
        },
        tiltActions: .init(
          begin: { _, id in
            guard pendingBegin else { return DocumentTiltController(runID: id).presentation }
            return try await withCheckedThrowingContinuation { value in
              beginContinuation = value
              beginning?.fulfill()
            }
          },
          end: { _, _, reason in
            XCTAssertEqual(
              reason, failedGuidance ? .cancelled : (duringRelease ? .userSkipped : .userCaptureNow)
            )
            order.append("end")
            beginContinuation?.resume(throwing: CancellationError())
            beginContinuation = nil
            await withCheckedContinuation { value in
              continuation = value
              ending.fulfill()
            }
          }))
      try await prepareManualCapture(engine)
      if let beginning { await waitForBegin(engine, beginning: beginning) }
      if failedGuidance {
        try failGuidance(engine)
      } else if duringRelease {
        engine.skipTiltGuidance()
      } else {
        engine.capture()
      }
      let release = engine.tiltGuidance.controlTask
      await fulfillment(of: [ending], timeout: 1)
      if duringRelease || failedGuidance { engine.capture() }
      continuation?.resume()
      await release?.value
      await engine.operation?.value
      XCTAssertEqual(engine.tiltGuidance.outcome, duringRelease ? .skipped : .incomplete)
      await finishManualCapture(engine, order: order)
      try await engine.erase()
    }

    func testBeginResultCannotOverwriteNewerStreamPresentation() throws {
      let engine = model()
      activate(engine)
      let runID = try XCTUnwrap(engine.tiltGuidance.runID)
      let initial = DocumentTiltController(runID: runID).presentation
      let newer = DocumentTiltPresentation(
        runID: runID, revision: 9, phase: .baseline,
        reason: .baselineUnstable, baseline: nil, signedDelta: nil,
        consecutiveObservations: 0, dwellSeconds: 0)
      engine.receiveTilt(newer, generation: engine.cameraGeneration)
      engine.receiveTilt(initial, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltGuidance.presentation, newer)
      engine.stop()
    }

    func testOldRunSnapshotCannotAffectNewAttempt() {
      let engine = model()
      activate(engine)
      let old = DocumentTiltController(runID: UUID()).presentation
      engine.receiveTilt(old, generation: engine.cameraGeneration)
      XCTAssertNil(engine.tiltGuidance.presentation)
      let current = engine.tiltGuidance.runID
      engine.resetTiltForCameraStart(recordingOnly: false)
      XCTAssertNil(engine.tiltGuidance.runID)
      XCTAssertNil(engine.tiltGuidance.presentation)
      XCTAssertTrue(engine.tiltDefersAutomaticCapture)
      XCTAssertNotNil(current)
      engine.stop()
    }

    func testJournalValidatesTypedTiltEventsAndOptionalTurnoverRemainsInformational() async throws {
      for mismatched in [false, true] {
        let fixture = try TiltMechanismFixture()
        defer { fixture.cleanup() }
        let journal = try await CaptureRecordingJournal.start(
          workflowID: UUID(), store: fixture.store, clock: .tiltFixture)
        let update = DocumentTiltController(runID: UUID()).initialUpdate
        let fakeTime = DocumentCaptureClockTimestamp(
          value: 1, timescale: 30, flags: 1, epoch: 0, clock: .captureSessionSynchronizationClock)
        journal.appendEvent(
          .init(
            kind: "tilt_guidance", hostTimeSeconds: 1,
            timestamp: mismatched ? fakeTime : nil, tiltGuidance: update))
        journal.appendEvent(
          .init(
            kind: "turnover_optional_prompt", hostTimeSeconds: 2,
            contextCode: "operator_selected;outcome=indeterminate"))
        journal.appendEvent(
          .init(
            kind: "turnover_optional_end", hostTimeSeconds: 3,
            contextCode: "outcome=skipped"))
        _ = try await journal.finish(reason: "operator_stop")
        do {
          _ = try await CaptureRecordingVerification.verify(
            journal.reference, store: fixture.store)
          XCTAssertFalse(mismatched, "Mismatched typed tilt event was accepted")
        } catch {
          XCTAssertTrue(mismatched, "Valid typed tilt event was rejected: \(error)")
        }
        XCTAssertFalse(CaptureRecordingVerification.isIssue("tilt_guidance"))
        XCTAssertFalse(CaptureRecordingVerification.isIssue("turnover_optional_prompt"))
        XCTAssertFalse(CaptureRecordingVerification.isIssue("turnover_optional_end"))
      }
    }

    func model(actions: TiltTestActions = .init()) -> CaptureSession {
      makeTiltSession(tiltActions: actions)
    }

    func activate(_ engine: CaptureSession) {
      engine.phase = .capturing
      engine.ready = true
      engine.tiltGuidance.requestedForFront = true
      engine.resetTiltForCameraStart(recordingOnly: false)
      engine.tiltGuidance.lifecycle = .measuring(.init(runID: UUID()))
      engine.disarmAutomaticCapture()
    }
  }

  extension CaptureTiltIntegrationTests {
    private func waitForBegin(_ engine: CaptureSession, beginning: XCTestExpectation) async {
      engine.tiltGuidance.lifecycle = .waiting
      engine.startTiltIfRequested(camera: engine.camera, generation: engine.cameraGeneration)
      await fulfillment(of: [beginning], timeout: 1)
      XCTAssertFalse(engine.busy)
      XCTAssertNil(engine.operation)
    }

    private func finishManualCapture(_ engine: CaptureSession, order: [String]) async {
      XCTAssertEqual(order, ["end", "capture"])
      engine.stop()
      await engine.recordingSettlement?.value
    }

    private func failGuidance(_ engine: CaptureSession) throws {
      let id = try XCTUnwrap(engine.tiltGuidance.runID)
      engine.receiveTilt(
        DocumentTiltPresentation(
          runID: id, revision: 2, phase: .cancelled,
          reason: .observationUnavailable, baseline: nil, signedDelta: nil,
          consecutiveObservations: 0, dwellSeconds: 0), generation: engine.cameraGeneration)
    }

    private func prepareManualCapture(_ engine: CaptureSession) async throws {
      let store = try engine.openCustody()
      activate(engine)
      engine.location.startUpdatesIfAuthorized()
      engine.location.locationManager(
        CLLocationManager(),
        didUpdateLocations: [
          CLLocation(
            coordinate: .init(latitude: 1, longitude: 1), altitude: 0,
            horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: engine.configuration.clock.now())
        ])
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: store, clock: .tiltFixture, policy: .retainedV1)
      XCTAssertTrue(
        journal.tiltBudgetSnapshot().tiltBudgetAvailable,
        "This fixture must admit optional tilt before testing its lifecycle")
      engine.journeyRecording = journal
    }
  }

#endif
