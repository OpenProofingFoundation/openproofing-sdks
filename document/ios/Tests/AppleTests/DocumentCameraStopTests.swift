import AVFoundation
import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

@MainActor
@Test
func stopAndWaitRequiresNativeAcknowledgement() async throws {
  let controller = ControlledStopController()
  let camera = stopCamera(controller)
  try await camera.start()
  var completed = false
  let stop = Task {
    try await camera.stopAndWait()
    completed = true
  }
  var registrations = controller.registrations.makeAsyncIterator()
  _ = await registrations.next()
  #expect(controller.stopCount == 1)
  #expect(!completed)
  controller.acknowledge(stopped: true)
  try await stop.value
  #expect(completed)
  await expectError(.cameraNotReady) { _ = try await camera.capture(side: .front) }
}

@MainActor
@Test
func stopAndWaitRejectsInterveningRestart() async throws {
  let controller = ControlledStopController()
  let camera = stopCamera(controller)
  try await camera.start()
  let stop = Task { try await camera.stopAndWait() }
  var registrations = controller.registrations.makeAsyncIterator()
  _ = await registrations.next()
  try await camera.start()
  controller.acknowledge(stopped: true)
  await expectError(.cameraNotReady) { try await stop.value }
}

@MainActor
@Test
func stopAndWaitRejectsNativeFailureToStop() async throws {
  let controller = ControlledStopController()
  let camera = stopCamera(controller)
  try await camera.start()
  let stop = Task { try await camera.stopAndWait() }
  var registrations = controller.registrations.makeAsyncIterator()
  _ = await registrations.next()
  controller.acknowledge(stopped: false)
  await expectError(.cameraNotReady) { try await stop.value }
}

@MainActor
private func stopCamera(_ controller: ControlledStopController) -> DocumentCamera {
  DocumentCamera(now: { Date() }, 
    sessionID: CaptureSessionID(), authorizationProvider: StubCameraAuthorizationProvider(.authorized),
    sessionController: controller)
}

/// The test controls native queue acknowledgement without sleeps or actual camera hardware.
private final class ControlledStopController: CameraSessionControlling, CameraSessionStopAwaiting,
  @unchecked Sendable {
  let registrations: AsyncStream<Void>
  private let registration: AsyncStream<Void>.Continuation
  private let lock = NSLock()
  private var completion: (@Sendable (Bool) -> Void)?
  private var stops = 0
  private let base = StubCameraSessionController()

  init() {
    let pair = AsyncStream.makeStream(of: Void.self)
    registrations = pair.stream
    registration = pair.continuation
  }

  var stopCount: Int { lock.withLock { stops } }

  func stop() { lock.withLock { stops += 1 } }

  func afterStop(_ completion: @escaping @Sendable (Bool) -> Void) {
    lock.withLock { self.completion = completion }
    registration.yield(())
  }

  func acknowledge(stopped: Bool) {
    let callback = lock.withLock {
      let callback = completion
      completion = nil
      return callback
    }
    callback?(stopped)
  }

  func start(completion: @escaping @Sendable (Result<DocumentCameraHardwareSelection, PhotoCaptureError>) -> Void) {
    base.start(completion: completion)
  }

  func setQualityObservationHandler(
    configuration: DocumentCameraDiagnosticsConfiguration,
    handler: @escaping @Sendable (DocumentCaptureQualityObservation) -> Void
  ) {}

  func capture(
    request: CameraPhotoCaptureRequest,
    completion: @escaping @Sendable (Result<CapturedDocumentPhoto, PhotoCaptureError>) -> Void
  ) { base.capture(request: request, completion: completion) }

  #if os(iOS)
    @MainActor func attachPreview(to previewLayer: AVCaptureVideoPreviewLayer) {}
    @MainActor func updateCaptureOrientation(_ orientation: DocumentCameraOrientation) {}
    @MainActor func updateDocumentGuideRegion(_ region: DocumentCameraGuideRegion?) {}
  #endif
}
