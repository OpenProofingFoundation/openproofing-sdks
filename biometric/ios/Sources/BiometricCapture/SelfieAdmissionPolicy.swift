import Foundation

/// Named, versioned selfie-admission parameters.
///
/// The frame-admission values are CARRIED OVER unchanged from the gate being replaced, so this
/// is not a re-tuning: `requiredTrackedFrames` 10, `maximumFrameAge` 0.25 s, `blinkFreshness`
/// 5 s, `eyeClosedThreshold` 0.5, `steadyHold` 1 s.
///
/// The two measurement terms are DECLARED BUT UNENFORCED by default, and that is deliberate.
/// Apple documents `DetectFaceCaptureQualityRequest` as producing 0...1 where higher is "better
/// lit, sharper, and more centrally positioned" — one aggregate over three different properties,
/// with no absolute threshold published. A cutoff cannot be read off the source; it has to be
/// selected from retained device measurements. Until it is, the score is recorded on every
/// receipt and gates nothing. The native capture view separately enables guide containment
/// by default and requires a measurable quality result.
public struct SelfieAdmissionPolicy: Sendable, Equatable, Codable {
  /// Stamped onto every receipt so a retained admission can be read back against the rules
  /// that produced it. Bump this whenever a value below changes meaning.
  public static let version = "selfie-admission-v1"

  /// Consecutive accepted tracked frames before the geometry counts as steadily held.
  public let requiredTrackedFrames: Int
  /// Maximum age of the frame being admitted, and the maximum gap between accepted frames.
  public let maximumFrameAge: TimeInterval
  /// How long a completed blink stays fresh.
  public let blinkFreshness: TimeInterval
  /// Per-eye ARKit blink blend-shape value at or above which that eye counts as closed.
  public let eyeClosedThreshold: Float
  /// How long readiness must hold before automatic capture fires.
  public let steadyHold: TimeInterval
  /// `nil` means NOT ENFORCED — no invented default. Set only from device measurements.
  public let minimumCaptureQuality: Float?
  /// `false` means containment is recorded but not required. Native capture enables it.
  public let requiresGuideContainment: Bool

  /// Existing engineering defaults, preserved from the donor gate; not population calibration.
  public static let engineeringV1 = Self(
    requiredTrackedFrames: 10, maximumFrameAge: 0.25, blinkFreshness: 5,
    eyeClosedThreshold: 0.5, steadyHold: 1,
    minimumCaptureQuality: nil, requiresGuideContainment: false)

  public init(
    requiredTrackedFrames: Int = Self.engineeringV1.requiredTrackedFrames,
    maximumFrameAge: TimeInterval = Self.engineeringV1.maximumFrameAge,
    blinkFreshness: TimeInterval = Self.engineeringV1.blinkFreshness,
    eyeClosedThreshold: Float = Self.engineeringV1.eyeClosedThreshold,
    steadyHold: TimeInterval = Self.engineeringV1.steadyHold,
    minimumCaptureQuality: Float? = nil,
    requiresGuideContainment: Bool = false
  ) {
    self.requiredTrackedFrames = requiredTrackedFrames
    self.maximumFrameAge = maximumFrameAge
    self.blinkFreshness = blinkFreshness
    self.eyeClosedThreshold = eyeClosedThreshold
    self.steadyHold = steadyHold
    self.minimumCaptureQuality = minimumCaptureQuality
    self.requiresGuideContainment = requiresGuideContainment
  }

  /// Both eyes open. Note this is strict: a value exactly at the threshold is neither open
  /// nor closed, and such a frame is refused rather than admitted.
  public func eyesOpen(left: Float, right: Float) -> Bool {
    left < eyeClosedThreshold && right < eyeClosedThreshold
  }

  /// Both eyes closed — the closing half of a blink, not a squint on one side.
  public func eyesClosed(left: Float, right: Float) -> Bool {
    left > eyeClosedThreshold && right > eyeClosedThreshold
  }

  public func trackingSteady(consecutiveTrackedFrames: Int) -> Bool {
    consecutiveTrackedFrames >= requiredTrackedFrames
  }

  public func blinkFresh(age: TimeInterval?) -> Bool {
    guard let age else { return false }
    return age >= 0 && age < blinkFreshness
  }

  /// Whether a blend-shape pair is usable at all.
  public func blendShapesValid(left: Float, right: Float) -> Bool {
    left.isFinite && right.isFinite && (0...1).contains(left) && (0...1).contains(right)
  }
}

extension SelfieAdmissionPolicy {
  public var configurationValid: Bool {
    requiredTrackedFrames > 0 && maximumFrameAge.isFinite && maximumFrameAge > 0
      && blinkFreshness.isFinite && blinkFreshness > 0
      && eyeClosedThreshold.isFinite && eyeClosedThreshold > 0 && eyeClosedThreshold < 1
      && steadyHold.isFinite && steadyHold >= 0
      && (minimumCaptureQuality.map { $0.isFinite && (0...1).contains($0) } ?? true)
  }
}
