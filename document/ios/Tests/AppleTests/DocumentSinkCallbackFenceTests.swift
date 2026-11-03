import Foundation
import Testing

@testable import DocumentCaptureApple

struct DocumentSinkCallbackFenceTests {
  @Test func detachWaitsForAdmittedMotionCallbackWithoutHoldingRecorderLock() async {
    let sink = BlockingMotionSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    let zero = DocumentTemporalVector3(x: 0, y: 0, z: 0)
    let sample = DocumentTemporalMotionSample(
      bootTimeSeconds: 1,
      attitude: .init(x: 0, y: 0, z: 0, w: 1), rotationRate: zero, gravity: zero,
      userAcceleration: zero, referenceFrame: "fixture")
    DispatchQueue.global().async { recorder.withState { recorder.retainMotion(sample) } }
    #expect(await waitForDocumentTestSemaphore(sink.entered, timeout: .now() + 2) == .success)
    let detached = DispatchSemaphore(value: 0)
    recorder.detachJourneySink { detached.signal() }
    #expect(await waitForDocumentTestSemaphore(detached, timeout: .now() + 0.05) == .timedOut)
    #expect(recorder.withState { recorder.journeySink == nil })
    sink.release.signal()
    #expect(await waitForDocumentTestSemaphore(detached, timeout: .now() + 2) == .success)
    #expect(recorder.withState { recorder.activeSinkCallbacks.isEmpty })
    #expect(sink.delivered)
  }
}

private final class BlockingMotionSink: DocumentJourneyRecordingSink, @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var didDeliver = false
  var delivered: Bool { lock.withLock { didDeliver } }
  func reserveFrame(byteCount: Int) -> UUID? { nil }
  func appendFrame(_ frame: DocumentTemporalFrame, reservation: UUID) {}
  func cancelReservation(_ reservation: UUID, reason: String) {}
  func appendEvent(_ event: DocumentJourneyRecordingEvent) {}
  func appendMotion(_ sample: DocumentTemporalMotionSample) {
    entered.signal()
    _ = release.wait(timeout: .now() + 3)
    lock.withLock { didDeliver = true }
  }
  func finish(reason: String) async throws -> DocumentJourneyRecordingReceipt {
    .init(recordingID: UUID(), status: reason, frameCount: 0, motionSampleCount: 1)
  }
}
