import Foundation
import Testing
@testable import DocumentCaptureApple

private enum RetirementFailure: Error { case denied }

struct DocumentZoomRampRetirementTests {
  @Test func failedRetirementRefusesProfileHandoffAndRetainsOldConfiguration() async {
    let owner = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .geometry,
      retireZoomRamp: { _ in throw RetirementFailure.denied })
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        owner.state.isConfigured = true
        owner.state.nativeCaptureReady = true
        owner.state.frameAnalyzer = DocumentFrameAnalyzer(now: { Date() }, configuration: .qualityOnly,
          observationHandler: { _ in }, focusHandler: { _ in })
        continuation.resume()
      }
    }
    let result = await withCheckedContinuation { continuation in
      owner.updateCaptureAnalysis(configuration: .init(includesAdaptiveCapture: true)) {
        continuation.resume(returning: $0)
      }
    }
    if case .success = result { Issue.record("Failed native retirement acknowledged profile handoff") }
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        #expect(!owner.state.captureAdmissionEnabled)
        #expect(owner.state.zoomRetirementFailed)
        #expect(!owner.diagnosticsConfiguration.includesAdaptiveCapture)
        continuation.resume()
      }
    }
    owner.stop()
  }

  @Test func failedRetirementDetachesGraphButCannotAcknowledgeCleanStop() async {
    let owner = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .geometry,
      retireZoomRamp: { _ in throw RetirementFailure.denied })
    for _ in 0..<2 {
      owner.stop()
      await withCheckedContinuation { continuation in
        owner.afterStop { stopped in
          #expect(!stopped)
          #expect(owner.state.captureSession.inputs.isEmpty)
          #expect(owner.state.captureSession.outputs.isEmpty)
          #expect(owner.state.zoomRetirementFailed)
          continuation.resume()
        }
      }
    }
  }

  @Test func failedReviewRetirementCannotReenableNativeCapture() async {
    let owner = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .geometry,
      retireZoomRamp: { _ in throw RetirementFailure.denied })
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        owner.state.nativeCaptureReady = true
        continuation.resume()
      }
    }
    owner.setCaptureAdmissionEnabled(false)
    owner.setCaptureAdmissionEnabled(true)
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        #expect(!owner.state.captureAdmissionEnabled)
        #expect(owner.state.zoomRetirementFailed)
        #if os(iOS)
          #expect(owner.state.geometryRevision > 0)
        #endif
        continuation.resume()
      }
    }
  }
}
