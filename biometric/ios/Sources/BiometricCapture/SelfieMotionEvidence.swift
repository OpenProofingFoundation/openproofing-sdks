import Foundation
import KenshikiMotion

/// Pulse ceremony summary shape plus the captured frame and monotonic window binding.
/// Host uptime checks establish temporal proximity, not camera or sensor authenticity.
public struct SelfieMotionEvidence: Sendable, Codable, Equatable {
  public let imageSHA256: String
  public let frameTimestampSeconds: Double
  public let windowStartTimestampSeconds: Double
  public let windowEndTimestampSeconds: Double
  public let requestedSampleRateHz: Double
  public let clockDomain: String
  public let alignment: String
  public let summary: PulseCeremonyMotionSummary
}

