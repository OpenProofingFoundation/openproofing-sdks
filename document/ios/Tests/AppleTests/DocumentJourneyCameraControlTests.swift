import AVFoundation
import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

struct DocumentJourneyCameraControlTests {
  @Test func reviewSuspendsAdmissionWithoutStoppingSessionOwner() async {
    let owner = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .geometry)
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        owner.state.nativeCaptureReady = true
        continuation.resume()
      }
    }
    owner.setCaptureAdmissionEnabled(false)
    let disabled = await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        continuation.resume(returning: !owner.state.captureAdmissionEnabled)
      }
    }
    #expect(disabled)
    let request = CameraPhotoCaptureRequest(sessionID: CaptureSessionID(), side: .front,
      qualityGate: .operatorInitiatedAdvisory, attemptID: UUID(), userRequestedAt: Date())
    let refusal = await withCheckedContinuation { continuation in
      owner.capture(request: request) { result in
        if case .failure(let error) = result {
          continuation.resume(returning: error)
        } else {
          continuation.resume(returning: PhotoCaptureError.captureIdentityMismatch)
        }
      }
    }
    #expect(refusal == .captureAdmissionSuspended)
    // No stop or restart is involved in re-enabling the existing owner.
    owner.setCaptureAdmissionEnabled(true)
    let enabled = await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        continuation.resume(returning: owner.state.captureAdmissionEnabled)
      }
    }
    #expect(enabled)
  }

  @Test func hiddenReviewIntentSurvivesStartupAndRuntimeRecovery() async {
    let owner = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .geometry)
    owner.setCaptureAdmissionEnabled(false)
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        owner.state.nativeCaptureReady = false
        owner.state.nativeCaptureReady = true
        #expect(!owner.state.captureAdmissionEnabled)
        owner.reportNativeFailure("synthetic_interruption")
        #expect(!owner.state.nativeCaptureReady)
        #expect(!owner.state.captureAdmissionRequested)
        owner.state.nativeCaptureReady = true
        #expect(!owner.state.captureAdmissionEnabled)
        continuation.resume()
      }
    }
    owner.setCaptureAdmissionEnabled(true)
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        #expect(owner.state.captureAdmissionEnabled)
        continuation.resume()
      }
    }
  }

  @Test func profileChangeAcknowledgesAnalysisResetAndKeepsCameraGraph() async throws {
    let owner = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .geometry)
    let target = DocumentCameraDiagnosticsConfiguration(
      includesAdaptiveCapture: true, includesLiveContentAnalysis: true,
      liveContentTarget: .licensePDF417)
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        owner.state.isConfigured = true
        owner.state.frameAnalyzer = DocumentFrameAnalyzer(now: { Date() }, 
          configuration: .qualityOnly,
          observationHandler: { _ in }, focusHandler: { _ in })
        continuation.resume()
      }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      owner.updateCaptureAnalysis(configuration: target) { result in
        continuation.resume(with: result)
      }
    }
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        #expect(owner.state.isConfigured)
        #expect(!owner.state.captureAdmissionEnabled)
        #expect(owner.state.latestQualityObservation == nil)
        #expect(owner.diagnosticsConfiguration.liveContentTarget == .licensePDF417)
        #expect(owner.diagnosticsConfiguration.includesLiveContentAnalysis)
        continuation.resume()
      }
    }
  }

  @Test func detachedJourneySinkIsFencedBeforeAcknowledgement() async {
    let owner = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .geometry)
    await withCheckedContinuation { continuation in
      owner.detachJourneyRecordingSink { continuation.resume() }
    }
    // Repeated detach is idempotent even before camera startup.
    await withCheckedContinuation { continuation in
      owner.detachJourneyRecordingSink { continuation.resume() }
    }
  }
}
