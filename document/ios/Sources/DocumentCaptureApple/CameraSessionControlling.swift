import AVFoundation
import DocumentSDK

/// Completion acknowledges that the serial native owner finished stopping.
protocol CameraSessionStopAwaiting: Sendable {
  func afterStop(_ completion: @escaping @Sendable (Bool) -> Void)
}

/// Reports native lifecycle failure without exposing AVFoundation state across executors.
protocol CameraSessionFailureReporting: Sendable {
  func setFailureHandler(_ handler: @escaping @Sendable () -> Void)
}

protocol CameraSessionControlling: Sendable {
  func setQualityObservationHandler(
    configuration: DocumentCameraDiagnosticsConfiguration,
    handler: @escaping @Sendable (DocumentCaptureQualityObservation) -> Void
  )

  func start(
    completion:
      @escaping @Sendable (
        Result<DocumentCameraHardwareSelection, PhotoCaptureError>
      ) -> Void
  )

  func stop()

  func capture(
    request: CameraPhotoCaptureRequest,
    completion:
      @escaping @Sendable (
        Result<CapturedDocumentPhoto, PhotoCaptureError>
      ) -> Void
  )

  #if os(iOS)
    @MainActor
    func attachPreview(to previewLayer: AVCaptureVideoPreviewLayer)

    @MainActor
    func updateCaptureOrientation(_ orientation: DocumentCameraOrientation)

    @MainActor
    func updateDocumentGuideRegion(_ region: DocumentCameraGuideRegion?)
  #endif
}
