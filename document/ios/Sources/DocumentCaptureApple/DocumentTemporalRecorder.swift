import AVFoundation
import Foundation

/// The lock owns all recording state. Native buffers are copied synchronously
/// on video ingress outside the state lock, never retained or queued without bounds.
final class DocumentTemporalRecorder: @unchecked Sendable {
  typealias PixelCopier = @Sendable (CVPixelBuffer, Int) throws -> DocumentTemporalPixelCopy.Copy
  let diagnosticSink: @Sendable (Data) -> Void
  let pixelCopier: PixelCopier
  var ringGeneration: UInt64 = 0
  let configuration: DocumentTemporalConfiguration
  let lock = NSLock()
  var journeySink: (any DocumentJourneyRecordingSink)?
  var buffer: DocumentTemporalBuffer
  var clock: CMClock?
  var camera: DocumentTemporalCameraState?
  var correlation: DocumentTemporalClockCorrelation?
  var running = false
  var sessionActive = false
  var inactiveReason = "session_stopped"
  var pinned = false
  var sequence = 0
  var lastJourneyFrameTime: DocumentCaptureClockTimestamp?
  /// Capture-clock seconds of the last frame offered to the journey sink.
  var lastAdmittedJourneySeconds: Double?
  /// The journey recording keeps raw frames, each copied, hashed, encrypted and
  /// written on its own, so the frames it is offered are paced. The pacing is a
  /// named, attributed default; see `DocumentJourneyPacing`.
  let journeyPacing = DocumentJourneyPacing.engineering20260922
  var lastJourneyMotionTime: Double?
  var motionGeneration = 0
  var frameGeneration: UInt64 = 0
  var pendingSinkActions: [() -> Void] = []
  var callbackTicket: UInt64 = 0
  var activeSinkCallbacks: Set<UInt64> = []
  var sinkDetachWaiters: [(UInt64, @Sendable () -> Void)] = []
  let motion = DocumentTemporalMotionCollector()

  init(
    configuration: DocumentTemporalConfiguration,
    diagnosticSink: @escaping @Sendable (Data) -> Void = { _ in },
    pixelCopier: @escaping PixelCopier = {
      try DocumentTemporalPixelCopy.copy($0, maximumBytes: $1)
    }
  ) {
    self.diagnosticSink = diagnosticSink
    self.pixelCopier = pixelCopier
    self.configuration = configuration
    buffer = DocumentTemporalBuffer(configuration: configuration)
  }

  func setJourneySink(_ sink: (any DocumentJourneyRecordingSink)?) {
    let restart = withState { () -> (Bool, CMClock?) in
      frameGeneration &+= 1
      journeySink = sink
      if running {
        emit(
          .init(
            kind: "session_started", hostTimeSeconds: Self.hostNow(),
            clockCorrelation: correlation, contextCode: journeyPacing.identifier))
      }
      return (sink != nil && sessionActive && !running && !pinned, clock)
    }
    if restart.0 { start(clock: restart.1) }
  }

  func start(clock: CMClock?) {
    let generation = withState { () -> Int? in
      guard !pinned else {
        buffer.recordIssue("restart_rejected_pending_sequence")
        return nil
      }
      if !pinned { buffer = DocumentTemporalBuffer(configuration: configuration) }
      frameGeneration &+= 1
      sessionActive = true
      self.clock = clock
      correlation = Self.clockCorrelation()
      running = configuration.enabled || journeySink != nil
      guard running else { return nil }
      emit(
        .init(
          kind: "session_started", hostTimeSeconds: Self.hostNow(),
          clockCorrelation: correlation, contextCode: journeyPacing.identifier))
      sequence = 0
      lastJourneyFrameTime = nil
      lastAdmittedJourneySeconds = nil
      lastJourneyMotionTime = nil
      motionGeneration += 1
      if clock == nil { buffer.recordIssue("session_clock_unavailable") }
      return motionGeneration
    }
    guard let generation, withState({ running && motionGeneration == generation }) else { return }
    motion.start { [weak self] sample, issue in
      guard let self else { return }
      self.withState {
        guard self.running, self.motionGeneration == generation else { return }
        if let sample { self.retainMotion(sample) }
        if let issue {
          self.buffer.recordIssue(issue)
          self.emit(
            .init(kind: "motion_issue", hostTimeSeconds: Self.hostNow(), contextCode: issue))
        }
      }
    }
  }

  func stop() {
    let didStop = withState {
      guard running || sessionActive else { return false }
      frameGeneration &+= 1
      running = false
      sessionActive = false
      inactiveReason = "session_stopped"
      emit(.init(kind: "session_stopped", hostTimeSeconds: Self.hostNow()))
      motionGeneration += 1
      if pinned {
        buffer.recordIssue("session_stopped_during_sequence")
      } else {
        buffer = DocumentTemporalBuffer(configuration: configuration)
      }
      return true
    }
    if didStop { motion.stop() }
  }

  /// A changed session clock invalidates the pending association even if the
  /// platform changes back before the owner processes its notification.
  func clockDidChange(to replacement: CMClock?) {
    let stopMotion = withState { () -> Bool in
      emit(.init(kind: "clock_changed", hostTimeSeconds: Self.hostNow()))
      if pinned {
        clock = nil
        frameGeneration &+= 1
        running = false
        inactiveReason = "session_clock_changed"
        motionGeneration += 1
        buffer.recordIssue("session_clock_changed_during_sequence")
        return true
      }
      frameGeneration &+= 1
      lastJourneyFrameTime = nil
      lastAdmittedJourneySeconds = nil
      clock = replacement
      emit(
        .init(
          kind: "clock_epoch_started", hostTimeSeconds: Self.hostNow(),
          clockCorrelation: Self.clockCorrelation()))
      buffer = DocumentTemporalBuffer(configuration: configuration)
      correlation = Self.clockCorrelation()
      if replacement == nil { buffer.recordIssue("session_clock_unavailable") }
      return false
    }
    if stopMotion { motion.stop() }
  }

  func updateCamera(_ state: DocumentTemporalCameraState) {
    withState { camera = state }
  }

  func sessionFailed(reason: String) {
    withState {
      frameGeneration &+= 1
      running = false
      sessionActive = false
      inactiveReason = "session_failed"
      motionGeneration += 1
      buffer.recordIssue(reason)
      emit(
        .init(kind: "session_issue", hostTimeSeconds: Self.hostNow(), contextCode: reason))
    }
    motion.stop()
  }

  func discontinuity(_ reason: String) {
    withState {
      if !pinned {
        ringGeneration &+= 1
        buffer = DocumentTemporalBuffer(configuration: configuration)
      }
      buffer.recordIssue(reason)
      emit(
        .init(kind: "configuration_changed", hostTimeSeconds: Self.hostNow(), contextCode: reason))
    }
  }

  func beginCapture() {
    withState {
      pinned = true
      buffer.beginCapture()
    }
  }

  func abandonCapture() {
    withState {
      pinned = false
      ringGeneration &+= 1
      buffer = DocumentTemporalBuffer(configuration: configuration)
    }
  }

  func delayAfterPhoto(_ photo: CapturedDocumentPhoto) -> Double {
    withState {
      guard running, configuration.enabled else { return 0 }
      guard let still = hostSeconds(Self.mediaTime(photo.captureTimestamp)) else {
        return configuration.postCaptureDuration
      }
      return min(
        configuration.postCaptureDuration,
        max(0, still + configuration.postCaptureDuration - Self.hostNow()))
    }
  }

  func needsTailObservation(_ photo: CapturedDocumentPhoto) -> Bool {
    withState {
      guard running, configuration.enabled,
        let still = hostSeconds(Self.mediaTime(photo.captureTimestamp))
      else {
        return false
      }
      let target = still + configuration.postCaptureDuration
      guard let last = buffer.frames.last?.metadata.hostTimeSeconds, last >= target else {
        return true
      }
      guard let correlation, let motion = buffer.motionSamples.last else { return true }
      let latestMotionLowerBound =
        motion.bootTimeSeconds + correlation.hostBeforeSeconds - correlation.bootTimeSeconds
      return latestMotionLowerBound < target
    }
  }

  /// Finalize the still association even when only the continuous sink is enabled.
  /// A disabled optional window must not be published as a retained window.
  func finishForDelivery(_ photo: CapturedDocumentPhoto) -> DocumentTemporalEvidence? {
    let evidence = finish(photo)
    return configuration.enabled ? evidence : nil
  }

  func finish(_ photo: CapturedDocumentPhoto) -> DocumentTemporalEvidence {
    withState {
      let binding = DocumentTemporalBinding(
        sessionID: photo.sessionID.rawValue.uuidString,
        attemptID: photo.admission?.attemptID.uuidString, side: photo.side.rawValue,
        stillSHA256: photo.fidelity.sha256, stillTimestamp: photo.captureTimestamp,
        stillHostTimeSeconds: hostSeconds(Self.mediaTime(photo.captureTimestamp)))
      emit(
        .init(kind: "still_capture", hostTimeSeconds: Self.hostNow(), binding: binding))
      let result = buffer.finish(
        binding: binding, clockCorrelation: correlation,
        termination: running ? "completed" : inactiveReason)
      pinned = false
      ringGeneration &+= 1
      buffer = DocumentTemporalBuffer(configuration: configuration)
      return result
    }
  }

  func hostSeconds(_ time: CMTime) -> Double? {
    guard let clock else { return nil }
    let converted = CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock())
    let seconds = CMTimeGetSeconds(converted)
    return converted.isNumeric && seconds.isFinite ? seconds : nil
  }

  static func hostNow() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

  static func mediaTime(_ value: DocumentCaptureClockTimestamp) -> CMTime {
    CMTime(
      value: value.value, timescale: value.timescale,
      flags: CMTimeFlags(rawValue: value.flags), epoch: value.epoch)
  }

  static func clockCorrelation() -> DocumentTemporalClockCorrelation {
    let before = hostNow()
    let boot = ProcessInfo.processInfo.systemUptime
    let after = hostNow()
    return DocumentTemporalClockCorrelation(
      hostBeforeSeconds: before, bootTimeSeconds: boot, hostAfterSeconds: after,
      method: "CMClockGetHostTimeClock_brackets_ProcessInfo_systemUptime")
  }
}

extension DocumentTemporalRecorder {
  func observeGeometry(
    _ geometry: DocumentTemporalGeometry, liveGeometry: DocumentLiveGeometryObservation? = nil
  ) {
    withState {
      attachRingGeometry(geometry)
      emit(
        .init(
          kind: "geometry", hostTimeSeconds: Self.hostNow(),
          timestamp: geometry.observationTimestamp, geometry: geometry, liveGeometry: liveGeometry))
    }
  }
}
