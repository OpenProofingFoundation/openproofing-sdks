import Foundation
import DocumentCaptureApple

extension CaptureRecordingJournal {
  /// Fixed state/counters only; no images, recognized text or location.
  public func emitDiagnostic() {
    let snapshot = lock.withLock {
      CaptureRecordingDiagnostic(
        recordingID: recordingID, contextCode: terminalReason,
        writeFailed: writeFailed, pendingBytes: pendingBytes,
        maximumPendingBytes: maximumPendingBytes, chargedBytes: chargedBytes,
        maximumDiskBytes: maximumDiskBytes, frameCount: frameCount,
        refusedFrames: refusedFrames, refusedMotionSamples: refusedMotion,
        outstandingMilestones: milestones.count, acquisitionDiagnostics: acquisitionDiagnostics)
    }
    diagnosticSink(snapshot)
  }
}

public struct CaptureRecordingDiagnostic: Encodable, Sendable {
  public let recordingID: UUID
  public let contextCode: String?
  enum CodingKeys: String, CodingKey {
    case recordingID, writeFailed, pendingBytes, maximumPendingBytes, chargedBytes
    case maximumDiskBytes, frameCount, refusedFrames, refusedMotionSamples
    case outstandingMilestones, acquisitionDiagnostics
    case contextCode = "reason"
  }
  public let writeFailed: Bool
  public let pendingBytes: Int
  public let maximumPendingBytes: Int
  public let chargedBytes: Int
  public let maximumDiskBytes: Int
  public let frameCount: Int
  public let refusedFrames: Int
  public let refusedMotionSamples: Int
  public let outstandingMilestones: Int
  public let acquisitionDiagnostics: RecordingAcquisitionDiagnostics
}

extension CaptureRecordingJournal {
  /// Called under admission lock. A terminal refusal is separate from historical refusedFrames.
  func recordAdmissionRefusal(
    _ reason: RecordingAcquisitionDiagnostics.Refusal,
    loss: DocumentJourneyRecordingEvent?
  ) {
    countFrameRefusal(reason)
    if let loss {
      recordLoss(
        .init(
          kind: loss.kind, hostTimeSeconds: loss.hostTimeSeconds,
          sessionID: loss.sessionID, timestamp: loss.timestamp,
          clockCorrelation: loss.clockCorrelation, geometry: loss.geometry,
          binding: loss.binding, contextCode: reason.rawValue))
    }
    schedule()
  }

  func frameCapacityRefusal(byteCount: Int) -> RecordingAcquisitionDiagnostics.Refusal? {
    if byteCount <= 0 { return .invalidSize }
    if byteCount > maximumPendingBytes - pendingBytes { return .pendingByteCapacity }
    if queue.count >= 256 { return .queuedRecordCapacity }
    return nil
  }

  func countFrameRefusal(_ reason: RecordingAcquisitionDiagnostics.Refusal) {
    acquisitionDiagnostics.frameRefusals[reason.rawValue, default: 0] += 1
  }

  func observeQueuePressure() {
    acquisitionDiagnostics.pendingByteHighWaterMark = max(
      acquisitionDiagnostics.pendingByteHighWaterMark, pendingBytes)
    acquisitionDiagnostics.queuedRecordHighWaterMark = max(
      acquisitionDiagnostics.queuedRecordHighWaterMark, queue.count + (pendingGap == nil ? 0 : 1))
  }

  /// Includes actor wait plus encryption, publication and authenticated readback.
  /// Start and seal writes are excluded; a seal cannot contain its own completed timing.
  func recordStoreAwait(kind: String, elapsed: Double, failed: Bool) {
    let key: String
    switch kind {
    case "journeyRecordingFrame": key = "frame"
    case "journeyRecordingMotion": key = "motion"
    case "journeyRecordingEvent": key = "event"
    default: return
    }
    lock.withLock {
      var timing = acquisitionDiagnostics.storeAwaitCalls[key, default: .init()]
      timing.attempts += 1
      timing.failures += failed ? 1 : 0
      timing.totalSeconds += elapsed
      timing.maximumSeconds = max(timing.maximumSeconds, elapsed)
      acquisitionDiagnostics.storeAwaitCalls[key] = timing
    }
  }
}
