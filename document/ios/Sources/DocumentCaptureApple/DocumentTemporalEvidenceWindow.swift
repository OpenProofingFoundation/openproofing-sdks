import Foundation

extension DocumentTemporalBuffer {
  mutating func trimFinalWindow(
    binding: DocumentTemporalBinding, correlation: DocumentTemporalClockCorrelation?
  ) {
    guard let still = binding.stillHostTimeSeconds, still.isFinite else { return }
    let lower = still - configuration.preCaptureDuration
    let upper = still + configuration.postCaptureDuration
    if frames.allSatisfy({ $0.metadata.hostTimeSeconds != nil }) {
      let first = frames.lastIndex { ($0.metadata.hostTimeSeconds ?? .infinity) <= lower } ?? 0
      let last =
        frames.firstIndex { ($0.metadata.hostTimeSeconds ?? -.infinity) >= upper }
        ?? frames.indices.last
      if let last, first <= last { frames = Array(frames[first...last]) }
      byteCount = frames.reduce(0) { $0 + $1.payload.count }
    }
    guard let correlation, correlation.hostBeforeSeconds.isFinite,
      correlation.hostAfterSeconds.isFinite, correlation.bootTimeSeconds.isFinite,
      correlation.hostAfterSeconds >= correlation.hostBeforeSeconds
    else { return }
    let offset =
      (correlation.hostBeforeSeconds + correlation.hostAfterSeconds) / 2
      - correlation.bootTimeSeconds
    let error = (correlation.hostAfterSeconds - correlation.hostBeforeSeconds) / 2
    let first = motionSamples.lastIndex { $0.bootTimeSeconds + offset + error <= lower } ?? 0
    let last =
      motionSamples.firstIndex { $0.bootTimeSeconds + offset - error >= upper }
      ?? motionSamples.indices.last
    if let last, first <= last { motionSamples = Array(motionSamples[first...last]) }
  }

  mutating func filterDiagnostics(binding: DocumentTemporalBinding) {
    guard binding.stillTimestamp.isNumeric else { return }
    let lower = binding.stillTimestamp.seconds - configuration.preCaptureDuration
    pruneOldDiagnostics(before: lower, epoch: binding.stillTimestamp.epoch)
    let upper = binding.stillTimestamp.seconds + configuration.postCaptureDuration
    func relevant(_ timestamp: DocumentCaptureClockTimestamp?) -> Bool {
      guard let timestamp, timestamp.isNumeric,
        timestamp.epoch == binding.stillTimestamp.epoch
      else { return true }
      return timestamp.seconds >= lower && timestamp.seconds <= upper
    }
    gaps = gaps.filter { relevant($0.timestamp) }
    issues = issues.filter { relevant(issueTimes[$0]) }
  }

  mutating func assessCoverage(
    binding: DocumentTemporalBinding, correlation: DocumentTemporalClockCorrelation?
  ) {
    guard binding.stillTimestamp.isNumeric,
      frames.allSatisfy({ $0.metadata.timestamp.epoch == binding.stillTimestamp.epoch })
    else {
      recordIssue("still_clock_discontinuity")
      return
    }
    guard let still = binding.stillHostTimeSeconds, still.isFinite else {
      recordIssue("still_host_time_unavailable")
      return
    }
    guard let first = frames.first?.metadata.hostTimeSeconds,
      let last = frames.last?.metadata.hostTimeSeconds
    else {
      recordIssue("frame_host_time_unavailable")
      return
    }
    if first > still - configuration.preCaptureDuration {
      recordIssue("pre_capture_window_incomplete")
    }
    if last < still + configuration.postCaptureDuration {
      recordIssue("post_capture_window_incomplete")
    }
    if frames.contains(where: { $0.metadata.hostTimeSeconds == nil }) {
      recordIssue("frame_host_time_unavailable")
    }
    guard let correlation, correlation.hostBeforeSeconds.isFinite,
      correlation.hostAfterSeconds.isFinite, correlation.bootTimeSeconds.isFinite,
      correlation.hostAfterSeconds >= correlation.hostBeforeSeconds
    else {
      recordIssue("motion_clock_correlation_unavailable")
      return
    }
    let offset =
      (correlation.hostBeforeSeconds + correlation.hostAfterSeconds) / 2
      - correlation.bootTimeSeconds
    let error = (correlation.hostAfterSeconds - correlation.hostBeforeSeconds) / 2
    guard let firstMotion = motionSamples.first, let lastMotion = motionSamples.last else {
      recordIssue("motion_unavailable")
      return
    }
    let missesStart =
      firstMotion.bootTimeSeconds + offset + error > still - configuration.preCaptureDuration
    let missesEnd =
      lastMotion.bootTimeSeconds + offset - error < still + configuration.postCaptureDuration
    if missesStart || missesEnd {
      recordIssue("motion_window_incomplete")
    }
  }
}
