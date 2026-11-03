import CoreMedia

/// Confined to video ingress. It gates only the optional quality copy, never archive ingress.
struct DocumentAnalysisCadence {
  private var previous = CMTime.invalid

  func isDue(_ time: CMTime) -> Bool {
    guard time.isNumeric else { return false }
    guard previous.isNumeric, previous.epoch == time.epoch,
      CMTimeCompare(time, previous) >= 0
    else { return true }
    return CMTimeGetSeconds(time - previous) >= DocumentCaptureTuning.Timing.analysisIntervalSeconds
  }

  mutating func copyIfDue<Value>(_ time: CMTime, copy: () -> Value?) -> Value? {
    guard isDue(time), let value = copy() else { return nil }
    didAdmit(time)
    return value
  }

  mutating func didAdmit(_ time: CMTime) { previous = time }
  mutating func reset() { previous = .invalid }
}
