import CoreMedia
import Foundation

/// Consume every ordered analysis observation before UI coalescing. This controller never captures,
/// changes optics, runs a detector, or evaluates physical handling, PAD, or document authenticity.
public struct DocumentTiltController: Sendable {
  public let runID: UUID
  public let configuration: DocumentTiltConfiguration
  private var phase = DocumentTiltPhase.baseline
  private var reason: DocumentTiltReason?
  private var revision: UInt64 = 0
  private var baseline: DocumentTiltBaseline?
  private var signedDelta: Double?
  private var events: [DocumentTiltEvidenceEvent] = []
  private var previous: DocumentLiveGeometryObservation?
  private var previousMeasurement: DocumentPerspectiveMeasurement?
  private var correction = 0.0
  private struct BaselineSample: Sendable {
    let ratio: Double
    let measurement: DocumentPerspectiveMeasurement
    var time: DocumentCaptureClockTimestamp { measurement.captureTimestamp }
    var raw: Double { measurement.rightToLeftEdgeLogRatio }
  }
  private var baselineSamples: [BaselineSample] = []
  private var dwellCount = 0
  private var dwellSeconds = 0.0

  public init(runID: UUID, configuration: DocumentTiltConfiguration = .provisionalV1) {
    self.runID = runID
    self.configuration = configuration
    if !configuration.valid {
      phase = .cancelled
      reason = .invalidConfiguration
    }
    _ = record()
  }

  public var presentation: DocumentTiltPresentation {
    .init(
      runID: runID, revision: revision, phase: phase, reason: reason, baseline: baseline,
      signedDelta: signedDelta, consecutiveObservations: dwellCount, dwellSeconds: dwellSeconds)
  }

  public var initialUpdate: DocumentTiltUpdate {
    let first = events[0]
    return .init(
      presentation: .init(
        runID: runID, revision: first.revision, phase: first.phase,
        reason: first.reason, baseline: nil, signedDelta: nil, consecutiveObservations: 0,
        dwellSeconds: 0),
      event: first)
  }

  public var evidence: DocumentTiltEvidence {
    .init(
      configuration: configuration, presentation: presentation, events: events,
      reachedEvidenceLimit: phase == .evidenceLimit)
  }

  public mutating func skip(reason: DocumentTiltReason = .skipped) -> DocumentTiltUpdate {
    end(phase: .skipped, reason: reason)
  }

  public mutating func cancel(reason: DocumentTiltReason = .cancelled) -> DocumentTiltUpdate {
    end(phase: .cancelled, reason: reason)
  }

  public mutating func consume(
    _ observation: DocumentLiveGeometryObservation
  ) -> DocumentTiltUpdate {
    guard !phase.terminal else { return .init(presentation: presentation, event: nil) }
    guard events.count < configuration.evidenceSampleLimit - 1 else {
      return end(phase: .evidenceLimit, reason: .evidenceLimit)
    }
    guard observation.valid, supportsSource(observation) else {
      return recover(.invalidObservation, observation: nil)
    }
    guard let measurement = measurement(observation) else {
      return recover(.observationUnavailable, observation: observation)
    }
    if let issue = continuityIssue(observation) { return recover(issue, observation: observation) }
    let elapsed = previous.map { seconds($0.captureTimestamp, observation.captureTimestamp) } ?? 0
    let refresh =
      !configuration.usesFreshDetections
      && observation.tracker.transition == .periodicDetectionRefresh
    let associatedRefresh = refresh && previousMeasurement != nil
    if let previousMeasurement {
      guard associates(measurement, with: previousMeasurement, refresh: refresh) else {
        return recover(.associationFailed, observation: observation)
      }
      if refresh {
        correction +=
          measurement.rightToLeftEdgeLogRatio - previousMeasurement.rightToLeftEdgeLogRatio
        resetDwell()
      }
    }
    previous = observation
    previousMeasurement = measurement
    let corrected = measurement.rightToLeftEdgeLogRatio - correction
    reason = nil
    signedDelta = baseline.map { corrected - $0.medianLogRatio }
    let previousPhase = phase
    let previousDwell = dwellCount
    if !refresh {
      if baseline == nil {
        collectBaseline(corrected, measurement: measurement)
      } else {
        advance(
          delta: signedDelta ?? 0,
          rawDelta: measurement.rightToLeftEdgeLogRatio - (baseline?.rawMedianLogRatio ?? 0),
          elapsed: elapsed)
      }
    }
    return record(
      observation: observation, rawRatio: measurement.rightToLeftEdgeLogRatio,
      correctedRatio: corrected,
      credited: !refresh
        && (previousPhase == .baseline || phase != previousPhase || dwellCount > previousDwell),
      associatedRefresh: associatedRefresh)
  }
}

extension DocumentTiltController {
  private func measurement(
    _ observation: DocumentLiveGeometryObservation
  ) -> DocumentPerspectiveMeasurement? {
    guard observation.availability == .observed, let quad = observation.geometry.quadrilateral
    else { return nil }
    return try? DocumentPerspectiveMeasurement(
      deliveredTopLeftQuadrilateral: quad, pixelWidth: observation.pixelWidth,
      pixelHeight: observation.pixelHeight, captureTimestamp: observation.captureTimestamp)
  }

  private func supportsSource(_ observation: DocumentLiveGeometryObservation) -> Bool {
    if configuration.usesFreshDetections {
      return observation.schemaVersion == 2 && observation.analysisMode == .freshDetection
        && (observation.availability != .observed
          || observation.tracker.transition == .freshDetection)
    }
    return observation.schemaVersion == 1
  }

  private func continuityIssue(
    _ observation: DocumentLiveGeometryObservation
  ) -> DocumentTiltReason? {
    guard let previous else { return nil }
    guard observation.captureTimestamp.clock == previous.captureTimestamp.clock,
      observation.captureTimestamp.epoch == previous.captureTimestamp.epoch
    else { return .clockChanged }
    guard observation.geometryRevision == previous.geometryRevision else { return .geometryChanged }
    guard observation.pixelWidth == previous.pixelWidth,
      observation.pixelHeight == previous.pixelHeight,
      observation.tracker.resetReasons.isEmpty
    else { return .trackerReset }
    guard observation.analysisSequence == previous.analysisSequence &+ 1 else {
      return .sequenceDiscontinuity
    }
    let elapsed = seconds(previous.captureTimestamp, observation.captureTimestamp)
    guard elapsed > 0, elapsed <= configuration.maximumGapSeconds else { return .sourceGap }
    if configuration.usesFreshDetections {
      guard observation.geometry.method == previous.geometry.method,
        observation.requestRevision == previous.requestRevision
      else { return .measurementSourceChanged }
      return nil
    }
    return legacyTransitionIssue(observation, previous: previous)
  }

  private func legacyTransitionIssue(
    _ observation: DocumentLiveGeometryObservation, previous: DocumentLiveGeometryObservation
  ) -> DocumentTiltReason? {
    switch observation.tracker.transition {
    case .tracked:
      guard observation.tracker.precedingAnalysisTimestamp == previous.captureTimestamp else {
        return .sequenceDiscontinuity
      }
    case .periodicDetectionRefresh: break
    default: return .trackerReset
    }
    return nil
  }

  private func associates(
    _ value: DocumentPerspectiveMeasurement,
    with previous: DocumentPerspectiveMeasurement, refresh: Bool, baseline: Bool = false
  ) -> Bool {
    let diagonal = hypot(Double(value.pixelWidth), Double(value.pixelHeight))
    let displacement =
      zip(
        value.deliveredTopLeftQuadrilateral.points,
        previous.deliveredTopLeftQuadrilateral.points
      ).map { first, second in
        hypot(
          (first.x - second.x) * Double(value.pixelWidth),
          (first.y - second.y) * Double(value.pixelHeight)) / diagonal
      }.max() ?? .infinity
    let scale = max(
      abs(log(value.meanHorizontalEdgePixels / previous.meanHorizontalEdgePixels)),
      abs(log(value.meanVerticalEdgePixels / previous.meanVerticalEdgePixels)))
    let angle = abs(
      atan2(
        sin(value.imagePlaneAngleRadians - previous.imagePlaneAngleRadians),
        cos(value.imagePlaneAngleRadians - previous.imagePlaneAngleRadians)))
    return displacement
      <= (baseline
        ? configuration.maximumBaselineCornerDisplacement : configuration.maximumCornerDisplacement)
      && scale
        <= (baseline
          ? configuration.maximumBaselineScaleLogChange : configuration.maximumScaleLogChange)
      && angle
        <= (baseline
          ? configuration.maximumBaselineImagePlaneRotationRadians
          : configuration.maximumImagePlaneRotationRadians)
      && (!refresh
        || abs(value.rightToLeftEdgeLogRatio - previous.rightToLeftEdgeLogRatio)
          <= configuration.maximumRefreshRatioJump)
  }

  private mutating func collectBaseline(
    _ ratio: Double, measurement: DocumentPerspectiveMeasurement
  ) {
    baselineSamples.append(.init(ratio: ratio, measurement: measurement))
    if baselineSamples.count > configuration.baselineObservations * 2 {
      baselineSamples.removeFirst()
    }
    selectFreshBaselineSuffix()
    guard baselineSamples.count >= configuration.baselineObservations,
      let first = baselineSamples.first, let last = baselineSamples.last,
      seconds(first.time, last.time) + 1e-9 >= configuration.baselineDurationSeconds
    else { return }
    let values = baselineSamples.map(\.ratio)
    let middle = median(values)
    let deviation = median(values.map { abs($0 - middle) })
    let rawValues = baselineSamples.map(\.raw)
    let rawMiddle = median(rawValues)
    let rawDeviation = median(rawValues.map { abs($0 - rawMiddle) })
    guard (values.max() ?? 0) - (values.min() ?? 0) <= configuration.baselineMaximumRange,
      abs(last.ratio - first.ratio) <= configuration.baselineMaximumDrift,
      (rawValues.max() ?? 0) - (rawValues.min() ?? 0) <= configuration.baselineMaximumRange,
      abs(last.raw - first.raw) <= configuration.baselineMaximumDrift,
      baselineShapeIsStable(first: first, last: last)
    else {
      reason = .baselineUnstable
      return
    }
    let noise = max(configuration.empiricalNoiseFloor, max(deviation, rawDeviation) * 1.4826)
    let excursion = max(
      configuration.minimumExcursion, noise * configuration.excursionNoiseMultiplier)
    let neutral = max(
      configuration.neutralMinimumBand, noise * configuration.neutralNoiseMultiplier)
    baseline = .init(
      firstTimestamp: first.time, lastTimestamp: last.time,
      observationCount: values.count, rawMedianLogRatio: rawMiddle,
      rawMedianAbsoluteDeviation: rawDeviation,
      medianLogRatio: middle, medianAbsoluteDeviation: deviation,
      empiricalNoise: noise, excursionEnter: excursion,
      excursionRelease: excursion * configuration.excursionReleaseFraction,
      neutralEnter: neutral, neutralRelease: neutral * configuration.neutralReleaseMultiplier)
    phase = .leftEdgeCloser
    signedDelta = ratio - middle
    resetDwell()
  }

  /// V2 evaluates the shortest contiguous stable interval that meets both count and source time.
  /// V1 retains its historical growing window, including the demonstrated settling delay.
  private mutating func selectFreshBaselineSuffix() {
    guard configuration.usesFreshDetections, let last = baselineSamples.last else { return }
    while baselineSamples.count > configuration.baselineObservations {
      guard
        seconds(baselineSamples[1].time, last.time) + 1e-9 >= configuration.baselineDurationSeconds
      else { break }
      baselineSamples.removeFirst()
    }
  }

  private func baselineShapeIsStable(first: BaselineSample, last: BaselineSample) -> Bool {
    guard configuration.usesFreshDetections else {
      return baselineSamples.allSatisfy {
        associates($0.measurement, with: first.measurement, refresh: false, baseline: true)
      }
    }
    // Translation, uniform scale and in-plane roll do not change either measured edge ratio.
    // Per-frame corner/scale/roll association still applies before any baseline sample is admitted.
    let secondary = baselineSamples.map { $0.measurement.bottomToTopEdgeLogRatio }
    return (secondary.max() ?? 0) - (secondary.min() ?? 0) <= configuration.baselineMaximumRange
      && abs(last.measurement.bottomToTopEdgeLogRatio - first.measurement.bottomToTopEdgeLogRatio)
        <= configuration.baselineMaximumDrift
  }

  private mutating func advance(delta: Double, rawDelta: Double, elapsed: Double) {
    guard let baseline else { return }
    guard qualifies(delta: delta, baseline: baseline),
      qualifies(delta: rawDelta, baseline: baseline)
    else {
      resetDwell()
      return
    }
    if dwellCount > 0 { dwellSeconds += elapsed }
    dwellCount += 1
    guard dwellCount >= configuration.dwellObservations,
      dwellSeconds + 1e-9 >= configuration.dwellDurationSeconds
    else { return }
    switch phase {
    case .leftEdgeCloser: phase = .neutralAfterLeft
    case .neutralAfterLeft: phase = .rightEdgeCloser
    case .rightEdgeCloser: phase = .neutralAfterRight
    case .neutralAfterRight: phase = .readyForStill
    default: break
    }
    resetDwell()
  }

  private func qualifies(delta: Double, baseline: DocumentTiltBaseline) -> Bool {
    let excursion = dwellCount == 0 ? baseline.excursionEnter : baseline.excursionRelease
    let neutral = dwellCount == 0 ? baseline.neutralEnter : baseline.neutralRelease
    switch phase {
    case .leftEdgeCloser: return delta <= -excursion
    case .rightEdgeCloser: return delta >= excursion
    case .neutralAfterLeft, .neutralAfterRight: return abs(delta) <= neutral
    default: return false
    }
  }

  private func seconds(
    _ first: DocumentCaptureClockTimestamp, _ last: DocumentCaptureClockTimestamp
  ) -> Double {
    CMTimeGetSeconds(
      CMTimeSubtract(
        DocumentTemporalRecorder.mediaTime(last),
        DocumentTemporalRecorder.mediaTime(first)))
  }

  private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }

  private mutating func resetDwell() {
    dwellCount = 0
    dwellSeconds = 0
  }

  private mutating func recover(
    _ issue: DocumentTiltReason,
    observation: DocumentLiveGeometryObservation?
  ) -> DocumentTiltUpdate {
    phase = .baseline
    reason = issue
    baseline = nil
    signedDelta = nil
    previous = nil
    previousMeasurement = nil
    correction = 0
    baselineSamples.removeAll(keepingCapacity: true)
    resetDwell()
    return record(observation: observation)
  }

  private mutating func end(
    phase: DocumentTiltPhase, reason: DocumentTiltReason
  ) -> DocumentTiltUpdate {
    guard !self.phase.terminal else { return .init(presentation: presentation, event: nil) }
    self.phase = phase
    self.reason = reason
    resetDwell()
    return record()
  }

  private mutating func record(
    observation: DocumentLiveGeometryObservation? = nil,
    rawRatio: Double? = nil, correctedRatio: Double? = nil, credited: Bool = false,
    associatedRefresh: Bool = false
  ) -> DocumentTiltUpdate {
    revision &+= 1
    let event = DocumentTiltEvidenceEvent(
      runID: runID, revision: revision,
      configurationVersion: configuration.version,
      configuration: revision == 1 ? configuration : nil, phase: phase, reason: reason,
      observation: observation, rawLogRatio: rawRatio, correctedLogRatio: correctedRatio,
      signedDelta: signedDelta, credited: credited, associatedRefresh: associatedRefresh,
      baseline: baseline)
    events.append(event)
    return .init(presentation: presentation, event: event)
  }
}
