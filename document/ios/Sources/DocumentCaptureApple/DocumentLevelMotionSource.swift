import Foundation
import DocumentSDK

/// Advisory motion delivery for a host-owned level. It makes no capture decision.
@MainActor
public final class DocumentLevelMotionSource {
  public private(set) var latestSample: DocumentTemporalMotionSample?

  private let collector: any DocumentLevelMotionCollecting
  private let onSample: @MainActor @Sendable (DocumentTemporalMotionSample?) -> Void
  private var generation: UInt64 = 0
  private var running = false
  private let recording = DocumentMotionRecorder()
  private var recordingSessionID: CaptureSessionID?

  public convenience init(
    onSample: @escaping @MainActor @Sendable (DocumentTemporalMotionSample?) -> Void
  ) {
    self.init(collector: DocumentTemporalMotionCollector(), onSample: onSample)
  }

  init(
    collector: any DocumentLevelMotionCollecting,
    onSample: @escaping @MainActor @Sendable (DocumentTemporalMotionSample?) -> Void
  ) {
    self.collector = collector
    self.onSample = onSample
  }

  public func start() { start(recordingSessionID: nil) }

  func startRecording(sessionID: CaptureSessionID) { start(recordingSessionID: sessionID) }

  func restartRecording() {
    guard running, let recordingSessionID else { return }
    stop()
    startRecording(sessionID: recordingSessionID)
  }

  func finishRecording(photo: CapturedDocumentPhoto, attemptID: UUID) throws -> DocumentMotionEvidence? {
    try recording.finish(photo: photo, expectedAttemptID: attemptID, generation: generation)
  }

  private func start(recordingSessionID: CaptureSessionID?) {
    guard !running else { return }
    generation &+= 1
    let activeGeneration = generation
    running = true
    self.recordingSessionID = recordingSessionID
    if let recordingSessionID {
      recording.begin(sessionID: recordingSessionID, generation: activeGeneration)
      let recording = recording
      collector.startRecordingMotion { [weak self] sample, issue in
        recording.receive(sample, issue: issue, generation: activeGeneration)
        Task { @MainActor [weak self] in
          guard let self, self.running, self.generation == activeGeneration else { return }
          self.latestSample = issue == nil ? sample : nil
          self.onSample(self.latestSample)
        }
      }
    } else {
      collector.startLevelMotion { [weak self] sample in
        guard let self, self.running, self.generation == activeGeneration else { return }
        self.latestSample = sample
        self.onSample(sample)
      }
    }
  }

  public func stop() {
    guard running else { return }
    running = false
    generation &+= 1
    recording.discard()
    recordingSessionID = nil
    collector.stopLevelMotion()
    latestSample = nil
    onSample(nil)
  }
}

/// The adapter keeps platform callbacks outside the level's lifecycle owner.
@MainActor
protocol DocumentLevelMotionCollecting: AnyObject {
  func startLevelMotion(
    handler: @escaping @MainActor @Sendable (DocumentTemporalMotionSample?) -> Void
  )
  func stopLevelMotion()
  func startRecordingMotion(handler: @escaping @Sendable (DocumentTemporalMotionSample?, String?) -> Void)
}

extension DocumentLevelMotionCollecting {
  func startRecordingMotion(handler: @escaping @Sendable (DocumentTemporalMotionSample?, String?) -> Void) {
    startLevelMotion { sample in handler(sample, nil) }
  }
}

extension DocumentTemporalMotionCollector: DocumentLevelMotionCollecting {
  func startLevelMotion(
    handler: @escaping @MainActor @Sendable (DocumentTemporalMotionSample?) -> Void
  ) {
    start { sample, issue in
      Task { @MainActor in handler(issue == nil ? sample : nil) }
    }
  }

  func startRecordingMotion(handler: @escaping @Sendable (DocumentTemporalMotionSample?, String?) -> Void) {
    start(handler: handler)
  }

  func stopLevelMotion() { stop() }
}
