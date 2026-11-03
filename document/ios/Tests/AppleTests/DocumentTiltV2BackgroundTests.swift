import Foundation
import Testing

@testable import DocumentCaptureApple

/// Geometry-level adversarial controls, not a physical identity classifier or a native pixel replay.
struct DocumentTiltV2BackgroundTests {
  @Test func explicitLossBeforeFinalNeutralCannotCarryEarlierLegsIntoBackground() {
    var trial = preparedForFinalNeutral()
    let source = trial.next(0)
    let unavailable = DocumentLiveGeometryObservation(
      schemaVersion: 2, observedAt: source.observedAt,
      geometry: .init(
        quadrilateral: nil, observationTimestamp: source.captureTimestamp,
        coordinateSpace: source.geometry.coordinateSpace,
        status: "analyzed_no_accepted_rectangle", confidence: nil,
        method: "VNDetectRectanglesRequest"),
      pixelWidth: source.pixelWidth, pixelHeight: source.pixelHeight,
      analysisSequence: source.analysisSequence, geometryRevision: source.geometryRevision,
      availability: .noAcceptedRectangle, requestRevision: 1,
      tracker: .init(
        transition: .unavailable, trackingOutcome: .notAttempted,
        precedingAnalysisTimestamp: nil, resetReasons: []),
      requestFacts: [.completed(.documentSegmentation, revision: 1, count: 0, accepted: false)]
        + [.completed(.rectangleDetection, revision: 1, count: 0, accepted: false)],
      analysisMode: .freshDetection)
    #expect(unavailable.valid)
    let loss = trial.controller.consume(unavailable)
    #expect(loss.presentation.phase == .baseline)
    #expect(loss.presentation.reason == .observationUnavailable)
    #expect(loss.event?.credited == false)
    for _ in 0..<8 { feedBackground(&trial, delta: 0) }
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    #expect(!trial.controller.evidence.events.contains { $0.phase == .readyForStill })
  }

  @Test func actualBackgroundGeometryJumpCannotFinishARegularCardSequence() {
    var trial = preparedForFinalNeutral()
    let jump = trial.controller.consume(backgroundPacket(trial.next(0), delta: 0))
    #expect(jump.presentation.phase == .baseline)
    #expect(jump.presentation.reason == .associationFailed)
    #expect(jump.event?.credited == false)
    for _ in 0..<8 { feedBackground(&trial, delta: 0) }
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    #expect(!trial.controller.evidence.events.contains { $0.phase == .readyForStill })
  }

  @Test func sourceMethodOrRevisionSwitchBeforeFinalNeutralDiscardsAllEarlierLegs() {
    for changedMethod in [false, true] {
      var trial = preparedForFinalNeutral()
      let method =
        changedMethod ? "VNDetectRectanglesRequest" : "VNDetectDocumentSegmentationRequest"
      let requestRevision = changedMethod ? 1 : 2
      let update = trial.controller.consume(
        trial.next(0, method: method, requestRevision: requestRevision))
      #expect(update.presentation.phase == .baseline)
      #expect(update.presentation.reason == .measurementSourceChanged)
      #expect(update.event?.credited == false)
      for _ in 0..<8 {
        _ = trial.controller.consume(
          trial.next(0, method: method, requestRevision: requestRevision))
      }
      #expect(trial.controller.presentation.phase == .leftEdgeCloser)
      #expect(!trial.controller.evidence.events.contains { $0.phase == .readyForStill })
    }
  }

  @Test func unreportedGeometryCompatibleReplacementIsNotObservableAsIdentityLoss() {
    // Counterexample: a hypothetical foreground candidate has the measured shape of the
    // retained background rectangle. It supplies both excursions, then disappears without an
    // unavailable observation. Three background selections match the original projected shape.
    // This deliberately records the geometry-only policy's limit; it does not assert that this
    // replacement occurred in the retained run or that the SDK can recognize physical identity.
    var trial = TiltPolicyTrial()
    for _ in 0..<5 { feedBackground(&trial, delta: 0) }
    for delta in [-0.12, 0, 0.12] {
      for _ in 0..<3 { feedBackground(&trial, delta: delta) }
    }
    #expect(trial.controller.presentation.phase == .neutralAfterRight)
    for _ in 0..<3 { feedBackground(&trial, delta: 0) }
    #expect(trial.controller.presentation.phase == .readyForStill)
    #expect(trial.controller.evidence.events.allSatisfy { $0.valid })
    #expect(!trial.controller.evidence.events.contains { $0.reason == .observationUnavailable })
    #expect(!trial.controller.evidence.events.contains { $0.reason == .associationFailed })
  }
}

private func preparedForFinalNeutral() -> TiltPolicyTrial {
  var trial = TiltPolicyTrial()
  trial.hold(0, count: 5)
  for delta in [-0.12, 0, 0.12] { trial.hold(delta, count: 3) }
  #expect(trial.controller.presentation.phase == .neutralAfterRight)
  return trial
}

private func feedBackground(_ trial: inout TiltPolicyTrial, delta: Double) {
  let packet = backgroundPacket(trial.next(delta), delta: delta)
  #expect(packet.valid)
  _ = trial.controller.consume(packet)
}

private func backgroundPacket(
  _ source: DocumentLiveGeometryObservation, delta: Double
) -> DocumentLiveGeometryObservation {
  // Source213 of retained recording E67BA60C-0F41-49EC-90AA-22FCE59EDA81, production V2 replay.
  // Only these corners are retained values. Times, progression and altered shapes are synthetic.
  let corners: [DocumentNormalizedPoint] =
    [.init(x: 0.1041666641831398, y: 0.4921875)]
    + [.init(x: 0.5902777910232544, y: 0.4609375)]
    + [.init(x: 0.6458333134651184, y: 0.703125)]
    + [.init(x: 0.0069444444961845875, y: 0.734375)]
  let points = corners.enumerated().map { index, point in
    let opposite = corners[3 - index]
    let scale = exp((index == 0 || index == 3 ? -delta : delta) / 2)
    let centerX = (point.x + opposite.x) / 2
    let centerY = (point.y + opposite.y) / 2
    return DocumentNormalizedPoint(
      x: centerX + (point.x - centerX) * scale,
      y: centerY + (point.y - centerY) * scale)
  }
  return tiltPolicyReplacingQuad(source, points: points)
}
