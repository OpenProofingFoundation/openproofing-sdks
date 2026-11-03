/// Identifies the source and qualification limits of numerical processing defaults.
/// A conforming profile may be provisional; conformance does not establish measured accuracy.
public protocol CalibrationProfile: Sendable {
  static var profileIdentifier: String { get }
  static var calibrationStatus: String { get }
  static var populationDescription: String { get }
}

/// Source portrait policy v1: zero added padding, not calibrated on a population.
/// Coordinate rounding and clipping are geometric conventions, not measured accuracy.
public enum PortraitCropDefaults: CalibrationProfile {
  public static let profileIdentifier = "portrait-region-unpadded-v1"
  public static let calibrationStatus = "geometric_convention"
  public static let populationDescription = "none"
  public static let paddingFraction = 0.0
}
