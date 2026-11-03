import DocumentSDK

/// No population calibration: byte reservation from the imported September 2026 journal.
/// This is an engineering capacity profile, not evidence of capture or identity accuracy.
enum CaptureJournalEngineeringDefaults: CalibrationProfile {
  static let profileIdentifier = "capture-journal-engineering-2026-09-v1"
  static let calibrationStatus = "provisional_engineering_capacity"
  static let populationDescription = "none"
  static let controlReserveBytes = 65_536
}
