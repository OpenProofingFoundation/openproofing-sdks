import Foundation
import Testing

@testable import DocumentCaptureApple

@Suite struct DocumentTiltGuidanceTransportTests {
  @Test func archivesEveryOrderedSampleBeforeLatestOnlyPresentation() async throws {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    let delivery = DocumentTiltGuidanceDelivery()
    let runID = UUID()
    delivery.activate(generation: 1)
    delivery.begin(runID: runID)
    let stream = delivery.stream
    let transport = DocumentTiltGuidanceTransport(recorder: recorder) {
      #expect(sink.events.last?.tiltGuidance?.presentation == $0)
      delivery.yield($0, generation: 1)
    }
    transport.prepare(runID: runID)
    #expect(transport.begin(runID: runID, configuration: .provisionalV1, hostSeconds: 0) != nil)
    let packets = (1...8).map { tiltTransportPacket(sequence: UInt64($0)) }
    for packet in packets {
      transport.consume(packet, hostSeconds: Double(packet.analysisSequence))
    }
    let events = sink.events.filter { $0.kind == "tilt_guidance" }
    #expect(events.count == packets.count + 1)
    #expect(events.compactMap { $0.tiltGuidance?.event?.observation } == packets)
    #expect(events.compactMap(\.timestamp) == packets.map(\.captureTimestamp))
    #expect(events.allSatisfy { $0.tiltGuidance?.valid == true && $0.liveGeometry == nil })
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == events.last?.tiltGuidance?.presentation)
    transport.end(runID: runID, reason: .userSkipped)
    #expect(await iterator.next()?.phase == .skipped)
    let count = sink.events.count
    transport.end(runID: runID, reason: .cancelled)
    transport.consume(tiltTransportPacket(sequence: 9), hostSeconds: 9)
    #expect(sink.events.count == count)
  }

  @Test func pendingEndAndSynchronousInvalidationCannotCreditLateObservations() {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    let transport = DocumentTiltGuidanceTransport(recorder: recorder) { _ in }
    let runID = UUID()
    transport.prepare(runID: runID)
    transport.invalidate(runID: runID, reason: .userSkipped)
    // Public begin-failure cleanup can arrive before the queued controller begin.
    transport.invalidate(runID: runID, reason: .cancelled)
    #expect(transport.begin(runID: runID, configuration: .provisionalV1, hostSeconds: 0) == nil)
    transport.consume(tiltTransportPacket(sequence: 1), hostSeconds: 1)
    #expect(sink.events.count == 2)
    #expect(sink.events.last?.tiltGuidance?.presentation.reason == .userSkipped)
    #expect(sink.events.allSatisfy { $0.tiltGuidance?.event?.observation == nil })
    transport.end(runID: runID, reason: .cancelled)
    #expect(sink.events.count == 2)
    #expect(sink.events.last?.tiltGuidance?.presentation.reason == .userSkipped)
  }

  @Test func firstInvalidationAlsoWinsWhenControllerAlreadyExists() {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    let transport = DocumentTiltGuidanceTransport(recorder: recorder) { _ in }
    let runID = UUID()
    transport.prepare(runID: runID)
    _ = transport.begin(runID: runID, configuration: .provisionalV1, hostSeconds: 0)
    transport.invalidate(runID: runID, reason: .clockChanged)
    transport.invalidate(runID: runID, reason: .cancelled)
    transport.end(runID: runID, reason: .cancelled)
    #expect(sink.events.count == 2)
    #expect(sink.events.last?.tiltGuidance?.presentation.reason == .clockChanged)
  }

  @Test func staleEndDoesNotCancelReplacementOrItsStream() async {
    let delivery = DocumentTiltGuidanceDelivery()
    delivery.activate(generation: 1)
    let first = UUID()
    let replacement = UUID()
    let transport = DocumentTiltGuidanceTransport(recorder: nil) {
      delivery.yield($0, generation: 1)
    }
    transport.prepare(runID: first)
    delivery.begin(runID: first)
    let old = transport.begin(runID: first, configuration: .provisionalV1, hostSeconds: 0)
    transport.end(runID: first, reason: .cancelled)
    transport.prepare(runID: replacement)
    delivery.begin(runID: replacement)
    _ = transport.begin(runID: replacement, configuration: .provisionalV1, hostSeconds: 0)
    transport.end(runID: first, reason: .sessionStopped)
    if let old { delivery.yield(old, generation: 1) }
    transport.consume(tiltTransportPacket(sequence: 1), hostSeconds: 1)
    var iterator = delivery.stream.makeAsyncIterator()
    let current = await iterator.next()
    #expect(current?.runID == replacement && current?.phase == .baseline)
    delivery.deactivate()
    #expect(await iterator.next() == nil)
    delivery.activate(generation: 2)
    delivery.begin(runID: replacement)
    var replacementStream = delivery.stream.makeAsyncIterator()
    if let current { delivery.yield(current, generation: 1) }
    delivery.deactivate()
    #expect(await replacementStream.next() == nil)
  }

  @MainActor @Test func unsupportedCameraHasFinishedGuidanceStream() async throws {
    let camera = makeCamera(permissionState: .authorized, controller: StubCameraSessionController())
    var stream = camera.tiltGuidanceUpdates.makeAsyncIterator()
    #expect(await stream.next() == nil)
    try await camera.start()
    await expectError(.cameraNotReady) { _ = try await camera.beginTiltGuidance(runID: UUID()) }
    camera.stop()
  }

  @Test func legacyEventsDecodeWithoutGuidance() throws {
    let bytes = Data(#"{"kind":"geometry","hostTimeSeconds":1}"#.utf8)
    #expect(
      try JSONDecoder().decode(DocumentJourneyRecordingEvent.self, from: bytes).tiltGuidance == nil)
  }
}

func tiltTransportPacket(sequence: UInt64) -> DocumentLiveGeometryObservation {
  let time = DocumentCaptureClockTimestamp(
    value: Int64(sequence), timescale: 5, flags: 1, epoch: 0,
    clock: .captureSessionSynchronizationClock)
  return .init(
    schemaVersion: 1, observedAt: Date(),
    geometry: .init(
      quadrilateral: nil, observationTimestamp: time,
      coordinateSpace: "normalized_delivered_video_buffer_top_left",
      status: "analyzed_no_accepted_rectangle", confidence: nil, method: nil),
    pixelWidth: 1320, pixelHeight: 1760, analysisSequence: sequence, geometryRevision: 0,
    availability: .noAcceptedRectangle, requestRevision: nil,
    tracker: .init(
      transition: .unavailable, trackingOutcome: .notAttempted,
      precedingAnalysisTimestamp: nil, resetReasons: []))
}
