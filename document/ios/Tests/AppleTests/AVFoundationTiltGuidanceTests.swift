import CoreMedia
import Foundation
import Testing

@testable import DocumentCaptureApple

@Suite struct AVFoundationTiltGuidanceTests {
  @Test func freezeAndReleasePreserveManualAdmissionAndPriorAdaptiveChoice() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare(adaptive: false)
    let runID = UUID()
    let initial = try await fixture.begin(runID)
    #expect(initial.runID == runID)
    await fixture.ownerOperation {
      #expect(fixture.owner.state.tiltGuidance.holding)
      #expect(fixture.owner.state.captureAdmissionRequested)
      #expect(!fixture.owner.state.adaptiveCaptureEnabled)
    }
    await fixture.end(runID, reason: .userCaptureNow)
    await fixture.drain()
    await fixture.ownerOperation {
      #expect(!fixture.owner.state.tiltGuidance.holding)
      #expect(fixture.owner.state.captureAdmissionRequested)
      #expect(!fixture.owner.state.adaptiveCaptureEnabled)
    }
    #expect(
      fixture.sink.events.compactMap(\.tiltGuidance).last?.presentation.reason == .userCaptureNow)
  }

  @Test func skipWhileZoomSettlesResolvesBeginAndCannotActivateLater() async {
    let fixture = TiltNativeFixture()
    fixture.ramp.set(true)
    await fixture.prepare()
    let runID = UUID()
    fixture.owner.beginTiltGuidance(
      runID: runID, configuration: .provisionalV1, cancellation: .init(),
      completion: fixture.results.append)
    await fixture.drain()
    #expect(fixture.results.values.isEmpty)
    await fixture.end(runID, reason: .userSkipped)
    fixture.ramp.set(false)
    await fixture.ownerOperation { fixture.owner.pollTiltGuidance() }
    await fixture.drain()
    #expect(fixture.results.values.count == 1)
    if case .success = fixture.results.values.first { Issue.record("Ended pending run activated") }
    #expect(fixture.sink.events.compactMap(\.tiltGuidance).last?.presentation.phase == .skipped)
    await fixture.ownerOperation { #expect(!fixture.owner.state.tiltGuidance.holding) }
  }

  @Test func nativeReadbackNotCancellationRequestAdmitsBegin() async {
    let fixture = TiltNativeFixture()
    fixture.ramp.set(true)
    await fixture.prepare()
    fixture.owner.beginTiltGuidance(
      runID: UUID(), configuration: .provisionalV1, cancellation: .init(),
      completion: fixture.results.append)
    await fixture.drain()
    #expect(fixture.results.values.isEmpty)
    fixture.ramp.set(false)
    await fixture.ownerOperation { fixture.owner.pollTiltGuidance() }
    await fixture.drain()
    #expect(fixture.results.values.count == 1)
    if case .failure = fixture.results.values.first { Issue.record("Settled readback rejected") }
    await fixture.ownerOperation { fixture.owner.cancelTiltGuidance(reason: .sessionStopped) }
    await fixture.drain()
  }

  @Test func noObservationSilenceAndClockResetCancelWithoutCompletion() async throws {
    for reason in [DocumentTiltReason.observationSilence, .clockChanged] {
      let fixture = TiltNativeFixture()
      await fixture.prepare()
      let runID = UUID()
      _ = try await fixture.begin(runID)
      await fixture.ownerOperation {
        if reason == .observationSilence {
          fixture.owner.pollTiltGuidance(now: DocumentTemporalRecorder.hostNow() + 10)
        } else {
          fixture.owner.resetGeometryObservationEpoch(reason: .clockChanged)
        }
      }
      await fixture.drain()
      #expect(fixture.sink.events.compactMap(\.tiltGuidance).last?.presentation.reason == reason)
      #expect(fixture.sink.events.compactMap(\.tiltGuidance).last?.presentation.phase == .cancelled)
      await fixture.ownerOperation { #expect(!fixture.owner.state.tiltGuidance.holding) }
    }
  }

  @Test func clockBoundaryAlreadyFencesDelayedSourceConsumption() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    let runID = UUID()
    _ = try await fixture.begin(runID)
    let gate = DispatchSemaphore(value: 0)
    await withCheckedContinuation { continuation in
      fixture.analyzer.analysisQueue.async {
        continuation.resume()
        gate.wait()
        fixture.analyzer.tiltGuidanceTransport.consume(
          tiltTransportPacket(sequence: 1), hostSeconds: DocumentTemporalRecorder.hostNow())
      }
    }
    let probe = TiltClockBoundarySink { event in
      if event.kind == "clock_changed" {
        #expect(!fixture.owner.state.tiltGuidance.holding)
        #expect(
          !fixture.analyzer.tiltGuidanceTransport.silenceExceeded(
            runID: runID, now: DocumentTemporalRecorder.hostNow() + 10, maximum: 0))
      }
    }
    await fixture.ownerOperation {
      fixture.owner.state.temporalRecorder?.setJourneySink(probe)
      fixture.owner.temporalClockDidChange(to: nil)
    }
    gate.signal()
    await fixture.drain()
    #expect(probe.recording.events.contains { $0.kind == "clock_changed" })
    let updates = probe.recording.events.compactMap(\.tiltGuidance)
    #expect(updates.count == 1)
    #expect(updates.first?.presentation.reason == .clockChanged)
    #expect(updates.allSatisfy { $0.event?.observation == nil })
    await fixture.ownerOperation { fixture.owner.state.temporalRecorder?.setJourneySink(nil) }
  }

  @Test func terminalCleanupDoesNotWaitForAnyUIConsumer() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    let runID = UUID()
    _ = try await fixture.begin(runID, configuration: .init(evidenceSampleLimit: 16))
    await withCheckedContinuation { continuation in
      fixture.analyzer.analysisQueue.async {
        for sequence in 1...16 {
          fixture.analyzer.tiltGuidanceTransport.consume(
            tiltTransportPacket(sequence: UInt64(sequence)), hostSeconds: Double(sequence))
        }
        continuation.resume()
      }
    }
    await fixture.drain()
    let terminal = fixture.sink.events.compactMap(\.tiltGuidance).last
    #expect(terminal?.presentation.phase == .evidenceLimit)
    await fixture.ownerOperation {
      #expect(!fixture.owner.state.tiltGuidance.holding)
      #expect(fixture.owner.state.captureAdmissionRequested)
    }
  }

  @Test func staleNativeEndCannotReleaseReplacementHold() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    let old = UUID()
    _ = try await fixture.begin(old)
    await fixture.end(old, reason: .cancelled)
    await fixture.drain()
    let replacement = UUID()
    _ = try await fixture.begin(replacement)
    await fixture.end(old, reason: .sessionStopped)
    await fixture.ownerOperation {
      #expect(fixture.owner.state.tiltGuidance.runID == replacement)
      #expect(fixture.owner.state.tiltGuidance.holding)
    }
    await fixture.end(replacement, reason: .userSkipped)
  }

  #if os(iOS)
    @Test func repeatedEndBeforeInitialGuideArchivesOneTerminalAttempt() async {
      let fixture = TiltNativeFixture()
      await fixture.prepare(guideAvailable: false)
      let runID = UUID()
      fixture.owner.beginTiltGuidance(
        runID: runID, configuration: .provisionalV1, cancellation: .init(),
        completion: fixture.results.append)
      await fixture.drain()
      await fixture.end(runID, reason: .userSkipped)
      await fixture.end(runID, reason: .cancelled)
      await fixture.drain()
      let updates = fixture.sink.events.compactMap(\.tiltGuidance)
      #expect(fixture.results.values.count == 1)
      #expect(updates.count == 2)
      #expect(updates.map(\.presentation.revision) == [1, 2])
      #expect(updates.last?.presentation.phase == .skipped)
    }

    @Test(arguments: [DocumentTiltConfiguration.provisionalV1, .provisionalV2])
    func delayedInitialGuidePrecedesControllerAndLaterGuideCancels(
      configuration: DocumentTiltConfiguration
    ) async {
      let fixture = TiltNativeFixture()
      await fixture.prepare(guideAvailable: false)
      let runID = UUID()
      fixture.owner.beginTiltGuidance(
        runID: runID, configuration: configuration, cancellation: .init(),
        completion: fixture.results.append)
      await fixture.drain()
      #expect(fixture.results.values.isEmpty)
      #expect(fixture.sink.events.isEmpty)
      await fixture.ownerOperation {
        #expect(!fixture.owner.state.tiltGuidance.controllerStarted)
        fixture.owner.state.captureDeviceGuideRegion = .init(
          minX: 0.1, minY: 0.2, width: 0.8, height: 0.5)
        fixture.owner.refreshAnalysisGeometry()
        fixture.owner.pollTiltGuidance()
      }
      await fixture.drain()
      #expect(fixture.results.values.count == 1)
      if case .failure = fixture.results.values.first {
        Issue.record("Initial guide cancelled begin")
      }
      await fixture.ownerOperation {
        #expect(fixture.owner.state.tiltGuidance.holding)
        fixture.owner.refreshAnalysisGeometry()
      }
      await fixture.drain()
      #expect(
        fixture.sink.events.compactMap(\.tiltGuidance).last?.presentation.reason == .geometryChanged
      )
      await fixture.ownerOperation { #expect(!fixture.owner.state.tiltGuidance.holding) }
    }
  #endif

  @Test func preCancelledBeginDoesNotFreezeOrRetainAnAttempt() async {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    let cancellation = DocumentTiltStartCancellation()
    cancellation.cancel()
    fixture.owner.beginTiltGuidance(
      runID: UUID(), configuration: .provisionalV1, cancellation: cancellation,
      completion: fixture.results.append)
    await fixture.drain()
    #expect(fixture.results.values.count == 1)
    #expect(fixture.sink.events.isEmpty)
    await fixture.ownerOperation { #expect(!fixture.owner.state.tiltGuidance.holding) }
  }
}

final class TiltNativeFixture: @unchecked Sendable {
  let ramp: TiltRampFlag
  let owner: AVFoundationCameraSessionController
  let analyzer: DocumentFrameAnalyzer
  let sink = RecordingSink()
  let results = TiltStartResults()

  init() {
    let ramp = TiltRampFlag()
    self.ramp = ramp
    let owner = AVFoundationCameraSessionController(
      notifications: NotificationCenter(),
      now: { Date() },
      configuration: .geometry, retireZoomRamp: { _ in }, guidanceZoomIsRamping: { _ in ramp.value }
    )
    self.owner = owner
    analyzer = DocumentFrameAnalyzer(
      now: { Date() },
      configuration: .qualityOnly, observationHandler: { _ in }, focusHandler: { _ in },
      temporalRecorder: owner.state.temporalRecorder,
      tiltGuidanceHandler: { [weak owner] in owner?.enqueueTiltGuidance($0, generation: 0) })
  }

  func prepare(
    adaptive: Bool = true, guideAvailable: Bool = true, clockAvailable: Bool = true
  ) async {
    await ownerOperation { [self] in
      owner.state.isConfigured = true
      owner.state.nativeCaptureReady = true
      owner.state.frameAnalyzer = analyzer
      #if os(iOS)
        if guideAvailable {
          owner.state.captureDeviceGuideRegion = .init(
            minX: 0.1, minY: 0.2, width: 0.8, height: 0.5)
          owner.refreshAnalysisGeometry()
        }
      #endif
      owner.state.adaptiveCaptureEnabled = adaptive
      if clockAvailable, let recorder = owner.state.temporalRecorder {
        recorder.withState { recorder.clock = CMClockGetHostTimeClock() }
      }
      owner.state.temporalRecorder?.setJourneySink(sink)
    }
  }

  func begin(
    _ runID: UUID, configuration: DocumentTiltConfiguration = .provisionalV1
  ) async throws -> DocumentTiltPresentation {
    try await withCheckedThrowingContinuation { continuation in
      owner.beginTiltGuidance(runID: runID, configuration: configuration, cancellation: .init()) {
        continuation.resume(with: $0)
      }
    }
  }

  func end(_ runID: UUID, reason: DocumentTiltReason) async {
    await withCheckedContinuation { continuation in
      owner.endTiltGuidance(runID: runID, reason: reason) { continuation.resume() }
    }
  }

  func ownerOperation(_ operation: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { continuation in
      owner.sessionQueue.async {
        operation()
        continuation.resume()
      }
    }
  }

  func drain() async {
    for _ in 0..<2 {
      await withCheckedContinuation { continuation in
        owner.sessionQueue.async { [self] in
          analyzer.ingressQueue.async { [self] in
            analyzer.analysisQueue.async { [self] in
              owner.sessionQueue.async { continuation.resume() }
            }
          }
        }
      }
    }
  }
}

final class TiltRampFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var ramping = false
  var value: Bool { lock.withLock { ramping } }
  func set(_ value: Bool) { lock.withLock { ramping = value } }
}

final class TiltStartResults: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Result<DocumentTiltPresentation, PhotoCaptureError>] = []
  var values: [Result<DocumentTiltPresentation, PhotoCaptureError>] { lock.withLock { storage } }
  func append(_ result: Result<DocumentTiltPresentation, PhotoCaptureError>) {
    lock.withLock { storage.append(result) }
  }
}

private final class TiltClockBoundarySink: DocumentJourneyRecordingSink, @unchecked Sendable {
  let recording = RecordingSink()
  let inspect: @Sendable (DocumentJourneyRecordingEvent) -> Void

  init(inspect: @escaping @Sendable (DocumentJourneyRecordingEvent) -> Void) {
    self.inspect = inspect
  }

  func reserveFrame(byteCount: Int) -> UUID? { recording.reserveFrame(byteCount: byteCount) }
  func appendFrame(_ frame: DocumentTemporalFrame, reservation: UUID) {
    recording.appendFrame(frame, reservation: reservation)
  }
  func cancelReservation(_ reservation: UUID, reason: String) {
    recording.cancelReservation(reservation, reason: reason)
  }
  func appendMotion(_ sample: DocumentTemporalMotionSample) { recording.appendMotion(sample) }
  func appendEvent(_ event: DocumentJourneyRecordingEvent) {
    inspect(event)
    recording.appendEvent(event)
  }
  func finish(reason: String) async throws -> DocumentJourneyRecordingReceipt {
    try await recording.finish(reason: reason)
  }
}
