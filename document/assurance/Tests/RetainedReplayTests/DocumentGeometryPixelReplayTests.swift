import CoreMedia
import Foundation
import Testing

@testable import DocumentCaptureApple

@Suite struct DocumentGeometryPixelReplayTests {
  /// Opt-in because the real source pixels remain in the user's local retained evidence export.
  @Test
  func retainedPixelsTraverseProductionAnalyzerAndController() throws {
    let environment = ProcessInfo.processInfo.environment
    let input = try #require(environment["IDENTITY_EVIDENCE_GEOMETRY_REPLAY_MANIFEST"])
    let output = try #require(environment["IDENTITY_EVIDENCE_GEOMETRY_REPLAY_OUTPUT"])
    let scenario = environment["IDENTITY_EVIDENCE_GEOMETRY_REPLAY_SCENARIO"] ?? "v1"
    try #require(["v1", "v2", "v2-restoration"].contains(scenario))
    let configuration: DocumentTiltConfiguration =
      scenario == "v1" ? .provisionalV1 : .provisionalV2
    let bytes = try Data(contentsOf: URL(fileURLWithPath: input))
    let manifest = try JSONDecoder().decode(DocumentGeometryReplayManifest.self, from: bytes)
    try manifest.validate()
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    let analyzer = DocumentFrameAnalyzer(now: { Date() }, 
      configuration: .init(includesAdaptiveCapture: true),
      observationHandler: { _ in }, focusHandler: { _ in }, temporalRecorder: recorder)
    let runID = try begin(analyzer, guide: manifest.guide, configuration: configuration)
    let selected = try replay(manifest, analyzer: analyzer, runID: runID, scenario: scenario)
    analyzer.analysisQueue.sync {
      analyzer.tiltGuidanceTransport.end(runID: runID, reason: .userSkipped)
    }
    let events = sink.events
    verify(events, selected: selected)
    let report = Report(
      scenario: scenario, configuration: configuration.version,
      manifestSHA256: DocumentGeometryReplayManifest.digest(bytes),
      recordingID: manifest.recordingID,
      guide: manifest.guide, guideProvenance: manifest.guideProvenance,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      sources: selected, events: events)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
  }

  private func replay(
    _ manifest: DocumentGeometryReplayManifest, analyzer: DocumentFrameAnalyzer,
    runID: UUID, scenario: String
  ) throws -> [Source] {
    var cadence = DocumentAnalysisCadence()
    var selected: [Source] = []
    for item in manifest.frames {
      let time = DocumentTemporalRecorder.mediaTime(item.frame.timestamp)
      guard cadence.isDue(time) else { continue }
      if scenario == "v2-restoration", selected.count == 12 {
        analyzer.analysisQueue.sync {
          analyzer.tiltGuidanceTransport.end(runID: runID, reason: .userSkipped)
          analyzer.updateGeometryAnalysisMode()
        }
      }
      var analysisMilliseconds = 0.0
      try autoreleasepool {
        let pixels = try manifest.load(item)
        // Production ingress makes its own bounded copy; exercise that same copy before analysis.
        let owned = try #require(cadence.copyIfDue(time) { DocumentAnalysisPixelCopy.copy(pixels) })
        let began = ProcessInfo.processInfo.systemUptime
        analyzer.analysisQueue.sync {
          analyzer.analyzeFrame(owned, presentationTime: time, observedAt: Date())
        }
        analysisMilliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
      }
      selected.append(
        .init(
          sourceIndex: item.sourceIndex, recordID: item.recordID, timestamp: item.frame.timestamp,
          analysisMilliseconds: analysisMilliseconds))
    }
    return selected
  }

  private func begin(
    _ analyzer: DocumentFrameAnalyzer, guide: DocumentCameraGuideRegion,
    configuration: DocumentTiltConfiguration
  ) throws
    -> UUID {
    analyzer.updateGuideRegion(guide, geometryRevision: 1)
    analyzer.ingressQueue.sync {}
    analyzer.analysisQueue.sync {}
    let runID = UUID()
    try analyzer.analysisQueue.sync {
      analyzer.tiltGuidanceTransport.prepare(runID: runID)
      try #require(
        analyzer.tiltGuidanceTransport.begin(runID: runID, configuration: configuration) != nil)
      analyzer.updateGeometryAnalysisMode()
    }
    return runID
  }

  private func verify(_ events: [DocumentJourneyRecordingEvent], selected: [Source]) {
    let geometry = events.compactMap(\.liveGeometry)
    #expect(geometry.count == selected.count)
    #expect(geometry.map(\.captureTimestamp) == selected.map(\.timestamp))
    #expect(geometry.allSatisfy { $0.valid && $0.requestFacts?.isEmpty == false })
    var latest: DocumentLiveGeometryObservation?
    for event in events {
      if let packet = event.liveGeometry { latest = packet }
      if let update = event.tiltGuidance {
        #expect(update.valid)
        if let packet = update.event?.observation { #expect(packet == latest) }
      }
    }
    #expect(events.contains { $0.tiltGuidance?.event?.observation != nil })
  }

  private struct Source: Encodable {
    let sourceIndex: Int
    let recordID: UUID
    let timestamp: DocumentCaptureClockTimestamp
    let analysisMilliseconds: Double
  }

  private struct Report: Encodable {
    let schemaVersion = 1
    let mode = "production_analyzer_local_NV12_replay"
    let limits =
      "Explicit guide for this replay; historical guide unknown. Native macOS Vision, not iPhone acceptance."
    let ingress =
      "Production cadence and pixel copy; serial analysis queue; acquisition/admission/lens/watchdog bypassed."
    let wallTime =
      "observedAt is replay execution time; captureTimestamp preserves the exact retained media timestamp."
    let diagnostics = "Adaptive geometry on; live OCR and previews off."
    let scenario: String
    let configuration: String
    let manifestSHA256: String
    let recordingID: UUID
    let guide: DocumentCameraGuideRegion
    let guideProvenance: String
    let operatingSystem: String
    let sources: [Source]
    let events: [DocumentJourneyRecordingEvent]
  }
}
