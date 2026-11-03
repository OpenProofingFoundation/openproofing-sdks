import Foundation

/// CalibrationProfile: inherited engineering defaults from capture-stack 2026-09-17.
/// These preserve the existing image preparation behavior; no population calibration is claimed.
public struct CaptureProcessingCalibration: Sendable, Codable, Equatable {
  public let identifier: String
  public let status: String
  public let portraitPaddingFraction: Double

  public init(identifier: String, status: String, portraitPaddingFraction: Double) throws {
    guard !identifier.isEmpty, !status.isEmpty, portraitPaddingFraction.isFinite,
      (0...1).contains(portraitPaddingFraction)
    else { throw CaptureIntegrityError.integrityVerificationFailed }
    self.identifier = identifier
    self.status = status
    self.portraitPaddingFraction = portraitPaddingFraction
  }

  public static let source20260917 = Self()
  private init() {
    identifier = "capture_processing_2026_09_v1"
    status = "provisional_engineering_heuristics"
    portraitPaddingFraction = 0.2
  }
}
