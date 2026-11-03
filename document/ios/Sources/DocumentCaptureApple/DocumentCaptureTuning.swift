import DocumentSDK

/// Single source for document-capture tuning defaults used by the SDK and validation host.
/// Values are provisional engineering heuristics, not calibrated performance guarantees.
/// Edit here, rebuild, and compare retained captures before accepting a tuning change.
///
/// These groups represent distinct gates; their waiting periods can accumulate. Existing
/// initializer overrides remain supported. Document-format rules (MRZ/check digits), native
/// camera limits, geometry coordinate definitions and selfie policy are not tuning defaults.
/// Frozen September 2026 capture defaults; not calibrated on a population.
public enum DocumentCaptureTuning: CalibrationProfile {
  public static let populationDescription = "none"
  /// Frozen capture-stack engineering defaults, September 2026; no population calibration.
  public static let profileIdentifier = "capture_engineering_2026_09_v1"
  public static let calibrationStatus = "provisional_engineering_heuristics"

  public enum Geometry {
    public static let guideEdgeMarginFactor = 0.003
    public static let minimumID1EdgeAspect = 1.3
    public static let maximumID1EdgeAspect = 1.9
  }

  public enum Quality {
    /// Document area / largest aspect-preserving fit area (legacy: guide area).
    public static let minimumGuideFill = 0.45
    public static let maximumGuideFill = 1.0
    /// Mean sampled luma / 255, dimensionless.
    public static let minimumMeanLuminance = 0.18
    public static let maximumMeanLuminance = 0.92
    /// Fraction of luma samples at or above clippedLumaSample.
    public static let maximumClippedHighlightRatio = 0.08
    public static let clippedLumaSample: UInt8 = 250
    /// Sampled gradient score, not optical resolution. Also used for focus recovery.
    public static let minimumSharpness = 0.028
    /// Normalized inter-frame luma difference. Adaptive capture requires this lower limit.
    public static let maximumStableMotion = 0.06
    /// Legacy quality gate rejects higher motion unconditionally; moderate motion requires
    /// the stronger sharpness threshold below. Adaptive stability is stricter.
    public static let maximumMotion = 0.15
    public static let minimumSharpnessDuringMotion = 0.04
    public static let requiredStableObservations = 4
  }

  public enum Stability {
    /// Maximum change of each document bounding edge, in normalized buffer coordinates.
    public static let maximumEdgeMovement = 0.015
    public static let postControlSettleSeconds = 0.6
    public static let maximumObservationIntervalSeconds = 0.6
    /// Additional confirmations after the quality gate passes.
    public static let requiredObservations = 3
  }

  public enum AutoCapture {
    public static let frontRequiredObservations = 2
    public static let backRequiredObservations = 1
    /// Consecutive identical in-guide live PDF417 reads before the back photo is requested: the
    /// same confirmation the front asks of its quality observations.
    public static let livePDF417RequiredReads = frontRequiredObservations
    public static let maximumConfirmationIntervalMilliseconds = 500
    /// SDK retry-capable default versus the host's deliberately single-attempt journey.
    public static let defaultMaximumAttemptsPerSide = 3
    public static let journeyMaximumAttemptsPerSide = 1
  }

  public enum Framing {
    /// Fraction inset on each side for zoom planning; not a change to the visible guide.
    public static let zoomPlanningInsetFraction = 0.04
    /// Linear fill = max(document width / guide width, document height / guide height).
    /// These are linear ratios, unlike Quality.minimumGuideFill's area ratio.
    public static let minimumLinearFillBeforeZoom = 0.72
    public static let maximumLinearFillBeforeZoom = 0.9
    public static let targetLinearFill = 0.8
    /// Each zoom step stays within [current / factor, current * factor].
    public static let maximumZoomStepFactor = 1.12
    public static let minimumZoomChange = 0.04
  }

  public enum Focus {
    /// Normalized distance between requested focus points; also checks target acknowledgement.
    public static let targetMovementThreshold = 0.07
    public static let retryIntervalSeconds = 1.5
    public static let maximumAttemptsPerTarget = 3
    /// Control guidance can be older than the observation admitted to the shutter.
    public static let maximumGuidanceAgeSeconds = 1.0
  }

  public enum Controls {
    public static let minimumCommandIntervalSeconds = 0.6
    public static let maximumConsecutiveFailures = 3
    /// Failure deadline only. Elapsed time never establishes native adjustment completion.
    public static let adjustmentTimeoutSeconds = 8.0
  }

  public enum Timing {
    public static let analysisIntervalSeconds = 0.2
    public static let maximumShutterObservationAgeMilliseconds = 250
  }

  public enum Readability {
    /// Generic front-text heuristics, shared with retained-still evaluation.
    /// The validation host does not require live text for document fronts.
    public static let minimumTextLines = 6
    public static let minimumTextCharacters = 40
    public static let minimumPDF417Characters = 40
    /// Fraction of image height; live and retained OCR use different sampling policies.
    public static let minimumLiveTextHeight: Float = 0.01
    public static let minimumStillTextHeight: Float = 0.008
  }

  public enum Location {
    /// Host freshness requirement, seconds; no maximum horizontal-error cutoff is imposed.
    public static let maximumFixAgeSeconds = 10.0
  }

  /// Complete numerical settings inventory for capture provenance.
  public static var defaultValues: [String: Double] {
    [
      "Geometry.guideEdgeMarginFactor": Geometry.guideEdgeMarginFactor,
      "Geometry.minimumID1EdgeAspect": Geometry.minimumID1EdgeAspect,
      "Geometry.maximumID1EdgeAspect": Geometry.maximumID1EdgeAspect,
      "Quality.minimumGuideFill": Double(Quality.minimumGuideFill),
      "Quality.maximumGuideFill": Double(Quality.maximumGuideFill),
      "Quality.minimumMeanLuminance": Double(Quality.minimumMeanLuminance),
      "Quality.maximumMeanLuminance": Double(Quality.maximumMeanLuminance),
      "Quality.maximumClippedHighlightRatio": Double(Quality.maximumClippedHighlightRatio),
      "Quality.clippedLumaSample": Double(Quality.clippedLumaSample),
      "Quality.minimumSharpness": Double(Quality.minimumSharpness),
      "Quality.maximumStableMotion": Double(Quality.maximumStableMotion),
      "Quality.maximumMotion": Double(Quality.maximumMotion),
      "Quality.minimumSharpnessDuringMotion": Double(Quality.minimumSharpnessDuringMotion),
      "Quality.requiredStableObservations": Double(Quality.requiredStableObservations),
      "Stability.maximumEdgeMovement": Double(Stability.maximumEdgeMovement),
      "Stability.postControlSettleSeconds": Double(Stability.postControlSettleSeconds),
      "Stability.maximumObservationIntervalSeconds": Double(
        Stability.maximumObservationIntervalSeconds),
      "Stability.requiredObservations": Double(Stability.requiredObservations),
      "AutoCapture.frontRequiredObservations": Double(AutoCapture.frontRequiredObservations),
      "AutoCapture.backRequiredObservations": Double(AutoCapture.backRequiredObservations),
      "AutoCapture.livePDF417RequiredReads": Double(AutoCapture.livePDF417RequiredReads),
      "AutoCapture.maximumConfirmationIntervalMilliseconds": Double(
        AutoCapture.maximumConfirmationIntervalMilliseconds),
      "AutoCapture.defaultMaximumAttemptsPerSide": Double(
        AutoCapture.defaultMaximumAttemptsPerSide),
      "AutoCapture.journeyMaximumAttemptsPerSide": Double(
        AutoCapture.journeyMaximumAttemptsPerSide),
      "Framing.zoomPlanningInsetFraction": Double(Framing.zoomPlanningInsetFraction),
      "Framing.minimumLinearFillBeforeZoom": Double(Framing.minimumLinearFillBeforeZoom),
      "Framing.maximumLinearFillBeforeZoom": Double(Framing.maximumLinearFillBeforeZoom),
      "Framing.targetLinearFill": Double(Framing.targetLinearFill),
      "Framing.maximumZoomStepFactor": Double(Framing.maximumZoomStepFactor),
      "Framing.minimumZoomChange": Double(Framing.minimumZoomChange),
      "Focus.targetMovementThreshold": Double(Focus.targetMovementThreshold),
      "Focus.retryIntervalSeconds": Double(Focus.retryIntervalSeconds),
      "Focus.maximumAttemptsPerTarget": Double(Focus.maximumAttemptsPerTarget),
      "Focus.maximumGuidanceAgeSeconds": Double(Focus.maximumGuidanceAgeSeconds),
      "Controls.minimumCommandIntervalSeconds": Double(Controls.minimumCommandIntervalSeconds),
      "Controls.maximumConsecutiveFailures": Double(Controls.maximumConsecutiveFailures),
      "Controls.adjustmentTimeoutSeconds": Double(Controls.adjustmentTimeoutSeconds),
      "Timing.analysisIntervalSeconds": Double(Timing.analysisIntervalSeconds),
      "Timing.maximumShutterObservationAgeMilliseconds": Double(
        Timing.maximumShutterObservationAgeMilliseconds),
      "Readability.minimumTextLines": Double(Readability.minimumTextLines),
      "Readability.minimumTextCharacters": Double(Readability.minimumTextCharacters),
      "Readability.minimumPDF417Characters": Double(Readability.minimumPDF417Characters),
      "Readability.minimumLiveTextHeight": Double(Readability.minimumLiveTextHeight),
      "Readability.minimumStillTextHeight": Double(Readability.minimumStillTextHeight),
      "Location.maximumFixAgeSeconds": Double(Location.maximumFixAgeSeconds)
    ]
  }
}
