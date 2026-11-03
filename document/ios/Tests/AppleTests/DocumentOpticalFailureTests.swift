import AVFoundation
import Foundation
import Testing
@testable import DocumentCaptureApple

@Test
func opticalFailureImmediatelyNotifiesTheRecordingAndClosesAdmissionAfterConfigurationEnds() async {
  let controller = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .init())
  let sink = RecordingSink()
  await withCheckedContinuation { continuation in
    controller.sessionQueue.async {
      controller.state.nativeCaptureReady = true
      controller.state.needsOpticalReconfiguration = true
      controller.state.temporalRecorder?.setJourneySink(sink)
      controller.state.failureHandler = {
        #expect(!controller.state.isConfiguring)
        #expect(!controller.state.captureAdmissionEnabled)
      }
      controller.reconfigureOpticalOutput {
        throw PhotoCaptureError.configurationFailed("synthetic_output_rotation_failure")
      }
      #expect(controller.state.nativeOperationUncertain)
      #expect(!controller.state.nativeCaptureReady)
      #expect(controller.state.needsOpticalReconfiguration)
      #expect(sink.events.filter { $0.kind == "session_issue" }.map(\.contextCode) == ["optical_configuration_failed"])
      // Another queued frame/KVO callback cannot retry an uncertain native transaction or flood failures.
      controller.reconfigureOpticalOutput { Issue.record("Uncertain optical state was reused") }
      #expect(sink.events.filter { $0.kind == "session_issue" }.count == 1)
      controller.state.failureHandler = nil
      continuation.resume()
    }
  }
}

@Test
func successfulOpticalReconfigurationKeepsAdmissionOpenWithoutARecordingFailure() async {
  let controller = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .init())
  let sink = RecordingSink()
  await withCheckedContinuation { continuation in
    controller.sessionQueue.async {
      controller.state.nativeCaptureReady = true
      controller.state.needsOpticalReconfiguration = true
      controller.state.temporalRecorder?.setJourneySink(sink)
      controller.state.failureHandler = { Issue.record("Successful reconfiguration reported failure") }
      controller.reconfigureOpticalOutput {}
      #expect(controller.state.captureAdmissionEnabled)
      #expect(!controller.state.needsOpticalReconfiguration)
      #expect(!controller.state.nativeOperationUncertain)
      #expect(!controller.state.isConfiguring)
      #expect(!sink.events.contains { $0.kind == "session_issue" })
      controller.state.failureHandler = nil
      continuation.resume()
    }
  }
}
