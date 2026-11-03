#if os(iOS)
  import AVFoundation
  import Foundation
  import UIKit
  import XCTest
  import DocumentSDK
  import DocumentCaptureJournal
  @testable import DocumentCapture
  @testable import DocumentCaptureApple
  @_spi(CaptureTestFixture) @testable import CaptureEvidenceCustody

  @MainActor
  struct MigrationFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let controller: MigrationController
    let session: CaptureSession
    init(
      fails: Bool = false, operations: CaptureDocumentOperations = .init(),
      onEvent: @escaping @MainActor (CaptureSessionEvent) -> Void = { _ in }
    ) throws {
      let configuration = CaptureSessionConfiguration(
        notifications: NotificationCenter(),
        custody: try .init(applicationID: "synthetic.capture-sdk.fixture",
          directory: directory,
          keychainService: "synthetic." + UUID().uuidString, keychainAccount: "session-tests", accessGroup: "TEST.capture-sdk.fixture"),
        signing: try .testing(applicationID: "synthetic.capture-sdk.fixture", installationID: "synthetic-installation"),
        clock: .init(
          now: { Date(timeIntervalSince1970: 1_700_000_000) },
          uptime: { ProcessInfo.processInfo.systemUptime }),
        consent: .permitted, requiresLocation: false)
      controller = MigrationController(fails: fails)
      session = CaptureSession(
        configuration: configuration, processingOperations: operations, onEvent: onEvent).withFixtureCustody()
      let controller = controller
      session.cameraFactory = { _ in
        DocumentCamera(
          now: configuration.clock.now, sessionID: CaptureSessionID(),
          authorizationProvider: MigrationAuthorization(), sessionController: controller)
      }
    }
    func start() async throws {
      session.start()
      await session.operation?.value
      if let error = session.startupFailure { throw error }
      _ = try XCTUnwrap(session.store)
      XCTAssertTrue(session.ready)
      XCTAssertFalse(session.busy)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func photoBytes() throws -> Data {
      let renderer = UIGraphicsImageRenderer(size: .init(width: 32, height: 32))
      return try XCTUnwrap(
        renderer.image { context in
          UIColor.gray.setFill()
          context.fill(.init(x: 0, y: 0, width: 32, height: 32))
        }.pngData())
    }
    func photo(camera: DocumentCamera, request: DocumentCaptureRequest, bytes: Data) throws
      -> CapturedDocumentPhoto
    {
      let now = session.configuration.clock.now()
      return CapturedDocumentPhoto(
        sessionID: camera.sessionID, side: request.side,
        requestedAt: now,
        captureTimestamp: .init(
          value: 1, timescale: 1, flags: 1, epoch: 0,
          clock: .captureSessionSynchronizationClock), processedAt: now, data: bytes,
        fidelity: try PhotoFidelityMetadata.make(from: bytes), admission: nil)
    }
  }

  @MainActor
  final class MigrationPhotoGate {
    var started = false
    var blocked: CheckedContinuation<Void, Never>?
    var starter: CheckedContinuation<Void, Never>?
    func block() async {
      started = true
      await withCheckedContinuation { continuation in
        blocked = continuation
        starter?.resume()
        starter = nil
      }
    }
    func waitForStart() async {
      if started { return }
      await withCheckedContinuation { starter = $0 }
    }
    func release() {
      blocked?.resume()
      blocked = nil
    }
  }

  private struct MigrationAuthorization: CameraAuthorizationProviding {
    func resolveAuthorization() async -> CameraAuthorizationDecision { .authorized }
  }
  private final class MigrationController: CameraSessionControlling, CameraSessionStopAwaiting,
    @unchecked Sendable
  {
    private let lock = NSLock()
    private var starts = 0
    let fails: Bool
    var startCount: Int { lock.withLock { starts } }
    init(fails: Bool) { self.fails = fails }
    func start(
      completion:
        @escaping @Sendable (Result<DocumentCameraHardwareSelection, PhotoCaptureError>) -> Void
    ) {
      lock.withLock { starts += 1 }
      if fails {
        completion(.failure(.backCameraUnavailable))
        return
      }
      let capability = DocumentCameraCapability(
        lens: .wide, localizedName: "test",
        minimumFocusDistanceMillimeters: 120, maximumPhotoWidth: 4032, maximumPhotoHeight: 3024,
        videoFieldOfViewDegrees: 80, lensAperture: 1.8,
        supportsContinuousAutoFocus: true, supportsFocusPointOfInterest: true)
      completion(
        .success(
          .init(
            selected: capability, discovered: [capability],
            reason: .wideMeetsWorkingDistance, targetWorkingDistanceMillimeters: 240)))
    }
    func stop() {}
    func afterStop(_ completion: @escaping @Sendable (Bool) -> Void) { completion(true) }
    func setQualityObservationHandler(
      configuration: DocumentCameraDiagnosticsConfiguration,
      handler: @escaping @Sendable (DocumentCaptureQualityObservation) -> Void
    ) {}
    func capture(
      request: CameraPhotoCaptureRequest,
      completion: @escaping @Sendable (Result<CapturedDocumentPhoto, PhotoCaptureError>) -> Void
    ) {
      completion(.failure(.cameraNotReady))
    }
    @MainActor func attachPreview(to previewLayer: AVCaptureVideoPreviewLayer) {}
    @MainActor func updateCaptureOrientation(_ orientation: DocumentCameraOrientation) {}
    @MainActor func updateDocumentGuideRegion(_ region: DocumentCameraGuideRegion?) {}
  }
#endif
