#if os(iOS)
  import Foundation
  import XCTest
  @testable import DocumentCaptureJournal
  @testable import DocumentCaptureApple
  @testable import DocumentCapture

  extension CaptureTiltIntegrationTests {
    func testWithdrawingConsentStopsOnceAndHonorsProcessingOwnership() {
      for cancelProcessing in [false, true] {
        let engine = model()
        activate(engine)
        let generation = engine.generation
        let processing = engine.processingGeneration
        engine.setConsent(.withheld, cancelProcessing: cancelProcessing)
        XCTAssertEqual(engine.generation, generation + 1)
        XCTAssertEqual(engine.phase, .inactive)
        XCTAssertFalse(engine.ready)
        XCTAssertFalse(engine.autoArmed)
        XCTAssertNil(engine.tiltGuidance.runID)
        XCTAssertEqual(engine.processingGeneration == processing, !cancelProcessing)
      }
    }

    func testPendingBeginReceiptCannotAdvertiseMovementBeforeActivation() async throws {
      let fixture = try PendingTiltInstructionFixture()
      defer { fixture.storage.cleanup() }
      try await fixture.start()
      let engine = fixture.engine
      let runID = try XCTUnwrap(engine.tiltGuidance.runID)
      let receipt = DocumentTiltController(runID: runID).presentation
      engine.receiveTilt(receipt, generation: engine.cameraGeneration)
      XCTAssertEqual(
        engine.tiltGuidance.presentation, receipt, "Retain the receipt without claiming activation")
      XCTAssertEqual(engine.tiltCaptureGuidance, .starting)
      XCTAssertFalse(engine.autoArmed)
      fixture.begin.resume(returning: receipt)
      await engine.tiltGuidance.startTask?.value
      XCTAssertEqual(engine.tiltCaptureGuidance, .movement(receipt, restartingBaseline: false))
      await fixture.finish()
    }

    func testActivationAcknowledgmentUsesNewerAlreadyReceivedPresentation() async throws {
      let fixture = try PendingTiltInstructionFixture()
      defer { fixture.storage.cleanup() }
      try await fixture.start()
      let engine = fixture.engine
      let runID = try XCTUnwrap(engine.tiltGuidance.runID)
      let initial = DocumentTiltController(runID: runID).presentation
      let newer = DocumentTiltPresentation(
        runID: runID, revision: initial.revision + 1, phase: .baseline,
        reason: .baselineUnstable, baseline: nil, signedDelta: nil,
        consecutiveObservations: 0, dwellSeconds: 0)
      engine.receiveTilt(newer, generation: engine.cameraGeneration)
      XCTAssertEqual(engine.tiltCaptureGuidance, .starting)
      fixture.begin.resume(returning: initial)
      await engine.tiltGuidance.startTask?.value
      XCTAssertEqual(engine.tiltGuidance.presentation, newer)
      XCTAssertEqual(engine.tiltCaptureGuidance, .movement(newer, restartingBaseline: false))
      await fixture.finish()
    }

    func testTerminalReceiptBeforeBeginAcknowledgmentCannotResurrectMovement() async throws {
      let fixture = try PendingTiltInstructionFixture()
      defer { fixture.storage.cleanup() }
      try await fixture.start()
      let engine = fixture.engine
      let runID = try XCTUnwrap(engine.tiltGuidance.runID)
      var controller = DocumentTiltController(runID: runID)
      let initial = controller.presentation
      let terminal = controller.cancel(reason: .clockChanged).presentation
      let pendingStart = engine.tiltGuidance.startTask
      engine.receiveTilt(terminal, generation: engine.cameraGeneration)
      await engine.tiltGuidance.controlTask?.value
      fixture.begin.resume(returning: initial)
      await pendingStart?.value
      XCTAssertEqual(engine.tiltCaptureGuidance, .retry(.clockChanged))
      XCTAssertEqual(engine.tiltGuidance.presentation, terminal)
      XCTAssertFalse(engine.autoArmed)
      XCTAssertNil(engine.tiltGuidance.runID)
      await fixture.finish()
    }
  }

  @MainActor
  private final class PendingTiltInstructionFixture {
    let storage: TiltMechanismFixture
    let begin = PendingTiltInstructionBegin()
    let engine: CaptureSession
    private var journal: CaptureRecordingJournal?

    init() throws {
      storage = try TiltMechanismFixture()
      let begin = begin
      engine = makeTiltSession(
        tiltActions: .init(
          begin: { _, _ in
            try await withCheckedThrowingContinuation { begin.continuation = $0 }
          }, end: { _, _, _ in }))
    }

    func start() async throws {
      engine.phase = .capturing
      engine.ready = true
      engine.tiltGuidance.requestedForFront = true
      engine.resetTiltForCameraStart(recordingOnly: false)
      journal = try await CaptureRecordingJournal.start(
        workflowID: engine.workflowID, store: storage.store, clock: .tiltFixture,
        policy: .retainedV1)
      engine.journeyRecording = journal
      engine.startTiltIfRequested(camera: engine.camera, generation: engine.cameraGeneration)
      let deadline = ContinuousClock.now.advanced(by: .seconds(1))
      while begin.continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
      XCTAssertNotNil(begin.continuation)
    }

    func finish() async {
      engine.stop()
      begin.resume(throwing: CancellationError())
      await engine.recordingSettlement?.value
    }
  }

  @MainActor
  private final class PendingTiltInstructionBegin {
    var continuation: CheckedContinuation<DocumentTiltPresentation, Error>?
    func resume(returning value: DocumentTiltPresentation) {
      let pending = continuation
      continuation = nil
      pending?.resume(returning: value)
    }
    func resume(throwing error: Error) {
      let pending = continuation
      continuation = nil
      pending?.resume(throwing: error)
    }
  }
#endif
