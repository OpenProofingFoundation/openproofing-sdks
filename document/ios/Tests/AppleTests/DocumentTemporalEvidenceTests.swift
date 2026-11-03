import Foundation
import Testing

@testable import DocumentCaptureApple

struct DocumentTemporalEvidenceTests {
  @Test func disabledByDefault() {
    var buffer = DocumentTemporalBuffer(configuration: .init())
    buffer.append(frame(0))
    #expect(buffer.frames.isEmpty)
    #expect(!DocumentCaptureConfiguration.geometry.temporalEvidence.enabled)
  }

  @Test func exactPlaneLayoutRequired() {
    var buffer = makeBuffer()
    let bad = DocumentTemporalFrame(metadata: frame(0).metadata, payload: Data([1, 2]))
    buffer.append(bad)
    #expect(buffer.frames.isEmpty)
    #expect(buffer.issues == ["invalid_frame"])
  }

  @Test func capturesActualStillWindowAndMotionCorrelation() {
    var buffer = makeBuffer()
    buffer.beginCapture()
    for index in 0...3 { buffer.append(frame(index)) }
    buffer.append(motion(100))
    buffer.append(motion(103))
    let result = buffer.finish(
      binding: binding(1), clockCorrelation: correlation, termination: "completed")
    #expect(result.manifest.status == "recorded")
    #expect(result.manifest.frames.count == 3)
    #expect(result.frames.map(\.payload) == Array(repeating: Data([42]), count: 3))
  }

  @Test func delayedStillCannotUseRequestCoverageAsProof() {
    var buffer = makeBuffer()
    buffer.pin(atHostTimeSeconds: 1)
    for index in 0...3 { buffer.append(frame(index)) }
    let result = buffer.finish(
      binding: binding(3), clockCorrelation: correlation, termination: "completed")
    #expect(result.manifest.status == "partial")
    #expect(result.manifest.issues.contains("post_capture_window_incomplete"))
  }

  @Test func byteCapEvictionsAreExplicitAndBounded() {
    var buffer = DocumentTemporalBuffer(
      configuration: .init(enabled: true, maximumBytes: 2, maximumFrames: 10))
    buffer.beginCapture()
    for index in 0...3 { buffer.append(frame(index)) }
    #expect(buffer.frames.map(\.metadata.sequenceNumber) == [2, 3])
    #expect(buffer.evictedFrameCount == 2)
    #expect(buffer.gaps.map(\.reason) == ["retention_cap", "retention_cap"])
  }

  @Test func rollingWindowKeepsPredecessorAndPinStopsPruning() {
    var buffer = makeBuffer()
    for index in 0...3 { buffer.append(frame(index)) }
    #expect(buffer.frames.map(\.metadata.sequenceNumber) == [1, 2, 3])
    buffer.beginCapture()
    buffer.append(frame(4))
    #expect(buffer.frames.map(\.metadata.sequenceNumber) == [1, 2, 3, 4])
  }

  @Test func clockDiscontinuitiesAndNonfiniteMotionAreRecorded() {
    var buffer = makeBuffer()
    buffer.append(frame(1))
    buffer.append(frame(0))
    buffer.append(motion(.nan))
    buffer.append(motion(5))
    buffer.append(motion(4))
    #expect(buffer.issues.count == 3)
    #expect(buffer.issues.contains("frame_clock_discontinuity"))
    #expect(buffer.issues.contains("invalid_motion_sample"))
    #expect(buffer.issues.contains("motion_clock_discontinuity"))
    #expect(buffer.frames.count == 1)
    #expect(buffer.motionSamples.count == 1)
  }

  @Test func diagnosticAndMotionStorageAreBounded() {
    var buffer = DocumentTemporalBuffer(
      configuration: .init(enabled: true, maximumMotionSamples: 2, maximumDiagnostics: 2))
    for index in 0...10 {
      buffer.recordIssue("issue_\(index)")
      buffer.append(motion(Double(index)))
    }
    #expect(buffer.issues.count == 2)
    #expect(buffer.omittedDiagnosticCount == 9)
    #expect(buffer.motionSamples.count == 2)
    #expect(buffer.evictedMotionSampleCount == 9)
  }

  @Test func noClockCorrelationCannotBeComplete() {
    var buffer = makeBuffer()
    buffer.beginCapture()
    for index in 0...3 { buffer.append(frame(index)) }
    let result = buffer.finish(binding: binding(1), clockCorrelation: nil, termination: "completed")
    #expect(result.manifest.status == "partial")
    #expect(result.manifest.issues.contains("motion_clock_correlation_unavailable"))
  }

  @Test func manifestRoundTripRetainsLinksWithoutPixels() throws {
    var buffer = makeBuffer()
    buffer.append(frame(0))
    let evidence = buffer.finish(
      binding: binding(0), clockCorrelation: nil, termination: "interrupted")
    let bytes = try JSONEncoder().encode(evidence.manifest)
    #expect(
      try JSONDecoder().decode(DocumentTemporalManifest.self, from: bytes) == evidence.manifest)
    #expect(String(data: bytes, encoding: .utf8)?.contains("payload") == false)
  }

  @Test func oldDroppedFramesDoNotPoisonRecoveredWindow() {
    var buffer = makeBuffer()
    buffer.recordGap(.init(reason: "platform_drop", timestamp: timestamp(0), count: 1))
    for index in 0...5 { buffer.append(frame(index)) }
    buffer.beginCapture()
    buffer.append(frame(6))
    buffer.append(motion(103))
    buffer.append(motion(107))
    let evidence = buffer.finish(
      binding: binding(5), clockCorrelation: correlation, termination: "completed")
    #expect(evidence.manifest.gaps.isEmpty)
    #expect(evidence.manifest.status == "recorded")
  }

  @Test func inWindowDroppedFramesRemainPartial() {
    var buffer = makeBuffer()
    buffer.beginCapture()
    for index in 0...3 { buffer.append(frame(index)) }
    buffer.recordGap(.init(reason: "platform_drop", timestamp: timestamp(1), count: 1))
    buffer.append(motion(100))
    buffer.append(motion(103))
    let evidence = buffer.finish(
      binding: binding(1), clockCorrelation: correlation, termination: "completed")
    #expect(evidence.manifest.status == "partial")
    #expect(evidence.manifest.gaps.count == 1)
  }

  @Test func invalidStillTimestampCannotBeRecorded() {
    var buffer = makeBuffer()
    buffer.beginCapture()
    for index in 0...3 { buffer.append(frame(index)) }
    let invalid = DocumentTemporalBinding(
      sessionID: "session", attemptID: "attempt", side: "front",
      stillSHA256: String(repeating: "a", count: 64),
      stillTimestamp: .init(
        value: 1, timescale: 0, flags: 0, epoch: 0,
        clock: .captureSessionSynchronizationClock), stillHostTimeSeconds: 1)
    let evidence = buffer.finish(
      binding: invalid, clockCorrelation: correlation, termination: "completed")
    #expect(evidence.manifest.issues.contains("still_clock_discontinuity"))
  }

  @Test func oldDiagnosticOverflowRecoversAfterFullCleanWindow() {
    var buffer = DocumentTemporalBuffer(configuration: .init(enabled: true, maximumDiagnostics: 2))
    for _ in 0...10 {
      buffer.recordGap(.init(reason: "old_drop", timestamp: timestamp(0), count: 1))
    }
    for index in 0...5 { buffer.append(frame(index)) }
    buffer.beginCapture()
    buffer.append(frame(6))
    buffer.append(motion(103))
    buffer.append(motion(107))
    let result = buffer.finish(
      binding: binding(5), clockCorrelation: correlation, termination: "completed")
    #expect(result.manifest.status == "recorded")
    #expect(result.manifest.omittedDiagnosticCount == 0)
  }

  private func makeBuffer() -> DocumentTemporalBuffer {
    DocumentTemporalBuffer(configuration: .init(enabled: true))
  }

  private func timestamp(_ value: Int) -> DocumentCaptureClockTimestamp {
    .init(
      value: Int64(value), timescale: 1, flags: 1, epoch: 0,
      clock: .captureSessionSynchronizationClock)
  }

  private func frame(_ value: Int) -> DocumentTemporalFrame {
    .init(
      metadata: .init(
        sequenceNumber: value, timestamp: timestamp(value), hostTimeSeconds: Double(value),
        width: 1, height: 1, pixelFormat: 0,
        planes: [
          .init(
            offset: 0, byteCount: 1, width: 1, height: 1, sourceBytesPerRow: 1, packedBytesPerRow: 1
          )
        ],
        sha256: String(repeating: "a", count: 64), colorAttachmentsPlist: nil, geometry: nil,
        camera: nil),
      payload: Data([42]))
  }

  private func binding(_ value: Int) -> DocumentTemporalBinding {
    .init(
      sessionID: "session", attemptID: "attempt", side: "front",
      stillSHA256: String(repeating: "b", count: 64),
      stillTimestamp: timestamp(value), stillHostTimeSeconds: Double(value))
  }

  private var correlation: DocumentTemporalClockCorrelation {
    .init(
      hostBeforeSeconds: 0, bootTimeSeconds: 100, hostAfterSeconds: 0, method: "synthetic_bracket")
  }

  private func motion(_ time: Double) -> DocumentTemporalMotionSample {
    let zero = DocumentTemporalVector3(x: 0, y: 0, z: 0)
    return .init(
      bootTimeSeconds: time, attitude: .init(x: 0, y: 0, z: 0, w: 1), rotationRate: zero,
      gravity: zero, userAcceleration: zero, referenceFrame: "synthetic")
  }
}
