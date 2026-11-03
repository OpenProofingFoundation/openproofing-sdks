import CryptoKit
import DocumentSDK
import Foundation
import Testing

@testable import DocumentCaptureApple

/// Deterministic callback/clock fixtures qualify bounded retention, not physical sensor authenticity.
struct DocumentMotionEvidenceTests {
  @Test func nativeFactsAndRawSamplesSurviveTypedRoundTripWithoutInventedExposureAlignment() throws {
    let clock = MotionEvidenceClock(), recorder = DocumentMotionRecorder(clock: { clock.read() })
    let session = CaptureSessionID(), attempt = UUID(), photo = photo(session: session, attempt: attempt)
    recorder.begin(sessionID: session, generation: 1)
    clock.set(101)
    let raw = sample(100.5)
    recorder.receive(raw, issue: nil, generation: 1)
    clock.set(102)
    let evidence = try #require(try recorder.finish(photo: photo, expectedAttemptID: attempt, generation: 1))
    #expect(evidence.schemaVersion == 1)
    #expect(evidence.binding.sessionID == session.rawValue.uuidString)
    #expect(evidence.binding.attemptID == attempt.uuidString)
    #expect(evidence.binding.side == DocumentSide.front.rawValue)
    #expect(evidence.binding.stillSHA256 == photo.fidelity.sha256)
    #expect(evidence.binding.stillTimestamp == photo.captureTimestamp)
    #expect(evidence.binding.stillHostTimeSeconds == nil)
    #expect(evidence.startedAt.bootTimeSeconds == 100)
    #expect(evidence.endedAt.bootTimeSeconds == 102)
    #expect(evidence.samples == [raw])
    #expect(evidence.status == .recorded)
    try evidence.requireValid()
    #expect(try JSONDecoder().decode(DocumentMotionEvidence.self,
      from: JSONEncoder().encode(evidence)) == evidence)
  }

  @Test func rawCallbackAdmissionIsBoundedAndEveryOmissionRemainsVisible() throws {
    let clock = MotionEvidenceClock(), recorder = DocumentMotionRecorder(clock: { clock.read() })
    let session = CaptureSessionID(), attempt = UUID()
    recorder.begin(sessionID: session, generation: 1)
    clock.set(103)
    for index in 0..<(DocumentMotionEvidence.maximumSamples + 3) {
      recorder.receive(sample(100 + Double(index) / 1000), issue: nil, generation: 1)
    }
    for _ in 0..<(DocumentMotionEvidence.maximumIssues + 2) {
      recorder.receive(nil, issue: "device_motion_callback_error", generation: 1)
    }
    clock.set(104)
    let value = try #require(try recorder.finish(photo: photo(session: session, attempt: attempt), expectedAttemptID: attempt, generation: 1))
    #expect(value.samples.count == DocumentMotionEvidence.maximumSamples)
    #expect(value.issues.count == DocumentMotionEvidence.maximumIssues)
    #expect(value.omittedSampleCount == 3)
    #expect(value.omittedIssueCount == 2)
    #expect(value.status == .partial)
    #expect(value.samples.first == sample(100))
    #expect(value.samples.last == sample(100 + Double(DocumentMotionEvidence.maximumSamples - 1) / 1000))
    try value.requireValid()
  }

  @Test func invalidOldFutureAndReversedCallbacksHaveExplicitOutcomesWithoutFabricatedRows() throws {
    let clock = MotionEvidenceClock(), recorder = DocumentMotionRecorder(clock: { clock.read() })
    let session = CaptureSessionID(), attempt = UUID()
    recorder.begin(sessionID: session, generation: 1)
    clock.set(103)
    recorder.receive(sample(.nan), issue: nil, generation: 1)
    recorder.receive(sample(99), issue: nil, generation: 1)
    recorder.receive(sample(104), issue: nil, generation: 1)
    recorder.receive(sample(102), issue: nil, generation: 1)
    recorder.receive(sample(101), issue: nil, generation: 1)
    clock.set(104)
    let value = try #require(try recorder.finish(photo: photo(session: session, attempt: attempt), expectedAttemptID: attempt, generation: 1))
    #expect(value.samples == [sample(102), sample(101)])
    #expect(value.omittedSampleCount == 3)
    #expect(value.issues.map(\.code) == [.invalidSample, .sampleOutsideObservationWindow,
      .sampleOutsideObservationWindow, .motionClockDiscontinuity])
    #expect(value.status == .partial)
    try value.requireValid()
  }

  @Test func unavailableCodesRemainDistinctAndAnEmptyWindowNeverBecomesZeroMotion() throws {
    let reasons: [(String, DocumentMotionEvidence.Issue.Code)] = [
      ("device_motion_unavailable", .deviceMotionUnavailable),
      ("motion_reference_frame_unavailable", .referenceFrameUnavailable),
      ("device_motion_callback_error", .callbackError),
      ("device_motion_platform_unavailable", .platformUnavailable)
    ]
    for (reason, expected) in reasons {
      let clock = MotionEvidenceClock(), recorder = DocumentMotionRecorder(clock: { clock.read() })
      let session = CaptureSessionID(), attempt = UUID()
      recorder.begin(sessionID: session, generation: 1)
      clock.set(101)
      recorder.receive(nil, issue: reason, generation: 1)
      clock.set(102)
      let value = try #require(try recorder.finish(photo: photo(session: session, attempt: attempt), expectedAttemptID: attempt, generation: 1))
      #expect(value.samples.isEmpty)
      #expect(value.status == .unavailable)
      #expect(value.issues.map(\.code) == [expected])
      #expect(value.omittedSampleCount == 0)
      try value.requireValid()
    }
  }

  @Test func restartAndFrozenResultCannotAdoptLateCallbacksFromAnotherGeneration() throws {
    let clock = MotionEvidenceClock(), recorder = DocumentMotionRecorder(clock: { clock.read() })
    let session = CaptureSessionID(), attempt = UUID()
    recorder.begin(sessionID: session, generation: 1)
    clock.set(102)
    recorder.receive(sample(101), issue: nil, generation: 1)
    let original = try #require(try recorder.finish(photo: photo(session: session, attempt: attempt), expectedAttemptID: attempt, generation: 1))
    clock.set(103)
    recorder.begin(sessionID: session, generation: 2)
    clock.set(105)
    recorder.receive(sample(104), issue: "device_motion_unavailable", generation: 1)
    recorder.receive(sample(104.5), issue: nil, generation: 2)
    let next = try #require(try recorder.finish(photo: photo(session: session, attempt: attempt), expectedAttemptID: attempt, generation: 2))
    #expect(original.samples == [sample(101)])
    #expect(next.samples == [sample(104.5)])
    #expect(next.issues.isEmpty)
    #expect(next.recordingID != original.recordingID)
    recorder.receive(sample(105), issue: nil, generation: 2)
    #expect(next.samples == [sample(104.5)])
    #expect(try recorder.finish(photo: photo(session: session, attempt: attempt), expectedAttemptID: attempt, generation: 2) == nil)
    recorder.begin(sessionID: session, generation: 3)
    recorder.discard()
    #expect(try recorder.finish(photo: photo(session: session, attempt: attempt), expectedAttemptID: attempt, generation: 3) == nil)
  }

  @Test func anotherSessionOrNativeAttemptCannotReceiveTheWindow() {
    let session = CaptureSessionID(), attempt = UUID()
    for wrongSession in [false, true] {
      let clock = MotionEvidenceClock(), recorder = DocumentMotionRecorder(clock: { clock.read() })
      recorder.begin(sessionID: session, generation: 1)
      clock.set(101)
      let value = photo(session: wrongSession ? CaptureSessionID() : session,
        attempt: wrongSession ? attempt : UUID())
      #expect(throws: DocumentMotionEvidence.Failure.self) {
        _ = try recorder.finish(photo: value, expectedAttemptID: attempt, generation: 1)
      }
    }
  }

  @Test func publicValidationRejectsMalformedDigestVersionsBindingsAndForeignIssueTimes() throws {
    let clock = MotionEvidenceClock(), recorder = DocumentMotionRecorder(clock: { clock.read() })
    let session = CaptureSessionID(), attempt = UUID()
    recorder.begin(sessionID: session, generation: 1)
    clock.set(101)
    recorder.receive(sample(100.5), issue: "device_motion_callback_error", generation: 1)
    clock.set(102)
    let good = try #require(try recorder.finish(photo: photo(session: session, attempt: attempt), expectedAttemptID: attempt, generation: 1))
    let data = try JSONEncoder().encode(good)
    for mutation in Mutation.allCases {
      var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      switch mutation {
      case .schema: object["schemaVersion"] = 2
      case .status: object["status"] = "recorded"
      case .omissions: object["omittedSampleCount"] = -1
      case .limits: object["maximumSampleCount"] = DocumentMotionEvidence.maximumSamples + 1
      case .digest, .digestNewline, .side, .session, .attempt, .exposure, .timestamp:
        var binding = try #require(object["binding"] as? [String: Any])
        switch mutation {
        case .digest: binding["stillSHA256"] = "not-a-sha256"
        case .digestNewline: binding["stillSHA256"] = good.binding.stillSHA256 + "\n"
        case .side: binding["side"] = "back"
        case .session: binding["sessionID"] = "foreign-session"
        case .attempt: binding["attemptID"] = "foreign-attempt"
        case .timestamp:
          var stamp = try #require(binding["stillTimestamp"] as? [String: Any])
          stamp["flags"] = 4
          binding["stillTimestamp"] = stamp
        default: binding["stillHostTimeSeconds"] = 100.5
        }
        object["binding"] = binding
      case .futureIssue, .foreignHostIssue:
        var issues = try #require(object["issues"] as? [[String: Any]])
        var time = try #require(issues[0]["observedAt"] as? [String: Any])
        time[mutation == .futureIssue ? "bootTimeSeconds" : "hostBeforeSeconds"] = 9999
        issues[0]["observedAt"] = time
        object["issues"] = issues
      }
      let invalid = try JSONDecoder().decode(DocumentMotionEvidence.self,
        from: JSONSerialization.data(withJSONObject: object))
      #expect(throws: DocumentMotionEvidence.Failure.self) { try invalid.requireValid() }
    }
  }

  private enum Mutation: CaseIterable {
    case schema, status, omissions, limits, digest, digestNewline, side, session, attempt, exposure, timestamp, futureIssue, foreignHostIssue
  }

  private func sample(_ time: Double) -> DocumentTemporalMotionSample {
    .init(bootTimeSeconds: time, attitude: .init(x: 0, y: 0, z: 0, w: 1),
      rotationRate: .init(x: 0.1, y: 0.2, z: 0.3), gravity: .init(x: 0, y: 0, z: -1),
      userAcceleration: .init(x: 0.01, y: 0.02, z: 0.03),
      referenceFrame: "xArbitraryZVertical_rotation_radians_per_second_acceleration_g")
  }

  private func photo(session: CaptureSessionID, attempt: UUID) -> CapturedDocumentPhoto {
    let data = Data([1]), date = Date(timeIntervalSince1970: 100)
    let request = CameraPhotoCaptureRequest(sessionID: session, side: .front,
      qualityGate: .operatorInitiatedAdvisory, attemptID: attempt, userRequestedAt: date)
    let admission = DocumentCaptureAdmissionSnapshot(request: request, admittedAt: date,
      photoSettingsUniqueID: 1, observation: nil)
    return CapturedDocumentPhoto(sessionID: session, side: .front, requestedAt: date,
      captureTimestamp: .init(value: 12345, timescale: 1000, flags: 1, epoch: 7,
        clock: .captureSessionSynchronizationClock), processedAt: date, data: data,
      fidelity: .init(pixelWidth: 32, pixelHeight: 16, fileByteCount: 1,
        uniformTypeIdentifier: "public.heic", orientation: 1, cameraModel: nil,
        lensModel: nil, exposureTimeSeconds: nil, fNumber: nil, isoSpeed: nil,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), optical: nil), admission: admission)
  }
}

private final class MotionEvidenceClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 100.0
  func set(_ value: Double) { lock.withLock { self.value = value } }
  func read() -> DocumentTemporalClockCorrelation {
    lock.withLock {
      .init(hostBeforeSeconds: value + 1000, bootTimeSeconds: value,
        hostAfterSeconds: value + 1000.001, method: "synthetic-motion-test-clock")
    }
  }
}
