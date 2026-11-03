import Foundation

/// Motion-only observations admitted during one front acquisition. `recorded` means the
/// bounded callbacks were retained, never continuous coverage or still-exposure alignment.
public struct DocumentMotionEvidence: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case recorded, partial, unavailable }
  public enum Failure: Error { case invalidEvidence, bindingMismatch }
  public struct Issue: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
      case deviceMotionUnavailable, referenceFrameUnavailable, callbackError, platformUnavailable
      case invalidSample, motionClockDiscontinuity, sampleOutsideObservationWindow
    }
    public let code: Code
    public let observedAt: DocumentTemporalClockCorrelation
  }

  public let schemaVersion: Int
  public let recordingID: UUID
  public let binding: DocumentTemporalBinding
  public let startedAt: DocumentTemporalClockCorrelation
  public let endedAt: DocumentTemporalClockCorrelation
  public let samples: [DocumentTemporalMotionSample]
  public let issues: [Issue]
  public let maximumSampleCount: Int
  public let maximumIssueCount: Int
  public let omittedSampleCount: Int
  public let omittedIssueCount: Int
  public let status: Status

  /// The existing temporal capture engineering bounds, not a calibrated motion policy.
  static let maximumSamples = DocumentTemporalConfiguration().maximumMotionSamples
  static let maximumIssues = DocumentTemporalConfiguration().maximumDiagnostics

  public func requireValid() throws {
    guard schemaVersion == 1, UUID(uuidString: binding.sessionID) != nil,
      binding.attemptID.map({ UUID(uuidString: $0) != nil }) ?? true,
      binding.side == "front", binding.stillSHA256.count == 64,
      binding.stillSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
      binding.stillTimestamp.isNumeric, binding.stillHostTimeSeconds == nil,
      Self.valid(startedAt), Self.valid(endedAt),
      endedAt.bootTimeSeconds >= startedAt.bootTimeSeconds,
      endedAt.hostBeforeSeconds >= startedAt.hostBeforeSeconds,
      maximumSampleCount == Self.maximumSamples, maximumIssueCount == Self.maximumIssues,
      samples.count <= maximumSampleCount, issues.count <= maximumIssueCount,
      omittedSampleCount >= 0, omittedIssueCount >= 0,
      samples.allSatisfy({ $0.isFinite && !$0.referenceFrame.isEmpty
        && $0.bootTimeSeconds >= startedAt.bootTimeSeconds
        && $0.bootTimeSeconds <= endedAt.bootTimeSeconds }),
      issues.allSatisfy({ Self.valid($0.observedAt)
        && $0.observedAt.bootTimeSeconds >= startedAt.bootTimeSeconds
        && $0.observedAt.bootTimeSeconds <= endedAt.bootTimeSeconds
        && $0.observedAt.hostBeforeSeconds >= startedAt.hostBeforeSeconds
        && $0.observedAt.hostAfterSeconds <= endedAt.hostAfterSeconds }),
      status == Self.status(samples: samples, issues: issues,
        omittedSamples: omittedSampleCount, omittedIssues: omittedIssueCount)
    else { throw Failure.invalidEvidence }
    let reversed = zip(samples, samples.dropFirst()).contains { $1.bootTimeSeconds <= $0.bootTimeSeconds }
    guard !reversed || issues.contains(where: { $0.code == .motionClockDiscontinuity }) || omittedIssueCount > 0
    else { throw Failure.invalidEvidence }
  }

  static func valid(_ value: DocumentTemporalClockCorrelation) -> Bool {
    value.hostBeforeSeconds.isFinite && value.bootTimeSeconds.isFinite && value.hostAfterSeconds.isFinite
      && value.hostBeforeSeconds >= 0 && value.bootTimeSeconds >= 0
      && value.hostAfterSeconds >= value.hostBeforeSeconds && !value.method.isEmpty
  }

  static func status(samples: [DocumentTemporalMotionSample], issues: [Issue],
    omittedSamples: Int, omittedIssues: Int) -> Status {
    if samples.isEmpty { return .unavailable }
    return issues.isEmpty && omittedSamples == 0 && omittedIssues == 0 ? .recorded : .partial
  }
}
