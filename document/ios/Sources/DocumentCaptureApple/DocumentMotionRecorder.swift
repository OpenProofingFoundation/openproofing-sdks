import Foundation
import DocumentSDK

/// Callback admission is synchronous and bounded, before the level's main-actor delivery.
/// No disk IO, camera controls, frame pixels or per-sample tasks belong in this recorder.
final class DocumentMotionRecorder: @unchecked Sendable {
  private final class Window {
    let recordingID = UUID()
    let sessionID: CaptureSessionID
    let startedAt: DocumentTemporalClockCorrelation
    var samples: [DocumentTemporalMotionSample] = []
    var issues: [DocumentMotionEvidence.Issue] = []
    var omittedSamples = 0
    var omittedIssues = 0
    var lastSampleTime: Double?
    init(sessionID: CaptureSessionID, startedAt: DocumentTemporalClockCorrelation) {
      self.sessionID = sessionID; self.startedAt = startedAt
    }
  }
  private let lock = NSLock()
  private let clock: @Sendable () -> DocumentTemporalClockCorrelation
  private var generation: UInt64?
  private var window: Window?

  init(clock: @escaping @Sendable () -> DocumentTemporalClockCorrelation = DocumentTemporalRecorder.clockCorrelation) {
    self.clock = clock
  }

  func begin(sessionID: CaptureSessionID, generation: UInt64) {
    lock.withLock {
      self.generation = generation
      window = Window(sessionID: sessionID, startedAt: clock())
    }
  }

  func discard() {
    lock.withLock { generation = nil; window = nil }
  }

  func receive(_ sample: DocumentTemporalMotionSample?, issue: String?, generation: UInt64) {
    lock.withLock {
      guard self.generation == generation, let value = window else { return }
      let observedAt = clock()
      if let issue { appendIssue(Self.code(issue), observedAt: observedAt, to: value) }
      if let sample {
        if !sample.isFinite || sample.referenceFrame.isEmpty {
          value.omittedSamples += 1
          appendIssue(.invalidSample, observedAt: observedAt, to: value)
        } else if sample.bootTimeSeconds < value.startedAt.bootTimeSeconds || sample.bootTimeSeconds > observedAt.bootTimeSeconds {
          value.omittedSamples += 1
          appendIssue(.sampleOutsideObservationWindow, observedAt: observedAt, to: value)
        } else {
          if let previous = value.lastSampleTime, sample.bootTimeSeconds <= previous {
            appendIssue(.motionClockDiscontinuity, observedAt: observedAt, to: value)
          }
          value.lastSampleTime = sample.bootTimeSeconds
          if value.samples.count < DocumentMotionEvidence.maximumSamples { value.samples.append(sample) }
          else { value.omittedSamples += 1 }
        }
      }
    }
  }

  func finish(photo: CapturedDocumentPhoto, expectedAttemptID: UUID, generation: UInt64) throws -> DocumentMotionEvidence? {
    try lock.withLock {
      guard self.generation == generation, let value = window else { return nil }
      self.generation = nil; window = nil
      guard value.sessionID == photo.sessionID, photo.side == .front,
        photo.admission.map({ $0.sessionID == photo.sessionID && $0.side == photo.side
          && $0.attemptID == expectedAttemptID }) ?? true
      else { throw DocumentMotionEvidence.Failure.bindingMismatch }
      let result = DocumentMotionEvidence(schemaVersion: 1, recordingID: value.recordingID,
        binding: .init(sessionID: photo.sessionID.rawValue.uuidString,
          attemptID: photo.admission?.attemptID.uuidString, side: photo.side.rawValue,
          stillSHA256: photo.fidelity.sha256, stillTimestamp: photo.captureTimestamp,
          stillHostTimeSeconds: nil),
        startedAt: value.startedAt, endedAt: clock(), samples: value.samples, issues: value.issues,
        maximumSampleCount: DocumentMotionEvidence.maximumSamples,
        maximumIssueCount: DocumentMotionEvidence.maximumIssues,
        omittedSampleCount: value.omittedSamples, omittedIssueCount: value.omittedIssues,
        status: DocumentMotionEvidence.status(samples: value.samples, issues: value.issues,
          omittedSamples: value.omittedSamples, omittedIssues: value.omittedIssues))
      try result.requireValid()
      return result
    }
  }

  private func appendIssue(_ code: DocumentMotionEvidence.Issue.Code,
    observedAt: DocumentTemporalClockCorrelation, to value: Window) {
    if value.issues.count < DocumentMotionEvidence.maximumIssues {
      value.issues.append(.init(code: code, observedAt: observedAt))
    } else { value.omittedIssues += 1 }
  }

  private static func code(_ issue: String) -> DocumentMotionEvidence.Issue.Code {
    switch issue {
    case "device_motion_unavailable": .deviceMotionUnavailable
    case "motion_reference_frame_unavailable": .referenceFrameUnavailable
    case "device_motion_platform_unavailable": .platformUnavailable
    default: .callbackError
    }
  }
}
