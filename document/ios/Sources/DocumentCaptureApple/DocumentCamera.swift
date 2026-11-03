import AVFoundation
import Foundation
import DocumentSDK

/// Main-actor orchestration for one live physical-document capture session.
///
/// Authorization, lifecycle policy, and application-facing delivery live here.
/// Mutable AVFoundation state is delegated to one serial session owner.
@MainActor
public final class DocumentCamera: DocumentPhotoCapturing, DocumentCameraQualityProviding {
  public let sessionID: CaptureSessionID
  /// Supplementary rectangle observations for a single consumer, coalesced to the newest value.
  /// Obtain a fresh stream after each successful start. Stop or native failure finishes
  /// the old stream, which may still drain its last buffered value; cancel or session-fence
  /// the old consumer. These observations do not establish capture or card identity.
  public var geometryObservations: AsyncStream<DocumentLiveGeometryObservation> {
    geometryDelivery.stream
  }
  private let geometryDelivery = DocumentGeometryObservationDelivery()
  let tiltGuidanceDelivery = DocumentTiltGuidanceDelivery()
  var tiltGuidanceAttemptID: UUID?
  public let qualityObservations: AsyncStream<DocumentCaptureQualityObservation>

  private let now: @Sendable () -> Date
  private let authorizationProvider: any CameraAuthorizationProviding
  let sessionController: any CameraSessionControlling
  private let telemetry: DocumentCameraTelemetry
  var generation = 0
  private var isStarting = false
  var isRunning = false
  var isCaptureInFlight = false
  private var captureFeedback = DocumentCaptureFeedback.seeking
  private var captureFeedbackHandler: (@MainActor @Sendable (DocumentCaptureFeedback) -> Void)?

  public convenience init(
    now: @escaping @Sendable () -> Date,
    notifications: NotificationCenter,
    diagnosticSink: @escaping @Sendable (Data) -> Void = { _ in },
    sessionID: CaptureSessionID = CaptureSessionID(),
    configuration: DocumentCaptureConfiguration = .geometry,
    telemetry: DocumentCameraTelemetry = .disabled,
    diagnostics: DocumentCameraDiagnosticsConfiguration = .qualityOnly
  ) {
    self.init(
      now: now,
      sessionID: sessionID,
      authorizationProvider: SystemCameraAuthorizationProvider(),
      sessionController: AVFoundationCameraSessionController(notifications: notifications, now: now, diagnosticSink: diagnosticSink, configuration: configuration),
      telemetry: telemetry,
      diagnostics: diagnostics
    )
  }

  init(
    now: @escaping @Sendable () -> Date,
    sessionID: CaptureSessionID,
    authorizationProvider: any CameraAuthorizationProviding,
    sessionController: any CameraSessionControlling,
    telemetry: DocumentCameraTelemetry = .disabled,
    diagnostics: DocumentCameraDiagnosticsConfiguration = .qualityOnly
  ) {
    let streamPair = AsyncStream.makeStream(
      of: DocumentCaptureQualityObservation.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    self.now = now
    self.sessionID = sessionID
    qualityObservations = streamPair.stream
    self.authorizationProvider = authorizationProvider
    self.sessionController = sessionController
    self.telemetry = telemetry
    if !(sessionController is any CameraSessionGeometryProviding) {
      geometryDelivery.finish()
    }
    if !(sessionController is any CameraSessionTiltGuidanceControlling) {
      tiltGuidanceDelivery.finishUnsupported()
    }
    sessionController.setQualityObservationHandler(
      configuration: diagnostics,
      handler: { observation in streamPair.continuation.yield(observation) }
    )
  }

  public func start() async throws {
    telemetry.record(event(.sessionStartRequested))
    if isRunning { return }
    guard !isStarting else {
      telemetry.record(event(.sessionStartFailed, errorCode: PhotoCaptureError.cameraNotReady.code))
      throw PhotoCaptureError.cameraNotReady
    }

    isStarting = true
    let operationGeneration = generation
    defer {
      if generation == operationGeneration {
        isStarting = false
      }
    }

    try await authorizeCamera()
    try ensureCurrent(operationGeneration)
    geometryDelivery.activate(generation: operationGeneration)
    activateTiltGuidanceDelivery(generation: operationGeneration)
    (sessionController as? any CameraSessionGeometryProviding)?
      .setGeometryObservationHandler { [geometryDelivery] packet in
        geometryDelivery.yield(packet, generation: operationGeneration)
      }
    (sessionController as? any CameraSessionFailureReporting)?.setFailureHandler { [weak self] in
      Task { @MainActor [weak self] in
        self?.nativeSessionFailed(operationGeneration: operationGeneration)
      }
    }
    do {
      let hardwareSelection = try await withCheckedThrowingContinuation { continuation in
        sessionController.start { result in
          continuation.resume(with: result)
        }
      }
      try ensureCurrent(operationGeneration)
      telemetry.record(event(.cameraSelected, cameraSelection: hardwareSelection))
      isRunning = true
      telemetry.record(event(.sessionStarted))
    } catch is CancellationError {
      if generation == operationGeneration {
        deactivateAdvisoryDelivery()
        sessionController.stop()
      }
      telemetry.record(event(.sessionStartFailed, errorCode: "cancelled"))
      throw CancellationError()
    } catch {
      if generation == operationGeneration {
        deactivateAdvisoryDelivery()
      }
      telemetry.record(event(.sessionStartFailed, errorCode: telemetryErrorCode(error)))
      throw error
    }
  }

  public func stop() {
    deactivateAdvisoryDelivery()
    generation += 1
    isStarting = false
    isRunning = false
    isCaptureInFlight = false
    sessionController.stop()
    telemetry.record(event(.sessionStopped))
  }

  public func capture(request: DocumentCaptureRequest) async throws -> CapturedDocumentPhoto {
    try Task.checkCancellation()
    let cameraRequest = CameraPhotoCaptureRequest(
      sessionID: sessionID,
      side: request.side,
      qualityGate: request.qualityGate,
      requiredObservationIdentity: request.requiredObservationIdentity,
      attemptID: request.attemptID,
      userRequestedAt: now(),
      livePDF417Candidate: request.livePDF417Candidate,
      locationAssertion: request.locationAssertion
    )
    telemetry.record(
      event(
        .captureRequested,
        side: request.side,
        captureAttemptID: cameraRequest.attemptID,
        qualityGate: request.qualityGate
      )
    )
    return try await performCapture(cameraRequest)
  }

  private func performCapture(
    _ request: CameraPhotoCaptureRequest
  ) async throws -> CapturedDocumentPhoto {
    guard isRunning, !isCaptureInFlight else {
      telemetry.record(
        event(
          .captureFailed,
          side: request.side,
          captureAttemptID: request.attemptID,
          qualityGate: request.qualityGate,
          errorCode: PhotoCaptureError.cameraNotReady.code
        )
      )
      throw PhotoCaptureError.cameraNotReady
    }

    isCaptureInFlight = true
    let operationGeneration = generation
    defer {
      if generation == operationGeneration {
        isCaptureInFlight = false
      }
    }

    do {
      let photo = try await withCheckedThrowingContinuation { continuation in
        sessionController.capture(request: request) { result in
          continuation.resume(with: result)
        }
      }
      try ensureCurrent(operationGeneration)
      telemetry.record(
        event(
          .captureCompleted,
          side: request.side,
          captureAttemptID: request.attemptID,
          qualityGate: request.qualityGate,
          photo: DocumentCameraTelemetryEvent.PhotoFacts(photo: photo)
        )
      )
      return photo
    } catch {
      telemetry.record(
        event(
          .captureFailed,
          side: request.side,
          captureAttemptID: request.attemptID,
          qualityGate: request.qualityGate,
          errorCode: telemetryErrorCode(error)
        )
      )
      throw error
    }
  }

  private func authorizeCamera() async throws {
    let permissionState = await authorizationProvider.resolveAuthorization()
    telemetry.record(
      event(
        .authorizationResolved,
        permissionState: telemetryAuthorization(permissionState)
      )
    )

    let error: PhotoCaptureError?
    switch permissionState {
    case .authorized:
      error = nil
    case .denied:
      error = .cameraPermissionDenied
    case .indeterminate:
      error = .cameraAuthorizationIndeterminate
    }

    if let error {
      telemetry.record(event(.sessionStartFailed, errorCode: error.code))
      throw error
    }
  }

  private func event(
    _ name: DocumentCameraTelemetryEvent.Name,
    side: DocumentSide? = nil,
    captureAttemptID: UUID? = nil,
    qualityGate: DocumentCaptureQualityGate? = nil,
    permissionState: DocumentCameraTelemetryEvent.Authorization? = nil,
    errorCode: String? = nil,
    photo: DocumentCameraTelemetryEvent.PhotoFacts? = nil,
    cameraSelection: DocumentCameraHardwareSelection? = nil,
    previewGeometry: DocumentCameraPreviewGeometryDiagnostic? = nil
  ) -> DocumentCameraTelemetryEvent {
    DocumentCameraTelemetryEvent(
      timestamp: now(),
      sessionID: sessionID,
      name: name,
      side: side,
      captureAttemptID: captureAttemptID,
      qualityGate: qualityGate,
      permissionState: permissionState,
      errorCode: errorCode,
      photo: photo,
      cameraSelection: cameraSelection,
      previewGeometry: previewGeometry
    )
  }
}

#if os(iOS)
  extension DocumentCamera: DocumentCameraPreviewProviding {
    public func attachPreview(to previewLayer: AVCaptureVideoPreviewLayer) {
      sessionController.attachPreview(to: previewLayer)
      telemetry.record(event(.previewAttached))
    }

    public func setPreviewGeometryInvalidationHandler(
      _ handler: @escaping @MainActor @Sendable (UInt64) -> Void
    ) {
      (sessionController as? any CameraSessionGeometryEpochProviding)?
        .setPreviewGeometryInvalidationHandler(handler)
    }

    public func updatePreviewGeometry(
      orientation: DocumentCameraOrientation, region: DocumentCameraGuideRegion?,
      sourceGeneration: UInt64
    ) {
      (sessionController as? any CameraSessionGeometryEpochProviding)?
        .updatePreviewGeometry(
          orientation: orientation, region: region, sourceGeneration: sourceGeneration
        )
    }

    public func updateCaptureOrientation(_ orientation: DocumentCameraOrientation) {
      sessionController.updateCaptureOrientation(orientation)
    }

    public func updateDocumentGuideRegion(_ region: DocumentCameraGuideRegion?) {
      sessionController.updateDocumentGuideRegion(region)
    }

    public func recordPreviewGeometry(_ diagnostic: DocumentCameraPreviewGeometryDiagnostic) {
      telemetry.record(event(.previewGeometry, previewGeometry: diagnostic))
    }
  }
#endif

extension DocumentCamera {
  public func updateCaptureFeedback(_ feedback: DocumentCaptureFeedback) {
    captureFeedback = feedback
    captureFeedbackHandler?(feedback)
  }

  public func setCaptureFeedbackHandler(
    _ handler: @escaping @MainActor @Sendable (DocumentCaptureFeedback) -> Void
  ) {
    captureFeedbackHandler = handler
    handler(captureFeedback)
  }
}

extension DocumentCamera {
  /// Await native camera release before handing acquisition to another SDK.
  public func stopAndWait() async throws {
    stop()
    let operationGeneration = generation
    guard let controller = sessionController as? any CameraSessionStopAwaiting else {
      throw PhotoCaptureError.cameraNotReady
    }
    let stopped = await withCheckedContinuation { continuation in
      controller.afterStop { continuation.resume(returning: $0) }
    }
    try ensureCurrent(operationGeneration)
    guard stopped, !isStarting, !isRunning else { throw PhotoCaptureError.cameraNotReady }
  }
}

extension DocumentCamera {
  private func nativeSessionFailed(operationGeneration: Int) {
    guard generation == operationGeneration, isRunning || isStarting else { return }
    deactivateAdvisoryDelivery()
    generation += 1
    isStarting = false
    isRunning = false
    isCaptureInFlight = false
    telemetry.record(event(.sessionStopped, errorCode: "native_session_failure"))
  }

  private func telemetryErrorCode(_ error: any Error) -> String {
    if let error = error as? PhotoCaptureError {
      return error.code
    }
    if error is CancellationError {
      return "cancelled"
    }
    return "unexpected_error"
  }
}

extension DocumentCamera {
  private func telemetryAuthorization(
    _ permissionState: CameraAuthorizationDecision
  ) -> DocumentCameraTelemetryEvent.Authorization {
    switch permissionState {
    case .authorized:
      .authorized
    case .denied:
      .denied
    case .indeterminate:
      .indeterminate
    }
  }
}

extension DocumentCamera {
  func ensureCurrent(_ operationGeneration: Int) throws {
    guard generation == operationGeneration, !Task.isCancelled else {
      throw CancellationError()
    }
  }
}

extension DocumentCamera {
  private func deactivateAdvisoryDelivery() {
    geometryDelivery.deactivate()
    tiltGuidanceDelivery.deactivate()
    tiltGuidanceAttemptID = nil
  }
}
