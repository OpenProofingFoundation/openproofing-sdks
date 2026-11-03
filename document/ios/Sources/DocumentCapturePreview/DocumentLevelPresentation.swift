import CoreGraphics
import Foundation
import DocumentCaptureApple
import DocumentSDK

/// Advisory display state. This does not authorize a photograph or assess document presence.
public struct DocumentLevelState: Equatable, Sendable {
  public enum Tone: Equatable, Sendable { case unavailable, centered, warning, tilted }
  public let offset: CGSize?
  public let tone: Tone

  public init(offset: CGSize?, tone: Tone) {
    self.offset = offset
    self.tone = tone
  }

  public static let unavailable = Self(offset: nil, tone: .unavailable)
}

/// Gravity projection adapted from SSA's DocumentLevelPresentation and Pulse's equivalent.
/// Hosts supply their existing motion observation and clock; no sensor is created here.
/// Display geometry inherited from SSA/Pulse: ten degrees spans the advisory level,
/// with the existing 12/32 centre ring and 0.75 warning transition. These are display
/// conventions, not measured document, motion, or capture-acceptance thresholds.
/// Not calibrated on a population; inherited display geometry only.
public enum DocumentLevelPresentation: CalibrationProfile {
  public static let profileIdentifier = "advisory-level-display-geometry-v1"
  public static let calibrationStatus = "geometric_convention"
  public static let populationDescription = "none"
  private static let fullScaleRadians = Double.pi / 18
  private static let centeredRadius = 12.0 / 32.0
  private static let warningRadius = 0.75

  public static func state(
    sample: DocumentTemporalMotionSample?, uptime: Double
  ) -> DocumentLevelState {
    guard let sample, uptime.isFinite, sample.bootTimeSeconds.isFinite,
      uptime >= sample.bootTimeSeconds, uptime - sample.bootTimeSeconds <= 0.5
    else { return .unavailable }
    let gravity = sample.gravity
    guard gravity.x.isFinite, gravity.y.isFinite, gravity.z.isFinite, gravity.z < 0 else {
      return .unavailable
    }
    let horizontal = hypot(gravity.x, gravity.y)
    guard horizontal.isFinite else { return .unavailable }
    guard horizontal > 0 else { return .init(offset: .zero, tone: .centered) }
    let radius = min(1, atan2(horizontal, -gravity.z) / fullScaleRadians)
    let offset = CGSize(width: -gravity.x / horizontal * radius, height: gravity.y / horizontal * radius)
    let tone: DocumentLevelState.Tone
    if radius <= centeredRadius { tone = .centered }
    else if radius <= warningRadius { tone = .warning }
    else { tone = .tilted }
    return .init(offset: offset, tone: tone)
  }
}
