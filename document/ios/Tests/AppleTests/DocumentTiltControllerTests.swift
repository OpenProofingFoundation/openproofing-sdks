import Foundation
import Testing

@testable import DocumentCaptureApple

struct DocumentTiltControllerTests {
  @Test func orderedLeftNeutralRightNeutralNeedsObservedDwell() {
    var trial = TiltTrial()
    trial.hold(0, count: 5)
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    #expect(trial.controller.presentation.baseline?.empiricalNoise == 0.015)
    trial.send(-0.04)
    trial.send(-0.08)
    trial.send(-0.12)
    #expect(trial.controller.presentation.consecutiveObservations == 1)
    trial.send(-0.12)
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    trial.send(-0.12)
    #expect(trial.controller.presentation.phase == .neutralAfterLeft)
    trial.send(-0.06)
    trial.hold(0, count: 3)
    #expect(trial.controller.presentation.phase == .rightEdgeCloser)
    trial.send(0.06)
    trial.hold(0.12, count: 3)
    #expect(trial.controller.presentation.phase == .neutralAfterRight)
    trial.send(0.06)
    trial.hold(0, count: 3)
    #expect(trial.controller.presentation.phase == .readyForStill)
    #expect(trial.controller.presentation.uncertaintyStatus == .notEstimated)
    #expect(trial.controller.evidence.events.allSatisfy { $0.valid })
    let count = trial.controller.evidence.events.count
    trial.hold(0, count: 100)
    #expect(trial.controller.evidence.events.count == count)
  }

  @Test func wrongDirectionAndSingleExtremeNeverAdvance() {
    var trial = TiltTrial()
    trial.hold(0, count: 5)
    trial.hold(0.12, count: 5)
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    #expect(trial.controller.presentation.consecutiveObservations == 0)
    trial.send(0)
    trial.send(-0.12)
    #expect(trial.controller.presentation.consecutiveObservations == 1)
    trial.send(0)
    #expect(trial.controller.presentation.consecutiveObservations == 0)
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
  }

  @Test func refreshJumpsAreRemovedAndRefreshCannotCompleteDwell() {
    var trial = TiltTrial()
    trial.hold(0, count: 5)
    for step in 1...6 {
      let ratio = -0.02 * Double(step)
      trial.send(ratio, refresh: true)
      trial.hold(ratio, count: 4)
    }
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    #expect(abs(trial.controller.presentation.signedDelta ?? 1) < 1e-10)
    #expect(trial.controller.evidence.events.filter(\.associatedRefresh).count == 6)
    #expect(
      trial.controller.evidence.events.filter(\.associatedRefresh).allSatisfy { !$0.credited })
    // Real tracked changes following refresh still accumulate, unlike resetting every fifth sample.
    trial.send(-0.16)
    trial.send(-0.20)
    trial.send(-0.24)
    trial.send(-0.24, refresh: true)
    #expect(trial.controller.presentation.consecutiveObservations == 0)
    trial.hold(-0.24, count: 2)
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    trial.send(-0.24)
    #expect(trial.controller.presentation.phase == .neutralAfterLeft)
  }

  @Test func refreshOffsetRatchetCannotManufactureAnExcursion() {
    var trial = TiltTrial()
    trial.hold(0, count: 5)
    for _ in 0..<8 {
      trial.send(0.02, refresh: true)
      trial.send(0.01)
      trial.hold(0, count: 3)
    }
    #expect((trial.controller.presentation.signedDelta ?? 0) < -0.1)
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    #expect(trial.controller.presentation.consecutiveObservations == 0)
  }

  @Test func refreshAssociationFailureAndRelabelingRecoverFreshBaseline() throws {
    var trial = TiltTrial()
    trial.hold(0, count: 5)
    trial.send(-0.12, refresh: true)
    #expect(trial.controller.presentation.phase == .baseline)
    #expect(trial.controller.presentation.reason == .associationFailed)
    #expect(trial.controller.presentation.baseline == nil)
    trial.hold(0, count: 5)
    var value = trial.next(0)
    let quad = try #require(value.geometry.quadrilateral)
    let reflected = DocumentQuadrilateral(
      topLeft: quad.topRight, topRight: quad.topLeft,
      bottomRight: quad.bottomLeft, bottomLeft: quad.bottomRight)
    value = replacing(value, quad: reflected)
    _ = trial.controller.consume(value)
    #expect(trial.controller.presentation.phase == .baseline)
    #expect(trial.controller.presentation.baseline == nil)
  }

  @Test func sourceGapSequenceRevisionLossAndResetCannotBridgeProgress() {
    for variant in 0..<5 {
      var trial = TiltTrial()
      trial.hold(0, count: 5)
      trial.send(-0.12)
      let old = trial.next(-0.12)
      let value: DocumentLiveGeometryObservation
      switch variant {
      case 0: value = replacing(old, time: timestamp(100))
      case 1: value = replacing(old, sequence: 100)
      case 2: value = replacing(old, revision: 1)
      case 3: value = unavailable(old)
      default: value = replacing(old, reset: true)
      }
      _ = trial.controller.consume(value)
      #expect(trial.controller.presentation.phase == .baseline)
      #expect(trial.controller.presentation.baseline == nil)
      #expect(trial.controller.presentation.consecutiveObservations == 0)
      #expect(trial.controller.presentation.reason != nil)
    }
  }

  @Test func translationScaleAndImagePlaneRotationDoNotEarnExcursion() throws {
    var trial = TiltTrial()
    trial.hold(0, count: 5)
    for step in 1...20 {
      let value = trial.next(0)
      let quad = try #require(value.geometry.quadrilateral)
      let angle = Double(step) * 0.015
      let scale = 1 + Double(step) * 0.003
      let points = quad.points.map { point in
        let offsetX = (point.x - 0.5) * 1320 * scale
        let offsetY = (point.y - 0.5) * 1760 * scale
        return DocumentNormalizedPoint(
          x: (offsetX * cos(angle) - offsetY * sin(angle)) / 1320 + 0.5 + Double(step) * 0.001,
          y: (offsetX * sin(angle) + offsetY * cos(angle)) / 1760 + 0.5)
      }
      let transformed = DocumentQuadrilateral(
        topLeft: points[0], topRight: points[1],
        bottomRight: points[2], bottomLeft: points[3])
      _ = trial.controller.consume(replacing(value, quad: transformed))
    }
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    #expect(abs(trial.controller.presentation.signedDelta ?? 1) < 1e-10)
    #expect(trial.controller.presentation.consecutiveObservations == 0)
  }

  @Test func translatingBaselineMustSettleBeforeAdmission() throws {
    var trial = TiltTrial()
    for step in 1...8 {
      let value = trial.next(0)
      _ = trial.controller.consume(translated(value, horizontal: Double(step) * 0.015))
    }
    #expect(trial.controller.presentation.phase == .baseline)
    #expect(trial.controller.presentation.baseline == nil)
    #expect(trial.controller.presentation.reason == .baselineUnstable)
    for _ in 0..<10 {
      let value = trial.next(0)
      _ = trial.controller.consume(translated(value, horizontal: 0.12))
    }
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
  }

  @Test func forgedReadyStateAndUnrelatedRawMeasurementFailStructuralValidation() throws {
    let initial = DocumentTiltController(runID: UUID()).initialUpdate
    var json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
    for key in ["event", "presentation"] {
      var nested = try #require(json[key] as? [String: Any])
      nested["phase"] = "readyForStill"
      json[key] = nested
    }
    let invented = try JSONDecoder().decode(
      DocumentTiltUpdate.self,
      from: JSONSerialization.data(withJSONObject: json))
    #expect(!invented.valid)
    var trial = TiltTrial()
    trial.hold(0, count: 5)
    let event = try #require(trial.controller.evidence.events.last)
    #expect(event.valid)
    var raw = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
    raw["rawLogRatio"] = 0.5
    let unrelated = try JSONDecoder().decode(
      DocumentTiltEvidenceEvent.self,
      from: JSONSerialization.data(withJSONObject: raw))
    #expect(!unrelated.valid)
    var baselineJSON = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(event.baseline)) as? [String: Any])
    baselineJSON["rawMedianAbsoluteDeviation"] = -0.01
    let invalidBaseline = try JSONDecoder().decode(
      DocumentTiltBaseline.self,
      from: JSONSerialization.data(withJSONObject: baselineJSON))
    #expect(!invalidBaseline.valid)
  }

  @Test func initialEventRequiresValidRetainedConfiguration() throws {
    let initial = DocumentTiltController(
      runID: UUID(), configuration: .init(evidenceSampleLimit: 32)
    ).initialUpdate
    #expect(initial.valid)
    #expect(initial.event?.configuration?.evidenceSampleLimit == 32)
    var json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(initial.event)) as? [String: Any])
    json.removeValue(forKey: "configuration")
    let missing = try JSONDecoder().decode(
      DocumentTiltEvidenceEvent.self,
      from: JSONSerialization.data(withJSONObject: json))
    #expect(!missing.valid)
  }

  @Test func boundedEvidenceAndExplicitSkipCancelNeverReportCompletion() throws {
    var trial = TiltTrial(configuration: .init(evidenceSampleLimit: 16))
    trial.hold(0, count: 100)
    #expect(trial.controller.presentation.phase == .evidenceLimit)
    #expect(trial.controller.evidence.events.count == 16)
    #expect(trial.controller.evidence.reachedEvidenceLimit)
    var skipped = DocumentTiltController(runID: UUID())
    #expect(skipped.skip(reason: .userSkipped).presentation.phase == .skipped)
    var cancelled = DocumentTiltController(runID: UUID())
    #expect(cancelled.cancel(reason: .observationSilence).presentation.phase == .cancelled)
    let encoded = try JSONEncoder().encode(trial.controller.evidence)
    #expect(
      try JSONDecoder().decode(DocumentTiltEvidence.self, from: encoded)
        == trial.controller.evidence)
    #expect(
      DocumentTiltController(runID: UUID(), configuration: .init(evidenceSampleLimit: 0))
        .presentation.reason == .invalidConfiguration)
  }
}

private struct TiltTrial {
  var controller: DocumentTiltController
  var sequence: UInt64 = 0
  init(configuration: DocumentTiltConfiguration = .provisionalV1) {
    controller = .init(runID: UUID(), configuration: configuration)
  }
  mutating func hold(_ ratio: Double, count: Int) {
    for _ in 0..<count { send(ratio) }
  }
  mutating func send(_ ratio: Double, refresh: Bool = false) {
    let value = next(ratio, refresh: refresh)
    _ = controller.consume(value)
  }
  mutating func next(_ ratio: Double, refresh: Bool = false) -> DocumentLiveGeometryObservation {
    sequence += 1
    let left = 0.35 * exp(-ratio / 2)
    let right = 0.35 * exp(ratio / 2)
    let quad = DocumentQuadrilateral(
      topLeft: .init(x: 0.25, y: 0.5 - left / 2),
      topRight: .init(x: 0.75, y: 0.5 - right / 2),
      bottomRight: .init(x: 0.75, y: 0.5 + right / 2), bottomLeft: .init(x: 0.25, y: 0.5 + left / 2)
    )
    let tracked = sequence > 1 && !refresh
    return .init(
      schemaVersion: 1, observedAt: Date(timeIntervalSince1970: Double(sequence)),
      geometry: .init(
        quadrilateral: quad, observationTimestamp: timestamp(Int64(sequence) * 6),
        coordinateSpace: "normalized_delivered_video_buffer_top_left", status: "observed",
        confidence: 0.9,
        method: tracked ? "VNTrackRectangleRequest" : "VNDetectRectanglesRequest"),
      pixelWidth: 1320, pixelHeight: 1760, analysisSequence: sequence, geometryRevision: 0,
      availability: .observed, requestRevision: 1,
      tracker: .init(
        transition: tracked ? .tracked : (refresh ? .periodicDetectionRefresh : .initialDetection),
        trackingOutcome: tracked ? .accepted : .notAttempted,
        precedingAnalysisTimestamp: tracked ? timestamp(Int64(sequence - 1) * 6) : nil,
        resetReasons: []))
  }
}

private func timestamp(_ value: Int64) -> DocumentCaptureClockTimestamp {
  .init(value: value, timescale: 30, flags: 1, epoch: 0, clock: .captureSessionSynchronizationClock)
}

private func replacing(
  _ value: DocumentLiveGeometryObservation, quad: DocumentQuadrilateral? = nil,
  time: DocumentCaptureClockTimestamp? = nil, sequence: UInt64? = nil, revision: UInt64? = nil,
  reset: Bool = false
) -> DocumentLiveGeometryObservation {
  .init(
    schemaVersion: value.schemaVersion, observedAt: value.observedAt,
    geometry: .init(
      quadrilateral: quad ?? value.geometry.quadrilateral,
      observationTimestamp: time ?? value.captureTimestamp,
      coordinateSpace: value.geometry.coordinateSpace,
      status: value.geometry.status, confidence: value.geometry.confidence,
      method: reset ? "VNDetectRectanglesRequest" : value.geometry.method),
    pixelWidth: value.pixelWidth, pixelHeight: value.pixelHeight,
    analysisSequence: sequence ?? value.analysisSequence,
    geometryRevision: revision ?? value.geometryRevision,
    availability: value.availability, requestRevision: value.requestRevision,
    tracker: reset
      ? .init(
        transition: .initialDetection, trackingOutcome: .notAttempted,
        precedingAnalysisTimestamp: nil, resetReasons: [.clockChanged]) : value.tracker)
}

private func unavailable(
  _ value: DocumentLiveGeometryObservation
) -> DocumentLiveGeometryObservation {
  .init(
    schemaVersion: 1, observedAt: value.observedAt,
    geometry: .init(
      quadrilateral: nil, observationTimestamp: value.captureTimestamp,
      coordinateSpace: value.geometry.coordinateSpace, status: "analyzed_no_accepted_rectangle",
      confidence: nil, method: nil), pixelWidth: value.pixelWidth, pixelHeight: value.pixelHeight,
    analysisSequence: value.analysisSequence, geometryRevision: value.geometryRevision,
    availability: .guideUnavailable, requestRevision: nil,
    tracker: .init(
      transition: .unavailable, trackingOutcome: .notAttempted,
      precedingAnalysisTimestamp: nil, resetReasons: []))
}

private func translated(
  _ value: DocumentLiveGeometryObservation, horizontal: Double
) -> DocumentLiveGeometryObservation {
  guard let quad = value.geometry.quadrilateral else { return value }
  let points = quad.points.map { DocumentNormalizedPoint(x: $0.x + horizontal, y: $0.y) }
  return replacing(
    value,
    quad: .init(
      topLeft: points[0], topRight: points[1],
      bottomRight: points[2], bottomLeft: points[3]))
}
