import Foundation
import XCTest

@testable import DocumentCaptureJournal
@testable import DocumentCaptureApple

@MainActor
final class TiltGuidanceEvidenceTests: XCTestCase {
  func testTiltSourceMustMatchArchivedGeometry() async throws {
    for mismatch in [false, true] {
      let fixture = try RecordingFixture()
      defer { fixture.cleanup() }
      let journal = try await CaptureRecordingJournal.start(
        workflowID: UUID(), store: fixture.store, clock: .fixture)
      let source = packet(width: 1320)
      let retained = packet(width: mismatch ? 1330 : 1320)
      var controller = DocumentTiltController(runID: UUID())
      journal.appendEvent(
        .init(
          kind: "tilt_guidance", hostTimeSeconds: 0,
          tiltGuidance: controller.initialUpdate))
      journal.appendEvent(
        .init(
          kind: "geometry", hostTimeSeconds: 1,
          timestamp: retained.captureTimestamp, geometry: retained.geometry, liveGeometry: retained)
      )
      let update = controller.consume(source)
      XCTAssertTrue(update.valid)
      journal.appendEvent(
        .init(
          kind: "tilt_guidance", hostTimeSeconds: 1,
          timestamp: source.captureTimestamp, tiltGuidance: update))
      _ = try await journal.finish(reason: "operator_stop")
      do {
        _ = try await CaptureRecordingVerification.verify(
          journal.reference, store: fixture.store)
        XCTAssertFalse(mismatch, "Tilt source diverged from the retained geometry packet")
      } catch {
        XCTAssertTrue(mismatch, "Matching tilt source failed journal verification: \(error)")
      }
    }
  }

  private func packet(width: Int) -> DocumentLiveGeometryObservation {
    let time = DocumentCaptureClockTimestamp(
      value: 1, timescale: 30, flags: 1, epoch: 0, clock: .captureSessionSynchronizationClock)
    let geometry = DocumentTemporalGeometry(
      quadrilateral: .init(
        topLeft: .init(x: 0.1, y: 0.2), topRight: .init(x: 0.9, y: 0.2),
        bottomRight: .init(x: 0.9, y: 0.8), bottomLeft: .init(x: 0.1, y: 0.8)),
      observationTimestamp: time, coordinateSpace: "normalized_delivered_video_buffer_top_left",
      status: "observed", confidence: 0.8, method: "VNDetectRectanglesRequest")
    return .init(
      schemaVersion: 1, observedAt: Date(timeIntervalSince1970: 123), geometry: geometry,
      pixelWidth: width, pixelHeight: 1760, analysisSequence: 1, geometryRevision: 0,
      availability: .observed, requestRevision: 1,
      tracker: .init(
        transition: .initialDetection, trackingOutcome: .notAttempted,
        precedingAnalysisTimestamp: nil, resetReasons: [.sessionStarted]))
  }
}
