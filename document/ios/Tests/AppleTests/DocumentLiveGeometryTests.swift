import AVFoundation
import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

struct DocumentLiveGeometryTests {
  @Test func analysisWithoutRecorderReportsActualDimensionsAndIngressTime() throws {
    let values = GeometryPacketCollector()
    let analyzer = DocumentFrameAnalyzer(now: { Date() }, 
      configuration: .qualityOnly,
      observationHandler: { _ in }, focusHandler: { _ in }, geometryHandler: values.append)
    let sample = try DocumentJourneyRecordingTests().sample(7)
    let pixels = try #require(CMSampleBufferGetImageBuffer(sample))
    let observedAt = Date(timeIntervalSince1970: 123)
    analyzer.analyzeFrame(
      pixels, presentationTime: CMTime(value: 7, timescale: 1), observedAt: observedAt)
    let packet = try #require(values.values.first)
    #expect(packet.pixelWidth == 32 && packet.pixelHeight == 16)
    #expect(packet.observedAt == observedAt)
    #expect(packet.captureTimestamp.value == 7 && packet.captureTimestamp.timescale == 1)
    #expect(packet.analysisSequence == 1)
    #expect(packet.availability == .guideUnavailable)
    #expect(packet.geometry.quadrilateral == nil)
    #expect(packet.tracker.transition == .reset)
    #expect(packet.tracker.resetReasons == [.sessionStarted])
    #expect(packet.valid)
  }

  @Test func trackerHistoryDistinguishesRefreshLossAndReset() {
    var history = DocumentLiveGeometryHistory()
    let first = packet(history: &history, time: 1, transition: .initialDetection)
    #expect(first.tracker.resetReasons == [.sessionStarted])
    #expect(first.tracker.precedingAnalysisTimestamp == nil)
    let tracked = packet(history: &history, time: 2, transition: .tracked, outcome: .accepted)
    #expect(tracked.tracker.precedingAnalysisTimestamp == first.captureTimestamp)
    #expect(tracked.valid)
    let refreshed = packet(history: &history, time: 3, transition: .periodicDetectionRefresh)
    #expect(refreshed.tracker.precedingAnalysisTimestamp == nil)
    #expect(refreshed.valid)
    let redetected = packet(
      history: &history, time: 4, transition: .trackingLostThenDetected, outcome: .rejected)
    #expect(redetected.tracker.precedingAnalysisTimestamp == nil)
    #expect(redetected.valid)
    history.reset(.clockChanged)
    let reset = packet(history: &history, time: 5, transition: .initialDetection)
    #expect(reset.tracker.resetReasons == [.clockChanged])
    #expect(reset.tracker.precedingAnalysisTimestamp == nil)
    #expect(reset.valid)
    #expect(
      DocumentRegionDetector.transition(hadTrack: true, periodicRefresh: true, detected: true)
        == .periodicDetectionRefresh)
    #expect(
      DocumentRegionDetector.transition(hadTrack: true, periodicRefresh: false, detected: true)
        == .trackingLostThenDetected)
    #expect(
      DocumentRegionDetector.transition(hadTrack: true, periodicRefresh: false, detected: false)
        == .lost)
  }

  @Test func repeatedTimeAndDimensionsInvalidatePredecessor() {
    var history = DocumentLiveGeometryHistory()
    _ = history.prepare(timestamp: timestamp(1), width: 32, height: 16)
    _ = packet(history: &history, time: 1, transition: .initialDetection)
    let resetRequired = history.prepare(timestamp: timestamp(1), width: 64, height: 16)
    #expect(resetRequired)
    let reset = packet(history: &history, time: 1, transition: .initialDetection)
    #expect(Set(reset.tracker.resetReasons) == [.clockDiscontinuity, .bufferDimensionsChanged])
    #expect(reset.tracker.precedingAnalysisTimestamp == nil)
  }

  @Test func reviewDeliveryPrecedesAdmissionAndJournalUsesIdenticalPacket() async throws {
    let owner = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .geometry)
    let values = GeometryPacketCollector()
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    let valid = packet(revision: 4)
    recorder.observeGeometry(valid.geometry, liveGeometry: valid)
    owner.setGeometryObservationHandler(values.append)
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        owner.state.nativeCaptureReady = true
        owner.state.captureAdmissionRequested = false
        owner.state.pendingDiagnosticID = UUID()
        owner.state.geometryRevision = 4
        owner.state.geometryObservationGeneration = 9
        owner.state.temporalRecorder = recorder
        owner.publishLiveGeometry(valid, generation: 8)
        owner.publishLiveGeometry(packet(revision: 3), generation: 9)
        owner.publishLiveGeometry(valid, generation: 9)
        #expect(!owner.state.captureAdmissionEnabled)
        #expect(owner.state.latestQualityObservation == nil)
        continuation.resume()
      }
    }
    #expect(values.values == [valid])
    let event = try #require(sink.events.first { $0.kind == "geometry" })
    #expect(event.liveGeometry == valid)
    #expect(event.geometry == valid.geometry)
    #expect(event.timestamp == valid.captureTimestamp)
    let decoded = try JSONDecoder().decode(
      DocumentJourneyRecordingEvent.self, from: JSONEncoder().encode(event))
    #expect(decoded == event)
  }

  @Test func staleAnalysisRemainsArchivedButCannotReachLiveConsumer() async throws {
    let owner = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .geometry)
    let values = GeometryPacketCollector()
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    owner.setGeometryObservationHandler(values.append)
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        owner.state.nativeCaptureReady = true
        owner.state.geometryRevision = 1
        owner.state.geometryObservationGeneration = 1
        continuation.resume()
      }
    }
    let analyzer = DocumentFrameAnalyzer(now: { Date() }, 
      configuration: .qualityOnly,
      observationHandler: { _ in }, focusHandler: { _ in }, temporalRecorder: recorder,
      geometryHandler: { packet in
        owner.sessionQueue.async { owner.publishLiveGeometry(packet, generation: 1) }
      })
    let sample = try DocumentJourneyRecordingTests().sample(7)
    let pixels = try #require(CMSampleBufferGetImageBuffer(sample))
    analyzer.analyzeFrame(
      pixels, presentationTime: CMTime(value: 7, timescale: 1), observedAt: Date())
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async { continuation.resume() }
    }
    #expect(values.values.isEmpty)
    let retained = try #require(sink.events.first { $0.kind == "geometry" })
    #expect(retained.liveGeometry?.geometryRevision == 0)
    #expect(retained.liveGeometry?.geometry == retained.geometry)
    #expect(retained.liveGeometry?.captureTimestamp == retained.timestamp)
  }

  @Test func newestStreamRejectsOldCallbacksAndRevisionWithoutDroppingRecordedEvents() async {
    let delivery = DocumentGeometryObservationDelivery()
    delivery.activate(generation: 1)
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    for revision in 1...10 {
      let value = packet(revision: UInt64(revision))
      recorder.observeGeometry(value.geometry, liveGeometry: value)
      delivery.yield(value, generation: 1)
    }
    delivery.yield(packet(revision: 9), generation: 1)
    delivery.yield(packet(revision: 100), generation: 0)
    var iterator = delivery.stream.makeAsyncIterator()
    #expect(await iterator.next()?.geometryRevision == 10)
    #expect(sink.events.filter { $0.kind == "geometry" }.count == 10)
    delivery.yield(packet(revision: 11), generation: 1)
    delivery.deactivate()
    delivery.activate(generation: 2)
    delivery.yield(packet(revision: 999), generation: 1)
    delivery.yield(packet(revision: 1), generation: 2)
    var nextSession = delivery.stream.makeAsyncIterator()
    #expect(await nextSession.next()?.geometryRevision == 1)
    delivery.finish()
  }

  @Test func busyOwnerMailboxCoalescesAndNeverRegressesSession() {
    let mailbox = DocumentGeometryObservationMailbox()
    #expect(mailbox.offer(packet(revision: 1), generation: 2))
    for revision in 2...100 {
      #expect(!mailbox.offer(packet(revision: UInt64(revision)), generation: 2))
    }
    #expect(!mailbox.offer(packet(revision: 999), generation: 1))
    let newest = mailbox.take()
    #expect(newest?.packet.geometryRevision == 100)
    #expect(newest?.generation == 2)
    #expect(mailbox.take() == nil)
    #expect(mailbox.offer(packet(revision: 101), generation: 2))
  }

  @Test func nativeClockIdentityChangeFencesSameMediaEpoch() async throws {
    let owner = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .geometry)
    let values = GeometryPacketCollector()
    let analyzer = DocumentFrameAnalyzer(now: { Date() }, 
      configuration: .qualityOnly,
      observationHandler: { _ in }, focusHandler: { _ in }, geometryHandler: values.append)
    let sample = try DocumentJourneyRecordingTests().sample(1)
    let pixels = try #require(CMSampleBufferGetImageBuffer(sample))
    analyzer.analyzeFrame(
      pixels, presentationTime: CMTime(value: 1, timescale: 30), observedAt: Date())
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        owner.state.frameAnalyzer = analyzer
        owner.state.nativeCaptureReady = true
        owner.resetGeometryObservationEpoch(reason: .clockChanged)
        analyzer.ingressQueue.async {
          analyzer.analysisQueue.async { continuation.resume() }
        }
      }
    }
    analyzer.analyzeFrame(
      pixels, presentationTime: CMTime(value: 2, timescale: 30), observedAt: Date())
    let previous = try #require(values.values.first)
    let current = try #require(values.values.last)
    #expect(previous.captureTimestamp.epoch == current.captureTimestamp.epoch)
    #expect(current.geometryRevision > previous.geometryRevision)
    #expect(current.tracker.resetReasons == [.clockChanged])
    #expect(current.tracker.precedingAnalysisTimestamp == nil)
    let delivered = GeometryPacketCollector()
    owner.setGeometryObservationHandler(delivered.append)
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        owner.publishLiveGeometry(previous, generation: 0)
        owner.publishLiveGeometry(current, generation: 0)
        continuation.resume()
      }
    }
    #expect(delivered.values == [current])
  }

  @MainActor @Test func unsupportedControllerFinishesOptionalStream() async throws {
    let camera = makeCamera(permissionState: .authorized, controller: StubCameraSessionController())
    var iterator = camera.geometryObservations.makeAsyncIterator()
    #expect(await iterator.next() == nil)
    camera.stop()
    var afterStop = camera.geometryObservations.makeAsyncIterator()
    #expect(await afterStop.next() == nil)
  }

  @Test func legacyDecodeAndMalformedMetadata() throws {
    let legacy = Data(#"{"kind":"geometry","hostTimeSeconds":1}"#.utf8)
    #expect(
      try JSONDecoder().decode(DocumentJourneyRecordingEvent.self, from: legacy).liveGeometry == nil
    )
    let good = packet()
    #expect(good.valid)
    var json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
    json["pixelWidth"] = 0
    let malformed = try JSONDecoder().decode(
      DocumentLiveGeometryObservation.self,
      from: JSONSerialization.data(withJSONObject: json))
    #expect(!malformed.valid)
    json["pixelWidth"] = 32
    json["availability"] = "guideUnavailable"
    #expect(
      try !JSONDecoder().decode(
        DocumentLiveGeometryObservation.self,
        from: JSONSerialization.data(withJSONObject: json)
      ).valid)
  }
}

extension DocumentLiveGeometryTests {
  private func timestamp(_ value: Int64) -> DocumentCaptureClockTimestamp {
    .init(
      value: value, timescale: 30, flags: 1, epoch: 0, clock: .captureSessionSynchronizationClock)
  }

  private func packet(revision: UInt64 = 0) -> DocumentLiveGeometryObservation {
    var history = DocumentLiveGeometryHistory()
    return packet(history: &history, time: 1, transition: .initialDetection, revision: revision)
  }

  private func packet(
    history: inout DocumentLiveGeometryHistory, time: Int64,
    transition: DocumentLiveGeometryObservation.Transition,
    outcome: DocumentLiveGeometryObservation.TrackingOutcome = .notAttempted, revision: UInt64 = 0
  ) -> DocumentLiveGeometryObservation {
    let geometry = DocumentTemporalGeometry(
      quadrilateral: .init(
        topLeft: .init(x: 0.1, y: 0.2), topRight: .init(x: 0.9, y: 0.2),
        bottomRight: .init(x: 0.9, y: 0.8), bottomLeft: .init(x: 0.1, y: 0.8)),
      observationTimestamp: timestamp(time),
      coordinateSpace: "normalized_delivered_video_buffer_top_left",
      status: "observed", confidence: 0.8,
      method: transition == .tracked ? "VNTrackRectangleRequest" : "VNDetectRectanglesRequest")
    return history.packet(
      geometry: geometry,
      analysis: .init(
        width: 32, height: 16, sequence: UInt64(time), revision: revision,
        observedAt: Date(timeIntervalSince1970: 123)),
      availability: .observed, tracking: (transition, outcome), requestRevision: 1)
  }
}

private final class GeometryPacketCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DocumentLiveGeometryObservation] = []
  var values: [DocumentLiveGeometryObservation] { lock.withLock { storage } }
  func append(_ value: DocumentLiveGeometryObservation) { lock.withLock { storage.append(value) } }
}
