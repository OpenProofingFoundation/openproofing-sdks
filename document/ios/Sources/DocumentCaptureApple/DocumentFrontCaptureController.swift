import Foundation
import DocumentSDK

/// Optical front acquisition without durable custody or identity-verification policy.
@MainActor
public final class DocumentFrontCaptureController {
  public let camera: DocumentCamera
  public private(set) var latestQuality: DocumentCaptureQualityObservation?
  public var latestMotion: DocumentTemporalMotionSample? { motion.latestSample }
  public private(set) var running = false
  public private(set) var capturing = false
  public private(set) var automaticCaptureAvailable = false
  /// Advisory availability from the latest published observation. Native admission
  /// independently rechecks the current camera graph, guide and optical epoch.
  public var manualCaptureAvailable: Bool {
    guard running, !starting, stopping == nil, !capturing, !completed,
      let value = latestQuality, let armedAt, value.timestamp > armedAt else { return false }
    let metrics = value.metrics
    let guide: DocumentCameraGuideRegion?
    if let centerX = metrics.guideCenterX, let centerY = metrics.guideCenterY,
      let width = metrics.guideWidth, let height = metrics.guideHeight {
      guide = .init(minX: centerX - width / 2, minY: centerY - height / 2,
        width: width, height: height)
    } else { guide = nil }
    return DocumentCaptureAdmissionPolicy().failure(in: .init(
      isConfigured: running, isRunning: running, isCaptureInFlight: capturing,
      isGuideAvailable: guide?.normalizedTopLeftRect != nil,
      currentGeometryRevision: value.geometryRevision, observation: value, side: .front,
      qualityGate: .operatorInitiatedAdvisory, admissionTime: now())) == nil
  }
  public var onChange: @MainActor () -> Void = {}
  public var onAutomaticCapture: (@MainActor (DocumentCaptureObservationIdentity) -> Void)?

  private let now: @Sendable () -> Date
  private let operations: DocumentFrontCaptureOperations
  private let motion: DocumentLevelMotionSource
  private var coordinator: DocumentAutoCaptureCoordinator
  private var armedAt: Date?
  private var generation: UInt64 = 0
  private var starting = false
  private var completed = false
  private var retirementFailed = false
  private var stopping: Task<Void, Error>?

  public convenience init(now: @escaping @Sendable () -> Date, notifications: NotificationCenter) {
    let camera = DocumentCamera(now: now, notifications: notifications,
      configuration: .geometry,
      diagnostics: .init(includesAdaptiveCapture: true, includesLiveContentAnalysis: false))
    let delivery = DocumentFrontQualityDelivery(stream: camera.qualityObservations)
    self.init(camera: camera, now: now,
      operations: .init(start: { try await camera.start() },
        stop: { try await camera.stopAndWait() }, capture: { try await camera.capture(request: $0) },
        observe: { delivery.observe($0) }, endObservation: { delivery.endObservation() }),
      motion: DocumentLevelMotionSource(onSample: { _ in }))
  }

  init(camera: DocumentCamera, now: @escaping @Sendable () -> Date,
       operations: DocumentFrontCaptureOperations, motion: DocumentLevelMotionSource) {
    self.camera = camera
    self.now = now
    self.operations = operations
    self.motion = motion
    coordinator = Self.makeCoordinator()
  }

  public func start() async throws {
    if let stopping { try await stopping.value }
    guard !running else { return }
    guard !starting, !retirementFailed else { throw PhotoCaptureError.cameraNotReady }
    generation &+= 1
    let token = generation
    starting = true
    do {
      try await operations.start()
      guard token == generation, starting, !Task.isCancelled else { throw CancellationError() }
      starting = false
      running = true
      completed = false
      latestQuality = nil
      coordinator = Self.makeCoordinator()
      coordinator.begin(side: .front)
      armedAt = now()
      automaticCaptureAvailable = true
      camera.updateCaptureFeedback(.seeking)
      operations.observe { [weak self] value in self?.receive(value, generation: token) }
      motion.startRecording(sessionID: camera.sessionID)
      onChange()
    } catch {
      if token == generation {
        starting = false
        automaticCaptureAvailable = false
        onChange()
      }
      throw error
    }
  }

  public func stop() async throws {
    if let stopping { try await stopping.value; return }
    generation &+= 1
    starting = false
    running = false
    capturing = false
    completed = false
    latestQuality = nil
    armedAt = nil
    automaticCaptureAvailable = false
    operations.endObservation()
    motion.stop()
    let work = Task { @MainActor [operations] in try await operations.stop() }
    stopping = work
    onChange()
    do {
      try await work.value
      retirementFailed = false
      stopping = nil
    } catch {
      retirementFailed = true
      stopping = nil
      throw error
    }
  }

  public func capture(observationIdentity: DocumentCaptureObservationIdentity? = nil) async throws
    -> CapturedDocumentPhoto {
    guard running, !starting, stopping == nil, !capturing, !completed else {
      throw PhotoCaptureError.cameraNotReady
    }
    let token = generation
    capturing = true
    automaticCaptureAvailable = false
    camera.updateCaptureFeedback(.capturing)
    onChange()
    let request = DocumentCaptureRequest(side: .front,
      qualityGate: observationIdentity == nil ? .operatorInitiatedAdvisory : .qualityDrivenAutoCapture,
      requiredObservationIdentity: observationIdentity)
    do {
      let photo = try await operations.capture(request)
      guard token == generation, running, !Task.isCancelled else { throw CancellationError() }
      let motionEvidence = try motion.finishRecording(photo: photo, attemptID: request.attemptID)
      completed = true
      capturing = false
      operations.endObservation()
      motion.stop()
      camera.updateCaptureFeedback(.stored)
      onChange()
      return photo.retainingMotion(motionEvidence)
    } catch {
      if token == generation {
        motion.restartRecording()
        capturing = false
        camera.updateCaptureFeedback(.failed)
        onChange()
      }
      throw error
    }
  }

  private func receive(_ value: DocumentCaptureQualityObservation, generation token: UInt64) {
    guard token == generation, running, !capturing, !completed else { return }
    guard let armedAt, value.timestamp > armedAt,
      DocumentCaptureObservationFreshness.fresh(value, at: now()) else { return }
    latestQuality = value
    if value.cameraControl?.adaptiveFailureReason != nil {
      automaticCaptureAvailable = false
      camera.updateCaptureFeedback(.failed)
    } else {
      camera.updateCaptureFeedback(value.assessment.ready ? .ready : .seeking)
    }
    let decision = automaticCaptureAvailable
      ? coordinator.observe(side: .front, observation: value) : .observing
    if case .trigger = decision {
      automaticCaptureAvailable = false
      onChange()
      onAutomaticCapture?(DocumentCaptureObservationIdentity(observation: value))
    } else {
      if case .exhausted = decision { automaticCaptureAvailable = false }
      onChange()
    }
  }

  private static func makeCoordinator() -> DocumentAutoCaptureCoordinator {
    let tuning = DocumentCaptureTuningOverrides()
    return .init(requireQualityReadiness: true, requiresContentSignal: false,
      maximumAttemptsPerSide: DocumentCaptureTuning.AutoCapture.journeyMaximumAttemptsPerSide,
      frontRequiredConsecutiveObservations: tuning.frontObservations,
      backRequiredConsecutiveObservations: tuning.backObservations)
  }
}

@MainActor
struct DocumentFrontCaptureOperations {
  let start: @MainActor () async throws -> Void
  let stop: @MainActor () async throws -> Void
  let capture: @MainActor (DocumentCaptureRequest) async throws -> CapturedDocumentPhoto
  let observe: @MainActor (@escaping @MainActor (DocumentCaptureQualityObservation) -> Void) -> Void
  let endObservation: @MainActor () -> Void
}

/// Keep one iterator: cancelling it would permanently finish the camera's shared stream.
/// Retiring the handler stops front delivery while the camera can continue serving its host.
@MainActor
final class DocumentFrontQualityDelivery {
  private let stream: AsyncStream<DocumentCaptureQualityObservation>
  private var task: Task<Void, Never>?
  private var handler: (@MainActor (DocumentCaptureQualityObservation) -> Void)?

  init(stream: AsyncStream<DocumentCaptureQualityObservation>) { self.stream = stream }

  deinit { task?.cancel() }

  func observe(_ handler: @escaping @MainActor (DocumentCaptureQualityObservation) -> Void) {
    self.handler = handler
    guard task == nil else { return }
    task = Task { @MainActor [weak self, stream] in
      for await value in stream {
        guard !Task.isCancelled, let self else { return }
        self.handler?(value)
      }
    }
  }

  func endObservation() { handler = nil }
}
