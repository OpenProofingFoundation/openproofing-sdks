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
  final class CaptureSessionLifecycleTests: XCTestCase {
    func testLiveBarcodeDuplicatesAndStoppedGenerationCannotReplaceRetainedBack() async throws {
      var retained: [UUID] = []
      let fixture = try SessionFixture(livePDF417: true) { event in
        if case .originalRetained(let identity, _) = event { retained.append(identity.captureID) }
      }
      defer { fixture.cleanup() }
      try await fixture.start()
      let bytes = try fixture.photoBytes()
      var admitted = 0
      fixture.session.capturePhoto = { camera, request in
        admitted += 1
        return try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      fixture.session.receivePDF417("front-trigger", generation: fixture.session.cameraGeneration)
      XCTAssertEqual(admitted, 0)
      XCTAssertNil(fixture.session.activeCaptureAttempt)
      fixture.session.capture()
      await fixture.session.waitUntilIdle()
      let front = try XCTUnwrap(fixture.session.selectedCaptureID)
      let store = try XCTUnwrap(fixture.session.store)
      let before = try await store.read(id: front)
      fixture.session.completeDocumentRecording()
      await fixture.session.waitForRecordingSettlement()
      try await fixture.session.beginBackCapture(frontCaptureID: front, workflowID: fixture.session.workflowID)
      await fixture.session.waitUntilIdle()
      let generation = fixture.session.cameraGeneration
      let gate = SessionPhotoGate()
      fixture.session.capturePhoto = { camera, request in
        admitted += 1
        XCTAssertEqual(request.qualityGate, .livePDF417AutoCapture)
        await gate.block()
        return try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      fixture.session.receivePDF417("stale-trigger", generation: generation - 1)
      XCTAssertNil(fixture.session.activeCaptureAttempt)
      let candidate = "synthetic-native-metadata-candidate"
      fixture.session.receivePDF417(candidate, generation: generation)
      let back = try XCTUnwrap(fixture.session.activeCaptureAttempt)
      await gate.waitForStart()
      fixture.session.receivePDF417("different-card", generation: generation)
      fixture.session.receivePDF417(candidate, generation: generation)
      XCTAssertEqual(fixture.session.activeCaptureAttempt, back)
      XCTAssertEqual(admitted, 2, "One front and exactly one back photo may be admitted")
      fixture.session.stop()
      fixture.session.receivePDF417("after-stop", generation: generation)
      gate.release()
      await fixture.session.waitUntilIdle()
      await fixture.session.waitForRecordingSettlement()
      let saved = try await CaptureJourneyRecovery.retainedBack(captureID: back,
        frontCaptureID: front, workflowID: fixture.session.workflowID, store: store)
      XCTAssertEqual(saved.record.original, bytes)
      XCTAssertEqual(saved.manifest.livePDF417Candidate, candidate)
      let after = try await store.read(id: front)
      XCTAssertEqual(after.original, before.original)
      XCTAssertEqual(after.manifest, before.manifest)
      XCTAssertEqual(retained, [front, back])
      XCTAssertEqual(admitted, 2)
      XCTAssertFalse(fixture.session.ready)
      try await fixture.session.erase()
    }

    func testLiveBackReadyQualityObservationAloneNeverRequestsShutter() async throws {
      let clock = SessionClock()
      let fixture = try SessionFixture(livePDF417: true, now: clock.now)
      defer { fixture.cleanup() }
      try await fixture.startBack()
      let bytes = try fixture.photoBytes()
      var requests: [DocumentCaptureRequest] = []
      fixture.session.capturePhoto = { camera, request in
        requests.append(request)
        return try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      clock.advance(1)
      let observation = sessionQuality(at: clock.now().addingTimeInterval(-0.1))
      fixture.session.receive(observation)
      XCTAssertEqual(fixture.session.latestQuality, observation)
      XCTAssertNil(fixture.session.activeCaptureAttempt)
      XCTAssertTrue(requests.isEmpty)
      // Only the barcode path requests the back photo, gated by that same observation.
      fixture.session.receivePDF417("confirmed-in-guide-candidate",
        generation: fixture.session.cameraGeneration)
      XCTAssertNotNil(fixture.session.activeCaptureAttempt)
      await fixture.session.waitUntilIdle()
      XCTAssertEqual(requests.map(\.qualityGate), [.livePDF417AutoCapture])
      try await fixture.session.erase()
    }

    func testDocumentBackReadyQualityObservationRequestsShutter() async throws {
      let clock = SessionClock()
      let fixture = try SessionFixture(now: clock.now)
      defer { fixture.cleanup() }
      try await fixture.startBack()
      let bytes = try fixture.photoBytes()
      var requests: [DocumentCaptureRequest] = []
      fixture.session.capturePhoto = { camera, request in
        requests.append(request)
        return try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      clock.advance(1)
      fixture.session.receive(sessionQuality(at: clock.now().addingTimeInterval(-0.1)))
      XCTAssertNotNil(fixture.session.activeCaptureAttempt)
      await fixture.session.waitUntilIdle()
      XCTAssertEqual(requests.map(\.qualityGate), [.qualityDrivenAutoCapture])
      try await fixture.session.erase()
    }

    func testLiveBackCameraRunsTheFrontAdaptiveAnalysisWithoutLiveContent() throws {
      var tuning = DocumentCaptureTuningOverrides()
      tuning.minimumSharpness = 0.02
      let document = CaptureSession.analysisConfiguration(profile: .licenseBack, tuning: tuning)
      let live = try diagnostics(
        of: CaptureSession.makeCamera(
          notifications: NotificationCenter(),
          profile: .licenseBack, tuning: tuning, telemetry: .disabled, now: { Date() },
          livePDF417: true))
      XCTAssertTrue(live.livePDF417)
      XCTAssertTrue(live.includesAdaptiveCapture)
      XCTAssertFalse(live.includesLiveContentAnalysis)
      XCTAssertEqual(
        live,
        DocumentCameraDiagnosticsConfiguration(
          livePDF417: true, includesAdaptiveCapture: document.includesAdaptiveCapture,
          includesPreviewFrames: document.includesPreviewFrames,
          includesLiveContentAnalysis: false, liveContentTarget: document.liveContentTarget,
          previewFrameIntervalSeconds: document.previewFrameIntervalSeconds,
          tuning: document.tuning))
      let analyzer = DocumentFrameAnalyzer(
        now: { Date() }, configuration: live, observationHandler: { _ in },
        focusHandler: { _ in })
      XCTAssertFalse(analyzer.metadataOnlyCapture)
      // The document-mode back camera is unchanged: no live barcode output, Vision content on.
      let documentCamera = try diagnostics(
        of: CaptureSession.makeCamera(
          notifications: NotificationCenter(),
          profile: .licenseBack, tuning: tuning, telemetry: .disabled, now: { Date() }))
      XCTAssertEqual(documentCamera, document)
      XCTAssertFalse(documentCamera.livePDF417)
      XCTAssertTrue(documentCamera.includesLiveContentAnalysis)
    }

    private func diagnostics(of camera: DocumentCamera) throws
      -> DocumentCameraDiagnosticsConfiguration
    {
      let controller = try XCTUnwrap(
        camera.sessionController as? AVFoundationCameraSessionController)
      return controller.sessionQueue.sync { controller.diagnosticsConfiguration }
    }

    func testFallbackCommitsBackBeforeCameraAndCancellationRetainsBothOriginals() async throws {
      var retained: [(UUID, CaptureRecords.Profile)] = []
      let fixture = try SessionFixture { event in
        if case .originalRetained(let identity, let profile) = event {
          retained.append((identity.captureID, profile))
        }
      }
      defer { fixture.cleanup() }
      try await fixture.start()
      let bytes = try fixture.photoBytes()
      fixture.session.capturePhoto = { camera, request in
        try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      fixture.session.capture()
      await fixture.session.waitUntilIdle()
      let front = try XCTUnwrap(fixture.session.selectedCaptureID)
      let workflow = fixture.session.workflowID
      fixture.session.completeDocumentRecording()
      await fixture.session.waitForRecordingSettlement()
      let store = try XCTUnwrap(fixture.session.store)
      let before = try await store.read(id: front)

      try await fixture.session.beginBackCapture(frontCaptureID: front, workflowID: workflow)
      await fixture.session.waitUntilIdle()
      XCTAssertTrue(fixture.session.ready)
      XCTAssertEqual(fixture.session.profile, .licenseBack)
      XCTAssertEqual(fixture.session.retainedFrontCaptureID, front)
      let savedCheckpoint = try await store.journeyCheckpoint(workflowID: workflow)
      let pending = try XCTUnwrap(savedCheckpoint)
      XCTAssertEqual(pending.nextStage, .back)
      XCTAssertEqual(pending.frontID, front)
      XCTAssertEqual(fixture.session.journeyRevision, pending.revision)
      let gate = SessionPhotoGate()
      fixture.session.capturePhoto = { camera, request in
        await gate.block()
        return try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      fixture.session.capture()
      await gate.waitForStart()
      let back = try XCTUnwrap(fixture.session.activeCaptureAttempt)
      fixture.session.stop()
      gate.release()
      await fixture.session.waitUntilIdle()
      await fixture.session.waitForRecordingSettlement()
      let after = try await store.read(id: front)
      XCTAssertEqual(after.original, before.original)
      XCTAssertEqual(after.manifest, before.manifest)
      let savedBack = try await CaptureJourneyRecovery.retainedBack(
        captureID: back, frontCaptureID: front, workflowID: workflow, store: store)
      XCTAssertEqual(savedBack.record.original, bytes)
      XCTAssertEqual(savedBack.manifest.journeyRevision, pending.revision)
      XCTAssertEqual(retained.map { $0.0 }, [front, back])
      XCTAssertEqual(retained.map { $0.1 }, [.licenseFront, .licenseBack])
      let recovery = try await CaptureJourneyRecovery.resolve(
        workflowID: workflow, candidateCaptureID: back, store: store)
      XCTAssertEqual(recovery.selected?.captureID, back)
      let frontAgain = try await CaptureJourneyRecovery.retainedFront(
        captureID: front, workflowID: workflow, store: store)
      XCTAssertEqual(frontAgain.captureID, front)

      // Explicit retry has a new attempt revision; the old back stays readable in custody.
      try await fixture.session.beginBackCapture(frontCaptureID: front, workflowID: workflow)
      await fixture.session.waitUntilIdle()
      try await fixture.session.stopAndWait()
      let pendingRetry = try await CaptureJourneyRecovery.resolve(
        workflowID: workflow, candidateCaptureID: back, store: store)
      XCTAssertEqual(pendingRetry.pendingCaptureStage, .back)
      XCTAssertEqual(pendingRetry.selected?.captureID, front)
      _ = try await CaptureJourneyRecovery.retainedBack(
        captureID: back, frontCaptureID: front, workflowID: workflow, store: store)
      try await fixture.session.erase()
    }

    func testFallbackStartupFailureLeavesDurableFrontAndPendingBack() async throws {
      let fixture = try SessionFixture(fails: true)
      defer { fixture.cleanup() }
      let store = try fixture.session.openCustody()
      let front = UUID()
      let workflow = UUID()
      let bytes = try fixture.photoBytes()
      let manifest = CaptureRecords.Manifest(
        schemaVersion: 1, captureID: front, profile: .licenseFront,
        sessionID: CaptureSessionID(),
        captureTimestamp: .init(value: 1, timescale: 1, flags: 1, epoch: 0,
          clock: .captureSessionSynchronizationClock),
        processedAt: fixture.session.configuration.clock.now(),
        fidelity: try PhotoFidelityMetadata.make(from: bytes),
        motionStatus: "fixture", workflowID: workflow)
      try await CaptureSignedRecords.retainOriginal(id: front, original: bytes, manifest: JSONEncoder().encode(manifest), store: store)
      try await fixture.session.beginBackCapture(frontCaptureID: front, workflowID: workflow)
      await fixture.session.waitUntilIdle()
      await fixture.session.waitForRecordingSettlement()
      XCTAssertFalse(fixture.session.ready)
      XCTAssertEqual(fixture.session.issue, .cameraUnavailable)
      let result = try await CaptureJourneyRecovery.resolve(
        workflowID: workflow, candidateCaptureID: front, store: store)
      XCTAssertEqual(result.pendingCaptureStage, .back)
      XCTAssertEqual(result.selected?.record.original, bytes)
      XCTAssertEqual(result.selected?.captureID, front)
      try await fixture.session.erase()
    }

    func testSynchronousStopCannotRepublishStartupOrCreateCustody() async throws {
      let fixture = try SessionFixture()
      defer { fixture.cleanup() }
      fixture.session.start(recordingOnly: true)
      let pending = fixture.session.operation
      fixture.session.stop()
      await pending?.value
      XCTAssertNil(fixture.session.startup)
      XCTAssertNil(fixture.session.custody)
      XCTAssertFalse(fixture.session.ready)
      XCTAssertFalse(fixture.session.busy)
      XCTAssertEqual(fixture.controller.startCount, 0)
    }

    func testNativeStartupFailureClosesLiveLookupAndSettlesRecording() async throws {
      let fixture = try SessionFixture(fails: true)
      defer { fixture.cleanup() }
      fixture.session.start()
      await fixture.session.operation?.value
      await fixture.session.recordingSettlement?.value
      if fixture.session.store == nil, let error = fixture.session.startupFailure { throw error }
      XCTAssertEqual(fixture.controller.startCount, 1)
      XCTAssertFalse(fixture.session.ready)
      XCTAssertNil(fixture.session.startup)
      XCTAssertEqual(fixture.session.issue, .cameraUnavailable)
      XCTAssertNil(fixture.session.journeyRecording)
      let store = try XCTUnwrap(fixture.session.store)
      let live = try await store.liveLookupSnapshot(captureIDs: [])
      XCTAssertNil(live)
      try await fixture.session.erase()
    }

    func testRecordingTerminationCannotRearmSuspendedBackTransition() async throws {
      let fixture = try SessionFixture()
      defer { fixture.cleanup() }
      try await fixture.start()
      let gate = SessionPhotoGate()
      fixture.session.selectedCaptureID = UUID()
      fixture.session.analysisUpdater = { _, _ in await gate.block() }
      fixture.session.transitionToBack()
      await gate.waitForStart()
      let pending = fixture.session.operation
      fixture.session.suspendTerminatedRecording()
      gate.release()
      await pending?.value
      await fixture.session.recordingSettlement?.value
      XCTAssertFalse(fixture.session.ready)
      XCTAssertFalse(fixture.session.autoArmed)
      XCTAssertNotEqual(fixture.session.phase, .capturing)
      XCTAssertNil(fixture.session.journeyRecording)
      XCTAssertEqual(fixture.controller.startCount, 1)
      try await fixture.session.erase()
    }

    func testRecordingTerminationPublishesOneHostFailure() async throws {
      var issues: [CaptureSessionIssue] = []
      let fixture = try SessionFixture { event in
        if case .issue(let issue) = event { issues.append(issue) }
      }
      defer { fixture.cleanup() }
      try await fixture.start()
      fixture.session.suspendTerminatedRecording()
      fixture.session.suspendTerminatedRecording()
      await fixture.session.waitForRecordingSettlement()
      XCTAssertEqual(issues, [.recordingTerminated])
      XCTAssertFalse(fixture.session.ready)
      try await fixture.session.erase()
    }

    func testRecordingTerminationDoesNotReplaceAdmittedOriginalWithFailure() async throws {
      var issues: [CaptureSessionIssue] = []
      var retained: [UUID] = []
      let fixture = try SessionFixture { event in
        if case .issue(let issue) = event { issues.append(issue) }
        if case .originalRetained(let identity, _) = event { retained.append(identity.captureID) }
      }
      defer { fixture.cleanup() }
      try await fixture.start()
      let gate = SessionPhotoGate()
      let bytes = try fixture.photoBytes()
      fixture.session.capturePhoto = { camera, request in
        await gate.block()
        return try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      fixture.session.capture()
      await gate.waitForStart()
      let attempt = try XCTUnwrap(fixture.session.activeCaptureAttempt)
      fixture.session.suspendTerminatedRecording()
      gate.release()
      await fixture.session.waitUntilIdle()
      await fixture.session.waitForRecordingSettlement()
      XCTAssertFalse(issues.contains(.recordingTerminated))
      XCTAssertEqual(retained, [attempt])
      let original = try await fixture.session.openCustody().read(id: attempt)
      XCTAssertEqual(original.original, bytes)
      try await fixture.session.erase()
    }

    func testNativeDiagnosticAdmissionGuardPreservesManualControlExclusivity() async throws {
      let fixture = try SessionFixture()
      defer { fixture.cleanup() }
      try await fixture.start()
      fixture.session.setNativeControlState(busy: true, adaptiveEnabled: true)
      fixture.session.capture()
      XCTAssertNil(fixture.session.activeCaptureAttempt)
      XCTAssertFalse(fixture.session.autoArmed)
      fixture.session.setNativeControlState(busy: false, adaptiveEnabled: false)
      fixture.session.armAutomaticCapture()
      XCTAssertFalse(fixture.session.autoArmed)
      XCTAssertEqual(fixture.session.issue, .nativeControlsPaused)
      try await fixture.session.erase()
    }

    func testStoppedAdmittedPhotoRetainsOriginalButCannotSelectStaleResult() async throws {
      var receipts: [CaptureSessionAttemptIdentity] = []
      let fixture = try SessionFixture { event in
        if case .originalRetained(let identity, _) = event { receipts.append(identity) }
      }
      defer { fixture.cleanup() }
      try await fixture.start()
      let gate = SessionPhotoGate()
      let bytes = try fixture.photoBytes()
      fixture.session.capturePhoto = { camera, request in
        await gate.block()
        return try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      fixture.session.capture()
      await gate.waitForStart()
      let attempt = try XCTUnwrap(fixture.session.activeCaptureAttempt)
      let admissionGeneration = fixture.session.generation
      let operation = fixture.session.operation
      fixture.session.stop()
      XCTAssertNotEqual(fixture.session.generation, admissionGeneration)
      gate.release()
      await operation?.value
      await fixture.session.recordingSettlement?.value
      let store = try XCTUnwrap(fixture.session.store)
      let retained = try await store.read(id: attempt)
      XCTAssertEqual(retained.original, bytes)
      XCTAssertEqual(receipts.map(\.captureID), [attempt])
      XCTAssertEqual(receipts.first?.generation, admissionGeneration)
      XCTAssertNil(fixture.session.selectedCaptureID)
      XCTAssertNil(fixture.session.recoveryCaptureID)
      XCTAssertFalse(fixture.session.ready)
      XCTAssertNil(fixture.session.issue)
      try await fixture.session.erase()
    }

    func testEraseDoesNotAwaitOptionalWorkerAndLateWorkerCannotAlterReplacement() async throws {
      let gate = SessionPhotoGate()
      var oldStore: CaptureEvidenceStore?
      var rejectedLateWrite = false
      var processingEvents = 0
      let fixture = try SessionFixture(
        processingOperations: .init(prepare: { _ in
          await gate.block()  // Deliberately ignores task cancellation.
          do {
            try await XCTUnwrap(oldStore).store(
              id: UUID(), original: Data([9]), manifest: Data([9]))
            XCTFail("Canceled worker published after durable erasure")
          } catch CaptureEvidenceStoreError.custodyRevoked {
            rejectedLateWrite = true
          }
          throw CancellationError()
        }),
        onEvent: { event in
          switch event {
          case .processingCompleted, .processingFailed: processingEvents += 1
          default: break
          }
        })
      defer {
        gate.release()
        fixture.cleanup()
      }
      try await fixture.start()
      oldStore = try XCTUnwrap(fixture.session.store)
      let bytes = try fixture.photoBytes()
      fixture.session.capturePhoto = { camera, request in
        try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      fixture.session.capture()
      await gate.waitForStart()
      var erased = false
      let erasure = Task {
        try await fixture.session.erase()
        erased = true
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while !erased, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertTrue(erased, "Optional analysis blocked erasure")
      // Always release on regression so this test fails instead of wedging the suite.
      guard erased else {
        gate.release()
        try await erasure.value
        return
      }
      try await erasure.value
      XCTAssertNil(fixture.session.custody)
      XCTAssertNil(fixture.session.selectedCaptureID)
      let replacement = try CaptureCustodyRuntime.testing(
        configuration: fixture.session.configuration.custody, signing: fixture.session.configuration.signing)
      let replacementID = UUID()
      try await replacement.store.store(
        id: replacementID, original: bytes, manifest: Data([1]))
      gate.release()
      await fixture.session.processingQueue.waitUntilIdle()
      XCTAssertTrue(rejectedLateWrite)
      XCTAssertEqual(processingEvents, 0)
      XCTAssertNil(fixture.session.selectedCaptureID)
      let retained = try await replacement.store.read(id: replacementID)
      XCTAssertEqual(retained.original, bytes)
      try await replacement.erase()
    }

    func testNativeStopFailurePersistsErasureIntentAndBlocksSessionUntilExplicitRetry() async throws {
      let fixture = try SessionFixture()
      defer { fixture.cleanup() }
      try await fixture.start()
      let store = try XCTUnwrap(fixture.session.store)
      let id = UUID()
      try await store.store(id: id, original: Data([1]), manifest: Data([2]))
      fixture.controller.setStopSucceeds(false)
      do {
        try await fixture.session.erase()
        XCTFail("Native stop failure reported completed erasure")
      } catch {}
      XCTAssertTrue(fixture.session.erasing)
      XCTAssertTrue(try CaptureCustodyErasureState.pending(directory: fixture.directory, fileManager: FileManager.default))
      XCTAssertThrowsError(try fixture.session.openCustody()) { error in
        XCTAssertEqual(error as? CaptureEvidenceStoreError, .custodyRevoked)
      }
      do {
        _ = try await store.read(id: id)
        XCTFail("Failed native settlement restored access to revoked evidence")
      } catch CaptureEvidenceStoreError.custodyRevoked {}
      let starts = fixture.controller.startCount
      fixture.session.start()
      XCTAssertEqual(fixture.controller.startCount, starts)
      XCTAssertFalse(fixture.session.restartWhenIdle)
      fixture.controller.setStopSucceeds(true)
      try await fixture.session.erase()
      XCTAssertFalse(fixture.session.erasing)
      XCTAssertNil(fixture.session.custody)
      let replacement = try fixture.session.openCustody()
      try await replacement.store(id: UUID(), original: Data([3]), manifest: Data([4]))
      try await fixture.session.erase()
    }

    func testEraseWaitsAdmittedPhotoAndRejectsRestartUntilDeletionCompletes() async throws {
      let fixture = try SessionFixture()
      defer { fixture.cleanup() }
      try await fixture.start()
      let store = try XCTUnwrap(fixture.session.store)
      let gate = SessionPhotoGate()
      let bytes = try fixture.photoBytes()
      fixture.session.capturePhoto = { camera, request in
        await gate.block()
        return try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      fixture.session.capture()
      await gate.waitForStart()
      let erase = Task { try await fixture.session.erase() }
      for _ in 0..<100 where !fixture.session.erasing { await Task.yield() }
      XCTAssertTrue(fixture.session.erasing)
      fixture.session.start()
      XCTAssertFalse(fixture.session.restartWhenIdle)
      gate.release()
      try await erase.value
      XCTAssertNil(fixture.session.custody)
      XCTAssertNil(fixture.session.selectedCaptureID)
      XCTAssertFalse(fixture.session.ready)
      XCTAssertEqual(fixture.controller.startCount, 1)
      do {
        _ = try await store.list()
        XCTFail("Erased generation enumerated evidence")
      } catch CaptureEvidenceStoreError.custodyRevoked {}
      do {
        try await store.store(id: UUID(), original: bytes, manifest: Data([1]))
        XCTFail("Erased session admitted late publication")
      } catch CaptureEvidenceStoreError.custodyRevoked {}
    }
  }

  @MainActor
  private struct SessionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let controller: SessionController
    let session: CaptureSession
    init(
      fails: Bool = false, livePDF417: Bool = false, processingOperations: CaptureDocumentOperations = .init(),
      onEvent: @escaping @MainActor (CaptureSessionEvent) -> Void = { _ in },
      now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
    ) throws {
      let configuration = CaptureSessionConfiguration(
        notifications: NotificationCenter(),
        custody: try .init(applicationID: "synthetic.capture-sdk.fixture",
          directory: directory,
          keychainService: "synthetic." + UUID().uuidString, keychainAccount: "session-tests", accessGroup: "TEST.capture-sdk.fixture"),
        signing: try .testing(applicationID: "synthetic.capture-sdk.fixture", installationID: "synthetic-installation"),
        clock: .init(
          now: now,
          uptime: { ProcessInfo.processInfo.systemUptime }),
        consent: .permitted, requiresLocation: false,
        licenseBackCaptureMode: livePDF417 ? .livePDF417 : .document)
      controller = SessionController(fails: fails)
      session = CaptureSession(
        configuration: configuration, processingOperations: processingOperations, onEvent: onEvent).withFixtureCustody()
      let controller = controller
      session.cameraFactory = { _ in
        DocumentCamera(
          now: configuration.clock.now, sessionID: CaptureSessionID(),
          authorizationProvider: SessionAuthorization(), sessionController: controller)
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
    /// Capture and retain a front, then arm the licence back on the fixture's back mode.
    func startBack() async throws {
      try await start()
      let bytes = try photoBytes()
      session.capturePhoto = { camera, request in
        try self.photo(camera: camera, request: request, bytes: bytes)
      }
      session.capture()
      await session.waitUntilIdle()
      let front = try XCTUnwrap(session.selectedCaptureID)
      session.completeDocumentRecording()
      await session.waitForRecordingSettlement()
      try await session.beginBackCapture(frontCaptureID: front, workflowID: session.workflowID)
      await session.waitUntilIdle()
      XCTAssertTrue(session.ready)
      XCTAssertEqual(session.profile, .licenseBack)
      XCTAssertEqual(session.phase, .capturing)
      XCTAssertTrue(session.autoArmed)
      XCTAssertNil(session.activeCaptureAttempt)
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

  /// A ready, settled back observation that the document-mode coordinator would trigger on.
  private func sessionQuality(at timestamp: Date, ready: Bool = true)
    -> DocumentCaptureQualityObservation
  {
    DocumentCaptureQualityObservation(
      sequence: 1, geometryRevision: 0, timestamp: timestamp,
      metrics: .init(
        documentFillRatio: 0.5, documentGuideFillRatio: 0.64,
        documentInsideGuide: true, guideCenterX: 0.5, guideCenterY: 0.5, guideWidth: 0.8,
        guideHeight: 0.5, documentAspectRatio: 1.58, sharpness: 0.1, motion: 0,
        clippedHighlightRatio: 0, meanLuminance: 0.5, documentCenterX: 0.5,
        documentCenterY: 0.5),
      assessment: .init(
        ready: ready, blockingReasons: ready ? [] : [.holdSteady],
        stableFrameCount: ready ? 4 : 0),
      liveContent: .init(
        recognizedTextLineCount: 0, recognizedCharacterCount: 0, decodedPDF417Count: 1,
        decodedPDF417CharacterCount: 200),
      cameraControl: .init(
        sampledAt: timestamp, zoomFactor: 1, adjustingFocus: false,
        adjustingExposure: false, rampingZoom: false, settled: true))
  }

  private final class SessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    var now: @Sendable () -> Date { { [self] in lock.withLock { current } } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
  }

  @MainActor
  private final class SessionPhotoGate {
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

  private struct SessionAuthorization: CameraAuthorizationProviding {
    func resolveAuthorization() async -> CameraAuthorizationDecision { .authorized }
  }
  private final class SessionController: CameraSessionControlling, CameraSessionStopAwaiting,
    @unchecked Sendable
  {
    private let lock = NSLock()
    private var starts = 0
    private var stopSucceeds = true
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
    func setStopSucceeds(_ value: Bool) { lock.withLock { stopSucceeds = value } }
    func afterStop(_ completion: @escaping @Sendable (Bool) -> Void) {
      completion(lock.withLock { stopSucceeds })
    }
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
