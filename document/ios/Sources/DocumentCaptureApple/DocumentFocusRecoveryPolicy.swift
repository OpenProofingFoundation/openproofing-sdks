import Foundation

/// Focus guidance may tolerate analysis latency; shutter admission keeps its separate shutter-age limit.
struct DocumentFocusRecoveryPolicy {
  private typealias Tuning = DocumentCaptureTuning.Focus
  static func permitsControl(observedAt: Date, now: Date) -> Bool {
    (0...Tuning.maximumGuidanceAgeSeconds).contains(now.timeIntervalSince(observedAt))
  }

  static func needsFocus(
    previous: CGPoint?, target: CGPoint, sharpness: Double, sinceLastRequest: TimeInterval,
    tuning: DocumentCaptureTuningOverrides = .init()
  ) -> Bool {
    guard let previous else { return true }
    if hypot(previous.x - target.x, previous.y - target.y) > Tuning.targetMovementThreshold {
      return true
    }
    return sharpness.isFinite && sharpness < tuning.minimumSharpness
      && sinceLastRequest >= Tuning.retryIntervalSeconds
  }
}
