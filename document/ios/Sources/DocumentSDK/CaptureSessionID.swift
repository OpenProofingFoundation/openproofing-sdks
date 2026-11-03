import Foundation

/// An opaque identifier that binds observations produced by one capture ceremony.
public struct CaptureSessionID: Codable, Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}
