import Foundation

/// Selects live readability evidence only. It never replaces full-image capture,
/// quality admission, retained extraction, or document authentication.
public enum DocumentLiveContentTarget: String, Codable, Equatable, Sendable {
  case documentText
  case licensePDF417
  case passportMRZ
  case passportCardMRZ
}
