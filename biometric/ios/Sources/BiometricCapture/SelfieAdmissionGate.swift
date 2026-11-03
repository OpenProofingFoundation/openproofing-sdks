import Foundation

/// The selfie-admission state machine: pure, camera-free and unit-testable.
///
/// Everything the gate it replaces got right is kept deliberately, and each of these is covered
/// by a test: exact frame identity between the admitted decision and the retained pixels;
/// monotonic timestamps; a retained `lastTimestamp` across resets so a duplicate or reordered
/// frame cannot seed a new sequence; anchor changes, tracking gaps and multiple faces reset the
/// sequence; and no admission at all without a blink.
///
/// What is new is the blink phase requiring the eyes to REOPEN, the close being recorded once
/// per blink rather than on every closed frame, and the admitted frame having to show open eyes.
/// The gate being replaced failed all three: eyes held shut refreshed the freshness window
/// indefinitely and were admitted one second later.
public struct SelfieAdmissionGate: Sendable {
  /// The accepted frame's facts, kept so admission and the receipt describe the same frame.
  private struct Accepted: Sendable {
    let timestamp: TimeInterval
    let anchorID: UUID
    let leftEyeClosed: Float
    let rightEyeClosed: Float
    let eyesOpen: Bool
    let captureQuality: Float?
    let insideGuide: Bool?
  }

  public let policy: SelfieAdmissionPolicy
  private var isRunning = false
  private var startedAt: TimeInterval = .infinity
  /// Retained across resets on purpose, so a duplicate or out-of-order frame cannot restart
  /// the sequence. This is the one piece of state `reset()` must not clear.
  private var lastTimestamp: TimeInterval?
  private var anchorID: UUID?
  private var blinkPhase: BlinkPhase = .waitingForOpenEyes
  private var blinkCompletedAt: TimeInterval?
  private var blinkClosedAt: TimeInterval?
  private var readySince: TimeInterval?
  private var accepted: Accepted?
  public private(set) var consecutiveTrackedFrames = 0

  public init(policy: SelfieAdmissionPolicy = SelfieAdmissionPolicy()) {
    self.policy = policy
  }

  public var trackingObserved: Bool {
    policy.trackingSteady(consecutiveTrackedFrames: consecutiveTrackedFrames)
  }

  public var currentBlinkPhase: BlinkPhase { blinkPhase }

  /// Begin a sequence. `timestamp` is the newest frame already seen, so a frame captured
  /// before the gate started cannot be admitted.
  public mutating func start(at timestamp: TimeInterval) {
    let retained = lastTimestamp
    self = Self(policy: policy)
    lastTimestamp = retained
    isRunning = policy.configurationValid
    startedAt = timestamp.isFinite ? timestamp : .infinity
  }

  public mutating func resetHold() { readySince = nil }

  public mutating func stop() {
    let retained = lastTimestamp
    self = Self(policy: policy)
    lastTimestamp = retained
  }

  /// Feed one frame. Returns the presentation state for that frame.
  @discardableResult
  public mutating func observe(_ observation: Observation, now: TimeInterval) -> Readiness {
    guard isRunning else { return readiness(.sessionNotRunning) }
    if let rejection = reject(observation, now: now) {
      resetSequence()
      return readiness(rejection)
    }
    guard let observedAnchor = observation.anchorID,
      let left = observation.leftEyeClosed, let right = observation.rightEyeClosed
    else {
      resetSequence()
      return readiness(.blendShapesUnavailable)
    }

    // A different face, or a gap longer than one frame's grace, is a new sequence.
    let gapped = lastTimestamp.map { observation.timestamp - $0 > policy.maximumFrameAge }
    if anchorID != observedAnchor || gapped == true {
      resetSequence()
    }
    anchorID = observedAnchor
    lastTimestamp = observation.timestamp
    consecutiveTrackedFrames += 1

    let eyesOpen = policy.eyesOpen(left: left, right: right)
    accepted = Accepted(
      timestamp: observation.timestamp, anchorID: observedAnchor,
      leftEyeClosed: left, rightEyeClosed: right, eyesOpen: eyesOpen,
      captureQuality: observation.captureQuality, insideGuide: observation.insideGuide)

    // The blink only advances once the face is steadily held. ARKit's blend shapes spike
    // as tracking locks on, and a single closed-eyes frame there once read as a blink.
    guard trackingObserved else {
      readySince = nil
      return readiness(.trackingNotSteady)
    }
    advanceBlink(left: left, right: right, eyesOpen: eyesOpen, timestamp: observation.timestamp)

    let decision = evaluate(frameTimestamp: observation.timestamp, now: now, trigger: .automatic)
    if case .refuse(let reason) = decision, reason != .steadyHoldIncomplete {
      readySince = nil
      return readiness(reason)
    }
    readySince = readySince ?? observation.timestamp
    if case .refuse(let reason) = decision { return readiness(reason) }
    return readiness(nil)
  }

  /// Admit the frame the caller is about to retain. `frameTimestamp` must be the frame the
  /// gate last accepted, so the pixels and the receipt cannot diverge.
  public mutating func admit(
    frameTimestamp: TimeInterval, now: TimeInterval, trigger: SelfieAdmissionReceipt.Trigger
  ) -> Decision {
    let decision = evaluate(frameTimestamp: frameTimestamp, now: now, trigger: trigger)
    return decision
  }

  /// Add measurements to the accepted frame in this value. Callers analyzing asynchronously
  /// must use the snapshot belonging to their selected frame.
  public mutating func measure(quality: Float?, insideGuide: Bool?) {
    guard let old = accepted else { return }
    accepted = Accepted(
      timestamp: old.timestamp, anchorID: old.anchorID,
      leftEyeClosed: old.leftEyeClosed, rightEyeClosed: old.rightEyeClosed,
      eyesOpen: old.eyesOpen, captureQuality: quality, insideGuide: insideGuide)
  }

  /// Refusal reasons that do not depend on a held sequence.
  private func reject(_ observation: Observation, now: TimeInterval) -> Refusal? {
    if observation.faceCount > 1 { return .multipleFacesObserved }
    if observation.anchorID == nil || observation.faceCount == 0 { return .noFaceObserved }
    if !observation.trackingObserved { return .faceNotTracked }
    guard let left = observation.leftEyeClosed, let right = observation.rightEyeClosed,
      policy.blendShapesValid(left: left, right: right)
    else { return .blendShapesUnavailable }
    if !fresh(observation.timestamp, now: now) { return .frameStale }
    if observation.timestamp < startedAt { return .frameStale }
    if lastTimestamp.map({ observation.timestamp <= $0 }) == true { return .frameNotCurrent }
    return nil
  }

  private func evaluate(
    frameTimestamp: TimeInterval, now: TimeInterval, trigger: SelfieAdmissionReceipt.Trigger
  ) -> Decision {
    if let refusal = sequenceRefusal(frameTimestamp: frameTimestamp, now: now) {
      return .refuse(refusal)
    }
    guard let accepted else { return .refuse(.frameNotCurrent) }
    if let refusal = expressionRefusal(accepted: accepted, now: now) {
      return .refuse(refusal)
    }
    if let refusal = measurementRefusal(accepted: accepted) { return .refuse(refusal) }
    guard let blinkCompletedAt else { return .refuse(.blinkNotObserved) }
    let hold = readySince.map { frameTimestamp - $0 } ?? 0
    if trigger == .automatic && hold < policy.steadyHold {
      return .refuse(.steadyHoldIncomplete)
    }
    var receipt = SelfieAdmissionReceipt(
      policyVersion: SelfieAdmissionPolicy.version, trigger: trigger,
      frameTimestamp: frameTimestamp, anchorID: accepted.anchorID,
      consecutiveTrackedFrames: consecutiveTrackedFrames,
      blinkCompletedAt: blinkCompletedAt, blinkAge: now - blinkCompletedAt,
      leftEyeClosed: accepted.leftEyeClosed, rightEyeClosed: accepted.rightEyeClosed,
      eyesOpen: accepted.eyesOpen, steadyHoldDuration: hold,
      captureQuality: accepted.captureQuality,
      captureQualityEnforced: policy.minimumCaptureQuality != nil,
      insideGuide: accepted.insideGuide,
      guideContainmentEnforced: policy.requiresGuideContainment)
    receipt.effectivePolicy = policy
    return .admit(receipt)
  }

  /// Is this the frame the gate accepted, is it still fresh, and is the face steadily held?
  private func sequenceRefusal(frameTimestamp: TimeInterval, now: TimeInterval) -> Refusal? {
    guard isRunning else { return .sessionNotRunning }
    guard let accepted, frameTimestamp == accepted.timestamp, frameTimestamp == lastTimestamp
    else { return .frameNotCurrent }
    guard fresh(frameTimestamp, now: now) else { return .frameStale }
    guard trackingObserved else { return .trackingNotSteady }
    return nil
  }

  /// Eye state is checked BEFORE blink completion on purpose. Both can fail at once when the
  /// holder is holding their eyes shut, and `Refusal` selects the one instruction the host
  /// shows: "open your eyes" is actionable, "you have not blinked" is confusing mid-blink.
  /// This decides which true statement to surface, not which conditions gate — all still do.
  private func expressionRefusal(accepted: Accepted, now: TimeInterval) -> Refusal? {
    guard accepted.eyesOpen else { return .eyesClosed }
    guard blinkPhase == .reopened, let blinkCompletedAt else { return .blinkNotObserved }
    guard policy.blinkFresh(age: now - blinkCompletedAt) else { return .blinkExpired }
    return nil
  }

  /// Measurement terms. Each gates only once its policy value has been set from device data.
  private func measurementRefusal(accepted: Accepted) -> Refusal? {
    if let minimum = policy.minimumCaptureQuality {
      guard let quality = accepted.captureQuality, quality.isFinite else {
        return .captureQualityUnavailable
      }
      guard quality >= minimum else { return .captureQualityBelowMinimum }
    }
    if policy.requiresGuideContainment, accepted.insideGuide != true { return .outsideGuide }
    return nil
  }

  /// open -> closed -> open. The close is recorded ONCE, on the transition into
  /// `sawClosedEyes`; a held closure therefore cannot keep rewriting `blinkCompletedAt` and
  /// hold the freshness window open forever. Reopening completes the blink, and a later
  /// open frame leaves the phase at `reopened` so a genuine second blink can still re-arm.
  private mutating func advanceBlink(
    left: Float, right: Float, eyesOpen: Bool, timestamp: TimeInterval
  ) {
    let closed = policy.eyesClosed(left: left, right: right)
    switch blinkPhase {
    case .waitingForOpenEyes:
      if eyesOpen { blinkPhase = .sawOpenEyes }
    case .sawOpenEyes:
      if closed {
        blinkPhase = .sawClosedEyes
        blinkClosedAt = timestamp
      }
    case .sawClosedEyes:
      if eyesOpen {
        if let closed = blinkClosedAt, timestamp - closed < policy.blinkFreshness {
          blinkPhase = .reopened
          blinkCompletedAt = timestamp
        } else {
          blinkPhase = .sawOpenEyes
          blinkCompletedAt = nil
        }
      }
    case .reopened:
      // A second deliberate blink refreshes the evidence.
      if closed {
        blinkPhase = .sawClosedEyes
        blinkClosedAt = timestamp
      }
    }
  }

  private mutating func resetSequence() {
    anchorID = nil
    consecutiveTrackedFrames = 0
    blinkPhase = .waitingForOpenEyes
    blinkCompletedAt = nil
    blinkClosedAt = nil
    readySince = nil
    accepted = nil
    // `lastTimestamp` is deliberately retained.
  }

  private func fresh(_ timestamp: TimeInterval, now: TimeInterval) -> Bool {
    timestamp.isFinite && now.isFinite && now >= timestamp
      && now - timestamp <= policy.maximumFrameAge
  }

  private func readiness(_ reason: Refusal?) -> Readiness {
    Readiness(
      trackingObserved: trackingObserved, captureReady: reason == nil, blinkPhase: blinkPhase,
      refusal: reason)
  }
}

// Nested vocabulary, held in an extension so the state machine's own body stays small.
extension SelfieAdmissionGate {
  public enum BlinkPhase: String, Sendable, Codable {
    case waitingForOpenEyes
    case sawOpenEyes
    case sawClosedEyes
    case reopened
  }

  /// Why a frame was refused, in evaluation order. The first failing condition is reported so
  /// a host can select exactly one instruction for the holder.
  public enum Refusal: String, Sendable, Codable, Equatable {
    case sessionNotRunning
    case captureInProgress
    case noFaceObserved
    case multipleFacesObserved
    case faceNotTracked
    case blendShapesUnavailable
    case frameNotCurrent
    case frameStale
    case trackingNotSteady
    case blinkNotObserved
    case blinkExpired
    case eyesClosed
    case steadyHoldIncomplete
    case captureQualityUnavailable
    case captureQualityBelowMinimum
    case outsideGuide
    case depthUnavailable
    case depthStale
    case depthInsufficient
    case depthFlat
  }

  public enum Decision: Sendable, Equatable {
    case admit(SelfieAdmissionReceipt)
    case refuse(Refusal)
  }

  /// One frame's facts. The camera controller builds this; it owns no policy.
  public struct Observation: Sendable {
    public let timestamp: TimeInterval
    public let anchorID: UUID?
    /// Number of face anchors in the frame. More than one is ambiguous and resets.
    public let faceCount: Int
    public let trackingObserved: Bool
    public let leftEyeClosed: Float?
    public let rightEyeClosed: Float?
    /// Optional measurement supplied by the host analyzer, if any ran for this frame.
    public let captureQuality: Float?
    /// Whether the projected face centre sat inside the drawn guide, when computable.
    public let insideGuide: Bool?

    /// Analyzer measurements for this frame; unavailable values remain absent.
    public struct Measurements: Sendable {
      public let captureQuality: Float?
      public let insideGuide: Bool?

      public init(captureQuality: Float? = nil, insideGuide: Bool? = nil) {
        self.captureQuality = captureQuality
        self.insideGuide = insideGuide
      }
    }

    public init(
      timestamp: TimeInterval,
      anchorID: UUID?,
      faceCount: Int,
      trackingObserved: Bool,
      leftEyeClosed: Float?,
      rightEyeClosed: Float?,
      measurements: Measurements = Measurements()
    ) {
      self.timestamp = timestamp
      self.anchorID = anchorID
      self.faceCount = faceCount
      self.trackingObserved = trackingObserved
      self.leftEyeClosed = leftEyeClosed
      self.rightEyeClosed = rightEyeClosed
      self.captureQuality = measurements.captureQuality
      self.insideGuide = measurements.insideGuide
    }
  }

  /// Immutable presentation state for the host. SwiftUI renders this and emits intents; it
  /// does not recompute any of it.
  public struct Readiness: Sendable, Equatable {
    public let trackingObserved: Bool
    public let captureReady: Bool
    public let blinkPhase: BlinkPhase
    /// Present whenever `captureReady` is false.
    public let refusal: Refusal?
    public init(trackingObserved: Bool, captureReady: Bool, blinkPhase: BlinkPhase, refusal: Refusal?) {
      self.trackingObserved = trackingObserved
      self.captureReady = captureReady
      self.blinkPhase = blinkPhase
      self.refusal = refusal
    }
  }
}
