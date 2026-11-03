import Foundation
import Testing

@testable import DocumentCaptureApple

struct DocumentGeometryRequestFactTests {
  @Test func failuresContainOnlyBoundedDomainAndCode() throws {
    let original = NSError(
      domain: String(repeating: "界", count: 100), code: 9,
      userInfo: [NSLocalizedDescriptionKey: "PRIVATE_DESCRIPTION", "private": "PRIVATE_USERINFO"])
    let fact = DocumentGeometryRequestFact.failed(.rectangleTracking, revision: 1, error: original)
    #expect(fact.valid)
    #expect(fact.error?.domain.utf8.count == 126)
    #expect(fact.error?.domainWasTruncated == true)
    #expect(fact.error?.code == 9)
    let data = try JSONEncoder().encode(fact)
    let encoded = try #require(String(data: data, encoding: .utf8))
    #expect(!encoded.contains("PRIVATE") && !encoded.contains("userInfo"))
    #expect(try JSONDecoder().decode(DocumentGeometryRequestFact.self, from: data) == fact)
    let native = DocumentGeometryRequestFact.failed(
      .rectangleTracking, revision: 1, error: NSError(domain: "com.apple.Vision", code: 9))
    #expect(native.error?.domain == "com.apple.Vision" && native.error?.domainWasTruncated == false)
  }

  @Test func legacyPacketAndExactNativeAttemptsRoundTrip() throws {
    let legacy = try packet(facts: nil)
    #expect(legacy.valid && legacy.requestFacts == nil)
    let failed = DocumentGeometryRequestFact.failed(
      .rectangleTracking, revision: 1, error: NSError(domain: "com.apple.Vision", code: 9))
    let facts: [DocumentGeometryRequestFact] = [
      failed, .completed(.documentSegmentation, revision: 1, count: 1, accepted: false),
      .completed(.rectangleDetection, revision: 1, count: 2, accepted: true)
    ]
    let value = try packet(facts: facts, tracking: "failed")
    #expect(value.valid && value.requestFacts == facts)
    #expect(
      try JSONDecoder().decode(
        DocumentLiveGeometryObservation.self, from: JSONEncoder().encode(value)) == value)
  }

  @Test func impossibleOrdersCountsAndAvailabilityAreRejected() throws {
    let accepted = DocumentGeometryRequestFact.completed(
      .rectangleDetection, revision: 1, count: 1, accepted: true)
    let empty = DocumentGeometryRequestFact.completed(
      .rectangleDetection, revision: 1, count: 0, accepted: false)
    let failed = DocumentGeometryRequestFact.failed(
      .rectangleDetection, revision: 1, error: NSError(domain: "com.apple.Vision", code: 9))
    #expect(try packet(facts: [empty], availability: "noAcceptedRectangle").valid)
    #expect(try packet(facts: [failed], availability: "analysisFailed").valid)
    #expect(try !packet(facts: [failed], availability: "noAcceptedRectangle").valid)
    #expect(try !packet(facts: [empty], availability: "analysisFailed").valid)
    for facts in [
      [], [accepted, accepted], [accepted, empty], Array(repeating: accepted, count: 4),
      [.completed(.rectangleDetection, revision: 1, count: 17, accepted: true)],
      [.completed(.rectangleDetection, revision: 0, count: 1, accepted: true)],
      [.completed(.documentSegmentation, revision: 1, count: 1, accepted: true)]
    ] {
      #expect(try !packet(facts: facts).valid)
    }
    #expect(
      try !packet(
        facts: [.completed(.documentSegmentation, revision: 1, count: 0, accepted: false)],
        availability: "noAcceptedRectangle"
      ).valid)
    #expect(try !packet(facts: [accepted], tracking: "failed").valid)
  }

  private func packet(
    facts: [DocumentGeometryRequestFact]?, availability: String = "observed",
    tracking: String = "notAttempted"
  ) throws -> DocumentLiveGeometryObservation {
    let observed = availability == "observed"
    let timestamp: [String: Any] = [
      "value": 2, "timescale": 5, "flags": 1, "epoch": 0,
      "clock": "captureSessionSynchronizationClock"
    ]
    var geometry: [String: Any] = [
      "observationTimestamp": timestamp,
      "coordinateSpace": "normalized_delivered_video_buffer_top_left",
      "status": observed ? "observed" : "analyzed_no_accepted_rectangle"
    ]
    if observed {
      geometry["method"] = "VNDetectRectanglesRequest"
      geometry["confidence"] = 0.9
      geometry["quadrilateral"] = [
        "topLeft": ["x": 0.1, "y": 0.1], "topRight": ["x": 0.9, "y": 0.1],
        "bottomRight": ["x": 0.9, "y": 0.8], "bottomLeft": ["x": 0.1, "y": 0.8]
      ]
    }
    let transition =
      observed
      ? (tracking == "failed" ? "trackingLostThenDetected" : "initialDetection") : "unavailable"
    var value: [String: Any] = [
      "schemaVersion": 1, "observedAt": 1, "geometry": geometry,
      "pixelWidth": 1320, "pixelHeight": 1760, "analysisSequence": 1, "geometryRevision": 0,
      "availability": availability, "requestRevision": 1,
      "tracker": ["transition": transition, "trackingOutcome": tracking, "resetReasons": []]
    ]
    if let facts {
      value["requestFacts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(facts))
    }
    return try JSONDecoder().decode(
      DocumentLiveGeometryObservation.self,
      from: JSONSerialization.data(withJSONObject: value))
  }
}
