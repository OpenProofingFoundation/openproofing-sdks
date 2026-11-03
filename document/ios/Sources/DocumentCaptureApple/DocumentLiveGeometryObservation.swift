import CoreMedia
import Foundation

/// One existing analysis result, not a native-frame sequence or a card identity.
/// Corners use normalized delivered-buffer top-left coordinates without smoothing.
public struct DocumentLiveGeometryObservation: Codable, Equatable, Sendable {
  public enum AnalysisMode: String, Codable, Sendable {
    case trackingAssisted, freshDetection
  }
  public enum Availability: String, Codable, Sendable {
    case observed, noAcceptedRectangle, guideUnavailable, analysisFailed
  }
  public enum Transition: String, Codable, Sendable {
    case initialDetection, tracked, periodicDetectionRefresh, trackingLostThenDetected
    case lost, reset, unavailable, freshDetection
  }
  public enum TrackingOutcome: String, Codable, Sendable {
    case notAttempted, accepted, rejected, failed
  }
  public enum ResetReason: String, Codable, CaseIterable, Sendable {
    case sessionStarted, sessionReset, geometryRevisionChanged, configurationChanged
    case clockChanged, clockDiscontinuity, bufferDimensionsChanged, analysisModeChanged
  }
  public struct TrackerFacts: Codable, Equatable, Sendable {
    public let transition: Transition
    public let trackingOutcome: TrackingOutcome
    /// Present only for an accepted tracker update, never for re-detection.
    public let precedingAnalysisTimestamp: DocumentCaptureClockTimestamp?
    public let resetReasons: [ResetReason]
  }

  public let schemaVersion: Int
  public let observedAt: Date
  public let geometry: DocumentTemporalGeometry
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let analysisSequence: UInt64
  public let geometryRevision: UInt64
  public let availability: Availability
  public let requestRevision: Int?
  public let tracker: TrackerFacts
  /// Absent on legacy packets; ordered native attempts on this exact source image, at most three.
  public let requestFacts: [DocumentGeometryRequestFact]?
  /// Schema 2 explicitly identifies independent per-image detections; schema 1 remains legacy tracking.
  public let analysisMode: AnalysisMode?

  init(
    schemaVersion: Int, observedAt: Date, geometry: DocumentTemporalGeometry,
    pixelWidth: Int, pixelHeight: Int, analysisSequence: UInt64, geometryRevision: UInt64,
    availability: Availability, requestRevision: Int?, tracker: TrackerFacts,
    requestFacts: [DocumentGeometryRequestFact]? = nil, analysisMode: AnalysisMode? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.observedAt = observedAt
    self.geometry = geometry
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.analysisSequence = analysisSequence
    self.geometryRevision = geometryRevision
    self.availability = availability
    self.requestRevision = requestRevision
    self.tracker = tracker
    self.requestFacts = requestFacts
    self.analysisMode = analysisMode
  }
  public var captureTimestamp: DocumentCaptureClockTimestamp { geometry.observationTimestamp }

  /// Structural validation only; rectangle confidence is not evidence of card identity.
  public var valid: Bool {
    guard validAnalysisMode, pixelWidth > 0, pixelHeight > 0, analysisSequence > 0,
      observedAt.timeIntervalSinceReferenceDate.isFinite,
      Self.validTime(captureTimestamp),
      geometry.coordinateSpace == "normalized_delivered_video_buffer_top_left",
      requestRevision.map({ $0 > 0 }) ?? true,
      Set(tracker.resetReasons).count == tracker.resetReasons.count, requestFactsAreValid
    else { return false }
    if let confidence = geometry.confidence {
      guard confidence.isFinite, (0...1).contains(confidence) else { return false }
    }
    if availability == .observed {
      guard let quad = geometry.quadrilateral, geometry.status == "observed",
        geometry.confidence != nil, geometry.method != nil, requestRevision != nil,
        quad.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
      else { return false }
    } else {
      guard geometry.quadrilateral == nil, geometry.confidence == nil,
        geometry.status == "analyzed_no_accepted_rectangle"
      else { return false }
    }
    switch tracker.transition {
    case .tracked:
      guard availability == .observed, tracker.trackingOutcome == .accepted,
        tracker.resetReasons.isEmpty, let previous = tracker.precedingAnalysisTimestamp,
        Self.validTime(previous), previous.clock == captureTimestamp.clock,
        previous.epoch == captureTimestamp.epoch,
        CMTimeCompare(
          DocumentTemporalRecorder.mediaTime(previous),
          DocumentTemporalRecorder.mediaTime(captureTimestamp)) < 0
      else { return false }
    case .initialDetection, .periodicDetectionRefresh, .freshDetection:
      guard availability == .observed, tracker.trackingOutcome == .notAttempted,
        tracker.precedingAnalysisTimestamp == nil
      else { return false }
      if tracker.transition == .periodicDetectionRefresh && !tracker.resetReasons.isEmpty {
        return false
      }
    case .trackingLostThenDetected:
      guard availability == .observed, tracker.resetReasons.isEmpty,
        [.rejected, .failed].contains(tracker.trackingOutcome),
        tracker.precedingAnalysisTimestamp == nil
      else { return false }
    case .lost, .reset, .unavailable:
      guard availability != .observed, tracker.trackingOutcome != .accepted,
        tracker.precedingAnalysisTimestamp == nil
      else { return false }
      if tracker.transition == .reset && tracker.resetReasons.isEmpty { return false }
      if tracker.transition != .reset && !tracker.resetReasons.isEmpty { return false }
    }
    return true
  }

  private var validAnalysisMode: Bool {
    if schemaVersion == 1 { return analysisMode == nil && tracker.transition != .freshDetection }
    guard schemaVersion == 2, analysisMode == .freshDetection,
      tracker.trackingOutcome == .notAttempted, tracker.precedingAnalysisTimestamp == nil,
      let requestFacts, requestFacts.allSatisfy({ $0.stage != .rectangleTracking })
    else { return false }
    return availability != .observed || tracker.transition == .freshDetection
  }

  private static func validTime(_ timestamp: DocumentCaptureClockTimestamp) -> Bool {
    timestamp.timescale > 0 && DocumentTemporalRecorder.mediaTime(timestamp).isNumeric
  }
}

/// Analysis-queue metadata only. It cannot run Vision, retain pixels, or infer identity.
struct DocumentLiveGeometryHistory {
  typealias Packet = DocumentLiveGeometryObservation
  private var previousTimestamp: DocumentCaptureClockTimestamp?
  private var previousWidth: Int?
  private var previousHeight: Int?
  private var pendingResets: [Packet.ResetReason] = [.sessionStarted]

  mutating func reset(_ reason: Packet.ResetReason) {
    previousTimestamp = nil
    if !pendingResets.contains(reason) { pendingResets.append(reason) }
  }

  /// Return true when the actual source time or dimensions require tracker reset.
  mutating func prepare(timestamp: DocumentCaptureClockTimestamp, width: Int, height: Int) -> Bool {
    var changed = false
    if let previousTimestamp {
      let ordered =
        CMTimeCompare(
          DocumentTemporalRecorder.mediaTime(timestamp),
          DocumentTemporalRecorder.mediaTime(previousTimestamp)) > 0
      let sameClock =
        previousTimestamp.clock == timestamp.clock && previousTimestamp.epoch == timestamp.epoch
      if !ordered || !sameClock {
        reset(.clockDiscontinuity)
        changed = true
      }
    }
    if let previousWidth, let previousHeight, previousWidth != width || previousHeight != height {
      reset(.bufferDimensionsChanged)
      changed = true
    }
    previousWidth = width
    previousHeight = height
    return changed
  }

  struct Analysis {
    let width: Int
    let height: Int
    let sequence: UInt64
    let revision: UInt64
    let observedAt: Date
  }

  mutating func packet(
    geometry: DocumentTemporalGeometry, analysis: Analysis,
    availability: Packet.Availability, tracking: (Packet.Transition, Packet.TrackingOutcome),
    requestRevision: Int?, requestFacts: [DocumentGeometryRequestFact]? = nil,
    analysisMode: Packet.AnalysisMode = .trackingAssisted
  ) -> Packet {
    let (transition, trackingOutcome) = tracking
    let predecessor = transition == .tracked && pendingResets.isEmpty ? previousTimestamp : nil
    let effectiveTransition =
      availability != .observed && !pendingResets.isEmpty ? .reset : transition
    let value = Packet(
      schemaVersion: analysisMode == .freshDetection ? 2 : 1, observedAt: analysis.observedAt,
      geometry: geometry,
      pixelWidth: analysis.width,
      pixelHeight: analysis.height, analysisSequence: analysis.sequence,
      geometryRevision: analysis.revision, availability: availability,
      requestRevision: requestRevision,
      tracker: .init(
        transition: effectiveTransition, trackingOutcome: trackingOutcome,
        precedingAnalysisTimestamp: predecessor, resetReasons: pendingResets),
      requestFacts: requestFacts, analysisMode: analysisMode == .freshDetection ? analysisMode : nil
    )
    previousTimestamp = geometry.observationTimestamp
    pendingResets.removeAll(keepingCapacity: true)
    return value
  }
}
