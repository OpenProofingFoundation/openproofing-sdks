import Foundation

extension DocumentTemporalRecorder {
  /// Called while the recorder lock is held. Preserve finite raw observations;
  /// chronology limitations are events, never fabricated motion or dropped pixels.
  func retainMotion(_ sample: DocumentTemporalMotionSample) {
    guard sample.isFinite else {
      buffer.recordIssue("invalid_motion_sample")
      emit(
        .init(
          kind: "motion_issue", hostTimeSeconds: Self.hostNow(),
          contextCode: "nonfinite_motion_sample_not_serializable"))
      return
    }
    if let previous = lastJourneyMotionTime, sample.bootTimeSeconds <= previous {
      emit(
        .init(
          kind: "motion_issue", hostTimeSeconds: Self.hostNow(),
          contextCode: "motion_clock_discontinuity"))
    }
    lastJourneyMotionTime = sample.bootTimeSeconds
    buffer.append(sample)
    emitMotion(sample)
  }

  func validateJourneyFrame(_ frame: DocumentTemporalFrame) {
    let timestamp = frame.metadata.timestamp
    if !frame.valid {
      emit(
        .init(
          kind: "frame_issue", hostTimeSeconds: Self.hostNow(),
          timestamp: timestamp, contextCode: "invalid_native_frame_metadata"))
    }
    let discontinuity =
      lastJourneyFrameTime.map {
        $0.epoch != timestamp.epoch || timestamp.seconds <= $0.seconds
      } ?? false
    if discontinuity {
      emit(
        .init(
          kind: "frame_issue", hostTimeSeconds: Self.hostNow(),
          timestamp: timestamp, contextCode: "frame_clock_discontinuity"))
    }
    lastJourneyFrameTime = timestamp
    if frame.metadata.hostTimeSeconds == nil {
      emit(
        .init(
          kind: "frame_issue", hostTimeSeconds: Self.hostNow(),
          timestamp: timestamp, contextCode: "frame_host_time_unavailable"))
    }
  }
}
