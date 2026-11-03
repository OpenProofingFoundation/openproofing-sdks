import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Testing

@testable import DocumentCaptureApple

@Suite(.serialized) struct DocumentFreshDetectionPixelTests {
  @Test func staticRasterCannotCompleteAndEndingRestoresOrdinaryTracking() throws {
    let fixture = try Trial()
    try fixture.send(Array(repeating: 0, count: 12))
    let values = fixture.sink.events.compactMap(\.liveGeometry)
    #expect(values.count == 12 && values.allSatisfy { $0.valid && $0.schemaVersion == 2 })
    #expect(values.allSatisfy { $0.tracker.transition == .freshDetection })
    #expect(
      values.allSatisfy { $0.requestFacts?.contains { $0.stage == .rectangleTracking } == false })
    #expect(fixture.sink.events.last?.tiltGuidance?.presentation.phase == .leftEdgeCloser)
    fixture.end()
    try fixture.send([0, 0])
    let restored = fixture.sink.events.compactMap(\.liveGeometry).suffix(2)
    #expect(restored.allSatisfy { $0.schemaVersion == 1 && $0.analysisMode == nil })
    #expect(restored.first?.tracker.resetReasons.contains(.analysisModeChanged) == true)
    #expect(restored.last?.requestFacts?.contains { $0.stage == .rectangleTracking } == true)
  }

  @Test func syntheticProjectionTraversesProductionVisionAndOrderedController() throws {
    let fixture = try Trial(guide: .init(minX: 0.2, minY: 0.2, width: 0.6, height: 0.6))
    try fixture.send(Array(repeating: 0, count: 8))
    try fixture.send([-0.04, -0.08, -0.12, -0.16] + Array(repeating: -0.16, count: 4))
    try fixture.send([-0.12, -0.08, -0.04, 0] + Array(repeating: 0, count: 4))
    try fixture.send([0.04, 0.08, 0.12, 0.16] + Array(repeating: 0.16, count: 4))
    try fixture.send([0.12, 0.08, 0.04, 0] + Array(repeating: 0, count: 4))
    let events = fixture.sink.events.compactMap(\.tiltGuidance)
    #expect(events.allSatisfy { $0.valid })
    #expect(events.last?.presentation.phase == .readyForStill)
    #expect(
      Set(events.map(\.presentation.phase)).isSuperset(of: [
        .baseline, .leftEdgeCloser,
        .neutralAfterLeft, .rightEdgeCloser, .neutralAfterRight, .readyForStill,
      ]))
    try fixture.writeIfRequested("projective-positive")
  }

  @Test func oversizedCardIsAvailableForReframingOnlyOutsideMovement() throws {
    let fixture = try Trial(guide: .init(minX: 0.35, minY: 0.4, width: 0.3, height: 0.2))
    try fixture.send([0])
    let movement = try #require(
      fixture.sink.events.last(where: { $0.liveGeometry != nil })?.liveGeometry)
    #expect(movement.analysisMode == .freshDetection)
    #expect(movement.availability == .noAcceptedRectangle)
    #expect(movement.geometry.quadrilateral == nil)
    fixture.end()
    try fixture.send([0])
    let packet = try #require(
      fixture.sink.events.last(where: { $0.liveGeometry != nil })?.liveGeometry)
    #expect(packet.availability == .observed)
    #expect(packet.geometry.method == "VNDetectRectanglesRequest")
    #expect(packet.requestFacts?.first?.stage == .documentSegmentation)
    #expect(packet.requestFacts?.first?.result != .accepted)
    #expect(packet.requestFacts?.last?.stage == .rectangleDetection)
    #expect(packet.requestFacts?.last?.result == .accepted)
  }

  @Test func translationOnlyRasterCannotEarnPerspectiveExcursion() throws {
    let fixture = try Trial()
    try fixture.send(Array(repeating: 0, count: 8))
    for index in 1...16 { try fixture.send([0], horizontalOffset: Double(index) * 3) }
    let events = fixture.sink.events.compactMap(\.tiltGuidance)
    #expect(
      !events.contains {
        $0.presentation.phase == .neutralAfterLeft || $0.presentation.phase == .readyForStill
      })
    try fixture.writeIfRequested("translation-negative")
  }

  @Test func missingRasterAndWrongDirectionCannotComplete() throws {
    let fixture = try Trial()
    try fixture.send(Array(repeating: 0, count: 8))
    try fixture.send([0.04, 0.08, 0.12, 0.16] + Array(repeating: 0.16, count: 4))
    #expect(fixture.sink.events.last?.tiltGuidance?.presentation.phase == .leftEdgeCloser)
    try fixture.send([nil, nil, nil])
    #expect(fixture.sink.events.last?.tiltGuidance?.presentation.phase == .baseline)
    #expect(
      !fixture.sink.events.compactMap(\.tiltGuidance).contains {
        $0.presentation.phase == .readyForStill
      })
    try fixture.writeIfRequested("projective-negative")
  }
}

private final class Trial {
  let sink = RecordingSink()
  let analyzer: DocumentFrameAnalyzer
  let pixels: DocumentSyntheticPerspectivePixels
  let runID = UUID()
  var sequence: Int64 = 0
  private struct Input: Encodable {
    let sequence: Int64
    let captureTimestamp: DocumentCaptureClockTimestamp
    let projectedLogRatio: Double?
    let horizontalOffsetPixels: Double
  }
  private var inputs: [Input] = []

  init(guide: DocumentCameraGuideRegion = .init(minX: 0, minY: 0, width: 1, height: 1)) throws {
    pixels = try .init()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    analyzer = .init(
      now: { Date() },
      configuration: .init(includesAdaptiveCapture: true),
      observationHandler: { _ in }, focusHandler: { _ in }, temporalRecorder: recorder)
    analyzer.updateGuideRegion(guide, geometryRevision: 1)
    analyzer.ingressQueue.sync {}
    try analyzer.analysisQueue.sync {
      analyzer.tiltGuidanceTransport.prepare(runID: runID)
      try #require(
        analyzer.tiltGuidanceTransport.begin(runID: runID, configuration: .provisionalV2) != nil)
      analyzer.updateGeometryAnalysisMode()
    }
  }

  func send(_ values: [Double?], horizontalOffset: Double = 0) throws {
    for value in values {
      sequence += 1
      let buffer = try pixels.pixels(logRatio: value, horizontalOffset: horizontalOffset)
      let owned = try #require(DocumentAnalysisPixelCopy.copy(buffer))
      inputs.append(
        .init(
          sequence: sequence,
          captureTimestamp: .init(
            value: sequence, timescale: 5, flags: 1, epoch: 0,
            clock: .captureSessionSynchronizationClock), projectedLogRatio: value,
          horizontalOffsetPixels: horizontalOffset))
      analyzer.analysisQueue.sync {
        analyzer.analyzeFrame(
          owned, presentationTime: CMTime(value: sequence, timescale: 5),
          observedAt: Date(timeIntervalSince1970: Double(sequence) / 5))
      }
    }
  }

  func end() {
    analyzer.analysisQueue.sync {
      analyzer.tiltGuidanceTransport.end(runID: runID, reason: .userSkipped)
      analyzer.updateGeometryAnalysisMode()
    }
  }

  func writeIfRequested(_ name: String) throws {
    guard
      let directory = ProcessInfo.processInfo.environment[
        "IDENTITY_EVIDENCE_GEOMETRY_SYNTHETIC_OUTPUT"]
    else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let root = URL(fileURLWithPath: directory)
    try encoder.encode(sink.events).write(to: root.appendingPathComponent(name + ".json"))
    try encoder.encode(inputs).write(to: root.appendingPathComponent(name + "-inputs.json"))
    if name == "projective-positive" { try writeRepresentativeImages(root) }
  }

  private func writeRepresentativeImages(_ root: URL) throws {
    let examples: [(String, Double?)] = [
      ("neutral", 0), ("left", -0.16), ("right", 0.16), ("blank", nil),
    ]
    for (name, ratio) in examples {
      let buffer = try pixels.pixels(logRatio: ratio)
      let image = try #require(
        pixels.context.createCGImage(CIImage(cvPixelBuffer: buffer), from: pixels.bounds))
      let url = root.appendingPathComponent("synthetic-" + name + ".png")
      let destination = try #require(
        CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      try #require(CGImageDestinationFinalize(destination))
    }
  }
}
