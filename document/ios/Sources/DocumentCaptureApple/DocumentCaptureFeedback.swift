import Foundation

/// Presentation facts only. Stored means original custody succeeded, not that
/// the document is authentic or its extracted content is usable.
public enum DocumentCaptureFeedback: String, Sendable {
  case seeking
  case ready
  case capturing
  case stored
  case accepted
  case failed
}
