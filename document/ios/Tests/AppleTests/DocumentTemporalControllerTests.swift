import AVFoundation
import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

struct DocumentTemporalControllerTests {
  @Test func terminalResultWaitsForBoundedTailAndReleasesProcessorOnce() async throws {
    try await exerciseTail(stop: false)
  }

  @Test func stopDuringTailCompletesOnceAndRejectsRestartUntilDelivery() async throws {
    try await exerciseTail(stop: true)
  }

  private func exerciseTail(stop: Bool) async throws {
    let controller = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, 
      configuration: .init(temporalEvidence: .init(enabled: true, postCaptureDuration: 0.1)))
    let probe = TailProbe()
    let identifier: Int64 = 123
    let photo = try makePhoto()
    let began = ContinuousClock.now
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      controller.sessionQueue.async {
        controller.state.temporalRecorder?.start(clock: CMClockGetHostTimeClock())
        controller.state.temporalRecorder?.beginCapture()
        controller.state.processors[identifier] = PhotoCaptureProcessor(
          assembler: CapturedDocumentPhotoAssembler(now: { Date() }),
          admission: Self.admission(photo: photo, identifier: identifier), completion: { _ in })
        controller.completeTemporalCapture(identifier: identifier, result: .success(photo)) { result in
          #expect(controller.state.processors[identifier] == nil)
          if probe.receive(result) { continuation.resume() }
        }
        // Scheduling a tail must keep native-operation exclusion active.
        #expect(controller.state.processors[identifier] != nil)
        if stop {
          controller.stop()
          Self.verifyPendingStop(controller, identifier: identifier, probe: probe)
          controller.start { result in
            if case .failure(.cameraNotReady) = result {
              probe.markRestartRejected()
            } else {
              Issue.record("Restart reached camera configuration during pending tail")
            }
          }
        }
      }
    }
    let elapsed = began.duration(to: .now)
    #expect(elapsed < .seconds(2))
    #expect(probe.count == 1)
    let recorded = try #require(probe.photo)
    #expect(recorded.data == photo.data)
    #expect(recorded.captureTimestamp == photo.captureTimestamp)
    #expect(recorded.temporalEvidence?.manifest.binding.stillSHA256 == photo.fidelity.sha256)
    #expect(recorded.temporalEvidence?.manifest.status == "partial")
    if stop {
      #expect(recorded.temporalEvidence?.manifest.termination == "session_stopped")
      #expect(probe.restartRejected)
      #expect(probe.stopAcknowledged)
    } else {
      #expect(elapsed >= .milliseconds(400))
      #expect(recorded.temporalEvidence?.manifest.termination == "completed")
    }
    // No deferred poll may deliver a second completion after the final one.
    try await Task.sleep(for: .milliseconds(600))
    #expect(probe.count == 1)
    controller.stop()
  }

  private static func verifyPendingStop(
    _ controller: AVFoundationCameraSessionController, identifier: Int64, probe: TailProbe
  ) {
    controller.sessionQueue.async {
      #expect(controller.state.graphReleasePending)
      #expect(controller.state.processors[identifier] != nil)
    }
    controller.afterStop { stopped in
      #expect(stopped)
      #expect(controller.state.processors.isEmpty)
      #expect(controller.state.captureSession.inputs.isEmpty)
      #expect(controller.state.captureSession.outputs.isEmpty)
      probe.markStopAcknowledged()
    }
  }

  private static func admission(
    photo: CapturedDocumentPhoto, identifier: Int64
  ) -> DocumentCaptureAdmissionSnapshot {
    DocumentCaptureAdmissionSnapshot(
      request: CameraPhotoCaptureRequest(
        sessionID: photo.sessionID, side: photo.side,
        qualityGate: .operatorInitiatedAdvisory, attemptID: UUID(), userRequestedAt: Date()),
      admittedAt: Date(), photoSettingsUniqueID: identifier, observation: nil)
  }

  private func makePhoto() throws -> CapturedDocumentPhoto {
    CapturedDocumentPhoto(
      sessionID: CaptureSessionID(), side: .front, requestedAt: Date(),
      captureTimestamp: try #require(
        DocumentCaptureClockTimestamp(
          avCapturePhotoTimestamp: CMClockGetTime(CMClockGetHostTimeClock()))),
      processedAt: Date(), data: Data([1]),
      fidelity: PhotoFidelityMetadata(
        pixelWidth: 32, pixelHeight: 16, fileByteCount: 1, uniformTypeIdentifier: "public.heic",
        orientation: 1, cameraModel: nil, lensModel: nil, exposureTimeSeconds: nil,
        fNumber: nil, isoSpeed: nil, sha256: String(repeating: "a", count: 64), optical: nil),
      admission: nil)
  }
}

/// Test-only callback recorder. Lock permits duplicate-completion assertions
/// without resuming a checked continuation twice.
private final class TailProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var received = 0
  private var receivedPhoto: CapturedDocumentPhoto?
  private var rejected = false
  private var acknowledged = false
  var stopAcknowledged: Bool { lock.withLock { acknowledged } }
  func markStopAcknowledged() { lock.withLock { acknowledged = true } }
  var count: Int { lock.withLock { received } }
  var photo: CapturedDocumentPhoto? { lock.withLock { receivedPhoto } }
  var restartRejected: Bool { lock.withLock { rejected } }
  func markRestartRejected() { lock.withLock { rejected = true } }
  func receive(_ result: Result<CapturedDocumentPhoto, PhotoCaptureError>) -> Bool {
    lock.withLock {
      received += 1
      if case .success(let photo) = result { receivedPhoto = photo }
      return received == 1
    }
  }
}
