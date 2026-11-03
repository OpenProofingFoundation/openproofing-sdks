import CoreMedia
import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

#if os(iOS)
  import AVFoundation
#endif

@MainActor
func makeCamera(
  permissionState: CameraAuthorizationDecision,
  controller: StubCameraSessionController,
  telemetry: DocumentCameraTelemetry = .disabled
) -> DocumentCamera {
  DocumentCamera(now: { Date() }, 
    sessionID: CaptureSessionID(),
    authorizationProvider: StubCameraAuthorizationProvider(permissionState),
    sessionController: controller,
    telemetry: telemetry
  )
}

@MainActor
func expectError(
  _ expected: PhotoCaptureError,
  operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected \(expected), but the operation succeeded")
  } catch let error as PhotoCaptureError {
    #expect(error == expected)
  } catch {
    Issue.record("Expected \(expected), but received \(error)")
  }
}

struct StubCameraAuthorizationProvider: CameraAuthorizationProviding {
  let decision: CameraAuthorizationDecision

  init(_ decision: CameraAuthorizationDecision) {
    self.decision = decision
  }

  func resolveAuthorization() async -> CameraAuthorizationDecision {
    decision
  }
}

final class TelemetryRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedEvents: [DocumentCameraTelemetryEvent] = []

  var telemetry: DocumentCameraTelemetry {
    DocumentCameraTelemetry { [self] event in
      lock.withLock { recordedEvents.append(event) }
    }
  }

  var events: [DocumentCameraTelemetryEvent] {
    lock.withLock { recordedEvents }
  }
}

extension StubCameraSessionController: CameraSessionDiagnosticsControlling, CameraSessionFailureReporting {}

final class StubCameraSessionController: CameraSessionControlling, @unchecked Sendable {
  private struct State {
    var startCallCount = 0
    var captureCallCount = 0
    var diagnosticCallCount = 0
    var lastCaptureRequest: CameraPhotoCaptureRequest?
  }

  private let lock = NSLock()
  private var state = State()
  private let startResult: Result<DocumentCameraHardwareSelection, PhotoCaptureError>
  private let captureResult: Result<CapturedDocumentPhoto, PhotoCaptureError>?
  private let holdCapture: Bool
  private var failureHandler: (@Sendable () -> Void)?
  private var heldCompletion: (@Sendable (Result<CapturedDocumentPhoto, PhotoCaptureError>) -> Void)?

  init(
    startResult: Result<DocumentCameraHardwareSelection, PhotoCaptureError> = .success(
      fixtureHardwareSelection()
    ),
    captureResult: Result<CapturedDocumentPhoto, PhotoCaptureError>? = nil,
    holdCapture: Bool = false
  ) {
    self.holdCapture = holdCapture
    self.startResult = startResult
    self.captureResult = captureResult
  }

  var startCallCount: Int {
    lock.withLock { state.startCallCount }
  }

  var captureCallCount: Int {
    lock.withLock { state.captureCallCount }
  }

  var diagnosticCallCount: Int {
    lock.withLock { state.diagnosticCallCount }
  }

  func performDiagnostic(
    _ command: DocumentCameraDiagnosticCommand,
    completion:
      @escaping @Sendable (Result<DocumentCameraNativeSnapshot, PhotoCaptureError>) -> Void
  ) {
    lock.withLock { state.diagnosticCallCount += 1 }
    completion(.failure(.configurationFailed("Native diagnostic fixture failure")))
  }

  var lastCaptureRequest: CameraPhotoCaptureRequest? {
    lock.withLock { state.lastCaptureRequest }
  }

  func setQualityObservationHandler(
    configuration: DocumentCameraDiagnosticsConfiguration,
    handler: @escaping @Sendable (DocumentCaptureQualityObservation) -> Void
  ) {}

  func start(
    completion:
      @escaping @Sendable (
        Result<DocumentCameraHardwareSelection, PhotoCaptureError>
      ) -> Void
  ) {
    lock.withLock { state.startCallCount += 1 }
    completion(startResult)
  }

  func stop() {}

  func capture(
    request: CameraPhotoCaptureRequest,
    completion:
      @escaping @Sendable (
        Result<CapturedDocumentPhoto, PhotoCaptureError>
      ) -> Void
  ) {
    lock.withLock {
      state.captureCallCount += 1
      state.lastCaptureRequest = request
    }
    if holdCapture { lock.withLock { heldCompletion = completion } } else {
      completion(captureResult ?? .failure(.captureFailed("No fixture result configured")))
    }
  }

  func setFailureHandler(_ handler: @escaping @Sendable () -> Void) {
    lock.withLock { failureHandler = handler }
  }

  func nativeFailure() { lock.withLock { failureHandler }?() }

  func finishHeldCapture() {
    let callback = lock.withLock { () -> (@Sendable (Result<CapturedDocumentPhoto, PhotoCaptureError>) -> Void)? in
      defer { heldCompletion = nil }
      return heldCompletion
    }
    callback?(captureResult ?? .failure(.captureFailed("No fixture result configured")))
  }

  #if os(iOS)
    @MainActor
    func attachPreview(to previewLayer: AVCaptureVideoPreviewLayer) {}

    @MainActor
    func updateCaptureOrientation(_ orientation: DocumentCameraOrientation) {}

    @MainActor
    func updateDocumentGuideRegion(_ region: DocumentCameraGuideRegion?) {}

    func recordPreviewGeometry(_ diagnostic: DocumentCameraPreviewGeometryDiagnostic) {}
  #endif
}

func fixtureHardwareSelection() -> DocumentCameraHardwareSelection {
  let capability = DocumentCameraCapability(
    lens: .wide,
    localizedName: "Fixture wide camera",
    minimumFocusDistanceMillimeters: 120,
    maximumPhotoWidth: 8_064,
    maximumPhotoHeight: 6_048,
    videoFieldOfViewDegrees: 80,
    lensAperture: 1.78,
    supportsContinuousAutoFocus: true,
    supportsFocusPointOfInterest: true
  )
  return DocumentCameraHardwareSelection(
    selected: capability,
    discovered: [capability],
    reason: .wideMeetsWorkingDistance,
    targetWorkingDistanceMillimeters: 240
  )
}

func fixtureCaptureTimestamp() -> DocumentCaptureClockTimestamp {
  DocumentCaptureClockTimestamp(
    value: 12_000,
    timescale: 600,
    flags: CMTimeFlags.valid.rawValue,
    epoch: 0,
    clock: .captureSessionSynchronizationClock
  )
}
