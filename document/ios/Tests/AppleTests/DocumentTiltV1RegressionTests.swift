import Foundation
import Testing

@testable import DocumentCaptureApple

/// Frozen-policy counterexamples: these document V1 defects, never reinterpret old evidence as V2.
struct DocumentTiltV1RegressionTests {
  @Test func oldRefreshCorrectionCanMakeNeutralUnreachableButFreshPolicyHasOneCoordinateSystem() {
    for version in [DocumentTiltConfiguration.Version.trackedV1, .freshDetectionV2] {
      var trial = TiltPolicyTrial(version: version)
      trial.automaticRefresh = version == .trackedV1
      trial.hold(0, count: 5)
      for _ in 0..<4 {
        trial.send(0.02)
        trial.send(0.01)
        trial.hold(0, count: 3)
      }
      for ratio in [-0.04, -0.08, -0.12] { trial.change(ratio) }
      trial.hold(-0.12, count: 5)
      #expect(trial.controller.presentation.phase == .neutralAfterLeft)
      for ratio in [-0.08, -0.04, 0.0] { trial.change(ratio) }
      trial.hold(0, count: 10)
      if version == .trackedV1 {
        #expect(trial.controller.presentation.phase == .neutralAfterLeft)
        #expect(abs((trial.controller.presentation.signedDelta ?? 0) + 0.08) < 1e-12)
        trial.hold(0, count: 100)
        #expect(trial.controller.presentation.phase == .evidenceLimit)
      } else {
        #expect(trial.controller.presentation.phase == .rightEdgeCloser)
        #expect(abs(trial.controller.presentation.signedDelta ?? 1) < 1e-12)
      }
    }
  }

  @Test func slowMovementAcrossV1RefreshIsAbsorbedButV2PreservesIt() {
    for version in [DocumentTiltConfiguration.Version.trackedV1, .freshDetectionV2] {
      var trial = TiltPolicyTrial(version: version)
      trial.automaticRefresh = version == .trackedV1
      trial.hold(0, count: 5)
      for step in 1...10 { trial.send(-0.01 * Double(step)) }
      trial.hold(-0.10, count: 10)
      #expect(
        trial.controller.presentation.phase
          == (version == .trackedV1 ? .leftEdgeCloser : .neutralAfterLeft))
    }
  }

  @Test func frozenV1MixedRefreshOffsetsCanEarnALeg() {
    var trial = TiltPolicyTrial(version: .trackedV1)
    trial.automaticRefresh = true
    trial.hold(0, count: 5)
    var raw = 0.0
    for _ in 0..<5 {
      trial.send(raw + 0.02)
      trial.hold(raw, count: 4)
      raw -= 0.02
      trial.send(raw)
      trial.hold(raw, count: 4)
    }
    #expect(trial.controller.presentation.phase == .neutralAfterLeft)
    #expect(trial.controller.configuration == .provisionalV1)
    #expect(trial.controller.evidence.events.allSatisfy { $0.valid })
  }
}
