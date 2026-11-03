import Foundation
import XCTest

@testable import BiometricCapture

/// Failure-mode coverage for the purpose-built selfie-admission gate.
///
/// The gate this replaces admitted a frame with the holder's eyes shut, and a held closure kept
/// its blink evidence permanently fresh. Those two behaviours are the first two tests here.
final class SelfieAdmissionPolicyTests: XCTestCase {
  // MARK: - The defects that motivated the replacement

  func testEyesHeldClosedNeverAdmitAndNeverAutoCapture() {
    var (gate, time) = blinkedGate()
    while time < 4 {
      time += 0.02
      gate.observe(observation(at: time, eyeClosed: 0.9), now: time)
      XCTAssertEqual(
        gate.admit(frameTimestamp: time, now: time, trigger: .automatic),
        .refuse(.eyesClosed))
      XCTAssertEqual(
        gate.admit(frameTimestamp: time, now: time, trigger: .manual),
        .refuse(.eyesClosed))
    }
    XCTAssertTrue(gate.trackingObserved, "tracking is unaffected; only admission is refused")
  }

  func testHeldClosureRecordsTheBlinkOnceSoFreshnessStillExpires() {
    var (gate, time) = blinkedGate()
    let closedFrom = time
    while time < closedFrom + 4.5 {
      time += 0.02
      gate.observe(observation(at: time, eyeClosed: 0.9), now: time)
    }
    // Reopening now completes a blink whose close is still inside the freshness window.
    time += 0.02
    gate.observe(observation(at: time, eyeClosed: 0), now: time)
    guard case .admit = gate.admit(frameTimestamp: time, now: time, trigger: .manual) else {
      return XCTFail("a blink 4.5 s old is still fresh")
    }

    var (expired, later) = blinkedGate()
    let start = later
    while later < start + 6 {
      later += 0.02
      expired.observe(observation(at: later, eyeClosed: 0.9), now: later)
    }
    later += 0.02
    expired.observe(observation(at: later, eyeClosed: 0), now: later)
    XCTAssertEqual(
      expired.admit(frameTimestamp: later, now: later, trigger: .manual),
      .refuse(.blinkNotObserved),
      "a held closure must not keep rewriting the blink timestamp")
  }

  func testClosingWithoutReopeningIsNotACompletedBlink() {
    var (gate, time) = trackedGate()
    time += 0.02
    gate.observe(observation(at: time, eyeClosed: 0.9), now: time)  // close only
    XCTAssertEqual(gate.currentBlinkPhase, .sawClosedEyes)
    XCTAssertEqual(
      gate.admit(frameTimestamp: time, now: time, trigger: .manual),
      .refuse(.eyesClosed))
  }

  func testNeverBlinkingNeverAdmits() {
    var gate = SelfieAdmissionGate()
    gate.start(at: 1)
    var time = 1.0
    for index in 0..<200 {
      time = 1 + Double(index) * 0.02
      gate.observe(observation(at: time, eyeClosed: 0), now: time)
      let decision = gate.admit(frameTimestamp: time, now: time, trigger: .manual)
      guard case .refuse(let reason) = decision else {
        return XCTFail("admitted without a blink at t=\(time)")
      }
      // Before the frame floor the first failing condition is tracking, which is the
      // better instruction; after it, the missing blink is what stands in the way.
      XCTAssertTrue(
        [.trackingNotSteady, .blinkNotObserved].contains(reason), "\(reason)")
    }
  }

  // MARK: - The admitting path

  func testCompletedBlinkWithOpenEyesIsAdmittedManually() {
    let (gate, time) = reopenedGate()
    var subject = gate
    guard
      case .admit(let receipt) = subject.admit(
        frameTimestamp: time, now: time, trigger: .manual)
    else { return XCTFail("a completed blink with open eyes must admit") }
    XCTAssertEqual(receipt.blinkCompletedAt, time)
    XCTAssertEqual(receipt.blinkAge, 0)
    XCTAssertTrue(receipt.eyesOpen)
    XCTAssertEqual(receipt.trigger, .manual)
    XCTAssertEqual(receipt.frameTimestamp, time)
    XCTAssertEqual(receipt.policyVersion, SelfieAdmissionPolicy.version)
    XCTAssertGreaterThanOrEqual(receipt.consecutiveTrackedFrames, 10)
  }

  func testAutomaticCaptureRequiresTheSteadyHold() {
    var (gate, time) = reopenedGate()
    XCTAssertEqual(
      gate.admit(frameTimestamp: time, now: time, trigger: .automatic),
      .refuse(.steadyHoldIncomplete))
    var fired: Double?
    let from = time
    while time < from + 1.6 {
      time += 0.02
      gate.observe(observation(at: time, eyeClosed: 0), now: time)
      if fired == nil,
        case .admit = gate.admit(frameTimestamp: time, now: time, trigger: .automatic)
      {
        fired = time
      }
    }
    XCTAssertEqual(try XCTUnwrap(fired) - from, 1, accuracy: 0.03)
  }

  // MARK: - Safeguards carried over from the replaced gate

  func testAdmissionRequiresTheExactAcceptedFrame() {
    var (gate, time) = reopenedGate()
    XCTAssertEqual(
      gate.admit(frameTimestamp: time - 0.02, now: time, trigger: .manual),
      .refuse(.frameNotCurrent))
    XCTAssertEqual(
      gate.admit(frameTimestamp: time + 0.02, now: time, trigger: .manual),
      .refuse(.frameNotCurrent))
  }

  func testStaleFrameIsRefusedEvenWhenOtherwiseAdmissible() {
    var (gate, time) = reopenedGate()
    XCTAssertEqual(
      gate.admit(frameTimestamp: time, now: time + 0.3, trigger: .manual),
      .refuse(.frameStale))
  }

  func testDuplicateAndReorderedFramesCannotSeedANewSequence() {
    var (gate, time) = reopenedGate()
    let readiness = gate.observe(observation(at: time, eyeClosed: 0), now: time)
    XCTAssertEqual(readiness.refusal, .frameNotCurrent)
    XCTAssertFalse(gate.trackingObserved)
    // Deliberately still inside maximumFrameAge, so the monotonic guard is what refuses
    // it rather than staleness.
    let earlier = gate.observe(observation(at: time - 0.1, eyeClosed: 0), now: time)
    XCTAssertEqual(earlier.refusal, .frameNotCurrent)
  }

  func testMultipleFacesResetTheSequence() {
    var (gate, time) = reopenedGate()
    time += 0.02
    let readiness = gate.observe(
      Observation(at: time, eyeClosed: 0, anchor: anchor, faceCount: 2), now: time)
    XCTAssertEqual(readiness.refusal, .multipleFacesObserved)
    XCTAssertFalse(gate.trackingObserved)
    XCTAssertEqual(gate.currentBlinkPhase, .waitingForOpenEyes)
  }

  func testChangedAnchorResetsTrackingAndBlink() {
    var (gate, time) = reopenedGate()
    time += 0.02
    let readiness = gate.observe(
      Observation(at: time, eyeClosed: 0, anchor: UUID(), faceCount: 1), now: time)
    XCTAssertFalse(readiness.captureReady)
    XCTAssertFalse(gate.trackingObserved)
    XCTAssertEqual(gate.currentBlinkPhase, .waitingForOpenEyes)
  }

  func testTrackingGapResetsTheSequence() {
    var (gate, time) = reopenedGate()
    time += 0.5  // longer than maximumFrameAge
    let readiness = gate.observe(observation(at: time, eyeClosed: 0), now: time)
    XCTAssertFalse(readiness.captureReady)
    XCTAssertFalse(gate.trackingObserved)
  }

  func testStopRefusesEverythingUntilRestarted() {
    var (gate, time) = reopenedGate()
    gate.stop()
    XCTAssertEqual(
      gate.admit(frameTimestamp: time, now: time, trigger: .manual),
      .refuse(.sessionNotRunning))
    gate.start(at: time)
    XCTAssertFalse(gate.trackingObserved)
    XCTAssertEqual(gate.currentBlinkPhase, .waitingForOpenEyes)
  }

  func testUnusableBlendShapesAreRefused() {
    for value in [Float.nan, -0.1, 1.5] {
      var (gate, time) = trackedGate()
      time += 0.02
      let readiness = gate.observe(observation(at: time, eyeClosed: value), now: time)
      XCTAssertEqual(readiness.refusal, .blendShapesUnavailable)
    }
  }

  func testUntrackedFaceIsRefused() {
    var (gate, time) = trackedGate()
    time += 0.02
    let readiness = gate.observe(
      Observation(at: time, eyeClosed: 0, anchor: anchor, faceCount: 1, tracked: false),
      now: time)
    XCTAssertEqual(readiness.refusal, .faceNotTracked)
  }

  /// Exactly at the threshold is neither open nor closed, and must not admit.
  func testEyeValueExactlyAtTheThresholdDoesNotAdmit() {
    var (gate, time) = blinkedGate()
    time += 0.02
    gate.observe(observation(at: time, eyeClosed: 0.5), now: time)
    XCTAssertEqual(
      gate.admit(frameTimestamp: time, now: time, trigger: .manual),
      .refuse(.eyesClosed))
  }

  // MARK: - Measurement terms are recorded, not invented

  func testQualityIsRecordedButNotEnforcedByDefault() {
    var (gate, time) = trackedGate()
    time += 0.02
    gate.observe(observation(at: time, eyeClosed: 0.9), now: time)
    time += 0.02
    gate.observe(
      Observation(at: time, eyeClosed: 0, anchor: anchor, faceCount: 1, quality: 0.01),
      now: time)
    guard
      case .admit(let receipt) = gate.admit(
        frameTimestamp: time, now: time, trigger: .manual)
    else { return XCTFail("no threshold is set, so a low score must not gate") }
    XCTAssertEqual(receipt.captureQuality, 0.01)
    XCTAssertFalse(receipt.captureQualityEnforced)
    XCTAssertNil(SelfieAdmissionPolicy().minimumCaptureQuality, "no invented default")
    XCTAssertFalse(SelfieAdmissionPolicy().requiresGuideContainment)
  }

  func testQualityGatesOnlyWhenAThresholdIsConfigured() {
    let strict = SelfieAdmissionPolicy(minimumCaptureQuality: 0.4)
    var (gate, time) = trackedGate(policy: strict)
    time += 0.02
    gate.observe(observation(at: time, eyeClosed: 0.9), now: time)
    time += 0.02
    gate.observe(
      Observation(at: time, eyeClosed: 0, anchor: anchor, faceCount: 1, quality: 0.2),
      now: time)
    XCTAssertEqual(
      gate.admit(frameTimestamp: time, now: time, trigger: .manual),
      .refuse(.captureQualityBelowMinimum))
  }

  func testConfiguredQualityGateRefusesAMissingMeasurement() {
    let strict = SelfieAdmissionPolicy(minimumCaptureQuality: 0.4)
    var (gate, time) = trackedGate(policy: strict)
    time += 0.02
    gate.observe(observation(at: time, eyeClosed: 0.9), now: time)
    time += 0.02
    gate.observe(observation(at: time, eyeClosed: 0), now: time)  // no quality supplied
    XCTAssertEqual(
      gate.admit(frameTimestamp: time, now: time, trigger: .manual),
      .refuse(.captureQualityUnavailable))
  }

  func testGuideContainmentGatesOnlyWhenRequired() {
    let strict = SelfieAdmissionPolicy(requiresGuideContainment: true)
    var (gate, time) = trackedGate(policy: strict)
    time += 0.02
    gate.observe(observation(at: time, eyeClosed: 0.9), now: time)
    time += 0.02
    gate.observe(
      Observation(at: time, eyeClosed: 0, anchor: anchor, faceCount: 1, insideGuide: false),
      now: time)
    XCTAssertEqual(
      gate.admit(frameTimestamp: time, now: time, trigger: .manual),
      .refuse(.outsideGuide))
  }

  /// The receipt replaces a hardcoded `blink=true` string, so it must be able to report what
  /// was actually measured rather than what the old string asserted.

  func testReceiptRoundTripsThroughJSON() throws {
    let (gate, time) = reopenedGate()
    var subject = gate
    guard
      case .admit(let receipt) = subject.admit(
        frameTimestamp: time, now: time, trigger: .manual)
    else { return XCTFail("expected admission") }
    let encoded = try JSONEncoder().encode(receipt)
    XCTAssertEqual(try JSONDecoder().decode(SelfieAdmissionReceipt.self, from: encoded), receipt)
  }

  func testLegacyReceiptWithoutMotionFieldsPreservesAdmissionAndOriginalWireBytes() throws {
    var (gate, time) = reopenedGate()
    guard case .admit(let receipt) = gate.admit(frameTimestamp: time, now: time, trigger: .manual)
    else { return XCTFail("Expected admission") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var historical = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(receipt)) as? [String: Any])
    historical.removeValue(forKey: "motionStatus")
    historical.removeValue(forKey: "motionEvidence")
    let bytes = try JSONSerialization.data(withJSONObject: historical, options: [.sortedKeys, .withoutEscapingSlashes])
    let decoded = try JSONDecoder().decode(SelfieAdmissionReceipt.self, from: bytes)
    XCTAssertEqual(decoded.motionStatus, .notRequested)
    XCTAssertNil(decoded.motionEvidence)
    XCTAssertEqual(decoded.admissionValid, receipt.admissionValid)
    XCTAssertEqual(try encoder.encode(decoded), bytes,
      "Historical receipt hashes must not change merely because an absent permission field was decoded")
    var changed = decoded
    changed.motionStatus = .denied
    let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(changed)) as? [String: Any])
    XCTAssertEqual(updated["motionStatus"] as? String, "denied")
  }

  func testCurrentReceiptPreservesEveryExplicitMotionPermissionAndRejectsUnknownOrNull() throws {
    var (gate, time) = reopenedGate()
    guard case .admit(let receipt) = gate.admit(frameTimestamp: time, now: time, trigger: .manual)
    else { return XCTFail("Expected admission") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for status in ["notRequested", "requesting", "authorized", "denied", "unavailable"] {
      var current = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(receipt)) as? [String: Any])
      current["motionStatus"] = status
      let bytes = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys, .withoutEscapingSlashes])
      let decoded = try JSONDecoder().decode(SelfieAdmissionReceipt.self, from: bytes)
      XCTAssertEqual(decoded.motionStatus.rawValue, status)
      XCTAssertEqual(try encoder.encode(decoded), bytes)
      XCTAssertEqual(decoded.admissionValid, receipt.admissionValid)
    }
    for supplied in ["unknown" as Any, NSNull()] {
      var current = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(receipt)) as? [String: Any])
      current["motionStatus"] = supplied
      XCTAssertThrowsError(try JSONDecoder().decode(SelfieAdmissionReceipt.self,
        from: JSONSerialization.data(withJSONObject: current)))
    }
  }

  func testReceiptRejectsPolicyEnforcementMismatch() throws {
    var (gate, time) = reopenedGate()
    guard case .admit(var receipt) = gate.admit(frameTimestamp: time, now: time, trigger: .manual)
    else {
      return XCTFail("Expected admission")
    }
    XCTAssertTrue(receipt.admissionValid)
    receipt.effectivePolicy = SelfieAdmissionPolicy(requiresGuideContainment: true)
    XCTAssertFalse(receipt.admissionValid)
    receipt.effectivePolicy = SelfieAdmissionPolicy(minimumCaptureQuality: 0.5)
    XCTAssertFalse(receipt.admissionValid)
  }

  func testInvalidPolicyCannotStartCapture() {
    for policy in [
      SelfieAdmissionPolicy(requiredTrackedFrames: 0),
      SelfieAdmissionPolicy(maximumFrameAge: .nan),
      SelfieAdmissionPolicy(minimumCaptureQuality: 1.1),
    ] {
      XCTAssertFalse(policy.configurationValid)
      var gate = SelfieAdmissionGate(policy: policy)
      gate.start(at: 1)
      XCTAssertEqual(
        gate.admit(frameTimestamp: 1, now: 1, trigger: .manual), .refuse(.sessionNotRunning))
    }
  }

  func testRejectedMeasurementRestartsAutomaticHold() {
    var (gate, time) = reopenedGate()
    for _ in 0..<60 {
      time += 0.02
      gate.observe(observation(at: time, eyeClosed: 0), now: time)
    }
    guard case .admit = gate.admit(frameTimestamp: time, now: time, trigger: .automatic) else {
      return XCTFail("Expected automatic admission before rejection")
    }
    gate.resetHold()
    time += 0.02
    gate.observe(observation(at: time, eyeClosed: 0), now: time)
    XCTAssertEqual(
      gate.admit(frameTimestamp: time, now: time, trigger: .automatic),
      .refuse(.steadyHoldIncomplete))
  }

  // MARK: - Fixtures

  private typealias Observation = SelfieAdmissionGate.Observation

  private let anchor = UUID()

  private func observation(at timestamp: Double, eyeClosed: Float) -> Observation {
    Observation(at: timestamp, eyeClosed: eyeClosed, anchor: anchor, faceCount: 1)
  }

  /// Ten accepted open-eyed frames: steadily tracked, no blink yet.
  private func trackedGate(
    policy: SelfieAdmissionPolicy = SelfieAdmissionPolicy()
  ) -> (SelfieAdmissionGate, Double) {
    var gate = SelfieAdmissionGate(policy: policy)
    gate.start(at: 1)
    var time = 1.0
    for index in 0..<10 {
      time = 1 + Double(index) * 0.02
      gate.observe(
        Observation(at: time, eyeClosed: 0, anchor: anchor, faceCount: 1), now: time)
    }
    return (gate, time)
  }

  /// Tracked, then one closed frame: the blink has closed but not reopened.
  private func blinkedGate() -> (SelfieAdmissionGate, Double) {
    var (gate, time) = trackedGate()
    time += 0.02
    gate.observe(observation(at: time, eyeClosed: 0.9), now: time)
    return (gate, time)
  }

  /// A completed blink with the eyes open again: the first admissible frame.
  private func reopenedGate() -> (SelfieAdmissionGate, Double) {
    var (gate, time) = blinkedGate()
    time += 0.02
    gate.observe(observation(at: time, eyeClosed: 0), now: time)
    return (gate, time)
  }
}

extension SelfieAdmissionGate.Observation {
  fileprivate init(
    at timestamp: Double, eyeClosed: Float, anchor: UUID, faceCount: Int,
    tracked: Bool = true, quality: Float? = nil, insideGuide: Bool? = nil
  ) {
    self.init(
      timestamp: timestamp, anchorID: anchor, faceCount: faceCount, trackingObserved: tracked,
      leftEyeClosed: eyeClosed, rightEyeClosed: eyeClosed,
      measurements: .init(captureQuality: quality, insideGuide: insideGuide))
  }
}
