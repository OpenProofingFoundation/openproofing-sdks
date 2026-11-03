import CoreMedia
import Foundation

/// A 2D policy; it is not physical validation or calibrated measurement uncertainty.
public struct DocumentTiltConfiguration: Codable, Equatable, Sendable {
  public enum Version: String, Codable, Sendable {
    case trackedV1 = "provisional-projected-tilt-v1"
    case freshDetectionV2 = "provisional-projected-tilt-v2"
  }

  public static let provisionalV1 = DocumentTiltConfiguration()
  public static let provisionalV2 = DocumentTiltConfiguration(version: .freshDetectionV2)
  public var usesFreshDetections: Bool { version == Version.freshDetectionV2.rawValue }
  public let version: String
  public let baselineObservations: Int
  public let baselineDurationSeconds: Double
  public let baselineMaximumRange: Double
  public let baselineMaximumDrift: Double
  /// Above the largest retained pre-still MAD × 1.4826 (~0.0133); those windows lack ground truth.
  public let empiricalNoiseFloor: Double
  public let minimumExcursion: Double
  public let excursionNoiseMultiplier: Double
  public let excursionReleaseFraction: Double
  public let neutralMinimumBand: Double
  public let neutralNoiseMultiplier: Double
  public let neutralReleaseMultiplier: Double
  public let dwellObservations: Int
  public let dwellDurationSeconds: Double
  public let maximumGapSeconds: Double
  /// Host lifecycle failure deadline; it never advances a movement or dwell.
  public let observationSilenceTimeoutSeconds: Double
  /// V1-only absolute framing anchors; V2 stabilizes both opposite-edge log ratios instead.
  public let maximumBaselineCornerDisplacement: Double
  public let maximumBaselineScaleLogChange: Double
  public let maximumBaselineImagePlaneRotationRadians: Double
  public let maximumCornerDisplacement: Double
  public let maximumScaleLogChange: Double
  /// Image-plane rotation only; never a 3D tilt angle.
  public let maximumImagePlaneRotationRadians: Double
  public let maximumRefreshRatioJump: Double
  public let evidenceSampleLimit: Int

  public init(evidenceSampleLimit: Int = 100, version: Version = .trackedV1) {
    self.version = version.rawValue
    baselineObservations = 5
    baselineDurationSeconds = 0.8
    baselineMaximumRange = 0.05
    baselineMaximumDrift = 0.03
    empiricalNoiseFloor = 0.015
    minimumExcursion = 0.08
    excursionNoiseMultiplier = 6
    excursionReleaseFraction = 0.75
    neutralMinimumBand = 0.02
    neutralNoiseMultiplier = 2
    neutralReleaseMultiplier = 1.5
    dwellObservations = 3
    dwellDurationSeconds = 0.4
    maximumGapSeconds = 0.45
    observationSilenceTimeoutSeconds = 1.0
    maximumBaselineCornerDisplacement = 0.010
    maximumBaselineScaleLogChange = 0.025
    maximumBaselineImagePlaneRotationRadians = 0.025
    maximumCornerDisplacement = 0.035
    maximumScaleLogChange = 0.10
    maximumImagePlaneRotationRadians = 0.10
    maximumRefreshRatioJump = 0.025
    self.evidenceSampleLimit = evidenceSampleLimit
  }

  /// Only the two frozen numerical policies are supported; evidence capacity is bounded.
  public var valid: Bool {
    guard (16...1200).contains(evidenceSampleLimit), let version = Version(rawValue: version) else {
      return false
    }
    return self
      == DocumentTiltConfiguration(evidenceSampleLimit: evidenceSampleLimit, version: version)
  }
}

public enum DocumentTiltPhase: String, Codable, Sendable {
  case baseline, leftEdgeCloser, neutralAfterLeft, rightEdgeCloser, neutralAfterRight
  case readyForStill, skipped, cancelled, evidenceLimit

  public var terminal: Bool {
    [.readyForStill, .skipped, .cancelled, .evidenceLimit].contains(self)
  }
}

public enum DocumentTiltReason: String, Codable, Sendable {
  case sessionStopped, configurationChanged, geometryChanged, clockChanged
  case nativeControlsChanged, zoomNotSettled, replaced, cancelled, skipped
  case userCaptureNow, userSkipped, completed
  case invalidConfiguration, invalidObservation, observationUnavailable, observationSilence,
    sourceGap
  case sequenceDiscontinuity, trackerReset, associationFailed, baselineUnstable, evidenceLimit
  case measurementSourceChanged, recordingBudget
}

public struct DocumentTiltBaseline: Codable, Equatable, Sendable {
  public let firstTimestamp: DocumentCaptureClockTimestamp
  public let lastTimestamp: DocumentCaptureClockTimestamp
  public let observationCount: Int
  public let rawMedianLogRatio: Double
  public let rawMedianAbsoluteDeviation: Double
  public let medianLogRatio: Double
  public let medianAbsoluteDeviation: Double
  public let empiricalNoise: Double
  public let excursionEnter: Double
  public let excursionRelease: Double
  public let neutralEnter: Double
  public let neutralRelease: Double

  public var valid: Bool {
    let config = DocumentTiltConfiguration.provisionalV1
    let values =
      [rawMedianLogRatio, rawMedianAbsoluteDeviation, medianLogRatio]
      + [medianAbsoluteDeviation, empiricalNoise, excursionEnter]
      + [excursionRelease, neutralEnter, neutralRelease]
    guard firstTimestamp.isNumeric, lastTimestamp.isNumeric,
      firstTimestamp.clock == lastTimestamp.clock, firstTimestamp.epoch == lastTimestamp.epoch,
      (config.baselineObservations...(config.baselineObservations * 2)).contains(observationCount),
      values.allSatisfy(\.isFinite),
      medianAbsoluteDeviation >= 0, rawMedianAbsoluteDeviation >= 0
    else { return false }
    let duration = CMTimeGetSeconds(
      CMTimeSubtract(
        DocumentTemporalRecorder.mediaTime(lastTimestamp),
        DocumentTemporalRecorder.mediaTime(firstTimestamp)))
    let noise = max(
      config.empiricalNoiseFloor, max(medianAbsoluteDeviation, rawMedianAbsoluteDeviation) * 1.4826)
    let excursion = max(config.minimumExcursion, noise * config.excursionNoiseMultiplier)
    let neutral = max(config.neutralMinimumBand, noise * config.neutralNoiseMultiplier)
    return duration + 1e-9 >= config.baselineDurationSeconds && empiricalNoise == noise
      && excursionEnter == excursion
      && excursionRelease == excursion * config.excursionReleaseFraction
      && neutralEnter == neutral && neutralRelease == neutral * config.neutralReleaseMultiplier
      && excursionRelease > neutralRelease
  }
}

public struct DocumentTiltPresentation: Codable, Equatable, Sendable {
  public enum UncertaintyStatus: String, Codable, Sendable { case notEstimated }
  public enum IllustratedEdge: String, Codable, Sendable { case none, left, right }
  public let runID: UUID
  public let revision: UInt64
  public let phase: DocumentTiltPhase
  public let reason: DocumentTiltReason?
  public let baseline: DocumentTiltBaseline?
  public let signedDelta: Double?
  public let consecutiveObservations: Int
  public let dwellSeconds: Double
  public var uncertaintyStatus: UncertaintyStatus { .notEstimated }

  public var valid: Bool {
    guard revision > 0, consecutiveObservations >= 0, dwellSeconds.isFinite, dwellSeconds >= 0,
      signedDelta?.isFinite ?? true, baseline?.valid ?? true
    else { return false }
    switch phase {
    case .baseline:
      return baseline == nil && signedDelta == nil
        && ![.completed, .skipped, .userSkipped, .evidenceLimit, .recordingBudget].contains(reason)
    case .leftEdgeCloser, .neutralAfterLeft, .rightEdgeCloser, .neutralAfterRight, .readyForStill:
      guard baseline != nil, signedDelta != nil, reason == nil else { return false }
      return phase != .readyForStill
        || abs(signedDelta ?? .infinity) <= (baseline?.neutralRelease ?? 0)
    case .skipped: return reason == .skipped || reason == .userSkipped
    case .cancelled:
      return reason != nil
        && ![.completed, .skipped, .userSkipped, .evidenceLimit].contains(reason)
    case .evidenceLimit: return reason == .evidenceLimit
    }
  }
}
