import AVFoundation
import Foundation
import DocumentSDK

extension AVFoundationCameraSessionController {
  func makeAdmissionSnapshot(
    request: CameraPhotoCaptureRequest, admittedAt: Date, photoSettingsUniqueID: Int64,
    nativeCaptureDeviceGuideRegion: DocumentCameraGuideRegion?,
    captureOrientation: DocumentCameraOrientation?
  ) -> DocumentCaptureAdmissionSnapshot {
    DocumentCaptureAdmissionSnapshot(
      request: request, admittedAt: admittedAt, photoSettingsUniqueID: photoSettingsUniqueID,
      observation: state.latestQualityObservation,
      nativeCaptureDeviceGuideRegion: nativeCaptureDeviceGuideRegion,
      captureOrientation: captureOrientation, nativeCamera: try? nativeSnapshot())
  }

  func capturePhoto(
    settings: AVCapturePhotoSettings,
    admission: DocumentCaptureAdmissionSnapshot,
    locationAssertion: CaptureLocationAssertion? = nil,
    completion: @escaping @Sendable (Result<CapturedDocumentPhoto, PhotoCaptureError>) -> Void
  ) {
    let identifier = settings.uniqueID
    let processor = PhotoCaptureProcessor(
      assembler: CapturedDocumentPhotoAssembler(now: now),
      admission: admission,
      locationAssertion: locationAssertion
    ) { [self] result in
      sessionQueue.async { [self] in
        completeTemporalCapture(identifier: identifier, result: result, completion: completion)
      }
    }

    state.processors[identifier] = processor
    state.photoOutput.capturePhoto(with: settings, delegate: processor)
  }

  func controlsPermitCapture(_ request: CameraPhotoCaptureRequest) -> Bool {
    #if os(iOS)
      if request.qualityGate == .qualityDrivenAutoCapture {
        guard state.adaptiveCaptureEnabled else { return false }
        guard let device = state.activeDevice,
          let admitted = state.latestQualityObservation?.cameraControl,
          admitted.adaptiveFailureReason == nil, admitted.settled
        else { return false }
        let current = AVFoundationAdaptiveDevice(device: device).snapshot(at: now())
        return DocumentNativeControlAdmission.matches(admitted: admitted, current: current)
      }
    #endif
    return true
  }

  func configureIfNeeded() throws {
    guard !state.isConfigured else { return }

    state.isConfiguring = true
    state.captureSession.beginConfiguration()
    defer {
      if !state.isConfigured {
        // A failed attempt must not leave an input or output attached for retry.
        state.videoOutput.setSampleBufferDelegate(nil, queue: nil)
        for output in state.captureSession.outputs {
          state.captureSession.removeOutput(output)
        }
        for input in state.captureSession.inputs {
          state.captureSession.removeInput(input)
        }
        state.frameAnalyzer = nil
        state.activeInput = nil
        state.activeDevice = nil
        state.hardwareSelection = nil
        state.latestQualityObservation = nil
      }
      state.captureSession.commitConfiguration()
      state.isConfiguring = false
    }
    state.captureSession.sessionPreset = .photo

    guard let selectedCamera = policy.selectCamera(choice: state.selection) else {
      throw PhotoCaptureError.backCameraUnavailable
    }
    let device = selectedCamera.device

    let input: AVCaptureDeviceInput
    do {
      input = try AVCaptureDeviceInput(device: device)
    } catch {
      throw PhotoCaptureError.configurationFailed(String(describing: error))
    }

    guard state.captureSession.canAddInput(input) else {
      throw PhotoCaptureError.cannotAddCameraInput
    }
    state.captureSession.addInput(input)
    state.activeInput = input

    guard state.captureSession.canAddOutput(state.photoOutput) else {
      throw PhotoCaptureError.cannotAddPhotoOutput
    }
    state.captureSession.addOutput(state.photoOutput)
    try configureVideoAnalysisOutput()
    if policy.configuration.livePDF417 { try configurePDF417Output() }
    #if os(iOS)
      applyStoredOrientation()
    #endif
    try policy.configure(device: device, photoOutput: state.photoOutput)
    state.activeDevice = device
    state.hardwareSelection = selectedCamera.hardwareSelection
    state.isConfigured = true
    observeOpticalChanges(device)
  }

  func configureVideoAnalysisOutput() throws {
    guard state.captureSession.canAddOutput(state.videoOutput) else {
      throw PhotoCaptureError.cannotAddVideoOutput
    }
    state.captureSession.addOutput(state.videoOutput)
    state.videoOutput.alwaysDiscardsLateVideoFrames = true
    state.videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String:
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ]

    state.geometryObservationGeneration &+= 1
    let geometryGeneration = state.geometryObservationGeneration
    let analyzer = DocumentFrameAnalyzer(
      now: now,
      configuration: diagnosticsConfiguration,
      observationHandler: { [weak self] observation in
        guard let self else { return }
        sessionQueue.async { [self] in
          #if os(iOS)
            guard
              observation.geometryRevision == state.geometryRevision,
              state.videoBufferGuideRegion != nil,
              state.captureSession.isRunning
            else { return }
          #endif
          publishAdaptiveObservation(observation)
        }
      },
      // Legacy point-only callbacks have no geometry epoch. Native AF remains
      // continuous; adaptive retargeting uses the versioned observation path.
      focusHandler: { _ in },
      temporalRecorder: state.temporalRecorder,
      geometryHandler: { [weak self] packet in
        guard let self else { return }
        enqueueLiveGeometry(packet, generation: geometryGeneration)
      },
      tiltGuidanceHandler: { [weak self] value in
        self?.enqueueTiltGuidance(value, generation: geometryGeneration)
      }
    )
    state.frameAnalyzer = analyzer
    state.videoOutput.setSampleBufferDelegate(analyzer, queue: analyzer.ingressQueue)
    #if os(iOS)
      analyzer.updateGuideRegion(
        state.videoBufferGuideRegion,
        geometryRevision: state.geometryRevision
      )
    #endif
  }
}
