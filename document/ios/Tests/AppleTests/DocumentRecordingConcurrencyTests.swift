import AVFoundation
import Foundation
import Testing

@testable import DocumentCaptureApple

struct DocumentRecordingConcurrencyTests {
  @Test func blockedCopyDoesNotBlockStopAndLateCopyCancelsReservation() async throws {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    let recorder = DocumentTemporalRecorder(
      configuration: .init(),
      pixelCopier: { pixels, bytes in
        entered.signal()
        _ = release.wait(timeout: .now() + 3)
        return try DocumentTemporalPixelCopy.copy(pixels, maximumBytes: bytes)
      })
    let sink = RecordingSink()
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    let sample = SampleBox(try DocumentJourneyRecordingTests().sample(1))
    DispatchQueue.global().async {
      recorder.append(sample.value, geometry: nil, rotationDegrees: 0, mirrored: false)
      completed.signal()
    }
    #expect(await waitForDocumentTestSemaphore(entered, timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
      recorder.stop()
      stopped.signal()
    }
    let stopFinished = await waitForDocumentTestSemaphore(stopped, timeout: .now() + 0.5)
    release.signal()
    #expect(stopFinished == .success)
    #expect(await waitForDocumentTestSemaphore(completed, timeout: .now() + 2) == .success)
    #expect(sink.frameCount == 0)
    #expect(sink.reservations.isEmpty)
    #expect(sink.events.contains { $0.kind == "frame_copy_cancelled" })
  }

  @Test func detachWaitsForAdmittedCopyAndResolvesItsReservation() async throws {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let detached = DispatchSemaphore(value: 0)
    let recorder = DocumentTemporalRecorder(
      configuration: .init(),
      pixelCopier: { pixels, bytes in
        entered.signal()
        _ = release.wait(timeout: .now() + 3)
        return try DocumentTemporalPixelCopy.copy(pixels, maximumBytes: bytes)
      })
    let sink = RecordingSink()
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    defer { recorder.stop() }
    let owner = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .geometry)
    let analyzer = DocumentFrameAnalyzer(now: { Date() }, 
      configuration: .qualityOnly,
      observationHandler: { _ in }, focusHandler: { _ in }, temporalRecorder: recorder)
    owner.sessionQueue.sync {
      owner.state.temporalRecorder = recorder
      owner.state.frameAnalyzer = analyzer
    }
    let sample = SampleBox(try DocumentJourneyRecordingTests().sample(1))
    analyzer.ingressQueue.async {
      recorder.append(sample.value, geometry: nil, rotationDegrees: 0, mirrored: false)
    }
    #expect(await waitForDocumentTestSemaphore(entered, timeout: .now() + 2) == .success)
    owner.detachJourneyRecordingSink { detached.signal() }
    #expect(await waitForDocumentTestSemaphore(detached, timeout: .now() + 0.05) == .timedOut)
    release.signal()
    #expect(await waitForDocumentTestSemaphore(detached, timeout: .now() + 2) == .success)
    #expect(sink.frameCount == 1)
    #expect(sink.reservations.isEmpty)
    #expect(recorder.withState { recorder.journeySink == nil })
  }

  @Test func directDetachWaitsForFrameCopyOutsideIngressBarrier() async throws {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let detached = DispatchSemaphore(value: 0)
    let recorder = DocumentTemporalRecorder(configuration: .init(), pixelCopier: { pixels, bytes in
      entered.signal()
      _ = release.wait(timeout: .now() + 3)
      return try DocumentTemporalPixelCopy.copy(pixels, maximumBytes: bytes)
    })
    let sink = RecordingSink()
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    defer { recorder.stop() }
    let sample = SampleBox(try DocumentJourneyRecordingTests().sample(1))
    DispatchQueue.global().async {
      recorder.append(sample.value, geometry: nil, rotationDegrees: 0, mirrored: false)
    }
    #expect(await waitForDocumentTestSemaphore(entered, timeout: .now() + 2) == .success)
    recorder.detachJourneySink { detached.signal() }
    let early = await waitForDocumentTestSemaphore(detached, timeout: .now() + 0.05)
    release.signal()
    #expect(early == .timedOut)
    if early == .timedOut {
      #expect(await waitForDocumentTestSemaphore(detached, timeout: .now() + 2) == .success)
    }
    #expect(sink.reservations.isEmpty)
  }

  @Test func sinkCanReenterRecorderDuringEventAndReservation() throws {
    let recorder = DocumentTemporalRecorder(configuration: .init())
    let sink = ReentrantSink(recorder: recorder)
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    recorder.append(
      try DocumentJourneyRecordingTests().sample(1), geometry: nil, rotationDegrees: 0,
      mirrored: false)
    #expect(sink.recorderWasUnlocked)
    recorder.stop()
  }

  @Test func reentrantStopDoesNotRestartMotionOrRepeatStopEvents() {
    let recorder = DocumentTemporalRecorder(configuration: .init())
    let sink = ReentrantSink(recorder: recorder, stopOnEvent: true)
    recorder.setJourneySink(sink)
    recorder.start(clock: CMClockGetHostTimeClock())
    #expect(!recorder.withState { recorder.running })
    #expect(sink.eventCount == 2)
    #expect(sink.recorderWasUnlocked)
  }

  @Test func cadenceRejectsBeforeAnalysisCopyAndResetsForNewEpoch() {
    var cadence = DocumentAnalysisCadence()
    var copies = 0
    for value in [0.0, 0.001, 0.002] {
      let time = CMTime(seconds: value, preferredTimescale: 1000)
      _ = cadence.copyIfDue(time) {
        copies += 1
        return true
      }
    }
    #expect(copies == 1)
    cadence.reset()
    #expect(cadence.isDue(CMTime(value: 2, timescale: 1000)))
    #expect(!cadence.isDue(.invalid))
    let time = CMTime(value: 2, timescale: 1000)
    let failedCopy: Bool? = cadence.copyIfDue(time) { nil }
    #expect(failedCopy == nil)
    #expect(cadence.isDue(time))
  }
}

private final class SampleBox: @unchecked Sendable {
  let value: CMSampleBuffer
  init(_ value: CMSampleBuffer) { self.value = value }
}

private final class ReentrantSink: DocumentJourneyRecordingSink, @unchecked Sendable {
  let recorder: DocumentTemporalRecorder
  var recorderWasUnlocked = true
  var eventCount = 0
  let stopOnEvent: Bool
  init(recorder: DocumentTemporalRecorder, stopOnEvent: Bool = false) {
    self.recorder = recorder
    self.stopOnEvent = stopOnEvent
  }
  func probe() {
    if recorder.lock.try() {
      recorder.lock.unlock()
      recorder.withState { _ = recorder.running }
    } else {
      recorderWasUnlocked = false
    }
  }
  func reserveFrame(byteCount: Int) -> UUID? {
    probe()
    return UUID()
  }
  func appendFrame(_ frame: DocumentTemporalFrame, reservation: UUID) { probe() }
  func cancelReservation(_ reservation: UUID, reason: String) { probe() }
  func appendMotion(_ sample: DocumentTemporalMotionSample) { probe() }
  func appendEvent(_ event: DocumentJourneyRecordingEvent) {
    probe()
    eventCount += 1
    if stopOnEvent && eventCount < 3 { recorder.stop() }
  }
  func finish(reason: String) async throws -> DocumentJourneyRecordingReceipt {
    .init(recordingID: UUID(), status: reason, frameCount: 0, motionSampleCount: 0)
  }
}
