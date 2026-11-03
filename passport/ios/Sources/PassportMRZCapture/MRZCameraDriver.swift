#if os(iOS)
  @preconcurrency import AVFoundation
  import Foundation
  import OSLog
  import Vision

  /// All mutable capture and Vision state is confined to one serial queue. Vision completes
  /// inside the delegate call, so Apple's late-frame discard bounds acquisition work to one.
  /// https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/alwaysdiscardslatevideoframes
  /// https://developer.apple.com/documentation/vision/vnrecognizetextrequest
  final class MRZCameraDriver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
  {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "capture.mrz.serial")
    private let policy: MRZOCRPolicy
    private let notificationsCenter: NotificationCenter
    private var onFrame: (@MainActor @Sendable (MRZOCRFrame) -> Void)?
    private var onFailure: (@MainActor @Sendable (MRZCameraFailure) -> Void)?
    private var notifications: [NSObjectProtocol] = []
    private var orientation: MRZCaptureOrientation = .portrait
    private var guideRevision: UUID?
    private let logger = Logger(subsystem: "com.kenshiki.passport", category: "MRZCamera")

    func updateGuideRegion(_: CGRect?, revision: UUID) {
      queue.async { self.guideRevision = revision }
    }

    init(policy: MRZOCRPolicy, notificationsCenter: NotificationCenter) {
      self.policy = policy
      self.notificationsCenter = notificationsCenter
    }

    func updateOrientation(_ value: MRZCaptureOrientation) {
      queue.async { self.orientation = value }
    }

    func start(
      onFrame: @escaping @MainActor @Sendable (MRZOCRFrame) -> Void,
      onFailure: @escaping @MainActor @Sendable (MRZCameraFailure) -> Void
    ) async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        queue.async {
          do {
            guard (1...10).contains(self.policy.candidatesPerRow),
              self.policy.minimumTextHeight.isFinite,
              (0...1).contains(self.policy.minimumTextHeight)
            else { throw MRZCameraFailure.invalidConfiguration }
            self.teardown()
            self.session.beginConfiguration()
            do {
              guard let device = MRZCameraSelection.device()
              else { throw MRZCameraFailure.unavailable }
              let input = try AVCaptureDeviceInput(device: device)
              guard self.session.canAddInput(input) else { throw MRZCameraFailure.captureFailed }
              self.session.addInput(input)
              let output = AVCaptureVideoDataOutput()
              output.alwaysDiscardsLateVideoFrames = true
              output.setSampleBufferDelegate(self, queue: self.queue)
              guard self.session.canAddOutput(output) else { throw MRZCameraFailure.captureFailed }
              self.session.addOutput(output)
              try MRZCameraSelection.configure(device)
              // Preserve unrotated buffers; Vision applies the same rotation as the preview.
              if let connection = output.connection(with: .video),
                connection.isVideoRotationAngleSupported(0)
              {
                connection.videoRotationAngle = 0
              }
              self.session.commitConfiguration()
            } catch {
              self.session.commitConfiguration()
              throw error
            }
            self.onFrame = onFrame
            self.onFailure = onFailure
            for name in [
              AVCaptureSession.wasInterruptedNotification,
              AVCaptureSession.runtimeErrorNotification,
            ] {
              let token = self.notificationsCenter.addObserver(
                forName: name, object: self.session, queue: nil
              ) { [weak self] _ in
                self?.queue.async { [weak self] in
                  guard let self, let failed = self.onFailure else { return }
                  self.teardown()
                  Task { @MainActor in failed(.interrupted) }
                }
              }
              self.notifications.append(token)
            }
            self.session.startRunning()
            guard self.session.isRunning else { throw MRZCameraFailure.captureFailed }
            self.diagnoseCamera()
            continuation.resume()
          } catch {
            self.teardown()
            continuation.resume(throwing: error)
          }
        }
      }
    }

    /// Actual native readback; fixed lens vocabulary and scalar settings only, never identifiers.
    private func diagnoseCamera() {
      guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
      let lens = MRZCameraSelection.lens(for: device.deviceType).rawValue
      let primary = device.activePrimaryConstituent.map {
        MRZCameraSelection.lens(for: $0.deviceType).rawValue
      } ?? "none"
      let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
      let switching = device.primaryConstituentDeviceSwitchingBehavior == .auto
      logger.notice("mrz_camera lens=\(lens, privacy: .public) primary=\(primary, privacy: .public) virtual=\(device.isVirtualDevice) switchingAutomatic=\(switching) zoom=\(Double(device.videoZoomFactor)) focusMode=\(device.focusMode.rawValue) exposureMode=\(device.exposureMode.rawValue) adjustingFocus=\(device.isAdjustingFocus) adjustingExposure=\(device.isAdjustingExposure) videoWidth=\(dimensions.width) videoHeight=\(dimensions.height)")
    }

    func stop() async {
      await withCheckedContinuation { continuation in
        queue.async {
          self.teardown()
          continuation.resume()
        }
      }
    }

    private func teardown() {
      onFrame = nil
      onFailure = nil
      notifications.forEach(notificationsCenter.removeObserver)
      notifications.removeAll()
      if session.isRunning { session.stopRunning() }
      session.beginConfiguration()
      for output in session.outputs {
        (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
        session.removeOutput(output)
      }
      for input in session.inputs { session.removeInput(input) }
      session.commitConfiguration()
    }

    func captureOutput(
      _ _: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
      from _: AVCaptureConnection
    ) {
      guard let publish = onFrame, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        return
      }
      autoreleasepool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = policy.minimumTextHeight
        do {
          try VNImageRequestHandler(
            cvPixelBuffer: buffer, orientation: orientation.imageOrientation
          )
          .perform([request])
          let frame = MRZOCRFrame(
            candidates: (request.results ?? []).map {
              $0.topCandidates(policy.candidatesPerRow).map(\.string)
            },
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds, policy: policy,
            orientation: orientation,
            rowBounds: (request.results ?? []).map(\.boundingBox),
            guideRevision: guideRevision)
          Task { @MainActor in publish(frame) }
        } catch {
          guard let failed = onFailure else { return }
          // Return from AVFoundation's delegate before closing the camera graph.
          queue.async {
            self.teardown()
            Task { @MainActor in failed(.recognitionFailed) }
          }
        }
      }
    }
  }
#endif
