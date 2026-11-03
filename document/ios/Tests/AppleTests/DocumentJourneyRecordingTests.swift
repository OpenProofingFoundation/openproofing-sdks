import AVFoundation
import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

struct DocumentJourneyRecordingTests {
  @Test func continuousSinkReceivesFramesAcrossStillBufferReset() throws {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    defer { recorder.stop() }
    recorder.append(try sample(1), geometry: nil, rotationDegrees: 90, mirrored: false)
    recorder.beginCapture()
    recorder.abandonCapture()
    recorder.append(try sample(2), geometry: nil, rotationDegrees: 90, mirrored: false)
    #expect(sink.frameCount == 2)
    #expect(recorder.buffer.frames.isEmpty)
    #expect(sink.reservationsMade == 2)
    #expect(sink.reservations.isEmpty)
  }

  @Test func rejectionDoesNotAllocateOrPublishFrame() throws {
    let sink = RecordingSink()
    sink.acceptFrames = false
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    defer { recorder.stop() }
    recorder.append(try sample(1), geometry: nil, rotationDegrees: 0, mirrored: false)
    #expect(sink.frameCount == 0)
    #expect(sink.events.contains { $0.kind == "frame_admission_failed" && $0.timestamp != nil })
  }

  @Test func stopPreventsFramesAndClockChangesArePreserved() throws {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    recorder.clockDidChange(to: nil)
    recorder.append(try sample(1), geometry: nil, rotationDegrees: 0, mirrored: false)
    recorder.stop()
    recorder.append(try sample(2), geometry: nil, rotationDegrees: 0, mirrored: false)
    #expect(sink.frameCount == 1)
    #expect(sink.events.contains { $0.kind == "clock_changed" })
    #expect(sink.events.contains { $0.kind == "session_stopped" })
  }

  @Test func lateSinkStartsObservationButStoppedSessionCannotRestartFromAttachment() throws {
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.start(clock: CMClockGetHostTimeClock())
    let sink = RecordingSink()
    recorder.setJourneySink(sink)
    recorder.append(try sample(1), geometry: nil, rotationDegrees: 0, mirrored: false)
    recorder.stop()
    recorder.setJourneySink(sink)
    recorder.append(try sample(2), geometry: nil, rotationDegrees: 0, mirrored: false)
    #expect(sink.frameCount == 1)
  }

  @Test func laterGeometryBindsExactFrameWithoutReplacingPixels() throws {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init(enabled: true))
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    defer { recorder.stop() }
    recorder.append(try sample(1), geometry: nil, rotationDegrees: 0, mirrored: false)
    let original = try #require(recorder.buffer.frames.first)
    let geometry = DocumentTemporalGeometry(
      quadrilateral: nil,
      observationTimestamp: original.metadata.timestamp, coordinateSpace: "fixture",
      status: "analyzed_no_accepted_rectangle", confidence: nil, method: "fixture")
    recorder.observeGeometry(geometry)
    #expect(recorder.buffer.frames.first?.payload == original.payload)
    #expect(recorder.buffer.frames.first?.metadata.geometry == geometry)
    #expect(sink.frameCount == 1)
    #expect(sink.events.contains { $0.geometry == geometry })
  }

  /// The journal gets at most one frame per `DocumentJourneyPacing` interval;
  /// the ring, which decides capture quality, still gets every frame. The
  /// journal records which pacing produced it.
  @Test func journeyFramesArePacedWhileTheRingSeesEveryFrame() throws {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init(enabled: true))
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    defer { recorder.stop() }
    // 0.0 s, 0.1 s, 0.2 s, then 0.6 s: only the first and the last are due.
    for tenths in [0, 1, 2, 6] as [Int64] {
      recorder.append(
        try sample(tenths, timescale: 10), geometry: nil, rotationDegrees: 0, mirrored: false)
    }
    #expect(sink.frameCount == 2)
    #expect(recorder.buffer.frames.count == 4)
    #expect(!sink.events.contains { $0.contextCode == "frame_clock_discontinuity" })
    #expect(sink.events.contains {
      $0.kind == "session_started"
        && $0.contextCode == DocumentJourneyPacing.engineering20260922.identifier
    })
  }

  @Test func repeatedFrameTimestampRetainsPixelsAndRecordsDiscontinuity() throws {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    defer { recorder.stop() }
    for _ in 0..<2 {
      recorder.append(try sample(1), geometry: nil, rotationDegrees: 0, mirrored: false)
    }
    #expect(sink.frameCount == 2)
    #expect(sink.events.contains { $0.contextCode == "frame_clock_discontinuity" })
  }

  @Test func nonfiniteMotionCannotPoisonJournalAndFiniteDisorderRemainsExplicit() {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    let zero = DocumentTemporalVector3(x: 0, y: 0, z: 0)
    for time in [Double.nan, 2, 1] {
      let motion = DocumentTemporalMotionSample(
        bootTimeSeconds: time,
        attitude: .init(x: 0, y: 0, z: 0, w: 1), rotationRate: zero, gravity: zero,
        userAcceleration: zero, referenceFrame: "fixture")
      recorder.withState { recorder.retainMotion(motion) }
    }
    #expect(sink.motionCount == 2)
    #expect(sink.events.contains { $0.contextCode == "nonfinite_motion_sample_not_serializable" })
    #expect(sink.events.contains { $0.contextCode == "motion_clock_discontinuity" })
  }

  @Test func sessionFailureIsNotAnOrdinaryConfigurationChange() throws {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    recorder.append(try sample(1), geometry: nil, rotationDegrees: 0, mirrored: false)
    recorder.sessionFailed(reason: AVCaptureSession.runtimeErrorNotification.rawValue)
    recorder.append(try sample(2), geometry: nil, rotationDegrees: 0, mirrored: false)
    #expect(sink.frameCount == 1)
    #expect(sink.events.contains { $0.kind == "session_issue" })
    #expect(!sink.events.contains { $0.kind == "configuration_changed" })
    #expect(!recorder.running)
    #expect(recorder.inactiveReason == "session_failed")
  }

  @Test func disabledWindowDeliveryKeepsContinuousStillBindingWithoutOptionalWindow() throws {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    defer { recorder.stop() }
    recorder.beginCapture()
    let photo = deliveryPhoto()
    let evidence = recorder.finishForDelivery(photo)
    #expect(evidence == nil)
    #expect(!recorder.pinned)
    #expect(
      sink.events.contains {
        $0.kind == "still_capture" && $0.binding?.stillSHA256 == photo.fidelity.sha256
          && $0.binding?.stillTimestamp == photo.captureTimestamp
      })
  }

  @Test func enabledWindowDeliveryRetainsOptionalEvidence() {
    let recorder = DocumentTemporalRecorder(configuration: .init(enabled: true))
    recorder.start(clock: CMClockGetHostTimeClock())
    defer { recorder.stop() }
    recorder.beginCapture()
    let photo = deliveryPhoto()
    let evidence = recorder.finishForDelivery(photo)
    #expect(evidence?.manifest.configuration.enabled == true)
    #expect(evidence?.manifest.binding.stillSHA256 == photo.fidelity.sha256)
    #expect(!recorder.pinned)
  }

  private func deliveryPhoto() -> CapturedDocumentPhoto {
    CapturedDocumentPhoto(
      sessionID: CaptureSessionID(), side: .front, requestedAt: Date(),
      captureTimestamp: .init(
        value: 1, timescale: 1, flags: 1, epoch: 0,
        clock: .captureSessionSynchronizationClock),
      processedAt: Date(), data: Data([1]),
      fidelity: PhotoFidelityMetadata(
        pixelWidth: 32, pixelHeight: 16, fileByteCount: 1, uniformTypeIdentifier: "public.heic",
        orientation: 1, cameraModel: nil, lensModel: nil, exposureTimeSeconds: nil,
        fNumber: nil, isoSpeed: nil, sha256: String(repeating: "a", count: 64), optical: nil),
      admission: nil)
  }

  func sample(_ value: Int64, timescale: Int32 = 1) throws -> CMSampleBuffer {
    var pixels: CVPixelBuffer?
    #expect(
      CVPixelBufferCreate(
        kCFAllocatorDefault, 32, 16,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pixels) == kCVReturnSuccess)
    let buffer = try #require(pixels)
    var format: CMVideoFormatDescription?
    #expect(
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(value: value, timescale: timescale), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer, formatDescription: try #require(format), sampleTiming: &timing,
        sampleBufferOut: &sample) == noErr)
    return try #require(sample)
  }
}

final class RecordingSink: DocumentJourneyRecordingSink, @unchecked Sendable {
  private let lock = NSLock()
  private var accepts = true
  private var reservationTotal = 0
  private var activeReservations: Set<UUID> = []
  private var frames = 0
  private var motions = 0
  private var retainedEvents: [DocumentJourneyRecordingEvent] = []
  var acceptFrames: Bool {
    get { lock.withLock { accepts } }
    set { lock.withLock { accepts = newValue } }
  }
  var reservationsMade: Int { lock.withLock { reservationTotal } }
  var reservations: Set<UUID> { lock.withLock { activeReservations } }
  var motionCount: Int { lock.withLock { motions } }
  var frameCount: Int { lock.withLock { frames } }
  var events: [DocumentJourneyRecordingEvent] { lock.withLock { retainedEvents } }

  func reserveFrame(byteCount: Int) -> UUID? {
    lock.withLock {
      guard accepts else { return nil }
      let token = UUID()
      activeReservations.insert(token)
      reservationTotal += 1
      return token
    }
  }

  func appendFrame(_ frame: DocumentTemporalFrame, reservation: UUID) {
    lock.withLock {
      #expect(activeReservations.remove(reservation) != nil)
      #expect(frame.payload.count == 768)
      frames += 1
    }
  }

  func cancelReservation(_ reservation: UUID, reason: String) {
    _ = lock.withLock { activeReservations.remove(reservation) }
  }

  func appendMotion(_ sample: DocumentTemporalMotionSample) { lock.withLock { motions += 1 } }
  func appendEvent(_ event: DocumentJourneyRecordingEvent) {
    lock.withLock { retainedEvents.append(event) }
  }
  func finish(reason: String) async throws -> DocumentJourneyRecordingReceipt {
    .init(recordingID: UUID(), status: "fixture", frameCount: frameCount, motionSampleCount: 0)
  }
}
