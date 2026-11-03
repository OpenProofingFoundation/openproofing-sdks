import Foundation

/// Queue-confined bounded storage. No platform clock conversion or image processing.
struct DocumentTemporalBuffer {
  let configuration: DocumentTemporalConfiguration
  let sequenceID = UUID()
  var frames: [DocumentTemporalFrame] = []
  var motionSamples: [DocumentTemporalMotionSample] = []
  var issues: [String] = []
  var gaps: [DocumentTemporalGap] = []
  var omittedDiagnosticCount = 0
  var evictedFrameCount = 0
  var evictedMotionSampleCount = 0
  var issueTimes: [String: DocumentCaptureClockTimestamp] = [:]
  var lastOmittedTimestamp: DocumentCaptureClockTimestamp?
  var omittedHasUnknownTime = false
  var byteCount = 0
  var pinnedHostTime: Double?

  init(configuration: DocumentTemporalConfiguration) {
    self.configuration = configuration
    if !configuration.valid { issues = ["invalid_configuration"] }
  }

  mutating func beginCapture() {
    pinnedHostTime = 0
  }

  mutating func pin(atHostTimeSeconds time: Double) {
    guard time.isFinite else {
      recordIssue("invalid_request_host_time")
      return
    }
    pinnedHostTime = time
  }

  mutating func append(_ frame: DocumentTemporalFrame) {
    guard configuration.enabled, configuration.valid else { return }
    guard frame.valid else {
      recordIssue("invalid_frame")
      return
    }
    if let previous = frames.last {
      guard frame.metadata.sequenceNumber > previous.metadata.sequenceNumber,
        frame.metadata.timestamp.epoch == previous.metadata.timestamp.epoch,
        frame.metadata.timestamp.seconds > previous.metadata.timestamp.seconds
      else {
        recordIssue("frame_clock_discontinuity")
        return
      }
      let movedBackwards =
        frame.metadata.hostTimeSeconds.flatMap { current in
          previous.metadata.hostTimeSeconds.map { current <= $0 }
        } ?? false
      if movedBackwards {
        recordIssue("host_clock_discontinuity")
        return
      }
    }
    guard prepareForFrame(byteCount: frame.payload.count) else { return }
    frames.append(frame)
    byteCount += frame.payload.count
    trimRollingWindow()
  }

  /// Reserve while still on the owner queue, before allocating the packed copy.
  mutating func prepareForFrame(byteCount incomingBytes: Int) -> Bool {
    guard configuration.enabled, configuration.valid else { return false }
    guard incomingBytes > 0, incomingBytes <= configuration.maximumBytes else {
      recordGap(.init(reason: "frame_exceeds_byte_cap", timestamp: nil, count: 1))
      return false
    }
    trimRollingWindow()
    while needsCapacity(for: incomingBytes) {
      let removed = frames.removeFirst()
      byteCount -= removed.payload.count
      evictedFrameCount += 1
      recordGap(.init(reason: "retention_cap", timestamp: removed.metadata.timestamp, count: 1))
    }
    return true
  }

  func needsCapacity(for incomingBytes: Int) -> Bool {
    !frames.isEmpty
      && (frames.count >= configuration.maximumFrames
        || byteCount > configuration.maximumBytes - incomingBytes)
  }

  mutating func append(_ sample: DocumentTemporalMotionSample) {
    guard configuration.enabled, configuration.valid else { return }
    guard sample.isFinite else {
      recordIssue("invalid_motion_sample")
      return
    }
    if let last = motionSamples.last, sample.bootTimeSeconds <= last.bootTimeSeconds {
      recordIssue("motion_clock_discontinuity")
      return
    }
    if motionSamples.count >= configuration.maximumMotionSamples {
      motionSamples.removeFirst()
      evictedMotionSampleCount += 1
    }
    motionSamples.append(sample)
  }

  mutating func recordIssue(_ issue: String) {
    let issue = String(issue.prefix(256))
    if issues.contains(issue) {
      issueTimes[issue] = issueTimestamp(for: issue)
      return
    }
    guard issues.count + gaps.count < max(1, configuration.maximumDiagnostics) else {
      recordOmission(timestamp: nil)
      return
    }
    issues.append(issue)
    issueTimes[issue] = issueTimestamp(for: issue)
  }

  func issueTimestamp(for issue: String) -> DocumentCaptureClockTimestamp? {
    switch issue {
    case "invalid_frame", "frame_clock_discontinuity", "host_clock_discontinuity":
      return frames.last?.metadata.timestamp
    default:
      return nil
    }
  }

  mutating func recordGap(_ gap: DocumentTemporalGap) {
    guard issues.count + gaps.count < max(1, configuration.maximumDiagnostics) else {
      recordOmission(timestamp: gap.timestamp)
      return
    }
    gaps.append(
      .init(reason: String(gap.reason.prefix(256)), timestamp: gap.timestamp, count: gap.count))
  }

  mutating func recordOmission(timestamp: DocumentCaptureClockTimestamp?) {
    omittedDiagnosticCount += 1
    guard let timestamp, timestamp.isNumeric else {
      omittedHasUnknownTime = true
      return
    }
    if let prior = lastOmittedTimestamp, prior.epoch != timestamp.epoch {
      omittedHasUnknownTime = true
    }
    if lastOmittedTimestamp == nil || timestamp.seconds > (lastOmittedTimestamp?.seconds ?? 0) {
      lastOmittedTimestamp = timestamp
    }
  }

  mutating func pruneOldDiagnostics(before lower: Double, epoch: Int64) {
    gaps.removeAll { gap in
      guard let timestamp = gap.timestamp, timestamp.isNumeric, timestamp.epoch == epoch else {
        return false
      }
      return timestamp.seconds < lower
    }
    let knownTime = !omittedHasUnknownTime && lastOmittedTimestamp?.epoch == epoch
    if knownTime, let last = lastOmittedTimestamp, last.seconds < lower {
      omittedDiagnosticCount = 0
      lastOmittedTimestamp = nil
    }
  }

  mutating func trimRollingWindow() {
    guard pinnedHostTime == nil, let latest = frames.last?.metadata.hostTimeSeconds else { return }
    let start = latest - configuration.preCaptureDuration
    if let stamp = frames.last?.metadata.timestamp {
      pruneOldDiagnostics(
        before: stamp.seconds - configuration.preCaptureDuration, epoch: stamp.epoch)
    }
    // Keep one predecessor so the requested interval can be bracketed honestly.
    while frames.count > 1, let second = frames[1].metadata.hostTimeSeconds, second < start {
      byteCount -= frames.removeFirst().payload.count
    }
  }

  mutating func finish(
    binding: DocumentTemporalBinding,
    clockCorrelation: DocumentTemporalClockCorrelation?,
    termination: String
  ) -> DocumentTemporalEvidence {
    trimFinalWindow(binding: binding, correlation: clockCorrelation)
    filterDiagnostics(binding: binding)
    assessCoverage(binding: binding, correlation: clockCorrelation)
    let complete =
      issues.isEmpty && gaps.isEmpty && omittedDiagnosticCount == 0
      && termination == "completed"
    let manifest = DocumentTemporalManifest(
      schemaVersion: 1, sequenceID: sequenceID, binding: binding, configuration: configuration,
      frames: frames.map(\.metadata), motionSamples: motionSamples,
      clockCorrelation: clockCorrelation,
      status: complete ? "recorded" : "partial", termination: termination, issues: issues,
      gaps: gaps,
      omittedDiagnosticCount: omittedDiagnosticCount, evictedFrameCount: evictedFrameCount,
      evictedMotionSampleCount: evictedMotionSampleCount)
    return DocumentTemporalEvidence(manifest: manifest, frames: frames)
  }
}
