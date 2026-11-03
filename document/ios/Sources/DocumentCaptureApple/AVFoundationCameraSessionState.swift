import AVFoundation
import Foundation

// Mutable state is exclusively owned by the controller's serial session queue.
extension AVFoundationCameraSessionController {
  final class State {
    init(now: @escaping @Sendable () -> Date) {
      #if os(iOS)
        adaptiveController = DocumentAdaptiveCameraController(now: now)
      #endif
    }

    let captureSession = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()
    let videoOutput = AVCaptureVideoDataOutput()
    let metadataOutput = AVCaptureMetadataOutput()
    var pdf417Delegate: LivePDF417MetadataDelegate?
    var pdf417Candidate: (payload: String, observedAt: Date)?
    var pdf417Confirmation = LivePDF417ReadConfirmation()
    #if os(iOS)
      var adaptiveController: DocumentAdaptiveCameraController
    #endif
    var activeInput: AVCaptureDeviceInput?
    var deviceObservations: [NSKeyValueObservation] = []
    var observationEpoch: UInt64 = 0
    var selection = DocumentCameraDeviceChoice.automatic
    var previewInvalidationHandler: (@MainActor @Sendable (UInt64) -> Void)?
    var opticalRevision: UInt64 = 0
    var opticalSignature = ""
    var needsOpticalReconfiguration = false
    var isConfiguring = false
    var previewRefreshPending = false
    var adaptiveCaptureEnabled = true
    var tiltGuidance = NativeTiltGuidanceState()
    var nativeOperationUncertain = false
    var pendingDiagnosticID: UUID?
    var pendingDiagnosticCompletion:
      (@Sendable (Result<DocumentCameraNativeSnapshot, PhotoCaptureError>) -> Void)?
    var manualFocusAppliedDeviceTime: Double?
    var failureHandler: (@Sendable () -> Void)?
    var captureAdmissionRequested = true
    var nativeCaptureReady = false
    var geometryRevision: UInt64 = 0
    var geometryObservationGeneration: UInt64 = 0
    var captureAdmissionEnabled: Bool { captureAdmissionRequested && nativeCaptureReady }
    var zoomRetirementFailed = false
    var graphReleasePending = false
    var graphDrainPending = false
    var stopWaiters: [@Sendable (Bool) -> Void] = []
    var isConfigured = false
    var processors: [Int64: PhotoCaptureProcessor] = [:]
    var hardwareSelection: DocumentCameraHardwareSelection?
    var activeDevice: AVCaptureDevice?
    var temporalRecorder: DocumentTemporalRecorder?
    var temporalReadbackTimer: DispatchSourceTimer?
    var temporalObservationEpoch: UInt64 = 0
    var temporalClockObservation: NSKeyValueObservation?
    var temporalNotifications: [NSObjectProtocol] = []
    var frameAnalyzer: DocumentFrameAnalyzer?
    var latestQualityObservation: DocumentCaptureQualityObservation?
    #if os(iOS)
      var captureOrientation = DocumentCameraOrientation.portrait
      var captureDeviceGuideRegion: DocumentCameraGuideRegion?
      var videoBufferGuideRegion: DocumentCameraGuideRegion?
    #endif
  }
}
