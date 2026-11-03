import Foundation
import DocumentCaptureApple

public struct CaptureRecordingReference: Codable, Equatable, Sendable {
  public let recordingID: UUID
  public let workflowID: UUID
  public let startSHA256: String
  public init(recordingID: UUID, workflowID: UUID, startSHA256: String) {
    self.recordingID = recordingID
    self.workflowID = workflowID
    self.startSHA256 = startSHA256
  }

}

struct CaptureRecordingLink: Codable, Sendable {
  let schemaVersion: Int
  let recordKind: String
  let recordingID: UUID
  let workflowID: UUID
  let ordinal: Int
  let previousID: UUID?
  let previousSHA256: String?
  let payloadSHA256: String
  let frame: DocumentTemporalFrameMetadata?
}

struct CaptureRecordingStart: Codable {
  let schemaVersion: Int
  let maximumDuration: Double
  let maximumDiskBytes: Int
  let maximumPendingBytes: Int
  let startedAt: Date
  var configurationVersion: String?
}

struct CaptureRecordingSeal: Codable {
  let status: String
  let reason: String
  let frameCount: Int
  let motionSampleCount: Int
  let issueCount: Int
  let retainedStillCount: Int
  let refusedFrames: Int
  let refusedMotionSamples: Int
  var firstLossTimestamp: DocumentCaptureClockTimestamp?
  var firstLossHostTimeSeconds: Double?
  var firstLossReason: String?
  var coalescedGapEvents: Int?
  var platformDropCallbacks: Int?
  var acquisitionDiagnostics: RecordingAcquisitionDiagnostics?
}

/// Bounded operational counters only; no source pixels or document fields.
public struct RecordingAcquisitionDiagnostics: Codable, Sendable {
  enum Refusal: String, CaseIterable {
    case invalidSize, pendingByteCapacity, queuedRecordCapacity, terminalAdmission
    case copyFailed, copyCancelled, otherCancellation, diskCapacity
  }

  struct StoreAwaitTiming: Codable, Sendable {
    var attempts = 0
    var failures = 0
    var totalSeconds = 0.0
    var maximumSeconds = 0.0
  }

  var schemaVersion = 1
  var pendingByteHighWaterMark = 0
  var queuedRecordHighWaterMark = 0
  // Keys are restricted by Refusal and the three journal data record kinds.
  var frameRefusals: [String: Int] = [:]
  var storeAwaitCalls: [String: StoreAwaitTiming] = [:]
}

extension RecordingAcquisitionDiagnostics {
  /// Diagnostics cannot weaken the existing journal/coverage checks.
  var valid: Bool {
    let refusalKeys = Set(Refusal.allCases.map(\.rawValue))
    guard schemaVersion == 1, pendingByteHighWaterMark >= 0, queuedRecordHighWaterMark >= 0,
      Set(frameRefusals.keys).isSubset(of: refusalKeys),
      frameRefusals.values.allSatisfy({ $0 >= 0 }),
      Set(storeAwaitCalls.keys).isSubset(of: ["frame", "motion", "event"])
    else { return false }
    return storeAwaitCalls.values.allSatisfy { timing in
      timing.attempts >= 0 && timing.failures >= 0 && timing.failures <= timing.attempts
        && timing.totalSeconds.isFinite && timing.maximumSeconds.isFinite
        && timing.totalSeconds >= 0 && timing.maximumSeconds >= 0
        && timing.maximumSeconds <= timing.totalSeconds
        && (timing.attempts > 0 || timing.totalSeconds == 0)
    }
  }
}
