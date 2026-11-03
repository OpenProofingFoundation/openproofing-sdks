#if os(iOS)
  import Combine
  import Foundation
  import DocumentCaptureApple
  import DocumentSDK
  import CaptureEvidenceCustody
  import DocumentCaptureJournal

  public enum CaptureSessionConsent: String, Sendable { case permitted, withheld }
  public enum CaptureSessionPhase: String, Sendable {
    case inactive, capturing, reviewing, preparingBack, completed
  }
  public enum CaptureSessionStartup: String, Sendable {
    case permissionState = "authorization"
    case storage, settlement, recording, cameraRelease, cameraStart
  }
  public enum CaptureSessionIssue: String, Sendable {
    case consentRequired, locationRequired, cameraUnavailable, recordingTerminated
    case captureFailed, originalSavedBindingFailed, analysisTransitionFailed, custodyErased,
      nativeControlsPaused
    /// A document presence policy is configured and its tilt guidance has not completed, so the
    /// front still is not taken: capture-now and skip are refused (S-02).
    case documentPresenceRequired
    /// The presence policy's tilt guidance cannot complete in this recording (its reserve ran
    /// out), so no front still is taken until the camera starts a new recording (S-02).
    case documentPresenceUnavailable
  }
  public enum CaptureSessionOriginalState: String, Sendable { case idle, capturing, retaining }
  public enum CaptureSessionRecordingState: String, Sendable {
    case inactive, recording, settling, complete, partial, failed
  }
  public struct CaptureSessionAttemptIdentity: Sendable, Equatable {
    public let workflowID: UUID
    public let captureID: UUID
    public let generation: Int
  }
  public enum CaptureSessionEvent: Sendable {
    case originalRetained(identity: CaptureSessionAttemptIdentity, profile: CaptureRecords.Profile)
    case recordingSettled(DocumentJourneyRecordingReceipt)
    case issue(CaptureSessionIssue)
    case processingCompleted(
      identity: CaptureSessionAttemptIdentity, assessment: DocumentCaptureExpectationAssessment)
    case processingFailed(identity: CaptureSessionAttemptIdentity)
  }

  public enum LicenseBackCaptureMode: Sendable { case document, livePDF417 }

  public struct CaptureSessionConfiguration: Sendable {
    public let licenseBackCaptureMode: LicenseBackCaptureMode
    public let notifications: NotificationCenter
    public let custody: CaptureCustodyConfiguration
    public let signing: CaptureSigningConfiguration
    public let clock: CaptureRecordingClock
    public let consent: CaptureSessionConsent
    public let tuning: DocumentCaptureTuningOverrides
    public let recordingPolicy: CaptureRecordingPolicy
    public let tiltConfiguration: DocumentTiltConfiguration
    public let requiresLocation: Bool
    /// The document presence check (S-02). Nil, the default, leaves capture as it was: no SDK
    /// value exists until the owner's device measurement (decision 13).
    public let documentPresence: DocumentPresencePolicy?
    public init(
      notifications: NotificationCenter, custody: CaptureCustodyConfiguration, signing: CaptureSigningConfiguration, clock: CaptureRecordingClock,
      consent: CaptureSessionConsent, tuning: DocumentCaptureTuningOverrides = .init(),
      recordingPolicy: CaptureRecordingPolicy = .retainedV2,
      tiltConfiguration: DocumentTiltConfiguration = .provisionalV2,
      requiresLocation: Bool = true,
      licenseBackCaptureMode: LicenseBackCaptureMode = .document,
      documentPresence: DocumentPresencePolicy? = nil
    ) {
      self.notifications = notifications
      self.documentPresence = documentPresence
      self.licenseBackCaptureMode = licenseBackCaptureMode
      self.custody = custody
      self.signing = signing
      self.clock = clock
      self.consent = consent
      self.tuning = tuning
      self.recordingPolicy = recordingPolicy
      self.tiltConfiguration = tiltConfiguration
      self.requiresLocation = requiresLocation
    }
  }

  /// Acquisition mechanics extracted from the validation host. Hosts render these operational
  /// states and own navigation; supplementary analysis never decides admission of an original.
  @MainActor
  public final class CaptureSession: ObservableObject {
    public private(set) var configuration: CaptureSessionConfiguration
    public internal(set) var location: CaptureSessionLocation
    public let tiltGuidance = CaptureSessionTiltState()
    public private(set) var custody: CaptureCustodyRuntime?
    // Internal test composition only. Public construction always selects hardware-bound custody.
    var makeCustody: (CaptureCustodyConfiguration, CaptureSigningConfiguration) throws -> CaptureCustodyRuntime = {
      try CaptureCustodyRuntime(configuration: $0, signing: $1)
    }
    var makeErasureCustody: (CaptureCustodyConfiguration) throws -> CaptureCustodyRuntime = {
      try CaptureCustodyRuntime(erasing: $0)
    }
    public var store: CaptureEvidenceStore? { custody?.store }
    @Published public private(set) var camera: DocumentCamera
    @Published public internal(set) var profile: CaptureRecords.Profile = .licenseFront
    @Published public internal(set) var phase: CaptureSessionPhase = .inactive
    @Published public internal(set) var startup: CaptureSessionStartup?
    @Published public internal(set) var issue: CaptureSessionIssue?
    @Published public internal(set) var ready = false
    @Published public internal(set) var busy = false
    @Published public internal(set) var autoArmed = false
    @Published public internal(set) var activeCaptureAttempt: UUID?
    @Published public internal(set) var originalState: CaptureSessionOriginalState = .idle
    @Published public internal(set) var recordingState: CaptureSessionRecordingState = .inactive
    @Published public internal(set) var selectedCaptureID: UUID?
    @Published public internal(set) var recoveryCaptureID: UUID?
    @Published public internal(set) var latestQuality: DocumentCaptureQualityObservation?
    @Published public internal(set) var latestGeometry: DocumentLiveGeometryObservation?
    public var workflowID = UUID()
    public var journeyRevision: UInt64?
    public internal(set) var retainedFrontCaptureID: UUID?
    public let processingQueue: CaptureProcessingQueue
    /// Changes when processing publication is cancelled; camera replacement may preserve it.
    public var processingGeneration: UUID { processingEpoch }
    var processingEpoch = UUID()
    var consent: CaptureSessionConsent
    public var generation: Int { cameraGeneration }
    /// The camera startup cause, for host permission and capability recovery.
    /// Presentation remains host-owned; raw provider text is not a user message.
    public var startupCameraFailure: PhotoCaptureError? { startupFailure as? PhotoCaptureError }
    var startupFailure: (any Error)?
    var cameraGeneration = 0
    var cameraFactory: (@MainActor (CaptureRecords.Profile) -> DocumentCamera)?
    var nativeControlsBusy = false
    var adaptiveControlsEnabled = true
    var erasing = false
    var eraseOperation: Task<Void, Error>?
    var processingIdentities: [UUID: CaptureSessionAttemptIdentity] = [:]
    var operation: Task<Void, Never>?
    var recordingSettlement: Task<Void, Never>?
    var qualityTask: Task<Void, Never>?
    var geometryObservationID = UUID()
    var geometryTask: Task<Void, Never>?
    public var recordingJournal: CaptureRecordingJournal? { journeyRecording }
    var journeyRecording: CaptureRecordingJournal?
    var restartWhenIdle = false
    var restartForReview = false
    var armedAt: Date
    var autoCaptureCoordinator: DocumentAutoCaptureCoordinator
    let onEvent: @MainActor (CaptureSessionEvent) -> Void
    let telemetry: DocumentCameraTelemetry
    var tiltActions: CaptureSessionTiltActions
    var capturePhoto:
      @MainActor (DocumentCamera, DocumentCaptureRequest) async throws -> CapturedDocumentPhoto = {
        try await $0.capture(request: $1)
      }
    var analysisUpdater:
      @MainActor (DocumentCamera, DocumentCameraDiagnosticsConfiguration) async throws -> Void = {
        try await $0.updateCaptureAnalysis($1)
      }

    public init(
      configuration: CaptureSessionConfiguration,
      telemetry: DocumentCameraTelemetry = .disabled,
      processingOperations: CaptureDocumentOperations = .init(),
      onEvent: @escaping @MainActor (CaptureSessionEvent) -> Void = { _ in }
    ) {
      self.configuration = configuration
      processingQueue = CaptureProcessingQueue(worker: { job in
        try await CaptureDocumentRecovery.process(
          captureID: job.captureID, store: job.store,
          operations: processingOperations, onStage: { job.progress($0) })
      })
      self.telemetry = telemetry
      self.onEvent = onEvent
      consent = configuration.consent
      location = CaptureSessionLocation(now: configuration.clock.now)
      tiltActions = .init(configuration: configuration.tiltConfiguration)
      camera = Self.makeCamera(
        notifications: configuration.notifications, profile: .licenseFront, tuning: configuration.tuning, telemetry: telemetry,
        now: configuration.clock.now, presence: configuration.documentPresence)
      armedAt = configuration.clock.now()
      autoCaptureCoordinator = Self.makeCoordinator(
        profile: .licenseFront, tuning: configuration.tuning)
      configureProcessingQueue()
    }

    static func makeCamera(
      notifications: NotificationCenter, profile: CaptureRecords.Profile, tuning: DocumentCaptureTuningOverrides,
      telemetry: DocumentCameraTelemetry, now: @escaping @Sendable () -> Date,
      livePDF417: Bool = false, presence: DocumentPresencePolicy? = nil
    ) -> DocumentCamera {
      .init(
        now: now, notifications: notifications, sessionID: CaptureSessionID(),
        configuration: captureConfiguration(livePDF417: livePDF417, presence: presence),
        telemetry: telemetry,
        diagnostics: livePDF417
          ? livePDF417AnalysisConfiguration(profile: profile, tuning: tuning)
          : analysisConfiguration(profile: profile, tuning: tuning))
    }
    /// The document-mode analysis with the barcode taken from the metadata output instead of
    /// Vision live content, so the live back keeps the front's card-readiness gate.
    static func livePDF417AnalysisConfiguration(
      profile: CaptureRecords.Profile,
      tuning: DocumentCaptureTuningOverrides
    ) -> DocumentCameraDiagnosticsConfiguration {
      let document = analysisConfiguration(profile: profile, tuning: tuning)
      return .init(
        livePDF417: true, includesAdaptiveCapture: document.includesAdaptiveCapture,
        includesPreviewFrames: document.includesPreviewFrames, includesLiveContentAnalysis: false,
        liveContentTarget: document.liveContentTarget,
        previewFrameIntervalSeconds: document.previewFrameIntervalSeconds, tuning: document.tuning)
    }
    static func analysisConfiguration(
      profile: CaptureRecords.Profile,
      tuning: DocumentCaptureTuningOverrides
    ) -> DocumentCameraDiagnosticsConfiguration {
      .init(
        includesAdaptiveCapture: true, includesLiveContentAnalysis: profile.requiresLiveContent,
        liveContentTarget: profile.liveContentTarget, tuning: tuning)
    }
    static func makeCoordinator(
      profile: CaptureRecords.Profile,
      tuning: DocumentCaptureTuningOverrides
    ) -> DocumentAutoCaptureCoordinator {
      .init(
        requireQualityReadiness: true, requiresContentSignal: profile.requiresLiveContent,
        contentTarget: profile.liveContentTarget,
        maximumAttemptsPerSide: DocumentCaptureTuning.AutoCapture.journeyMaximumAttemptsPerSide,
        frontRequiredConsecutiveObservations: tuning.frontObservations,
        backRequiredConsecutiveObservations: tuning.backObservations)
    }

    public func beginJourney(
      _ profile: CaptureRecords.Profile, workflowID: UUID,
      includeTiltPractice: Bool = false
    ) {
      guard !erasing, !busy, operation == nil else { return }
      stop()
      self.workflowID = workflowID
      self.profile = profile
      selectedCaptureID = nil
      recoveryCaptureID = nil
      retainedFrontCaptureID = nil
      // A presence policy runs tilt guidance on every two-sided front, without the host asking.
      tiltGuidance.requestedForFront = includeTiltPractice || configuration.documentPresence != nil
      start()
    }

    public func openCustody() throws -> CaptureEvidenceStore {
      guard !erasing else { throw CaptureEvidenceStoreError.custodyRevoked }
      if custody == nil {
        custody = try makeCustody(configuration.custody, configuration.signing)
      }
      guard custody?.erasurePendingOnOpen != true else {
        throw CaptureEvidenceStoreError.custodyRevoked
      }
      guard let store else { throw CaptureEvidenceStoreError.invalidRecord }
      return store
    }

    public func updateTuning(_ tuning: DocumentCaptureTuningOverrides) throws {
      guard !busy, operation == nil, !ready else { throw PhotoCaptureError.cameraNotReady }
      configuration = .init(
        notifications: configuration.notifications, custody: configuration.custody, signing: configuration.signing, clock: configuration.clock,
        consent: consent, tuning: tuning, recordingPolicy: configuration.recordingPolicy,
        tiltConfiguration: configuration.tiltConfiguration,
        requiresLocation: configuration.requiresLocation,
        licenseBackCaptureMode: configuration.licenseBackCaptureMode,
        documentPresence: configuration.documentPresence)
    }

    public func waitUntilIdle() async { await operation?.value }
    public func waitForRecordingSettlement() async { await recordingSettlement?.value }
    public func cancelProcessing() {
      processingEpoch = UUID()
      processingIdentities.removeAll()
      processingQueue.cancel()
    }

    public func setConsent(_ value: CaptureSessionConsent, cancelProcessing: Bool = true) {
      consent = value
      if value != .permitted {
        stop(cancelProcessing: cancelProcessing)
        issue = .consentRequired
      }
    }

    public func start(recordingOnly: Bool = false) {
      guard !erasing else { return }
      guard consent == .permitted else {
        issue = .consentRequired
        return
      }
      if operation != nil {
        restartForReview = recordingOnly
        restartWhenIdle = true
        return
      }
      guard !busy, !ready else { return }
      issue = nil
      startupFailure = nil
      phase = recordingOnly ? .reviewing : .capturing
      resetTiltForCameraStart(recordingOnly: recordingOnly)
      if !recordingOnly { armAutomaticCapture() }
      busy = true
      cameraGeneration += 1
      let generation = cameraGeneration
      qualityTask?.cancel()
      stopGeometryObservation()
      let previous = camera
      previous.stop()
      camera =
        cameraFactory?(profile)
        ?? Self.makeCamera(
          notifications: configuration.notifications, profile: profile, tuning: configuration.tuning, telemetry: telemetry,
          now: configuration.clock.now, livePDF417: usesLivePDF417,
          presence: configuration.documentPresence)
      let activeCamera = camera
      activeCamera.setLivePDF417Handler { [weak self] payload in
        self?.receivePDF417(payload, generation: generation)
      }
      latestQuality = nil
      resetCaptureCoordinator()
      startup = recordingOnly ? .storage : .permissionState
      operation = Task { [self] in
        defer {
          if generation == cameraGeneration { startup = nil }
          finishOperation()
        }
        do {
          try Task.checkCancellation()
          guard generation == cameraGeneration else { return }
          if !recordingOnly, configuration.requiresLocation {
            guard await location.requestPermission() else {
              issue = .locationRequired
              return
            }
            try Task.checkCancellation()
            guard generation == cameraGeneration else { return }
            location.startUpdatesIfAuthorized()
          }
          startup = .storage
          if custody == nil {
            custody = try makeCustody(configuration.custody, configuration.signing)
          }
          startup = .settlement
          await recordingSettlement?.value
          try Task.checkCancellation()
          guard generation == cameraGeneration else { return }
          startup = .recording
          try await beginContinuousRecording(camera: activeCamera)
          let recordingID = try requireRecording(camera: activeCamera)
          startup = .cameraRelease
          try await previous.stopAndWait()
          try Task.checkCancellation()
          guard generation == cameraGeneration else { return }
          try requireRecording(recordingID, camera: activeCamera)
          activeCamera.setCaptureAdmissionEnabled(!recordingOnly)
          startup = .cameraStart
          try await activeCamera.start()
          try Task.checkCancellation()
          guard generation == cameraGeneration else { return }
          try requireRecording(recordingID, camera: activeCamera)
          ready = true
          startup = nil
          observe(camera: activeCamera, generation: generation)
          startTiltIfRequested(camera: activeCamera, generation: generation)
          if !tiltDefersAutomaticCapture, phase == .capturing { prepareAutomaticCapture() }
        } catch is CancellationError {
          guard generation == cameraGeneration else { return }
          finishContinuousRecording(reason: "camera_start_cancelled")
        } catch {
          guard generation == cameraGeneration else { return }
          ready = false
          startupFailure = error
          issue = .cameraUnavailable
          finishContinuousRecording(reason: "camera_start_failed")
          onEvent(.issue(.cameraUnavailable))
        }
      }
    }

    public func stop(cancelProcessing: Bool = true) {
      if cancelProcessing {
        processingEpoch = UUID()
        processingIdentities.removeAll()
        processingQueue.cancel()
      }
      startup = nil
      stopTiltObservation()
      camera.setCaptureAdmissionEnabled(false)
      let admittedPhoto = activeCaptureAttempt != nil
      if !admittedPhoto { camera.stop() }
      phase = .inactive
      finishContinuousRecording(reason: "interrupted_or_cancelled", stopAfterCapture: admittedPhoto)
      location.stop()
      restartWhenIdle = false
      cameraGeneration += 1
      disarmAutomaticCapture()
      stopGeometryObservation()
      qualityTask?.cancel()
      qualityTask = nil
      // A photo already admitted owns its native callback and original until custody settles.
      if !admittedPhoto { operation?.cancel() }
      ready = false
    }

    /// The selfie camera and erasure must await complete native graph release.
    public func stopAndWait() async throws {
      stop()
      await operation?.value
      await recordingSettlement?.value
      try await camera.stopAndWait()
    }

    public func erase() async throws {
      if let eraseOperation { return try await eraseOperation.value }
      erasing = true
      let work = Task { [self] in
        stop()
        if custody == nil {
          custody = try makeErasureCustody(configuration.custody)
        }
        // Persist intent before native settlement can fail. Delayed capture/processing
        // callbacks cannot publish or recover a generation the user has revoked.
        try await custody?.prepareErasure()
        try await stopAndWait()
        try await custody?.erase()
        custody = nil
        selectedCaptureID = nil
        recoveryCaptureID = nil
        retainedFrontCaptureID = nil
        issue = .custodyErased
      }
      eraseOperation = work
      defer { eraseOperation = nil }
      // Failed deletion keeps admission closed; a later explicit erase retries it.
      try await work.value
      erasing = false
    }

    /// Host diagnostic controls must declare their exclusive operation before changing native state.
    /// Normal acquisition remains SDK-owned; a completed control operation does not silently rearm it.
    public func setNativeControlState(busy: Bool, adaptiveEnabled: Bool) {
      nativeControlsBusy = busy
      adaptiveControlsEnabled = adaptiveEnabled
      if busy || !adaptiveEnabled { disarmAutomaticCapture() }
    }

    func finishOperation() {
      busy = false
      operation = nil
      if restartWhenIdle {
        restartWhenIdle = false
        let recordingOnly = restartForReview
        restartForReview = false
        start(recordingOnly: recordingOnly)
      }
    }
    func resetCaptureCoordinator() {
      autoCaptureCoordinator = Self.makeCoordinator(profile: profile, tuning: configuration.tuning)
      autoCaptureCoordinator.begin(side: profile.side)
      armedAt = configuration.clock.now()
    }
    public func armAutomaticCapture() {
      guard !erasing, phase == .capturing, !busy, operation == nil, !nativeControlsBusy else {
        return
      }
      prepareAutomaticCapture()
    }
    func prepareAutomaticCapture() {
      guard adaptiveControlsEnabled else {
        issue = .nativeControlsPaused
        return
      }
      guard !tiltDefersAutomaticCapture else {
        disarmAutomaticCapture()
        return
      }
      if configuration.requiresLocation { location.startUpdatesIfAuthorized() }
      autoCaptureCoordinator.begin(side: profile.side)
      armedAt = configuration.clock.now()
      autoArmed = true
      camera.updateCaptureFeedback(.seeking)
    }
    public func disarmAutomaticCapture() { autoArmed = false }

    func observe(camera activeCamera: DocumentCamera, generation: Int) {
      let observations = activeCamera.qualityObservations
      qualityTask = Task { [weak self] in
        for await value in observations {
          guard !Task.isCancelled, let self, generation == self.cameraGeneration else { return }
          self.receive(value)
        }
      }
      observeGeometry(from: activeCamera, generation: generation)
    }

    var usesLivePDF417: Bool {
      profile == .licenseBack && configuration.licenseBackCaptureMode == .livePDF417
    }

    func receivePDF417(_ payload: String, generation: Int) {
      // The live back's guide is the barcode's box, not the card's, so the card-readiness gate
      // the front uses does not apply here: the symbol's corners inside that box, on two
      // consecutive identical reads, is the whole admission (owner, 2026-10-18).
      guard usesLivePDF417, generation == cameraGeneration, autoArmed, !payload.isEmpty else {
        return
      }
      capture(observation: nil, livePDF417Candidate: payload)
    }

    func receive(_ observation: DocumentCaptureQualityObservation) {
      latestQuality = observation
      guard !erasing, phase == .capturing, ready, !busy, operation == nil, !nativeControlsBusy,
        autoArmed,
        !tiltDefersAutomaticCapture
      else { return }
      guard !configuration.requiresLocation || location.assertion() != nil else {
        issue = .locationRequired
        camera.updateCaptureFeedback(.seeking)
        return
      }
      if observation.cameraControl?.adaptiveFailureReason != nil {
        autoArmed = false
        issue = .cameraUnavailable
        camera.updateCaptureFeedback(.failed)
        return
      }
      camera.updateCaptureFeedback(observation.assessment.ready ? .ready : .seeking)
      // Live PDF417: quality gates the barcode path; only that path requests the back photo.
      guard !usesLivePDF417 else { return }
      guard observation.timestamp > armedAt,
        DocumentCaptureObservationFreshness.fresh(observation, at: configuration.clock.now())
      else { return }
      switch autoCaptureCoordinator.observe(side: profile.side, observation: observation) {
      case .trigger: capture(observation: observation)
      case .observing: break
      case .exhausted: disarmAutomaticCapture()
      }
    }
    public func capture() {
      guard !usesLivePDF417 else { return }
      // The presence gate: capture-now does not cut tilt guidance short (S-02).
      guard !presenceGatesCapture || tiltGuidance.outcome == .completed else {
        issue = .documentPresenceRequired
        return
      }
      if tiltDefersAutomaticCapture || tiltGuidance.active || tiltGuidance.releasing {
        releaseTilt(reason: .userCaptureNow, captureNow: true)
        return
      }
      capture(observation: nil)
    }
  }

  extension CaptureSession {
    /// Restore authenticated original linkage without requiring supplementary analysis to finish.
    public func resume(captureID: UUID) async throws {
      guard !erasing, !busy, operation == nil else { throw PhotoCaptureError.cameraNotReady }
      try await stopAndWait()
      if custody == nil {
        custody = try makeCustody(configuration.custody, configuration.signing)
      }
      guard let store else { throw CaptureEvidenceStoreError.invalidRecord }
      let current = cameraGeneration
      let original = try await CaptureSignedRecords.original(id: captureID, store: store).record
      let manifest = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: original.manifest)
      guard manifest.captureID == captureID,
        manifest.fidelity.sha256 == CapturePayloadIntegrity.sha256(original.original)
      else { throw CaptureEvidenceStoreError.integrityFailure }
      try await CaptureRecordingVerification.verifyStart(
        manifestData: original.manifest, store: store)
      try Task.checkCancellation()
      guard current == cameraGeneration, !erasing else { throw CancellationError() }
      workflowID = manifest.workflowID ?? captureID
      profile = manifest.profile
      journeyRevision = manifest.journeyRevision
      retainedFrontCaptureID =
        manifest.profile.twoSided ? captureID : manifest.precedingFrontCaptureID
      selectedCaptureID = captureID
      recoveryCaptureID = captureID
      phase = .reviewing
      issue = nil
    }
  }

#endif
