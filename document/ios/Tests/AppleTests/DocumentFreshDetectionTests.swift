import Foundation
import Testing

@testable import DocumentCaptureApple

struct DocumentFreshDetectionTests {
  @Test func newModeIsExplicitAndLegacyPacketsStaySeparate() throws {
    let good = freshPacket()
    #expect(good.valid)
    #expect(
      try JSONDecoder().decode(
        DocumentLiveGeometryObservation.self,
        from: JSONEncoder().encode(good)) == good)
    let encoded = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
    for key in ["schemaVersion", "analysisMode", "requestFacts", "tracker"] {
      var bad = encoded
      switch key {
      case "schemaVersion": bad[key] = 1
      case "analysisMode": bad[key] = "trackingAssisted"
      case "requestFacts": bad.removeValue(forKey: key)
      default:
        bad[key] = [
          "transition": "initialDetection", "trackingOutcome": "notAttempted", "resetReasons": [],
        ]
      }
      let packet = try JSONDecoder().decode(
        DocumentLiveGeometryObservation.self,
        from: JSONSerialization.data(withJSONObject: bad))
      #expect(!packet.valid)
    }
  }

  @Test func pendingCancelledAndTerminalRunsCannotSelectFreshMode() {
    let transport = DocumentTiltGuidanceTransport(recorder: nil) { _ in }
    let first = UUID()
    transport.prepare(runID: first)
    #expect(!transport.usesFreshDetections)
    #expect(transport.begin(runID: first, configuration: .provisionalV2, hostSeconds: 0) != nil)
    #expect(transport.usesFreshDetections)
    transport.invalidate(runID: first, reason: .userSkipped)
    #expect(!transport.usesFreshDetections)
    transport.end(runID: first, reason: .userSkipped)
    let legacy = UUID()
    transport.prepare(runID: legacy)
    #expect(transport.begin(runID: legacy, configuration: .provisionalV1, hostSeconds: 1) != nil)
    #expect(!transport.usesFreshDetections)
  }

  private func freshPacket() -> DocumentLiveGeometryObservation {
    let time = DocumentCaptureClockTimestamp(
      value: 1, timescale: 5, flags: 1, epoch: 0,
      clock: .captureSessionSynchronizationClock)
    return .init(
      schemaVersion: 2, observedAt: Date(timeIntervalSince1970: 0),
      geometry: .init(
        quadrilateral: .init(
          topLeft: .init(x: 0.1, y: 0.1), topRight: .init(x: 0.9, y: 0.1),
          bottomRight: .init(x: 0.9, y: 0.8), bottomLeft: .init(x: 0.1, y: 0.8)),
        observationTimestamp: time, coordinateSpace: "normalized_delivered_video_buffer_top_left",
        status: "observed", confidence: 0.9, method: "VNDetectDocumentSegmentationRequest"),
      pixelWidth: 640, pixelHeight: 480, analysisSequence: 1, geometryRevision: 1,
      availability: .observed, requestRevision: 1,
      tracker: .init(
        transition: .freshDetection, trackingOutcome: .notAttempted,
        precedingAnalysisTimestamp: nil, resetReasons: [.analysisModeChanged]),
      requestFacts: [.completed(.documentSegmentation, revision: 1, count: 1, accepted: true)],
      analysisMode: .freshDetection)
  }
}
