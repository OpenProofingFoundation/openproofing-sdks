import Foundation
import Testing

@testable import DocumentCaptureApple

struct DocumentTiltV2BaselineTests {
  @Test func baselineRatiosAreInvariantToAdmittedTranslationScaleAndRoll() throws {
    for version in [DocumentTiltConfiguration.Version.trackedV1, .freshDetectionV2] {
      var trial = TiltPolicyTrial(version: version)
      for index in 0..<5 {
        let source = trial.next(0)
        let quad = try #require(source.geometry.quadrilateral)
        let angle = Double(index) * 0.012
        let scale = exp(Double(index) * 0.008)
        let points = quad.points.map { point in
          let horizontal = (point.x - 0.5) * 1320 * scale
          let vertical = (point.y - 0.5) * 1760 * scale
          return DocumentNormalizedPoint(
            x: (horizontal * cos(angle) - vertical * sin(angle)) / 1320 + 0.5 + Double(index)
              * 0.006,
            y: (horizontal * sin(angle) + vertical * cos(angle)) / 1760 + 0.5)
        }
        let packet = tiltPolicyReplacingQuad(source, points: points)
        #expect(packet.valid)
        _ = trial.controller.consume(packet)
      }
      if version == .freshDetectionV2 {
        #expect(trial.controller.presentation.phase == .leftEdgeCloser)
        #expect(abs(trial.controller.presentation.baseline?.medianLogRatio ?? 1) < 1e-12)
      } else {
        #expect(trial.controller.presentation.phase == .baseline)
        #expect(trial.controller.presentation.reason == .baselineUnstable)
      }
    }
  }

  @Test func secondaryPerspectiveDriftCannotHideBehindStableLeftRightRatio() {
    var trial = TiltPolicyTrial()
    for index in 0..<10 {
      let source = trial.next(0)
      let ratio = Double(index) * 0.02
      let topWidth = 0.5 * exp(-ratio / 2)
      let bottomWidth = 0.5 * exp(ratio / 2)
      let topLeft = DocumentNormalizedPoint(x: 0.5 - topWidth / 2, y: 0.325)
      let topRight = DocumentNormalizedPoint(x: 0.5 + topWidth / 2, y: 0.325)
      let bottomRight = DocumentNormalizedPoint(x: 0.5 + bottomWidth / 2, y: 0.675)
      let bottomLeft = DocumentNormalizedPoint(x: 0.5 - bottomWidth / 2, y: 0.675)
      let packet = tiltPolicyReplacingQuad(
        source, points: [topLeft, topRight, bottomRight, bottomLeft])
      #expect(packet.valid)
      _ = trial.controller.consume(packet)
    }
    #expect(trial.controller.presentation.phase == .baseline)
    #expect(trial.controller.presentation.reason == .baselineUnstable)
    #expect(trial.controller.presentation.baseline == nil)
    #expect(trial.controller.evidence.events.allSatisfy { abs($0.rawLogRatio ?? 0) < 1e-12 })
  }

  @Test func finitePriorDisturbanceDoesNotExtendTheSpecifiedStableInterval() {
    for version in [DocumentTiltConfiguration.Version.trackedV1, .freshDetectionV2] {
      var trial = TiltPolicyTrial(version: version)
      trial.send(0.08)
      trial.hold(0, count: 5)
      if version == .freshDetectionV2 {
        #expect(trial.controller.presentation.phase == .leftEdgeCloser)
        #expect(trial.controller.presentation.baseline?.observationCount == 5)
        #expect(trial.controller.presentation.baseline?.firstTimestamp == tiltPolicyTime(400))
        #expect(trial.controller.presentation.baseline?.lastTimestamp == tiltPolicyTime(1200))
      } else {
        #expect(trial.controller.presentation.phase == .baseline)
        #expect(trial.controller.presentation.reason == .baselineUnstable)
      }
    }
  }

  @Test func shortestSuffixNeverDiscardsTheRequiredSourceDuration() {
    var trial = TiltPolicyTrial()
    for _ in 0..<5 { trial.send(0, step: 190) }
    #expect(trial.controller.presentation.phase == .baseline)
    trial.send(0, step: 190)
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    #expect(trial.controller.presentation.baseline?.observationCount == 6)
    #expect(trial.controller.presentation.baseline?.firstTimestamp == tiltPolicyTime(190))
    #expect(trial.controller.presentation.baseline?.lastTimestamp == tiltPolicyTime(1140))
  }
}
