import Foundation

/// Temporal confirmation after camera control changes, independent of AVFoundation.
struct DocumentAdaptiveReadinessPolicy {
  private typealias Tuning = DocumentCaptureTuning.Stability
  var tuning = DocumentCaptureTuningOverrides()
  private var previous: DocumentCaptureQualityObservation?
  private var count = 0

  init(tuning: DocumentCaptureTuningOverrides = .init()) { self.tuning = tuning }

  mutating func reset() {
    previous = nil
    count = 0
  }

  mutating func observe(
    _ observation: DocumentCaptureQualityObservation, controlsAdjusting: Bool, changedAt: Date
  ) -> Bool {
    defer { previous = observation }
    guard let previous, previous.geometryRevision == observation.geometryRevision,
      observation.sequence == previous.sequence &+ 1,
      let before = previous.documentBounds, let current = observation.documentBounds
    else {
      count = 0
      return false
    }
    let interval = observation.timestamp.timeIntervalSince(previous.timestamp)
    let stationary =
      abs(before.minX - current.minX) < tuning.maximumEdgeMovement
      && abs(before.minY - current.minY) < tuning.maximumEdgeMovement
      && abs(before.maxX - current.maxX) < tuning.maximumEdgeMovement
      && abs(before.maxY - current.maxY) < tuning.maximumEdgeMovement
    let clean =
      !controlsAdjusting
      && observation.timestamp.timeIntervalSince(changedAt) >= tuning.settleSeconds
      && stationary && interval > 0 && interval <= Tuning.maximumObservationIntervalSeconds
      && observation.assessment.ready
      && observation.metrics.motion.map { $0 <= tuning.maximumStableMotion }
        == true
    count = clean ? min(count + 1, tuning.stabilityObservations) : 0
    return count >= tuning.stabilityObservations
  }
}
