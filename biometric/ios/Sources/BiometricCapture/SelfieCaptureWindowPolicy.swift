import Foundation

/// Optional acquisition budget, not a quality, identity or PAD threshold.
/// Every retained frame independently satisfies the existing admission policy.
public struct SelfieCaptureWindowPolicy: Sendable, Equatable {
  public let maximumCandidates: Int
  public let duration: TimeInterval
  public let minimumInterval: TimeInterval

  /// Eight admitted originals over at most two seconds, sampled no faster than 5 Hz.
  public static let engineeringV1 = Self(maximumCandidates: 8, duration: 2, minimumInterval: 0.20)

  public init(maximumCandidates: Int, duration: TimeInterval, minimumInterval: TimeInterval) {
    self.maximumCandidates = maximumCandidates
    self.duration = duration
    self.minimumInterval = minimumInterval
  }

  var isValid: Bool {
    (1...12).contains(maximumCandidates) && duration.isFinite && duration > 0 && duration <= 3
      && minimumInterval.isFinite && minimumInterval > 0 && minimumInterval <= duration
  }

  struct ResourceBounds {
    let encodedBytes: Int
    let pixels: Int
  }
  static let resourceBounds = ResourceBounds(encodedBytes: 67_108_864, pixels: 32_000_000)
}
