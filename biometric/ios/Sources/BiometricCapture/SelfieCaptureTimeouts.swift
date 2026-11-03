import Foundation

/// Operational deadlines only. These do not tune biometric quality or establish PAD.
public struct SelfieCaptureTimeouts: Sendable, Equatable {
  public let frameDelivery: TimeInterval
  public let analysis: TimeInterval
  public let rendering: TimeInterval

  /// Inherits the original ten-second first-frame deadline for all bounded native stages.
  /// Engineering watchdog defaults; no population calibration or biometric assurance is claimed.
  public static let operationalV1 = Self(frameDelivery: 10, analysis: 10, rendering: 10)

  public init(
    frameDelivery: TimeInterval, analysis: TimeInterval,
    rendering: TimeInterval
  ) {
    self.frameDelivery = frameDelivery
    self.analysis = analysis
    self.rendering = rendering
  }

  var isValid: Bool {
    [frameDelivery, analysis, rendering].allSatisfy { $0.isFinite && $0 > 0 }
  }
}

/// The host records its consent ceremony separately. Camera permission never implies consent.
public enum SelfieCaptureConsent: String, Sendable { case permitted, withheld }
