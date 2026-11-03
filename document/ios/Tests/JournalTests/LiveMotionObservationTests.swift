import XCTest
@testable import DocumentCaptureJournal
@testable import DocumentCaptureApple

@MainActor
final class LiveMotionObservationTests: XCTestCase {
  func testObservationIsImmediateAndStopsAtTerminalState() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.cleanup() }
    let journal = try await CaptureRecordingJournal.start(
      workflowID: UUID(), store: fixture.store, clock: .fixture)
    XCTAssertNil(journal.latestMotionObservation)
    let sample = DocumentTemporalMotionSample(
      bootTimeSeconds: 1, attitude: .init(x: 0, y: 0, z: 0, w: 1),
      rotationRate: .init(x: 0, y: 0, z: 0), gravity: .init(x: 0, y: 0, z: -1),
      userAcceleration: .init(x: 0, y: 0, z: 0), referenceFrame: "fixture")
    journal.appendMotion(sample)
    XCTAssertEqual(journal.latestMotionObservation, sample,
                   "Live presentation must not wait for the 100-sample disk batch")
    journal.appendEvent(.init(kind: "session_issue", hostTimeSeconds: 1))
    XCTAssertNil(journal.latestMotionObservation)
    _ = try await journal.finish(reason: "operator_stop")
    journal.appendMotion(sample)
    XCTAssertNil(journal.latestMotionObservation, "Late callbacks must not revive a stopped level")
  }
}
