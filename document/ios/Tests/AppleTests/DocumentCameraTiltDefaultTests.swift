import AVFoundation
import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

struct DocumentCameraTiltDefaultTests {
  @MainActor @Test func publicLiveDefaultUsesV2AndLegacyRequiresExplicitChoice() async throws {
    let controller = TiltDefaultCameraController()
    let camera = DocumentCamera(now: { Date() }, 
      sessionID: .init(),
      authorizationProvider: StubCameraAuthorizationProvider(.authorized),
      sessionController: controller)
    try await camera.start()
    let run = UUID()
    _ = try await camera.beginTiltGuidance(runID: run)
    #expect(controller.configuration == .provisionalV2)
    await camera.endTiltGuidance(runID: run)
    _ = try await camera.beginTiltGuidance(runID: UUID(), configuration: .provisionalV1)
    #expect(controller.configuration == .provisionalV1)
    camera.stop()
  }
}

private final class TiltDefaultCameraController:
  CameraSessionControlling, CameraSessionTiltGuidanceControlling, @unchecked Sendable {
  private let lock = NSLock()
  private var receivedConfiguration: DocumentTiltConfiguration?
  var configuration: DocumentTiltConfiguration? { lock.withLock { receivedConfiguration } }

  func setQualityObservationHandler(
    configuration: DocumentCameraDiagnosticsConfiguration,
    handler: @escaping @Sendable (DocumentCaptureQualityObservation) -> Void
  ) {}
  func start(
    completion:
      @escaping @Sendable (Result<DocumentCameraHardwareSelection, PhotoCaptureError>) -> Void
  ) {
    completion(.success(fixtureHardwareSelection()))
  }
  func stop() {}
  func capture(
    request: CameraPhotoCaptureRequest,
    completion: @escaping @Sendable (Result<CapturedDocumentPhoto, PhotoCaptureError>) -> Void
  ) {
    completion(.failure(.cameraNotReady))
  }
  func setTiltGuidanceHandler(_ handler: @escaping @Sendable (DocumentTiltPresentation) -> Void) {}
  func beginTiltGuidance(
    runID: UUID, configuration: DocumentTiltConfiguration,
    cancellation: DocumentTiltStartCancellation,
    completion: @escaping @Sendable (Result<DocumentTiltPresentation, PhotoCaptureError>) -> Void
  ) {
    lock.withLock { receivedConfiguration = configuration }
    completion(
      .success(DocumentTiltController(runID: runID, configuration: configuration).presentation))
  }
  func endTiltGuidance(
    runID: UUID, reason: DocumentTiltReason, completion: @escaping @Sendable () -> Void
  ) {
    completion()
  }
  #if os(iOS)
    @MainActor func attachPreview(to previewLayer: AVCaptureVideoPreviewLayer) {}
    @MainActor func updateCaptureOrientation(_ orientation: DocumentCameraOrientation) {}
    @MainActor func updateDocumentGuideRegion(_ region: DocumentCameraGuideRegion?) {}
  #endif
}
