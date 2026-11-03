import CoreMedia
import Foundation
import Testing

@testable import DocumentCaptureApple

@Suite struct AVFoundationTiltStartupClockTests {
  @Test func firstClockBindingStartsPendingGuidanceWithoutCancellingIt() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare(clockAvailable: false)
    let runID = UUID()
    let unbound = await startupState(fixture)
    #expect(!unbound.hasClock)
    fixture.owner.beginTiltGuidance(
      runID: runID, configuration: .provisionalV2, cancellation: .init(),
      completion: fixture.results.append)
    await fixture.drain()

    #expect(
      fixture.results.values.isEmpty,
      "Guidance must wait for its first capture synchronization clock before activating")

    await fixture.ownerOperation {
      fixture.owner.temporalClockDidChange(
        to: CMClockGetHostTimeClock(),
        observedTransition: (previous: nil, current: ObjectIdentifier(CMClockGetHostTimeClock())))
      fixture.owner.pollTiltGuidance()
    }
    await fixture.drain()

    #expect(fixture.results.values.count == 1)
    let result = try #require(fixture.results.values.first)
    let presentation = try result.get()
    #expect(presentation.runID == runID)
    #expect(presentation.phase == .baseline)
    #expect(
      fixture.sink.events.compactMap(\.tiltGuidance).allSatisfy {
        !$0.presentation.phase.terminal
      }, "First clock establishment must not manufacture an interrupted tilt attempt")
    let bound = await startupState(fixture)
    #expect(bound.holding)
    await fixture.end(runID, reason: .sessionStopped)
    await fixture.drain()
  }

  @Test func losingEstablishedClockStillCancelsGuidanceAndRefusesFurtherCredit() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    await fixture.ownerOperation {
      fixture.owner.temporalClockDidChange(to: CMClockGetHostTimeClock())
    }
    await fixture.drain()
    let runID = UUID()
    let initial = try await fixture.begin(runID, configuration: .provisionalV2)
    #expect(initial.phase == .baseline)

    await fixture.ownerOperation {
      fixture.owner.temporalClockDidChange(to: nil)
    }
    await fixture.drain()
    await withCheckedContinuation { continuation in
      fixture.analyzer.analysisQueue.async {
        var observations = TiltPolicyTrial()
        for _ in 0..<6 {
          fixture.analyzer.tiltGuidanceTransport.consume(
            observations.next(0), hostSeconds: DocumentTemporalRecorder.hostNow())
        }
        continuation.resume()
      }
    }
    await fixture.drain()

    let updates = fixture.sink.events.compactMap(\.tiltGuidance)
    #expect(updates.last?.presentation.phase == .cancelled)
    #expect(updates.last?.presentation.reason == .clockChanged)
    #expect(updates.allSatisfy { $0.event?.credited != true })
    let stopped = await startupState(fixture)
    #expect(!stopped.holding)
  }

  @Test func missingInitialClockTimesOutOnceWithoutActivating() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare(clockAvailable: false)
    await beginPending(fixture)
    await expireStartup(fixture)
    try assertPendingFailure(fixture, reason: .observationUnavailable)
    let timedOut = await startupState(fixture)
    #expect(!timedOut.holding)
    #expect(!timedOut.hasClock)

    await bindFirstClock(fixture)
    await expireStartup(fixture)
    try assertPendingFailure(fixture, reason: .observationUnavailable)
    let afterBinding = await startupState(fixture)
    #expect(!afterBinding.holding)
  }

  @Test func stoppingBeforeFirstClockCannotActivateThePendingGuidanceLater() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare(clockAvailable: false)
    await beginPending(fixture)
    fixture.owner.stop()
    await fixture.drain()
    try assertPendingFailure(fixture, reason: .sessionStopped)

    await bindFirstClock(fixture)
    try assertPendingFailure(fixture, reason: .sessionStopped)
    let stopped = await startupState(fixture)
    #expect(!stopped.holding)
  }

  @Test func pinnedRecorderWithAnEstablishedClockCannotStartGuidance() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    await fixture.ownerOperation { fixture.owner.state.temporalRecorder?.beginCapture() }
    await beginPending(fixture)
    let pending = await startupState(fixture)
    #expect(pending.pinned)
    #expect(pending.hasClock)
    #expect(!pending.controllerStarted)

    await expireStartup(fixture)
    try assertPendingFailure(fixture, reason: .observationUnavailable)
  }

  @Test func pinnedRecorderCannotReceiveTheFirstBindingException() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare(clockAvailable: false)
    await fixture.ownerOperation { fixture.owner.state.temporalRecorder?.beginCapture() }
    await beginPending(fixture)
    await bindFirstClock(fixture)

    try assertPendingFailure(fixture, reason: .clockChanged)
    let stopped = await startupState(fixture)
    #expect(stopped.pinned)
    #expect(!stopped.hasClock)
    #expect(!stopped.holding)
  }

  @Test func establishedClockBoundaryCancelsAnActiveAttempt() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    let presentation = try await fixture.begin(UUID(), configuration: .provisionalV2)
    #expect(presentation.phase == .baseline)
    await fixture.ownerOperation {
      // A direct boundary must fence the run even when readback has returned to the same clock.
      fixture.owner.temporalClockDidChange(to: CMClockGetHostTimeClock())
    }
    await fixture.drain()

    let terminals = fixture.sink.events.compactMap(\.tiltGuidance).filter {
      $0.presentation.phase.terminal
    }
    #expect(terminals.count == 1)
    #expect(terminals.first?.presentation.reason == .clockChanged)
    let stopped = await startupState(fixture)
    #expect(!stopped.holding)
  }

  @Test func staleFirstBindingNotificationCannotPreservePendingGuidance() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare(clockAvailable: false)
    await beginPending(fixture)
    await fixture.ownerOperation {
      // Model a queued notification whose clock identity no longer matches current readback.
      let staleIdentity = NSObject()
      fixture.owner.temporalClockDidChange(
        to: CMClockGetHostTimeClock(),
        observedTransition: (previous: nil, current: ObjectIdentifier(staleIdentity)))
      fixture.owner.pollTiltGuidance()
    }
    await fixture.drain()

    try assertPendingFailure(fixture, reason: .clockChanged)
    let stopped = await startupState(fixture)
    #expect(!stopped.holding)
  }

  @Test func queuedClockLossCannotBecomeFirstBindingWhenReadbackHasRebounded() async throws {
    let fixture = TiltNativeFixture()
    await fixture.prepare(clockAvailable: false)
    await beginPending(fixture)
    await fixture.ownerOperation {
      let clock = CMClockGetHostTimeClock()
      fixture.owner.temporalClockDidChange(
        to: clock, observedTransition: (previous: ObjectIdentifier(clock), current: nil))
      fixture.owner.pollTiltGuidance()
    }
    await fixture.drain()

    try assertPendingFailure(fixture, reason: .clockChanged)
    let stopped = await startupState(fixture)
    #expect(!stopped.holding)
  }

  #if os(iOS)
    @Test func losingEstablishedClockWhileWaitingForGuideStillCancels() async throws {
      let fixture = TiltNativeFixture()
      await fixture.prepare(guideAvailable: false)
      await beginPending(fixture)
      let pending = await startupState(fixture)
      #expect(pending.hasClock)
      #expect(!pending.controllerStarted)
      await fixture.ownerOperation {
        fixture.owner.temporalClockDidChange(to: nil)
      }
      await fixture.drain()

      try assertPendingFailure(fixture, reason: .clockChanged)
      let stopped = await startupState(fixture)
      #expect(!stopped.holding)
      #expect(!stopped.hasClock)
    }
  #endif

  private func beginPending(_ fixture: TiltNativeFixture) async {
    fixture.owner.beginTiltGuidance(
      runID: UUID(), configuration: .provisionalV2, cancellation: .init(),
      completion: fixture.results.append)
    await fixture.drain()
    #expect(fixture.results.values.isEmpty)
    let pending = await startupState(fixture)
    #expect(pending.holding)
    #expect(!pending.controllerStarted)
  }

  private func bindFirstClock(_ fixture: TiltNativeFixture) async {
    await fixture.ownerOperation {
      let clock = CMClockGetHostTimeClock()
      fixture.owner.temporalClockDidChange(
        to: clock, observedTransition: (previous: nil, current: ObjectIdentifier(clock)))
      fixture.owner.pollTiltGuidance()
    }
    await fixture.drain()
  }

  private func expireStartup(_ fixture: TiltNativeFixture) async {
    await fixture.ownerOperation {
      let expired =
        fixture.owner.state.tiltGuidance.startedAt
        + DocumentCaptureTuning.Controls.adjustmentTimeoutSeconds + 1
      fixture.owner.pollTiltGuidance(now: expired)
      fixture.owner.pollTiltGuidance(now: expired + 1)
    }
    await fixture.drain()
  }

  private func assertPendingFailure(
    _ fixture: TiltNativeFixture, reason: DocumentTiltReason
  ) throws {
    #expect(fixture.results.values.count == 1)
    let result = try #require(fixture.results.values.first)
    switch result {
    case .success:
      Issue.record("A revoked or unavailable startup must not activate guidance")
    case .failure(let error):
      #expect(error == .cameraNotReady)
    }
    let updates = fixture.sink.events.compactMap(\.tiltGuidance)
    let terminals = updates.filter { $0.presentation.phase.terminal }
    #expect(terminals.count == 1)
    #expect(terminals.first?.presentation.reason == reason)
    #expect(updates.allSatisfy { $0.event?.credited != true })
  }

  private func startupState(
    _ fixture: TiltNativeFixture
  ) async -> (hasClock: Bool, holding: Bool, pinned: Bool, controllerStarted: Bool) {
    await withCheckedContinuation { continuation in
      fixture.owner.sessionQueue.async {
        let recorder = fixture.owner.state.temporalRecorder
        continuation.resume(
          returning: (
            recorder?.withState { recorder?.clock != nil } == true,
            fixture.owner.state.tiltGuidance.holding,
            recorder?.withState { recorder?.pinned == true } == true,
            fixture.owner.state.tiltGuidance.controllerStarted
          ))
      }
    }
  }
}
