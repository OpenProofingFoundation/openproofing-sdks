import Foundation

@testable import DocumentCaptureApple

struct TiltPolicyTrial {
  var controller: DocumentTiltController
  var sequence: UInt64 = 0
  var tick: Int64 = 0
  var automaticRefresh = false
  var lastRatio = 0.0
  let fresh: Bool

  init(version: DocumentTiltConfiguration.Version = .freshDetectionV2) {
    fresh = version == .freshDetectionV2
    controller = .init(runID: UUID(), configuration: .init(version: version))
  }

  mutating func hold(_ ratio: Double, count: Int) {
    for _ in 0..<count { send(ratio) }
  }

  mutating func send(_ ratio: Double, step: Int64 = 200) {
    _ = controller.consume(next(ratio, step: step))
  }

  mutating func change(_ ratio: Double) {
    if automaticRefresh && sequence > 0 && sequence.isMultiple(of: 5) { send(lastRatio) }
    send(ratio)
  }

  mutating func next(
    _ ratio: Double, step: Int64 = 200,
    method: String = "VNDetectDocumentSegmentationRequest", requestRevision: Int = 1,
    reset: [DocumentLiveGeometryObservation.ResetReason] = []
  ) -> DocumentLiveGeometryObservation {
    let previousTick = tick
    sequence += 1
    tick += step
    lastRatio = ratio
    let refresh = automaticRefresh && sequence > 1 && (sequence - 1).isMultiple(of: 5)
    let tracked = !fresh && sequence > 1 && !refresh
    let left = 0.35 * exp(-ratio / 2)
    let right = 0.35 * exp(ratio / 2)
    let quad = DocumentQuadrilateral(
      topLeft: .init(x: 0.25, y: 0.5 - left / 2),
      topRight: .init(x: 0.75, y: 0.5 - right / 2),
      bottomRight: .init(x: 0.75, y: 0.5 + right / 2),
      bottomLeft: .init(x: 0.25, y: 0.5 + left / 2))
    let stage: DocumentGeometryRequestFact.Stage =
      method == "VNDetectRectanglesRequest" ? .rectangleDetection : .documentSegmentation
    return .init(
      schemaVersion: fresh ? 2 : 1, observedAt: Date(timeIntervalSince1970: Double(sequence)),
      geometry: .init(
        quadrilateral: quad, observationTimestamp: tiltPolicyTime(tick),
        coordinateSpace: "normalized_delivered_video_buffer_top_left", status: "observed",
        confidence: 0.9, method: tracked ? "VNTrackRectangleRequest" : method),
      pixelWidth: 1320, pixelHeight: 1760, analysisSequence: sequence, geometryRevision: 0,
      availability: .observed, requestRevision: requestRevision,
      tracker: .init(
        transition: fresh
          ? .freshDetection
          : (tracked ? .tracked : (refresh ? .periodicDetectionRefresh : .initialDetection)),
        trackingOutcome: tracked ? .accepted : .notAttempted,
        precedingAnalysisTimestamp: tracked ? tiltPolicyTime(previousTick) : nil,
        resetReasons: reset),
      requestFacts: fresh
        ? [.completed(stage, revision: requestRevision, count: 1, accepted: true)] : nil,
      analysisMode: fresh ? .freshDetection : nil)
  }
}

func tiltPolicyTime(_ value: Int64) -> DocumentCaptureClockTimestamp {
  .init(
    value: value, timescale: 1000, flags: 1, epoch: 0, clock: .captureSessionSynchronizationClock)
}

func tiltPolicyReplacingQuad(
  _ source: DocumentLiveGeometryObservation, points: [DocumentNormalizedPoint]
) -> DocumentLiveGeometryObservation {
  .init(
    schemaVersion: source.schemaVersion, observedAt: source.observedAt,
    geometry: .init(
      quadrilateral: .init(
        topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3]),
      observationTimestamp: source.captureTimestamp,
      coordinateSpace: source.geometry.coordinateSpace,
      status: source.geometry.status, confidence: source.geometry.confidence,
      method: source.geometry.method),
    pixelWidth: source.pixelWidth, pixelHeight: source.pixelHeight,
    analysisSequence: source.analysisSequence, geometryRevision: source.geometryRevision,
    availability: source.availability, requestRevision: source.requestRevision,
    tracker: source.tracker,
    requestFacts: source.requestFacts, analysisMode: source.analysisMode)
}
