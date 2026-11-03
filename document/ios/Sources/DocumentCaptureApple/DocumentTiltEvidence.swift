import Foundation

/// Ordered source observations, independent of lossy UI delivery. No retained frame UUID is invented.
public struct DocumentTiltEvidenceEvent: Codable, Equatable, Sendable {
  public let runID: UUID
  public let revision: UInt64
  public let configurationVersion: String
  public let configuration: DocumentTiltConfiguration?
  public let phase: DocumentTiltPhase
  public let reason: DocumentTiltReason?
  public let observation: DocumentLiveGeometryObservation?
  public let rawLogRatio: Double?
  public let correctedLogRatio: Double?
  public let signedDelta: Double?
  public let credited: Bool
  public let associatedRefresh: Bool
  public let baseline: DocumentTiltBaseline?
  public var captureTimestamp: DocumentCaptureClockTimestamp? { observation?.captureTimestamp }

  public var valid: Bool {
    let state = DocumentTiltPresentation(
      runID: runID, revision: revision, phase: phase,
      reason: reason, baseline: baseline, signedDelta: signedDelta, consecutiveObservations: 0,
      dwellSeconds: 0)
    return state.valid && measuredRatioMatches
      && (revision != 1 || configuration != nil)
      && (configuration.map { $0.valid && $0.version == configurationVersion } ?? true)
      && policyMatches
      && (observation?.valid ?? true) && (baseline?.valid ?? true)
      && [rawLogRatio, correctedLogRatio, signedDelta].allSatisfy { $0?.isFinite ?? true }
      && (rawLogRatio == nil) == (correctedLogRatio == nil)
      && (!credited || (observation?.availability == .observed && rawLogRatio != nil))
      && (!associatedRefresh
        || (observation?.tracker.transition == .periodicDetectionRefresh && !credited))
  }
  private var policyMatches: Bool {
    guard let version = DocumentTiltConfiguration.Version(rawValue: configurationVersion) else {
      return false
    }
    if reason == .recordingBudget {
      guard phase == .cancelled, observation == nil, !credited, rawLogRatio == nil else {
        return false
      }
    }
    switch version {
    case .trackedV1:
      return reason != .measurementSourceChanged && (observation?.schemaVersion ?? 1) == 1
    case .freshDetectionV2:
      guard !associatedRefresh, rawLogRatio == correctedLogRatio else { return false }
      if let baseline {
        guard baseline.rawMedianLogRatio == baseline.medianLogRatio,
          baseline.rawMedianAbsoluteDeviation == baseline.medianAbsoluteDeviation
        else { return false }
      }
      guard let observation else { return true }
      return observation.schemaVersion == 2 && observation.analysisMode == .freshDetection
        && (observation.availability != .observed
          || observation.tracker.transition == .freshDetection)
    }
  }

  private var measuredRatioMatches: Bool {
    guard let rawLogRatio else { return true }
    guard let observation, observation.availability == .observed,
      let quad = observation.geometry.quadrilateral,
      let measurement = try? DocumentPerspectiveMeasurement(
        deliveredTopLeftQuadrilateral: quad,
        pixelWidth: observation.pixelWidth, pixelHeight: observation.pixelHeight,
        captureTimestamp: observation.captureTimestamp)
    else { return false }
    let expected = measurement.rightToLeftEdgeLogRatio
    guard abs(rawLogRatio - expected) <= 1e-12 * max(1, abs(expected)) else { return false }
    if let baseline, let correctedLogRatio {
      guard signedDelta == correctedLogRatio - baseline.medianLogRatio else { return false }
      if phase == .readyForStill {
        return abs(rawLogRatio - baseline.rawMedianLogRatio) <= baseline.neutralRelease
      }
    }
    return true
  }
}

public struct DocumentTiltUpdate: Codable, Equatable, Sendable {
  public let presentation: DocumentTiltPresentation
  public let event: DocumentTiltEvidenceEvent?

  public var valid: Bool {
    guard presentation.valid else { return false }
    guard let event else { return true }
    return event.valid && event.runID == presentation.runID
      && event.revision == presentation.revision && event.phase == presentation.phase
      && event.baseline == presentation.baseline && event.signedDelta == presentation.signedDelta
      && event.reason == presentation.reason
  }
}

public struct DocumentTiltEvidence: Codable, Equatable, Sendable {
  public let configuration: DocumentTiltConfiguration
  public let presentation: DocumentTiltPresentation
  public let events: [DocumentTiltEvidenceEvent]
  /// True means observation stopped before another event would exceed the configured bound.
  public let reachedEvidenceLimit: Bool
}
