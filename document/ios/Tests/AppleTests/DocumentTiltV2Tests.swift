import Foundation
import Testing

@testable import DocumentCaptureApple

struct DocumentTiltV2Tests {
  @Test func completeFreshSequenceAcrossEveryFormerRefreshPhaseAndTimestampJitter() {
    let movement =
      [-0.04, -0.08] + Array(repeating: -0.12, count: 5)
      + [-0.06] + Array(repeating: 0.0, count: 5)
      + [0.06] + Array(repeating: 0.12, count: 5)
      + [0.06] + Array(repeating: 0.0, count: 5)
    for offset in 0..<5 {
      for jitter in [false, true] {
        var trial = TiltPolicyTrial()
        trial.hold(0, count: 10 + offset)
        for (index, ratio) in movement.enumerated() {
          trial.send(ratio, step: jitter ? [190, 210, 200][index % 3] : 200)
        }
        #expect(trial.controller.presentation.phase == .readyForStill)
        #expect(trial.controller.evidence.events.allSatisfy { $0.valid && !$0.associatedRefresh })
        #expect(
          trial.controller.evidence.events.allSatisfy { $0.rawLogRatio == $0.correctedLogRatio })
        #expect(
          trial.controller.configuration.version == DocumentTiltConfiguration.provisionalV2.version)
      }
    }
  }

  @Test func stationaryJitterWrongDirectionAndSingleSpikeNeverEarnLeftLeg() {
    var trial = TiltPolicyTrial()
    trial.hold(0, count: 5)
    for ratio in [0.01, -0.01, 0.02, 0, 0.01, -0.02, 0] { trial.send(ratio) }
    trial.hold(0.12, count: 5)
    trial.send(0)
    trial.send(-0.12)
    trial.send(0)
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    #expect(trial.controller.presentation.consecutiveObservations == 0)
    #expect(abs(trial.controller.presentation.signedDelta ?? 1) < 1e-12)
  }

  @Test func methodRevisionLossGapAndResetDiscardActiveProgress() {
    for variant in 0..<5 {
      var trial = TiltPolicyTrial()
      trial.hold(0, count: 5)
      trial.hold(-0.12, count: 3)
      #expect(trial.controller.presentation.phase == .neutralAfterLeft)
      let value: DocumentLiveGeometryObservation
      switch variant {
      case 0: value = trial.next(-0.12, method: "VNDetectRectanglesRequest")
      case 1: value = trial.next(-0.12, requestRevision: 2)
      case 2: value = trial.next(-0.12, step: 600)
      case 3: value = trial.next(-0.12, reset: [.geometryRevisionChanged])
      default:
        let source = trial.next(-0.12)
        value = .init(
          schemaVersion: 2, observedAt: source.observedAt,
          geometry: .init(
            quadrilateral: nil, observationTimestamp: source.captureTimestamp,
            coordinateSpace: source.geometry.coordinateSpace,
            status: "analyzed_no_accepted_rectangle",
            confidence: nil, method: nil), pixelWidth: 1320, pixelHeight: 1760,
          analysisSequence: source.analysisSequence, geometryRevision: 0,
          availability: .guideUnavailable, requestRevision: nil,
          tracker: .init(
            transition: .unavailable, trackingOutcome: .notAttempted,
            precedingAnalysisTimestamp: nil, resetReasons: []),
          requestFacts: [], analysisMode: .freshDetection)
      }
      #expect(value.valid)
      _ = trial.controller.consume(value)
      #expect(trial.controller.presentation.phase == .baseline)
      #expect(trial.controller.presentation.baseline == nil)
      #expect(trial.controller.presentation.consecutiveObservations == 0)
      if variant < 2 { #expect(trial.controller.presentation.reason == .measurementSourceChanged) }
      #expect(trial.controller.evidence.events.allSatisfy { $0.valid })
    }
  }

  @Test func policiesRejectEachOthersSourcesIncludingMixedRefreshAttack() {
    var currentPolicy = DocumentTiltController(runID: UUID(), configuration: .provisionalV2)
    var old = TiltPolicyTrial(version: .trackedV1)
    old.automaticRefresh = true
    for index in 0..<55 {
      let source = old.next(-Double(index / 10) * 0.02)
      #expect(source.valid)
      let update = currentPolicy.consume(source)
      #expect(
        update.presentation.phase == .baseline && update.presentation.reason == .invalidObservation)
      #expect(update.event?.credited == false && update.valid)
    }
    var legacyPolicy = DocumentTiltController(runID: UUID())
    var fresh = TiltPolicyTrial()
    let update = legacyPolicy.consume(fresh.next(0))
    #expect(update.presentation.reason == .invalidObservation)
    #expect(update.valid)
  }

  @Test func modeEntryResetStartsBaselineButLaterResetCannotBridgeIt() {
    var trial = TiltPolicyTrial()
    let entry = trial.next(0, reset: [.analysisModeChanged])
    _ = trial.controller.consume(entry)
    trial.hold(0, count: 4)
    #expect(trial.controller.presentation.phase == .leftEdgeCloser)
    let reset = trial.next(0, reset: [.analysisModeChanged])
    _ = trial.controller.consume(reset)
    #expect(trial.controller.presentation.phase == .baseline)
    #expect(trial.controller.presentation.reason == .trackerReset)
  }

  @Test func budgetIsOnlyAnExplicitTerminalControlReason() {
    for version in [DocumentTiltConfiguration.Version.trackedV1, .freshDetectionV2] {
      var controller = DocumentTiltController(runID: UUID(), configuration: .init(version: version))
      let result = controller.cancel(reason: .recordingBudget)
      #expect(result.valid && result.presentation.phase == .cancelled)
      #expect(result.event?.observation == nil && result.event?.credited == false)
    }
  }
}
