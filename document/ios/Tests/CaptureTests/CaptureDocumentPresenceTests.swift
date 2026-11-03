#if os(iOS)
  import CoreLocation
  import Foundation
  import XCTest

  @testable import DocumentCapture
  @testable import DocumentCaptureJournal
  import CaptureEvidenceCustody
  @testable import DocumentCaptureApple

  /// S-02 (RFC-0002 §4.5 live capture/document presence; owner decision 13): a document presence
  /// policy gates the front still on completed tilt guidance and retains the temporal window, with
  /// every value named and attributed by the host. The values below are synthetic test inputs, not
  /// measurements; the SDK ships none until the owner's device measurement.
  @MainActor
  final class CaptureDocumentPresenceTests: XCTestCase {
    private func policy(
      reserveBytes: Int = 1_048_576, reserveSeconds: Double = 1,
      enforcement: DocumentPresencePolicy.Enforcement = .enforce
    ) throws -> DocumentPresencePolicy {
      let enforced = try DocumentPresencePolicy(
        identifier: "synthetic-presence-test",
        attribution: "synthetic test inputs, not a measurement",
        tiltReserveBytes: reserveBytes, tiltReserveSeconds: reserveSeconds,
        windowBeforeStillSeconds: 1, windowAfterStillSeconds: 0.5, windowMaximumBytes: 2_097_152)
      return enforcement == .observe ? enforced.observed() : enforced
    }

    func testAPolicyWithoutANameOrWithANonPositiveValueIsRefused() {
      let invalid: [() throws -> DocumentPresencePolicy] = [
        {
          try .init(
            identifier: "", attribution: "a", tiltReserveBytes: 1, tiltReserveSeconds: 1,
            windowBeforeStillSeconds: 1, windowAfterStillSeconds: 1, windowMaximumBytes: 1)
        },
        {
          try .init(
            identifier: "p", attribution: "", tiltReserveBytes: 1, tiltReserveSeconds: 1,
            windowBeforeStillSeconds: 1, windowAfterStillSeconds: 1, windowMaximumBytes: 1)
        },
        {
          try .init(
            identifier: "p", attribution: "a", tiltReserveBytes: 0, tiltReserveSeconds: 1,
            windowBeforeStillSeconds: 1, windowAfterStillSeconds: 1, windowMaximumBytes: 1)
        },
        {
          try .init(
            identifier: "p", attribution: "a", tiltReserveBytes: 1, tiltReserveSeconds: .nan,
            windowBeforeStillSeconds: 1, windowAfterStillSeconds: 1, windowMaximumBytes: 1)
        },
        {
          try .init(
            identifier: "p", attribution: "a", tiltReserveBytes: 1, tiltReserveSeconds: 1,
            windowBeforeStillSeconds: -1, windowAfterStillSeconds: 1, windowMaximumBytes: 1)
        },
        {
          try .init(
            identifier: "p", attribution: "a", tiltReserveBytes: 1, tiltReserveSeconds: 1,
            windowBeforeStillSeconds: 1, windowAfterStillSeconds: 1, windowMaximumBytes: 0)
        },
      ]
      for make in invalid {
        XCTAssertThrowsError(try make()) {
          XCTAssertEqual($0 as? DocumentPresencePolicyError, .invalidValue)
        }
      }
    }

    func testAPolicyRunsTiltOnEveryFrontWithoutTheHostAsking() async throws {
      let engine = makeTiltSession(presence: try policy())
      engine.beginJourney(.licenseFront, workflowID: UUID())
      let opening = engine.operation
      XCTAssertTrue(engine.tiltDefersAutomaticCapture)
      XCTAssertFalse(engine.autoArmed)
      engine.stop()
      await opening?.value
      // Without a policy the ordinary front still never waits, as before.
      let ordinary = makeTiltSession()
      ordinary.beginJourney(.licenseFront, workflowID: UUID())
      let other = ordinary.operation
      XCTAssertFalse(ordinary.tiltDefersAutomaticCapture)
      ordinary.stop()
      await other?.value
    }

    func testTheTemporalWindowIsRetainedWithThePolicyValues() throws {
      let window = CaptureSession.captureConfiguration(livePDF417: false, presence: try policy())
        .temporalEvidence
      XCTAssertTrue(window.enabled)
      XCTAssertEqual(window.preCaptureDuration, 1)
      XCTAssertEqual(window.postCaptureDuration, 0.5)
      XCTAssertEqual(window.maximumBytes, 2_097_152)
      XCTAssertFalse(
        CaptureSession.captureConfiguration(livePDF417: false, presence: nil).temporalEvidence
          .enabled)
    }

    /// The fixed practice reserve (4 GiB, 30 s) cannot fit the default recording policy (512 MiB,
    /// 20 s); the policy's own reserve is what admits guidance.
    func testThePolicyReserveAdmitsTiltUnderTheDefaultRecordingPolicy() async throws {
      for (presence, admitted) in [(try policy(), true)] {
        let fixture = try TiltMechanismFixture()
        defer { fixture.cleanup() }
        let engine = makeTiltSession(presence: presence)
        engine.profile = .licenseFront
        engine.phase = .capturing
        engine.ready = true
        engine.tiltGuidance.requestedForFront = true
        engine.resetTiltForCameraStart(recordingOnly: false)
        // The default recording policy, retainedV2: 512 MiB and 20 s.
        engine.journeyRecording = try await CaptureRecordingJournal.start(
          workflowID: engine.workflowID, store: fixture.store, clock: .tiltFixture)
        XCTAssertEqual(
          engine.admitTiltBudget(runID: UUID(), generation: engine.cameraGeneration), admitted)
        engine.stop()
        await engine.recordingSettlement?.value
      }
    }

    func testCaptureNowAndSkipCannotTakeTheStillBeforeTiltCompletes() async throws {
      var captured = 0
      let engine = makeTiltSession(
        capturePhoto: { _, _ in
          captured += 1
          throw PhotoCaptureError.cameraNotReady
        }, presence: try policy())
      try await prepare(engine)
      engine.capture()
      engine.skipTiltGuidance()
      engine.capture(observation: nil)
      await engine.operation?.value
      XCTAssertEqual(captured, 0)
      XCTAssertEqual(engine.issue, .documentPresenceRequired)
      XCTAssertNotNil(engine.tiltGuidance.runID, "guidance was not released")
      XCTAssertNotEqual(engine.tiltGuidance.outcome, .skipped)
      XCTAssertTrue(engine.tiltDefersAutomaticCapture)
      // Completed guidance admits the still.
      engine.tiltGuidance.lifecycle = .released(
        .init(runID: engine.tiltGuidance.runID, outcome: .completed, reason: nil))
      engine.capture(observation: nil)
      await engine.operation?.value
      XCTAssertEqual(captured, 1)
      engine.stop()
      await engine.recordingSettlement?.value
      try await engine.erase()
    }

    func testAnExhaustedReserveStopsTheFrontStillInsteadOfReleasingCapture() async throws {
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      let engine = try await exhaustTiltReserve(try policy(), store: fixture.store)
      XCTAssertEqual(engine.issue, .documentPresenceUnavailable)
      XCTAssertEqual(engine.tiltGuidance.outcome, .incomplete)
      XCTAssertFalse(engine.autoArmed)
      XCTAssertTrue(engine.tiltDefersAutomaticCapture)
      engine.stop()
      await engine.recordingSettlement?.value
    }

    func testTheRetainedStillRecordsThePolicyThatAdmittedIt() async throws {
      let record = CaptureDocumentPresenceRecord(
        policyIdentifier: "synthetic-presence-test",
        attribution: "synthetic test inputs, not a measurement")
      let saved = try JSONDecoder().decode(
        CaptureRecords.Manifest.self, from: try await retainFront(record))
      XCTAssertEqual(saved.documentPresence, record)
      XCTAssertEqual(saved.origin, .liveSensor)
    }

    // MARK: - Observe mode: tilt runs and is recorded, the still is never refused on it.

    func testAPolicyEnforcesUnlessTheHostAsksOnlyToObserve() throws {
      XCTAssertEqual(try policy().enforcement, .enforce)
      XCTAssertEqual(try policy(enforcement: .observe).enforcement, .observe)
      // A policy or a record encoded before observe mode existed was enforced.
      let encoded = try JSONEncoder().encode(try policy())
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      object.removeValue(forKey: "enforcement")
      let older = try JSONDecoder().decode(
        DocumentPresencePolicy.self, from: JSONSerialization.data(withJSONObject: object))
      XCTAssertEqual(older, try policy())
      let record = try JSONDecoder().decode(
        CaptureDocumentPresenceRecord.self,
        from: Data(#"{"policyIdentifier":"p","attribution":"a"}"#.utf8))
      XCTAssertEqual(record.enforcement, .enforce)
      XCTAssertEqual(
        try JSONDecoder().decode(
          DocumentPresencePolicy.self, from: JSONEncoder().encode(try policy(enforcement: .observe))
        ),
        try policy(enforcement: .observe))
    }

    func testAnObservedPolicyStillRunsTiltAndRetainsTheWindow() async throws {
      let observed = try policy(enforcement: .observe)
      let engine = makeTiltSession(presence: observed)
      engine.beginJourney(.licenseFront, workflowID: UUID())
      let opening = engine.operation
      XCTAssertTrue(
        engine.tiltDefersAutomaticCapture, "tilt runs on the front without the host asking")
      XCTAssertFalse(engine.presenceGatesCapture)
      engine.stop()
      await opening?.value
      let window = CaptureSession.captureConfiguration(livePDF417: false, presence: observed)
        .temporalEvidence
      XCTAssertTrue(window.enabled)
      XCTAssertEqual(window.maximumBytes, 2_097_152)
    }

    func testUnderObserveCaptureNowAndSkipAreAllowed() async throws {
      var captured = 0
      let engine = makeTiltSession(
        capturePhoto: { _, _ in
          captured += 1
          throw PhotoCaptureError.cameraNotReady
        }, presence: try policy(enforcement: .observe))
      try await prepare(engine)
      engine.capture()
      await engine.tiltGuidance.controlTask?.value
      await engine.operation?.value
      XCTAssertEqual(captured, 1, "capture-now takes the still before tilt completes")
      XCTAssertNotEqual(engine.issue, .documentPresenceRequired)
      XCTAssertEqual(engine.tiltGuidance.outcome, .incomplete)
      XCTAssertEqual(engine.tiltGuidance.reason, .userCaptureNow)
      engine.stop()
      await engine.recordingSettlement?.value
      try await engine.erase()

      let skipping = makeTiltSession(presence: try policy(enforcement: .observe))
      try await prepare(skipping)
      skipping.skipTiltGuidance()
      await skipping.tiltGuidance.controlTask?.value
      XCTAssertNotEqual(skipping.issue, .documentPresenceRequired)
      XCTAssertEqual(skipping.tiltGuidance.outcome, .skipped)
      skipping.stop()
      await skipping.recordingSettlement?.value
      try await skipping.erase()
    }

    func testUnderObserveAnExhaustedReserveReleasesCaptureInsteadOfStoppingIt() async throws {
      let fixture = try TiltMechanismFixture()
      defer { fixture.cleanup() }
      let engine = try await exhaustTiltReserve(
        try policy(enforcement: .observe), store: fixture.store)
      XCTAssertNil(engine.issue)
      XCTAssertEqual(engine.tiltGuidance.outcome, .incomplete)
      XCTAssertEqual(engine.tiltGuidance.reason, .recordingBudget)
      XCTAssertFalse(engine.tiltDefersAutomaticCapture, "the reserve released capture")
      engine.stop()
      await engine.recordingSettlement?.value
    }

    func testTheRetainedStillRecordsThatTiltWasObservedNotRequired() async throws {
      let engine = makeTiltSession(presence: try policy(enforcement: .observe))
      engine.profile = .licenseFront
      XCTAssertEqual(
        engine.presenceRecord,
        CaptureDocumentPresenceRecord(
          policyIdentifier: "synthetic-presence-test",
          attribution: "synthetic test inputs, not a measurement",
          enforcement: .observe))
      let enforced = makeTiltSession(presence: try policy())
      enforced.profile = .licenseFront
      XCTAssertEqual(enforced.presenceRecord?.enforcement, .enforce)
      enforced.profile = .licenseBack
      XCTAssertNil(enforced.presenceRecord, "backs are not tilted")
      let stored = try await retainFront(try XCTUnwrap(engine.presenceRecord))
      let saved = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: stored)
      XCTAssertEqual(saved.documentPresence?.enforcement, .observe)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
      XCTAssertEqual(
        (object["documentPresence"] as? [String: Any])?["enforcement"] as? String, "observe")
    }

    // MARK: - Fixtures

    /// A front session whose running tilt guidance has just used up the policy's reserve.
    private func exhaustTiltReserve(
      _ presence: DocumentPresencePolicy, store: CaptureEvidenceStore
    ) async throws -> CaptureSession {
      let engine = makeTiltSession(
        tiltActions: .init(
          begin: { _, id in DocumentTiltController(runID: id).presentation }, end: { _, _, _ in }),
        presence: presence)
      engine.profile = .licenseFront
      engine.phase = .capturing
      engine.ready = true
      engine.tiltGuidance.requestedForFront = true
      engine.resetTiltForCameraStart(recordingOnly: false)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: store, clock: .tiltFixture)
      engine.journeyRecording = journal
      let runID = UUID()
      XCTAssertTrue(engine.admitTiltBudget(runID: runID, generation: engine.cameraGeneration))
      engine.tiltGuidance.lifecycle = .measuring(.init(runID: runID))
      journal.lock.withLock {
        journal.chargedBytes = journal.maximumDiskBytes - presence.tiltReserveBytes
      }
      journal.notifyTiltBudget()
      for _ in 0..<100 where engine.tiltGuidance.reason != .recordingBudget { await Task.yield() }
      await engine.tiltGuidance.controlTask?.value
      return engine
    }

    /// Retains a synthetic front still with `record` and returns the manifest bytes custody stored.
    private func retainFront(_ record: CaptureDocumentPresenceRecord) async throws -> Data {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let request = CameraPhotoCaptureRequest(
        sessionID: manifest.sessionID, side: .front, qualityGate: .qualityDrivenAutoCapture,
        attemptID: manifest.captureID, userRequestedAt: manifest.processedAt)
      let photo = CapturedDocumentPhoto(
        sessionID: manifest.sessionID, side: .front, requestedAt: manifest.processedAt,
        captureTimestamp: manifest.captureTimestamp, processedAt: manifest.processedAt,
        data: fixture.pixels, fidelity: manifest.fidelity,
        admission: .init(
          request: request, admittedAt: manifest.processedAt, photoSettingsUniqueID: 1,
          observation: nil))
      try await CaptureOriginalCustody.retain(
        photo, captureID: manifest.captureID, profile: .licenseFront,
        workflowID: try XCTUnwrap(manifest.workflowID),
        precedingFrontCaptureID: nil, journeyRevision: nil, tuning: .init(), store: fixture.store,
        hostTime: { ProcessInfo.processInfo.systemUptime }, documentPresence: record)
      return try await fixture.store.read(id: manifest.captureID).manifest
    }

    private func prepare(_ engine: CaptureSession) async throws {
      let store = try engine.openCustody()
      engine.phase = .capturing
      engine.ready = true
      engine.tiltGuidance.requestedForFront = true
      engine.resetTiltForCameraStart(recordingOnly: false)
      engine.tiltGuidance.lifecycle = .measuring(.init(runID: UUID()))
      engine.disarmAutomaticCapture()
      engine.location.startUpdatesIfAuthorized()
      engine.location.locationManager(
        CLLocationManager(),
        didUpdateLocations: [
          CLLocation(
            coordinate: .init(latitude: 1, longitude: 1), altitude: 0,
            horizontalAccuracy: 1, verticalAccuracy: 1, timestamp: engine.configuration.clock.now())
        ])
      engine.journeyRecording = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: store, clock: .tiltFixture)
    }
  }
#endif
