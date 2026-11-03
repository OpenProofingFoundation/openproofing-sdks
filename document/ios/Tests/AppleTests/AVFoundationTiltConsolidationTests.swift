import Foundation
import Testing

@testable import DocumentCaptureApple

@Suite struct AVFoundationTiltConsolidationTests {
  @Test func configuredStartupFailureDetachesGraphBeforeCompletion() async {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    await fixture.ownerOperation {
      let state = fixture.owner.state
      state.captureSession.beginConfiguration()
      state.captureSession.addOutput(state.videoOutput)
      state.captureSession.commitConfiguration()
    }
    let released = await withCheckedContinuation { continuation in
      fixture.owner.start { result in
        let state = fixture.owner.state
        let failed: Bool
        if case .failure = result { failed = true } else { failed = false }
        continuation.resume(
          returning: (
            failed, !state.nativeCaptureReady && !state.captureSession.isRunning,
            !state.isConfigured && state.captureSession.outputs.isEmpty,
            state.frameAnalyzer == nil && !state.graphReleasePending && !state.graphDrainPending
          ))
      }
    }
    #expect(released.0)
    #expect(released.1)
    #expect(released.2)
    #expect(released.3)
  }

  @Test func startupRejectedDuringGraphReleaseDoesNotDetachItsGraph() async {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    await fixture.ownerOperation { fixture.owner.state.graphReleasePending = true }
    let preserved = await withCheckedContinuation { continuation in
      fixture.owner.start { result in
        let state = fixture.owner.state
        let rejected: Bool
        if case .failure(.cameraNotReady) = result { rejected = true } else { rejected = false }
        continuation.resume(
          returning:
            rejected && state.isConfigured && state.frameAnalyzer === fixture.analyzer
            && state.graphReleasePending)
      }
    }
    #expect(preserved)
    await fixture.ownerOperation { fixture.owner.state.graphReleasePending = false }
  }

  @Test func failedStartupReleasesGraphBeforeReportingFailure() async {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    let released = await withCheckedContinuation { continuation in
      fixture.owner.sessionQueue.async {
        let state = fixture.owner.state
        state.captureSession.beginConfiguration()
        state.captureSession.addOutput(state.videoOutput)
        state.captureSession.commitConfiguration()
        state.nativeOperationUncertain = true
        fixture.owner.releaseFailedStartup {
          let state = fixture.owner.state
          continuation.resume(
            returning: (
              !state.nativeCaptureReady && !state.captureSession.isRunning,
              !state.isConfigured && state.captureSession.outputs.isEmpty,
              state.frameAnalyzer == nil && !state.graphReleasePending && !state.graphDrainPending
            ))
        }
      }
    }
    #expect(released.0)
    #expect(released.1)
    #expect(released.2)
  }

  @Test func settlingSetupDoesNotAnnounceBaselineAndGuideCorrectionStaysPending() async throws {
    let fixture = TiltNativeFixture()
    fixture.ramp.set(true)
    await fixture.prepare()
    let live = TiltStartResults()
    fixture.owner.setTiltGuidanceHandler { live.append(.success($0)) }
    let runID = UUID()
    fixture.owner.beginTiltGuidance(
      runID: runID, configuration: .provisionalV2, cancellation: .init(),
      completion: fixture.results.append)
    await fixture.drain()
    #expect(live.values.isEmpty, "Unsettled controls cannot announce a movement baseline")
    #expect(fixture.sink.events.compactMap(\.tiltGuidance).isEmpty)
    #if os(iOS)
      let holding = await withCheckedContinuation { continuation in
        fixture.owner.sessionQueue.async {
          fixture.owner.state.captureDeviceGuideRegion = .init(
            minX: 0.15, minY: 0.2, width: 0.7, height: 0.5)
          fixture.owner.refreshAnalysisGeometry()
          continuation.resume(returning: fixture.owner.state.tiltGuidance.holding)
        }
      }
      #expect(holding)
      await fixture.drain()
      #expect(
        fixture.results.values.isEmpty, "Setup geometry correction cannot fail an unstarted run")
    #endif
    fixture.ramp.set(false)
    await fixture.ownerOperation { fixture.owner.pollTiltGuidance() }
    await fixture.drain()
    #expect(fixture.results.values.count == 1)
    if let result = fixture.results.values.first {
      #expect(try result.get().phase == .baseline)
    }
    await fixture.end(runID, reason: .sessionStopped)
    await fixture.drain()
  }

  @Test func cancelledSetupRetainsControlEvidenceWithoutLiveBaseline() async {
    let fixture = TiltNativeFixture()
    await fixture.prepare(clockAvailable: false)
    let live = TiltStartResults()
    fixture.owner.setTiltGuidanceHandler { live.append(.success($0)) }
    let runID = UUID()
    fixture.owner.beginTiltGuidance(
      runID: runID, configuration: .provisionalV2, cancellation: .init(),
      completion: fixture.results.append)
    await fixture.drain()
    await fixture.end(runID, reason: .userSkipped)
    await fixture.drain()
    let archived = fixture.sink.events.compactMap(\.tiltGuidance)
    #expect(archived.map(\.presentation.phase) == [.baseline, .skipped])
    #expect(archived.allSatisfy { $0.event?.observation == nil })
    #expect(live.values.compactMap { try? $0.get().phase } == [.skipped])
  }

  @Test func invalidatedQueuedStartNeverPublishesBaseline() {
    let sink = RecordingSink()
    let recorder = DocumentTemporalRecorder(configuration: .init())
    recorder.setJourneySink(sink)
    let live = TiltStartResults()
    let transport = DocumentTiltGuidanceTransport(recorder: recorder) {
      live.append(.success($0))
    }
    let runID = UUID()
    transport.prepare(runID: runID)
    transport.invalidate(runID: runID, reason: .clockChanged)
    #expect(transport.begin(runID: runID, configuration: .provisionalV2) == nil)
    #expect(
      sink.events.compactMap(\.tiltGuidance).map(\.presentation.phase) == [.baseline, .cancelled])
    #expect(live.values.compactMap { try? $0.get().phase } == [.cancelled])
  }

  #if os(iOS)
    @Test(arguments: [DocumentTiltConfiguration.provisionalV1, .provisionalV2])
    func standaloneReleaseRejectsQueuedOldQualityButAcceptsCurrentRevision(
      configuration: DocumentTiltConfiguration
    ) async throws {
      let fixture = TiltNativeFixture()
      await fixture.prepare()
      let runID = UUID()
      _ = try await fixture.begin(runID, configuration: configuration)
      let previousRevision = await withCheckedContinuation { continuation in
        fixture.owner.sessionQueue.async {
          continuation.resume(returning: fixture.owner.state.geometryRevision)
        }
      }
      await fixture.end(runID, reason: .userCaptureNow)
      let result = await withCheckedContinuation { continuation in
        fixture.owner.sessionQueue.async {
          fixture.owner.publishAdaptiveObservation(consolidationQuality(revision: previousRevision))
          let rejectedOld = fixture.owner.state.latestQualityObservation == nil
          let revision = fixture.owner.state.geometryRevision
          fixture.owner.publishAdaptiveObservation(consolidationQuality(revision: revision))
          continuation.resume(
            returning: (
              rejectedOld, revision - previousRevision,
              fixture.owner.state.latestQualityObservation?.geometryRevision == revision
            ))
        }
      }
      #expect(result.0)
      #expect(result.1 == 1)
      #expect(result.2)
      await fixture.drain()
    }

    @Test func oneGeometryChangeHasOneRevisionAndOneRecordedDiscontinuity() async throws {
      let fixture = TiltNativeFixture()
      await fixture.prepare()
      _ = try await fixture.begin(UUID(), configuration: .provisionalV2)
      let revisionDelta = await withCheckedContinuation { continuation in
        fixture.owner.sessionQueue.async {
          let revision = fixture.owner.state.geometryRevision
          fixture.owner.refreshAnalysisGeometry()
          continuation.resume(returning: fixture.owner.state.geometryRevision - revision)
        }
      }
      #expect(revisionDelta == 1)
      await fixture.drain()
      #expect(fixture.sink.events.filter { $0.kind == "configuration_changed" }.count == 1)
      let terminal = fixture.sink.events.compactMap(\.tiltGuidance).filter {
        $0.presentation.phase.terminal
      }
      #expect(terminal.count == 1)
      #expect(terminal.first?.presentation.reason == .geometryChanged)
    }
  #endif
}

private func consolidationQuality(revision: UInt64) -> DocumentCaptureQualityObservation {
  .init(
    sequence: 1, geometryRevision: revision, timestamp: Date(),
    metrics: .init(
      documentFillRatio: nil, documentGuideFillRatio: nil, documentInsideGuide: nil,
      guideCenterX: nil, guideCenterY: nil, guideWidth: nil, guideHeight: nil,
      documentAspectRatio: nil, sharpness: 0, motion: nil,
      clippedHighlightRatio: 0, meanLuminance: 0, documentCenterX: nil, documentCenterY: nil),
    assessment: .init(ready: false, blockingReasons: [.documentNotFound], stableFrameCount: 0))
}
