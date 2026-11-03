import Foundation
import KenshikiMotion

/// What the gate accepted, bound to the frame whose pixels are retained.
///
/// This exists because the gate it replaces emitted the string `"arkit tracked=N blink=true"`
/// with `blink=true` hardcoded, and the host rendered that string to the holder verbatim. A
/// receipt that cannot say "the eyes were closed" is not evidence.
public struct SelfieAdmissionReceipt: Sendable, Codable, Equatable {
  public enum Trigger: String, Sendable, Codable {
    case automatic
    case manual
  }

  public var effectivePolicy: SelfieAdmissionPolicy? = nil
  public var frameEvidence: SelfieFrameEvidence? = nil
  /// Absent on legacy expression-only captures; never inferred from a completed blink.
  public var depthEvidence: SelfieDepthEvidence? = nil
  public var motionEvidence: SelfieMotionEvidence? = nil
  public var motionStatus: PulseMotionPermission.Status = .notRequested
  // Preserve the original receipt representation used by archived source digests.
  var motionStatusWasRecorded = true
  public let policyVersion: String
  public var trigger: Trigger
  /// ARKit frame timestamp of the admitted frame. The retained pixels must come from this
  /// exact frame; the gate refuses any other.
  public let frameTimestamp: TimeInterval
  public let anchorID: UUID
  public let consecutiveTrackedFrames: Int
  /// Blink completion: the eyes were seen open, then closed, then open again.
  public let blinkCompletedAt: TimeInterval
  public var blinkAge: TimeInterval
  public let leftEyeClosed: Float
  public let rightEyeClosed: Float
  /// Always true on an admitted receipt; recorded so the value is explicit, not implied.
  public let eyesOpen: Bool
  public var steadyHoldDuration: TimeInterval
  /// Measured at admission when available. `nil` means no measurement was supplied.
  public let captureQuality: Float?
  /// Whether `captureQuality` acted as a gate. False while no threshold has been selected.
  public var captureQualityEnforced: Bool
  /// Whether the projected face sat inside the drawn guide. `nil` means not evaluated.
  public let insideGuide: Bool?
  /// Whether `insideGuide` acted as a gate.
  public var guideContainmentEnforced: Bool

}

extension SelfieAdmissionReceipt {
  private enum CodingKeys: String, CodingKey {
    case effectivePolicy, frameEvidence, depthEvidence, motionEvidence
    case motionStatus, policyVersion, trigger, frameTimestamp
    case anchorID, consecutiveTrackedFrames, blinkCompletedAt, blinkAge
    case leftEyeClosed, rightEyeClosed, eyesOpen, steadyHoldDuration
    case captureQuality, captureQualityEnforced, insideGuide, guideContainmentEnforced
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    motionStatusWasRecorded = values.contains(.motionStatus)
    effectivePolicy = try values.decodeIfPresent(SelfieAdmissionPolicy.self, forKey: .effectivePolicy)
    frameEvidence = try values.decodeIfPresent(SelfieFrameEvidence.self, forKey: .frameEvidence)
    depthEvidence = try values.decodeIfPresent(SelfieDepthEvidence.self, forKey: .depthEvidence)
    motionEvidence = try values.decodeIfPresent(SelfieMotionEvidence.self, forKey: .motionEvidence)
    motionStatus = motionStatusWasRecorded
      ? try values.decode(PulseMotionPermission.Status.self, forKey: .motionStatus) : .notRequested
    policyVersion = try values.decode(String.self, forKey: .policyVersion)
    trigger = try values.decode(Trigger.self, forKey: .trigger)
    frameTimestamp = try values.decode(TimeInterval.self, forKey: .frameTimestamp)
    anchorID = try values.decode(UUID.self, forKey: .anchorID)
    consecutiveTrackedFrames = try values.decode(Int.self, forKey: .consecutiveTrackedFrames)
    blinkCompletedAt = try values.decode(TimeInterval.self, forKey: .blinkCompletedAt)
    blinkAge = try values.decode(TimeInterval.self, forKey: .blinkAge)
    leftEyeClosed = try values.decode(Float.self, forKey: .leftEyeClosed)
    rightEyeClosed = try values.decode(Float.self, forKey: .rightEyeClosed)
    eyesOpen = try values.decode(Bool.self, forKey: .eyesOpen)
    steadyHoldDuration = try values.decode(TimeInterval.self, forKey: .steadyHoldDuration)
    captureQuality = try values.decodeIfPresent(Float.self, forKey: .captureQuality)
    captureQualityEnforced = try values.decode(Bool.self, forKey: .captureQualityEnforced)
    insideGuide = try values.decodeIfPresent(Bool.self, forKey: .insideGuide)
    guideContainmentEnforced = try values.decode(Bool.self, forKey: .guideContainmentEnforced)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(effectivePolicy, forKey: .effectivePolicy)
    try values.encodeIfPresent(frameEvidence, forKey: .frameEvidence)
    try values.encodeIfPresent(depthEvidence, forKey: .depthEvidence)
    try values.encodeIfPresent(motionEvidence, forKey: .motionEvidence)
    if motionStatusWasRecorded || motionStatus != .notRequested || motionEvidence != nil {
      try values.encode(motionStatus, forKey: .motionStatus)
    }
    try values.encode(policyVersion, forKey: .policyVersion)
    try values.encode(trigger, forKey: .trigger)
    try values.encode(frameTimestamp, forKey: .frameTimestamp)
    try values.encode(anchorID, forKey: .anchorID)
    try values.encode(consecutiveTrackedFrames, forKey: .consecutiveTrackedFrames)
    try values.encode(blinkCompletedAt, forKey: .blinkCompletedAt)
    try values.encode(blinkAge, forKey: .blinkAge)
    try values.encode(leftEyeClosed, forKey: .leftEyeClosed)
    try values.encode(rightEyeClosed, forKey: .rightEyeClosed)
    try values.encode(eyesOpen, forKey: .eyesOpen)
    try values.encode(steadyHoldDuration, forKey: .steadyHoldDuration)
    try values.encodeIfPresent(captureQuality, forKey: .captureQuality)
    try values.encode(captureQualityEnforced, forKey: .captureQualityEnforced)
    try values.encodeIfPresent(insideGuide, forKey: .insideGuide)
    try values.encode(guideContainmentEnforced, forKey: .guideContainmentEnforced)
  }

  public var admissionValid: Bool {
    let policy = effectivePolicy ?? SelfieAdmissionPolicy()
    return policy.configurationValid && frameTimestamp.isFinite && blinkCompletedAt.isFinite
      && blinkAge.isFinite
      && frameTimestamp >= blinkCompletedAt && policy.blinkFresh(age: blinkAge) && eyesOpen
      && policy.blendShapesValid(left: leftEyeClosed, right: rightEyeClosed)
      && policy.eyesOpen(left: leftEyeClosed, right: rightEyeClosed)
      && consecutiveTrackedFrames >= policy.requiredTrackedFrames && steadyHoldDuration.isFinite
      && steadyHoldDuration >= 0 && policyVersion == SelfieAdmissionPolicy.version
      && (trigger != .automatic || steadyHoldDuration >= policy.steadyHold)
      && captureQualityEnforced == (policy.minimumCaptureQuality != nil)
      && guideContainmentEnforced == policy.requiresGuideContainment
      && (frameEvidence.map {
        $0.pixelWidth > 0 && $0.pixelHeight > 0
          && [1, 3, 6, 8].contains($0.orientation) && $0.analysisDuration.isFinite
          && $0.analysisDuration >= 0 && $0.frameAgeAtAdmission.isFinite
          && $0.frameAgeAtAdmission >= 0 && $0.frameAgeAtAdmission <= policy.maximumFrameAge
      } ?? true)
      && (!captureQualityEnforced
        || captureQuality.map {
          $0.isFinite && (0...1).contains($0) && $0 >= (policy.minimumCaptureQuality ?? 0)
        } == true)
      && (!guideContainmentEnforced || insideGuide == true)
  }
}

public struct SelfieFrameEvidence: Sendable, Codable, Equatable {
  public let sessionID: UUID
  public let sequence: UInt64
  public let guideRevision: UInt64
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let orientation: UInt32
  public let qualityRevision: Int
  public let analysisDuration: TimeInterval
  public var frameAgeAtAdmission: TimeInterval
}
