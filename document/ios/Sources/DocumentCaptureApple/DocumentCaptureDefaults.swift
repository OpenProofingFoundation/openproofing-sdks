import DocumentSDK

/// Frozen capture-stack defaults extracted 2026-10-23; no population calibration.
/// EXIF tolerance is a representation round-trip bound; preview and retention values
/// are engineering choices, not measured accuracy or credential-authenticity limits.
public enum DocumentCaptureDefaults: CalibrationProfile {
  public static let profileIdentifier = "capture-representation-2026-10-23-v1"
  public static let calibrationStatus = "provisional_engineering_heuristics"
  public static let populationDescription = "none"
  static let coordinateTolerance = 1e-6
  static let guideCoordinateTolerance = 0.000_5
  public static let previewFrameIntervalSeconds = 1.0
  public static let preCaptureDuration = 1.0
  public static let postCaptureDuration = 0.5
  public static let guideHorizontalInset = 16.0
  public static let guideVerticalInset = 16.0
  public static let guideMaximumWidth = 520.0
  static let resizeThreshold: Int32 = 300
  static let areaScaleMinFactor = 0.1
  static let analysisMaximumDimension = 1_200.0
}
