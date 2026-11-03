import CoreMedia
import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

#if os(iOS)
  import AVFoundation
#endif

@MainActor
@Test
func deniedAuthorizationFailsClosedWithoutStartingSession() async {
  let controller = StubCameraSessionController()
  let camera = makeCamera(permissionState: .denied, controller: controller)

  await expectError(.cameraPermissionDenied) {
    try await camera.start()
  }
  #expect(controller.startCallCount == 0)
}

@MainActor
@Test
func indeterminateAuthorizationHasExplicitFailure() async {
  let controller = StubCameraSessionController()
  let recorder = TelemetryRecorder()
  let camera = makeCamera(
    permissionState: .indeterminate,
    controller: controller,
    telemetry: recorder.telemetry
  )

  await expectError(.cameraAuthorizationIndeterminate) {
    try await camera.start()
  }
  #expect(controller.startCallCount == 0)
  #expect(recorder.events.count == 3)
  #expect(recorder.events.first?.name == .sessionStartRequested)
  #expect(recorder.events.dropFirst().first?.name == .authorizationResolved)
  #expect(recorder.events.last?.name == .sessionStartFailed)
  let authorizationEvent = recorder.events.first { $0.name == .authorizationResolved }
  let failureEvent = recorder.events.first { $0.name == .sessionStartFailed }
  #expect(authorizationEvent?.permissionState == .indeterminate)
  #expect(failureEvent?.errorCode == "camera_authorization_indeterminate")
}

@MainActor
@Test
func sessionStartFailureIsPreserved() async {
  let expected = PhotoCaptureError.configurationFailed("fixture failure")
  let controller = StubCameraSessionController(startResult: .failure(expected))
  let camera = makeCamera(permissionState: .authorized, controller: controller)

  await expectError(expected) {
    try await camera.start()
  }
  #expect(controller.startCallCount == 1)
}

@MainActor
@Test
func failedStartupCannotCaptureOrEmitStartedAndAllowsAnotherAttempt() async {
  let expected = PhotoCaptureError.configurationFailed("Session did not start")
  let controller = StubCameraSessionController(startResult: .failure(expected))
  let recorder = TelemetryRecorder()
  let camera = makeCamera(
    permissionState: .authorized,
    controller: controller,
    telemetry: recorder.telemetry
  )

  await expectError(expected) { try await camera.start() }
  await expectError(.cameraNotReady) {
    _ = try await camera.capture(side: .front)
  }
  await expectError(expected) { try await camera.start() }

  #expect(controller.startCallCount == 2)
  #expect(controller.captureCallCount == 0)
  #expect(!recorder.events.contains { $0.name == .sessionStarted })
  #expect(recorder.events.filter { $0.name == .sessionStartFailed }.count == 2)
}

@MainActor
@Test
func stopRefusesCaptureUntilExplicitRestart() async throws {
  let controller = StubCameraSessionController()
  let camera = makeCamera(permissionState: .authorized, controller: controller)
  try await camera.start()
  camera.stop()

  await expectError(.cameraNotReady) {
    _ = try await camera.capture(side: .front)
  }
  #expect(controller.captureCallCount == 0)

  try await camera.start()
  #expect(controller.startCallCount == 2)
}

@MainActor
@Test
func captureBeforeStartFailsClosed() async {
  let camera = makeCamera(
    permissionState: .authorized,
    controller: StubCameraSessionController()
  )

  await expectError(.cameraNotReady) {
    _ = try await camera.capture(side: .front)
  }
}

@MainActor
@Test
func diagnosticsBeforeStartAndAfterStopDoNotReachHardware() async throws {
  let controller = StubCameraSessionController()
  let camera = makeCamera(permissionState: .authorized, controller: controller)
  await expectError(.cameraNotReady) { _ = try await camera.performDiagnostic(.inspect) }
  try await camera.start()
  camera.stop()
  await expectError(.cameraNotReady) { _ = try await camera.performDiagnostic(.setLensPosition(0)) }
  #expect(controller.diagnosticCallCount == 0)
}

@MainActor
@Test
func diagnosticNativeFailureIsPreserved() async throws {
  let controller = StubCameraSessionController()
  let camera = makeCamera(permissionState: .authorized, controller: controller)
  try await camera.start()
  await expectError(.configurationFailed("Native diagnostic fixture failure")) {
    _ = try await camera.performDiagnostic(.setLensPosition(0.5))
  }
  #expect(controller.diagnosticCallCount == 1)
}

@MainActor
@Test
func captureFailureIsPreserved() async throws {
  let expected = PhotoCaptureError.captureFailed("fixture failure")
  let controller = StubCameraSessionController(captureResult: .failure(expected))
  let camera = makeCamera(permissionState: .authorized, controller: controller)

  try await camera.start()
  await expectError(expected) {
    _ = try await camera.capture(side: .front)
  }
  #expect(controller.captureCallCount == 1)
}

@MainActor
@Test
func advisoryCaptureIsExplicitInRequestAndTelemetry() async throws {
  let encoded = try tinyPNGFixture()
  let photo = try CapturedDocumentPhotoAssembler(now: { Date() }).assemble(
    data: encoded,
    sessionID: CaptureSessionID(),
    side: .front,
    captureTimestamp: fixtureCaptureTimestamp()
  )
  let controller = StubCameraSessionController(captureResult: .success(photo))
  let recorder = TelemetryRecorder()
  let camera = makeCamera(
    permissionState: .authorized,
    controller: controller,
    telemetry: recorder.telemetry
  )

  try await camera.start()
  _ = try await camera.capture(
    request: DocumentCaptureRequest(
      side: .front,
      qualityGate: .operatorInitiatedAdvisory
    )
  )

  #expect(controller.lastCaptureRequest?.qualityGate == .operatorInitiatedAdvisory)
  let requested = try #require(recorder.events.first { $0.name == .captureRequested })
  let completed = try #require(recorder.events.first { $0.name == .captureCompleted })
  #expect(requested.qualityGate == .operatorInitiatedAdvisory)
  #expect(requested.captureAttemptID != nil)
  #expect(completed.captureAttemptID == requested.captureAttemptID)
  #expect(completed.qualityGate == .operatorInitiatedAdvisory)
}

@MainActor
@Test
func authorizedCapturePreservesLiveProvenanceAndOriginalBytes() async throws {
  let sessionID = CaptureSessionID(
    rawValue: try #require(UUID(uuidString: "5CFD8650-A4CB-47D7-B42F-B5D6C2808833"))
  )
  let encoded = try tinyPNGFixture()
  let processedAt = Date(timeIntervalSince1970: 1_787_443_200)
  let captureTimestamp = fixtureCaptureTimestamp()
  let photo = try CapturedDocumentPhotoAssembler(now: { processedAt }).assemble(
    data: encoded,
    sessionID: sessionID,
    side: .back,
    captureTimestamp: captureTimestamp
  )
  let controller = StubCameraSessionController(captureResult: .success(photo))
  let recorder = TelemetryRecorder()
  let camera = DocumentCamera(now: { Date() }, 
    sessionID: sessionID,
    authorizationProvider: StubCameraAuthorizationProvider(.authorized),
    sessionController: controller,
    telemetry: recorder.telemetry
  )

  try await camera.start()
  let result = try await camera.capture(side: .back)

  #expect(result.sessionID == sessionID && result.side == .back)
  #expect(result.origin == .liveSensor)
  #expect(result.captureTimestamp == captureTimestamp && result.processedAt == processedAt)
  #expect(result.data == encoded)
  #expect(result.fidelity.fileByteCount == encoded.count)
  #expect(result.fidelity.sha256.count == 64)
  #expect(controller.captureCallCount == 1)

  let selectedEvent = try #require(
    recorder.events.first { $0.name == .cameraSelected }
  )
  #expect(selectedEvent.cameraSelection?.selected.lens == .wide)
  #expect(selectedEvent.cameraSelection?.selected.maximumPhotoWidth == 8_064)

  let captureEvent = try #require(
    recorder.events.first { $0.name == .captureCompleted }
  )
  #expect(captureEvent.side == .back)
  #expect(captureEvent.photo?.origin == .liveSensor)
  #expect(captureEvent.photo?.pixelWidth == 1)
  #expect(captureEvent.photo?.encodedByteCount == encoded.count)

  let telemetryJSON = try #require(
    String(
      bytes: try JSONEncoder().encode(captureEvent),
      encoding: .utf8
    )
  )
  #expect(!telemetryJSON.contains("sha256"))
  #expect(!telemetryJSON.contains("\"data\""))
  #expect(!telemetryJSON.contains(encoded.base64EncodedString()))
}
