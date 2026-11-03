#if os(iOS)
  import Foundation
  import XCTest
  import DocumentSDK
  import DocumentCaptureJournal
  @testable import DocumentCapture
  @testable import DocumentCaptureApple
  @testable import CaptureEvidenceCustody

  /// Session invariants extracted from the original host suites. UI assertions remain in the host.
  @MainActor
  final class CaptureSessionMigrationTests: XCTestCase {
    func testReviewKeepsCameraIdentityAndDisarmsHiddenCapture() throws {
      let fixture = try MigrationFixture()
      defer { fixture.cleanup() }
      let engine = fixture.session
      let identity = engine.camera.sessionID
      engine.phase = .capturing
      engine.ready = true
      engine.enterReview()
      XCTAssertTrue(engine.ready)
      XCTAssertEqual(engine.camera.sessionID, identity)
      XCTAssertEqual(engine.phase, .reviewing)
      engine.armAutomaticCapture()
      engine.capture()
      XCTAssertFalse(engine.autoArmed)
      XCTAssertNil(engine.operation)
      engine.stop()
    }

    func testStopPreventsRearmUntilExplicitCaptureStart() throws {
      let fixture = try MigrationFixture()
      defer { fixture.cleanup() }
      fixture.session.phase = .capturing
      fixture.session.stop()
      XCTAssertEqual(fixture.session.phase, .inactive)
      fixture.session.armAutomaticCapture()
      XCTAssertFalse(fixture.session.autoArmed)
      XCTAssertNil(fixture.session.operation)
    }

    func testDocumentCompletionDisarmsAndPreservesSelectedOriginal() throws {
      let fixture = try MigrationFixture()
      defer { fixture.cleanup() }
      let engine = fixture.session
      let identity = engine.camera.sessionID
      let selected = UUID()
      engine.selectedCaptureID = selected
      engine.phase = .capturing
      engine.completeDocumentRecording()
      XCTAssertEqual(engine.phase, .completed)
      XCTAssertEqual(engine.camera.sessionID, identity)
      XCTAssertEqual(engine.selectedCaptureID, selected)
      engine.armAutomaticCapture()
      engine.capture()
      XCTAssertNil(engine.operation)
      engine.stop()
    }

    func testStartupSkipsUnrelatedColdArchive() async throws {
      let fixture = try MigrationFixture()
      defer { fixture.cleanup() }
      let store = try fixture.session.openCustody()
      let unrelated = fixture.directory.appendingPathComponent(UUID().uuidString + ".evidence")
      let corrupt = Data("invalid unrelated legacy evidence".utf8)
      try corrupt.write(to: unrelated)
      try await fixture.start()
      let reads = await store.authenticatedMetadataReadCount
      XCTAssertEqual(reads, 0)
      XCTAssertEqual(try Data(contentsOf: unrelated), corrupt)
      XCTAssertNil(fixture.session.startup)
      fixture.session.stop()
      await fixture.session.waitForRecordingSettlement()
      try await fixture.session.erase()
    }

    func testTerminalRecordingDisablesCameraAndKeepsSelectedFront() async throws {
      let fixture = try MigrationFixture()
      defer { fixture.cleanup() }
      try await fixture.start()
      let engine = fixture.session
      let selected = UUID()
      engine.selectedCaptureID = selected
      engine.enterReview()
      let generation = engine.generation
      engine.suspendTerminatedRecording()
      XCTAssertFalse(engine.ready)
      XCTAssertFalse(engine.autoArmed)
      XCTAssertNil(engine.journeyRecording)
      XCTAssertEqual(engine.selectedCaptureID, selected)
      XCTAssertEqual(engine.generation, generation)
      await engine.waitForRecordingSettlement()
      let live = try await XCTUnwrap(engine.store).liveLookupSnapshot(captureIDs: [])
      XCTAssertNil(live)
      try await engine.erase()
    }

    func testRecordingEndsDuringAdmittedFrontWithoutCancellingOriginal() async throws {
      try await verifyAdmittedPhotoSurvivesTermination(back: false)
    }

    func testRecordingEndsDuringAdmittedBackWithoutCancellingOriginal() async throws {
      try await verifyAdmittedPhotoSurvivesTermination(back: true)
    }

    private func verifyAdmittedPhotoSurvivesTermination(back: Bool) async throws {
      var operations = CaptureDocumentOperations()
      operations.prepare = { _ in throw MigrationFailure.expected }
      let fixture = try MigrationFixture(operations: operations)
      defer { fixture.cleanup() }
      try await fixture.start()
      let engine = fixture.session
      let front = UUID()
      if back {
        engine.profile = .licenseBack
        engine.retainedFrontCaptureID = front
      }
      let gate = MigrationPhotoGate()
      let bytes = try fixture.photoBytes()
      engine.capturePhoto = { camera, request in
        await gate.block()
        try Task.checkCancellation()
        return try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      let journal = try XCTUnwrap(engine.journeyRecording)
      engine.capture()
      await gate.waitForStart()
      let admitted = try XCTUnwrap(engine.activeCaptureAttempt)
      let pending = engine.operation
      let generation = engine.generation
      engine.suspendTerminatedRecording()
      XCTAssertEqual(engine.activeCaptureAttempt, admitted)
      XCTAssertFalse(engine.ready)
      XCTAssertFalse(engine.autoArmed)
      engine.capture()
      XCTAssertEqual(engine.activeCaptureAttempt, admitted)
      gate.release()
      await pending?.value
      await engine.waitForRecordingSettlement()
      await engine.processingQueue.waitUntilIdle()
      XCTAssertEqual(engine.generation, generation)
      XCTAssertEqual(engine.selectedCaptureID, admitted)
      XCTAssertEqual(engine.phase, back ? .completed : .reviewing)
      let store = try XCTUnwrap(engine.store)
      let original = try await store.read(id: admitted)
      XCTAssertEqual(original.original, bytes)
      let manifest = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: original.manifest)
      XCTAssertEqual(manifest.precedingFrontCaptureID, back ? front : nil)
      let sealed = try await CaptureRecordingVerification.verify(journal.reference, store: store)
      XCTAssertEqual(sealed.stillIDs, [admitted])
      try await engine.erase()
    }

    func testFrontProcessingCannotBlockReviewBackTransitionOrRecordingSettlement() async throws {
      let gate = MigrationPhotoGate()
      var operations = JourneyRecoveryIntegrationTests.operations(
        calls: RecoveryExtractionCounter())
      operations.prepare = { _ in
        await gate.block()
        throw MigrationFailure.expected
      }
      let fixture = try MigrationFixture(operations: operations)
      defer { fixture.cleanup() }
      try await fixture.start()
      let engine = fixture.session
      let bytes = try fixture.photoBytes()
      engine.capturePhoto = { camera, request in
        try fixture.photo(camera: camera, request: request, bytes: bytes)
      }
      engine.capture()
      await engine.waitUntilIdle()
      await gate.waitForStart()
      let front = try XCTUnwrap(engine.selectedCaptureID)
      let camera = engine.camera.sessionID
      XCTAssertEqual(engine.phase, .reviewing)
      XCTAssertFalse(engine.busy)
      XCTAssertNil(engine.operation)
      var switches = 0
      engine.analysisUpdater = { _, configuration in
        XCTAssertEqual(configuration.liveContentTarget, .licensePDF417)
        switches += 1
      }
      engine.transitionToBack()
      await engine.waitUntilIdle()
      XCTAssertEqual(engine.phase, .capturing)
      XCTAssertEqual(engine.profile, .licenseBack)
      XCTAssertEqual(engine.retainedFrontCaptureID, front)
      XCTAssertEqual(engine.camera.sessionID, camera)
      XCTAssertEqual(switches, 1)
      engine.completeDocumentRecording()
      await engine.waitForRecordingSettlement()
      XCTAssertEqual(engine.processingQueue.activeID, front)
      gate.release()
      await engine.processingQueue.waitUntilIdle()
      XCTAssertEqual(engine.selectedCaptureID, front)
      try await engine.erase()
    }

    func testCancelledWorkerNeverPublishesOrOverlapsReplacement() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let gate = MigrationProcessingGate()
      let queue = CaptureProcessingQueue { job in
        await gate.block(job.captureID)
        throw MigrationFailure.expected
      }
      let old = UUID()
      let next = UUID()
      let workflow = UUID()
      let epoch = UUID()
      var completed: [UUID] = []
      queue.completion = { job, _ in completed.append(job.captureID) }
      func job(_ id: UUID) -> CaptureProcessingQueue.Job {
        .init(
          captureID: id, workflowID: workflow, profile: .licenseFront, publicationEpoch: epoch,
          store: fixture.store)
      }
      queue.enqueue(job(old))
      await gate.waitForStart(old)
      queue.cancel()
      queue.enqueue(job(next))
      XCTAssertEqual(gate.started, [old])
      XCTAssertEqual(queue.captureIDs, [next])
      gate.release(old)
      await gate.waitForStart(next)
      XCTAssertTrue(completed.isEmpty)
      gate.release(next)
      await queue.waitUntilIdle()
      XCTAssertEqual(gate.maximumConcurrent, 1)
      XCTAssertEqual(completed, [next])
    }
  }

  private enum MigrationFailure: Error { case expected }

  @MainActor
  private final class MigrationProcessingGate {
    var started: [UUID] = []
    var maximumConcurrent = 0
    private var blocked: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    func block(_ id: UUID) async {
      await withCheckedContinuation { continuation in
        blocked[id] = continuation
        started.append(id)
        maximumConcurrent = max(maximumConcurrent, blocked.count)
        waiters.removeValue(forKey: id)?.resume()
      }
    }
    func waitForStart(_ id: UUID) async {
      if started.contains(id) { return }
      await withCheckedContinuation { waiters[id] = $0 }
    }
    func release(_ id: UUID) { blocked.removeValue(forKey: id)?.resume() }
  }
#endif
