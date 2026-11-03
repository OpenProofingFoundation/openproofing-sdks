import AVFoundation
import Foundation
import DocumentSDK
import Testing
@testable import DocumentCaptureApple

@MainActor
@Test
func alreadyCancelledShutterAndDiagnosticNeverReachNativeController() async throws {
  let controller = StubCameraSessionController()
  let camera = makeCamera(permissionState: .authorized, controller: controller)
  try await camera.start()
  let capture = Task { try await camera.capture(side: .front) }
  capture.cancel()
  do { _ = try await capture.value; Issue.record("Cancelled shutter succeeded") } catch is CancellationError {}
  let diagnostic = Task { try await camera.performDiagnostic(.inspect) }
  diagnostic.cancel()
  do { _ = try await diagnostic.value; Issue.record("Cancelled diagnostic succeeded") } catch is CancellationError {}
  #expect(controller.captureCallCount == 0)
  #expect(controller.diagnosticCallCount == 0)
}

@MainActor
@Test
func nativeFailureInvalidatesReadinessAndAllowsSameInstanceRestart() async throws {
  let controller = StubCameraSessionController()
  let recorder = TelemetryRecorder()
  let camera = makeCamera(permissionState: .authorized, controller: controller, telemetry: recorder.telemetry)
  try await camera.start()
  controller.nativeFailure()
  while !recorder.events.contains(where: { $0.errorCode == "native_session_failure" }) { await Task.yield() }
  await expectError(.cameraNotReady) { _ = try await camera.capture(side: .back) }
  #expect(controller.captureCallCount == 0)
  try await camera.start()
  #expect(controller.startCallCount == 2)
  await expectError(.captureFailed("No fixture result configured")) { _ = try await camera.capture(side: .back) }
  #expect(controller.captureCallCount == 1)
}

@MainActor
@Test
func heldNativeSuccessReturnsBytesUnlessExplicitlyStopped() async throws {
  let bytes = try tinyPNGFixture()
  let photo = try CapturedDocumentPhotoAssembler(now: { Date() }).assemble(data: bytes,
    sessionID: CaptureSessionID(), side: .back, captureTimestamp: fixtureCaptureTimestamp())
  for cancellation in ["none", "stop", "task"] {
    let controller = StubCameraSessionController(captureResult: .success(photo), holdCapture: true)
    let camera = makeCamera(permissionState: .authorized, controller: controller)
    try await camera.start()
    let capture = Task { try await camera.capture(side: .back) }
    while controller.captureCallCount == 0 { await Task.yield() }
    if cancellation == "stop" { camera.stop() }
    if cancellation == "task" { capture.cancel() }
    controller.finishHeldCapture()
    do {
      let result = try await capture.value
      #expect(cancellation == "none")
      #expect(result.data == bytes)
    } catch is CancellationError {
      #expect(cancellation != "none")
    }
  }
}

@Test
func nativeFailureSuspendsAdmissionAndFailedStartupCannotRestoreIt() async {
  let controller = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, 
    configuration: .init(temporalEvidence: .init(maximumBytes: 0)))
  let before = await withCheckedContinuation { continuation in
    controller.sessionQueue.async {
      controller.reportNativeFailure("synthetic_runtime_failure")
      continuation.resume(returning: controller.state.captureAdmissionEnabled)
    }
  }
  #expect(!before)
  await withCheckedContinuation { continuation in
    controller.sessionQueue.async {
      controller.state.nativeCaptureReady = true
      controller.state.captureAdmissionRequested = true
      continuation.resume()
    }
  }
  let result = await withCheckedContinuation { continuation in
    controller.start { continuation.resume(returning: $0) }
  }
  if case .success = result { Issue.record("Invalid configuration unexpectedly started") }
  let after = await withCheckedContinuation { continuation in
    controller.sessionQueue.async {
      continuation.resume(returning: controller.state.captureAdmissionEnabled)
    }
  }
  #expect(!after)
}

@Test
func stoppedNativeSessionReleasesGraphAndCannotReconfigureFromOldOpticalState() async {
  let controller = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .init())
  await withCheckedContinuation { continuation in
    controller.sessionQueue.async {
      controller.state.captureSession.beginConfiguration()
      if controller.state.captureSession.canAddOutput(controller.state.photoOutput) {
        controller.state.captureSession.addOutput(controller.state.photoOutput)
      }
      controller.state.captureSession.commitConfiguration()
      controller.state.isConfigured = true
      controller.state.needsOpticalReconfiguration = true
      controller.state.opticalSignature = "previous-owner"
      controller.state.captureAdmissionRequested = false
      continuation.resume()
    }
  }
  controller.stop()
  await withCheckedContinuation { continuation in
    controller.afterStop { stopped in
      #expect(stopped)
      #expect(controller.state.captureSession.inputs.isEmpty)
      #expect(controller.state.captureSession.outputs.isEmpty)
      #expect(!controller.state.isConfigured)
      #expect(controller.state.deviceObservations.isEmpty)
      #expect(controller.state.temporalNotifications.isEmpty)
      #expect(controller.state.activeDevice == nil)
      #expect(controller.state.frameAnalyzer == nil)
      #expect(!controller.state.captureAdmissionRequested)
      controller.reconcileOpticalState()
      #expect(!controller.state.needsOpticalReconfiguration)
      #expect(controller.state.opticalSignature.isEmpty)
      continuation.resume()
    }
  }
}

@Test
func nativeStopWaitsForRetiredAnalysisBeforeAcknowledgingOrRestarting() async {
  let controller = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .init())
  let gate = DispatchSemaphore(value: 0)
  await withCheckedContinuation { continuation in
    controller.sessionQueue.async {
      let analyzer = DocumentFrameAnalyzer(now: { Date() }, configuration: .qualityOnly,
        observationHandler: { _ in }, focusHandler: { _ in })
      controller.state.frameAnalyzer = analyzer
      analyzer.analysisQueue.async {
        continuation.resume()
        gate.wait()
      }
    }
  }
  controller.stop()
  let result = await withCheckedContinuation { continuation in
    controller.start { continuation.resume(returning: $0) }
  }
  if case .failure(.cameraNotReady) = result {} else { Issue.record("Restart crossed undrained analysis") }
  await withCheckedContinuation { continuation in
    controller.sessionQueue.async {
      #expect(controller.state.graphDrainPending)
      #expect(controller.state.graphReleasePending)
      continuation.resume()
    }
  }
  gate.signal()
  await withCheckedContinuation { continuation in
    controller.afterStop { stopped in
      #expect(stopped)
      #expect(!controller.state.graphDrainPending)
      #expect(!controller.state.graphReleasePending)
      #expect(controller.state.frameAnalyzer == nil)
      continuation.resume()
    }
  }
}

@Test
func queuedRuntimeFailureFromReleasedSessionCannotCloseReplacementAdmission() async {
  let controller = AVFoundationCameraSessionController(notifications: NotificationCenter(), now: { Date() }, configuration: .init())
  await withCheckedContinuation { continuation in
    controller.sessionQueue.async {
      controller.startTemporalRecording()
      NotificationCenter.default.post(name: AVCaptureSession.runtimeErrorNotification,
        object: controller.state.captureSession)
      controller.state.temporalReadbackTimer?.cancel()
      controller.releaseStoppedCaptureGraph()
      controller.state.nativeCaptureReady = true
      controller.sessionQueue.async {
        #expect(controller.state.nativeCaptureReady)
        continuation.resume()
      }
    }
  }
}
