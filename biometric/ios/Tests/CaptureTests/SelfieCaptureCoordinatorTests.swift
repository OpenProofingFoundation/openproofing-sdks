#if os(iOS)
  import CoreImage
  import CryptoKit
  import UIKit
  import XCTest

  @testable import BiometricCapture

  @MainActor
  final class SelfieCaptureCoordinatorTests: XCTestCase {
    func testDepthExpiresReadinessBeforeItsNewerColourImageExpires() async throws {
      let h = makeHarness()
      try await admit(h)
      h.suppliesDepth = false
      try h.open(at: 1.46, marker: 46) // Image age 240 ms, depth age 256 ms.
      XCTAssertFalse(h.readiness.last?.captureReady == true)
      XCTAssertTrue(h.readiness.contains { $0.refusal == .depthStale })
      h.subject.shutterTapped()
      await equal(h.worker.renderCount, 0)
      XCTAssertTrue(h.captures.isEmpty)
    }

    func testDepthlessFrameKeepsThePairedImageAndItsOwnExpressionReceipt() async throws {
      let h = makeHarness()
      try await admit(h)
      h.suppliesDepth = false
      try h.open(at: 1.24, marker: 24)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      await equal(h.worker.renderMarkers, [22])
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.captures.count == 1 }
      let captured = try XCTUnwrap(h.captures.first)
      XCTAssertEqual(captured.1.depthEvidence?.imageTimestamp, 1.22)
      XCTAssertEqual(try XCTUnwrap(captured.1.depthEvidence).depthTimestamp, 1.204, accuracy: 0.000001)
      XCTAssertEqual(captured.1.depthEvidence?.assessment, .live)
      let digest = SHA256.hash(data: captured.0).map { String(format: "%02x", $0) }.joined()
      XCTAssertEqual(captured.1.depthAssessment(imageSHA256: digest), .live)
      XCTAssertEqual(captured.1.depthAssessment(imageSHA256: "different-image"), .insufficientData)
    }

    func testFlatDepthRefusesEvenAfterBlinkAndNeverRenders() async throws {
      let h = makeHarness()
      h.flatDepth = true
      try h.blink()
      await eventually { await h.worker.analysisCount == 1 }
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.refusal == .depthFlat }
      h.subject.shutterTapped()
      await equal(h.worker.renderCount, 0)
      XCTAssertTrue(h.captures.isEmpty)
    }

    func testMissingDepthHasABoundedRecoveryAndNoCapture() throws {
      let h = makeHarness()
      h.suppliesDepth = false
      try h.blink()
      XCTAssertEqual(h.readiness.last?.refusal, .depthUnavailable)
      try h.open(at: 11, marker: 11)
      h.subject.checkTimeouts()
      XCTAssertEqual(h.failures.map(\.reason), [.depthUnavailable])
      XCTAssertTrue(h.captures.isEmpty)
    }

    func testStaleOrZeroNativeDepthTimestampCannotSeedACandidate() async throws {
      for offset in [0.3, 1.22, -0.02] {
        let h = makeHarness()
        h.depthOffset = offset
        try h.blink()
        XCTAssertEqual(h.readiness.last?.refusal, .depthStale)
        await equal(h.worker.analysisCount, 0)
      }
    }

    func testSlowAnalysisKeepsOneWorkerAndOnlyNewestPendingFrame() async throws {
      let h = makeHarness()
      try h.blink()
      await eventually { await h.worker.analysisCount == 1 }
      for index in 1...5 { try h.open(at: 1.22 + Double(index) * 0.02, marker: UInt8(index)) }
      await equal(h.worker.analysisCount, 1)
      await h.worker.finishAnalysis()
      await eventually { await h.worker.analysisCount == 2 }
      await equal(h.worker.analysisMarkers, [22, 5])
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.captureReady == true }
      XCTAssertTrue(
        h.captures.isEmpty, "A first good measurement cannot inherit expression-only hold")
      h.subject.stop()
    }

    func testStopRestartDiscardsOldAnalysisAndKeepsWorkerBounded() async throws {
      let h = makeHarness()
      try h.blink()
      await eventually { await h.worker.analysisCount == 1 }
      h.subject.stop()
      XCTAssertTrue(h.subject.start(after: 2))
      try h.blink(from: 2)
      await equal(h.worker.analysisCount, 1)
      await h.worker.finishAnalysis()
      await eventually { await h.worker.analysisCount == 2 }
      XCTAssertFalse(h.readiness.last?.captureReady == true)
      XCTAssertTrue(h.captures.isEmpty)
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.captureReady == true }
      h.subject.stop()
    }

    func testGuideAndAnchorChangesRejectOutstandingAnalysis() async throws {
      for changesGuide in [true, false] {
        let h = makeHarness()
        try h.blink()
        await eventually { await h.worker.analysisCount == 1 }
        if changesGuide {
          h.subject.updateGuide(
            oval: CGRect(x: 5, y: 5, width: 90, height: 90),
            viewport: CGSize(width: 100, height: 100), orientation: .landscapeLeft)
          try h.open(at: 1.24, marker: 24)
        } else {
          h.anchor = UUID()
          try h.blink(from: 1.24)
        }
        await h.worker.finishAnalysis()
        await eventually { await h.worker.analysisCount == 2 }
        XCTAssertFalse(h.readiness.last?.captureReady == true)
        await h.worker.finishAnalysis()
        await eventually { h.readiness.last?.captureReady == true }
        h.subject.stop()
      }
    }

    func testDoubleShutterRendersExactlyMeasuredFrameEvenWhenNewFrameArrives() async throws {
      let h = makeHarness()
      try await admit(h)
      try h.open(at: 1.24, marker: 24)
      h.subject.shutterTapped()
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      await equal(h.worker.renderMarkers, [22])
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.captures.count == 1 }
      XCTAssertEqual(h.captures.first?.1.frameTimestamp, 1.22)
      XCTAssertTrue(h.captures.first?.1.admissionValid == true)
      XCTAssertFalse(h.subject.start(after: 3), "One capture surface delivers once")
      await h.worker.finishAnalysis()
      XCTAssertEqual(h.captures.count, 1)
    }

    func testStoppedRenderCannotDeliverIntoRestartedSession() async throws {
      let h = makeHarness()
      try await admit(h)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      h.subject.stop()
      XCTAssertTrue(h.subject.start(after: 2))
      try h.blink(from: 2)
      await eventually { await h.worker.analysisCount == 2 }
      await h.worker.finishRender(image: Harness.image())
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.captureReady == true }
      XCTAssertTrue(h.captures.isEmpty)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 2 }
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.captures.count == 1 }
      XCTAssertEqual(h.captures.first?.1.frameTimestamp, 2.22)
    }

    func testGuideChangeDuringRenderDoesNotWedgeOrReplaceAdmittedPixels() async throws {
      let h = makeHarness()
      try await admit(h)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      h.subject.updateGuide(
        oval: CGRect(x: 5, y: 5, width: 90, height: 90),
        viewport: CGSize(width: 100, height: 100), orientation: .landscapeLeft)
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.captures.count == 1 }
      XCTAssertEqual(h.captures.first?.1.frameTimestamp, 1.22)
    }

    func testRenderFailureIsTypedAndRequiresExplicitRestart() async throws {
      let h = makeHarness()
      try await admit(h)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      await h.worker.finishRender(image: nil)
      await eventually { h.failures.last?.reason == .renderingFailed }
      h.subject.shutterTapped()
      await equal(h.worker.renderCount, 1)
      XCTAssertTrue(h.subject.start(after: 2))
      try h.blink(from: 2)
      await eventually { await h.worker.analysisCount == 2 }
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.captureReady == true }
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 2 }
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.captures.count == 1 }
      XCTAssertEqual(h.captures.first?.1.frameTimestamp, 2.22)
    }

    func testBadMeasurementRestartsAutomaticMeasuredHold() async throws {
      let h = makeHarness(hold: 0.10)
      try await admit(h)
      try h.open(at: 1.28, marker: 28)
      await eventually { await h.worker.analysisCount == 2 }
      await h.worker.finishAnalysis(quality: nil)
      await eventually { h.readiness.last?.refusal == .captureQualityUnavailable }
      try h.open(at: 1.34, marker: 34)
      await eventually { await h.worker.analysisCount == 3 }
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.captureReady == true }
      await equal(h.worker.renderCount, 0)
      try h.open(at: 1.40, marker: 40)
      await eventually { await h.worker.analysisCount == 4 }
      let priorReadinessCount = h.readiness.count
      await h.worker.finishAnalysis()
      await eventually { h.readiness.count > priorReadinessCount }
      await equal(h.worker.renderCount, 0)
      try h.open(at: 1.46, marker: 46)
      await eventually { await h.worker.analysisCount == 5 }
      await h.worker.finishAnalysis()
      await eventually { await h.worker.renderCount == 1 }
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.captures.count == 1 }
      XCTAssertEqual(h.captures.first?.1.trigger, .automatic)
      XCTAssertEqual(h.captures.first?.1.frameTimestamp, 1.46)
    }

    func testSlowNextAnalysisExpiresReadinessAndRestartsMeasuredHold() async throws {
      let h = makeHarness(hold: 0.10)
      try await admit(h)
      try h.open(at: 1.24, marker: 24)
      await eventually { await h.worker.analysisCount == 2 }
      for index in 1...19 { try h.open(at: 1.24 + Double(index) * 0.02, marker: 62) }
      XCTAssertFalse(h.readiness.last?.captureReady == true)
      h.subject.shutterTapped()
      await equal(h.worker.renderCount, 0)
      await h.worker.finishAnalysis()
      await eventually { await h.worker.analysisCount == 3 }
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.captureReady == true }
      await equal(h.worker.renderCount, 0)
      try h.open(at: 1.74, marker: 74)
      await eventually { await h.worker.analysisCount == 4 }
      await h.worker.finishAnalysis()
      await eventually { await h.worker.renderCount == 1 }
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.captures.count == 1 }
      XCTAssertEqual(h.captures.first?.1.frameTimestamp, 1.74)
    }

    func testDuplicateStartPreservesMeasuredCandidate() async throws {
      let h = makeHarness()
      try await admit(h)
      let callbackCount = h.readiness.count
      XCTAssertFalse(h.subject.start(after: 1.23))
      XCTAssertEqual(h.readiness.count, callbackCount)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      await equal(h.worker.renderMarkers, [22])
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.captures.count == 1 }
      XCTAssertEqual(h.captures.first?.1.frameTimestamp, 1.22)
    }

    func testRestartCannotLaunchSecondRendererWhileOldRendererIsBlocked() async throws {
      let h = makeHarness()
      try await admit(h)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      h.subject.stop()
      XCTAssertTrue(h.subject.start(after: 2))
      try h.blink(from: 2)
      await eventually { await h.worker.analysisCount == 2 }
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.refusal == .captureInProgress }
      h.subject.shutterTapped()
      h.subject.shutterTapped()
      await equal(h.worker.renderCount, 1)
      XCTAssertTrue(h.captures.isEmpty)
      await h.worker.finishRender(image: Harness.image())
      try h.open(at: 2.24, marker: 24)
      await eventually { await h.worker.analysisCount == 3 }
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.captureReady == true }
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 2 }
      XCTAssertTrue(h.captures.isEmpty, "Old render may not deliver into the new session")
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.captures.count == 1 }
      XCTAssertEqual(h.captures.first?.1.frameTimestamp, 2.24)
    }

    func testVisionFailureIsDistinctFromSuccessfulNoFaceObservation() async throws {
      let h = makeHarness()
      try h.blink()
      await eventually { await h.worker.analysisCount == 1 }
      await h.worker.finishAnalysis(faceCount: 0)
      await eventually {
        h.subject.isQuiescent && h.readiness.last?.refusal == .captureQualityUnavailable
      }
      XCTAssertTrue(h.failures.isEmpty)
      try h.open(at: 1.24, marker: 24)
      await eventually { await h.worker.analysisCount == 2 }
      let error = NSError(
        domain: "VNErrorDomain", code: 9,
        userInfo: [NSLocalizedDescriptionKey: "private biometric details"])
      let failure = SelfieCameraFailure.analysis(error)
      await h.worker.finishAnalysis(failure: failure)
      await eventually { h.failures == [failure] }
      XCTAssertEqual(failure.reason, .analysisFailed)
      XCTAssertEqual(failure.domain, "VNErrorDomain")
      XCTAssertEqual(failure.code, 9)
      XCTAssertFalse(
        String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
          .contains("private biometric details"))
      h.subject.shutterTapped()
      XCTAssertTrue(h.captures.isEmpty)
    }

    func testFrameSilenceAfterWorkingFramesFailsOnce() throws {
      let h = makeHarness()
      try h.open(at: 1.1, marker: 1)
      h.now = 11.09
      h.subject.checkTimeouts()
      XCTAssertTrue(h.failures.isEmpty)
      h.now = 11.1
      h.subject.checkTimeouts()
      h.subject.checkTimeouts()
      XCTAssertEqual(h.failures.map(\.reason), [.noFrames])
      XCTAssertFalse(h.readiness.last?.captureReady == true)
    }

    func testBlockedAnalysisTimesOutWithoutOpeningAnotherWorker() async throws {
      let h = makeHarness()
      try h.blink()
      await eventually { await h.worker.analysisCount == 1 }
      h.now = 12
      h.subject.checkTimeouts()
      XCTAssertEqual(h.failures.map(\.reason), [.analysisTimedOut])
      XCTAssertFalse(h.subject.isQuiescent)
      h.subject.shutterTapped()
      await equal(h.worker.renderCount, 0)
      await h.worker.finishAnalysis()
      await eventually { h.subject.isQuiescent }
      XCTAssertTrue(h.captures.isEmpty)
      XCTAssertFalse(h.readiness.last?.captureReady == true)
      XCTAssertTrue(h.subject.start(after: 13))
      try h.blink(from: 13)
      await eventually { await h.worker.analysisCount == 2 }
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.captureReady == true }
      h.subject.stop()
    }

    func testBlockedRenderTimesOutAndCannotDeliverLatePixels() async throws {
      let h = makeHarness()
      try await admit(h)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      h.now = 12
      h.subject.checkTimeouts()
      XCTAssertEqual(h.failures.map(\.reason), [.renderingTimedOut])
      XCTAssertFalse(h.subject.isQuiescent)
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.subject.isQuiescent }
      XCTAssertTrue(h.captures.isEmpty)
      XCTAssertFalse(h.readiness.last?.captureReady == true)
    }

    func testStoppedWatchdogCannotFailReplacementBeforeItsOwnDeadline() throws {
      let h = makeHarness()
      h.now = 10
      h.subject.stop()
      h.now = 20
      h.subject.checkTimeouts()
      XCTAssertTrue(h.failures.isEmpty)
      XCTAssertTrue(h.subject.start(after: 20))
      h.now = 29.9
      h.subject.checkTimeouts()
      XCTAssertTrue(h.failures.isEmpty)
      h.now = 30
      h.subject.checkTimeouts()
      XCTAssertEqual(h.failures.map(\.reason), [.noFrames])
    }

    func testReentrantStopAtAdmissionPreventsRendererDispatch() async throws {
      let h = makeHarness()
      try await admit(h)
      h.subject.onReadiness = { readiness in
        if readiness.refusal == .captureInProgress { h.subject.stop() }
      }
      h.subject.shutterTapped()
      await Task.yield()
      await equal(h.worker.renderCount, 0)
      XCTAssertTrue(h.captures.isEmpty)
      XCTAssertTrue(h.subject.isQuiescent)
    }

    func testReentrantRevokeAndRegrantCannotDeliverPreviouslyAdmittedSelfie() async throws {
      let h = makeHarness()
      h.subject.stop()
      let native = NativeSelfieSession(
        coordinator: h.subject,
        camera: .init(
          isSupported: { true }, authorizationStatus: { .authorized },
          requestPermission: { true },
          run: { _ in
            // Synthetic frames are supplied directly to the coordinator; no AR session runs.
          },
          pause: { _ in
            // The synthetic camera has no AR session to pause.
          }))
      native.onCapture = { h.captures.append(($0.encodedPNG, $0.admissionReceipt)) }
      native.onState = { [weak native] state in
        if case .captured = state {
          native?.setConsent(.withheld)
          native?.setConsent(.permitted)
        }
      }
      native.setConsent(.permitted)
      native.setActive(true)
      try h.blink()
      await eventually { await h.worker.analysisCount == 1 }
      await h.worker.finishAnalysis()
      await eventually { h.subject.isQuiescent }
      native.capture()
      await eventually { await h.worker.renderCount == 1 }
      await h.worker.finishRender(image: Harness.image())
      await eventually {
        if case .captured = native.state { return true }
        return false
      }
      XCTAssertTrue(h.captures.isEmpty)
      native.stop()
    }

    func testNativeRetryRejectsHungAnalysisUntilWorkerActuallyReturns() async throws {
      let h = makeHarness()
      h.subject.stop()
      var cameraRuns = 0
      let native = NativeSelfieSession(
        coordinator: h.subject,
        camera: .init(
          isSupported: { true }, authorizationStatus: { .authorized },
          requestPermission: { true }, run: { _ in cameraRuns += 1 },
          pause: { _ in
            // The synthetic camera records starts but has no AR session to pause.
          }))
      native.setConsent(.permitted)
      native.setActive(true)
      try h.blink()
      await eventually { await h.worker.analysisCount == 1 }
      h.now = 12
      h.subject.checkTimeouts()
      XCTAssertEqual(native.state, .failed(.init(reason: .analysisTimedOut)))
      for _ in 0..<5 { XCTAssertFalse(native.retry()) }
      XCTAssertEqual(cameraRuns, 1)
      await equal(h.worker.analysisCount, 1)
      await h.worker.finishAnalysis()
      await eventually { h.subject.isQuiescent }
      XCTAssertTrue(native.retry())
      XCTAssertEqual(cameraRuns, 2)
      XCTAssertEqual(native.state, .starting)
      XCTAssertTrue(h.captures.isEmpty)
      native.stop()
    }

    func testWindowRetainsDistinctOriginalPixelsAndTheirOwnAdmissionDepthReceipts() async throws {
      let h = makeHarness(window: .init(maximumCandidates: 2, duration: 2, minimumInterval: 0.1))
      try await admit(h)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      await h.worker.finishRender(image: Harness.image(marker: 22))
      await eventually { h.windowCandidates.count == 1 }
      try h.open(at: 1.34, marker: 34)
      await eventually { await h.worker.analysisCount == 2 }
      await h.worker.finishAnalysis()
      await eventually { await h.worker.renderCount == 2 }
      await h.worker.finishRender(image: Harness.image(marker: 34))
      await eventually { h.windows.count == 1 }
      await equal(h.worker.renderMarkers, [22, 34])
      let candidates = try XCTUnwrap(h.windows.first)
      XCTAssertEqual(candidates.map { $0.1.frameTimestamp }, [1.22, 1.34])
      XCTAssertEqual(candidates.map { $0.1.depthEvidence?.imageTimestamp }, [1.22, 1.34])
      XCTAssertNotEqual(candidates[0].0, candidates[1].0)
      for (bytes, receipt) in candidates {
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(receipt.depthEvidence?.imageSHA256, digest)
        XCTAssertTrue(receipt.admissionValid)
        XCTAssertEqual(receipt.frameEvidence?.frameAgeAtAdmission, 0)
      }
      XCTAssertTrue(h.captures.isEmpty, "Window mode must not also deliver legacy single capture")
      XCTAssertFalse(h.subject.start(after: 3))
    }

    func testWindowDeadlineDeliversOnlyAlreadyAdmittedFramesWithoutRewritingFreshness() async throws {
      let h = makeHarness(window: .engineeringV1)
      try await admit(h)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.windowCandidates.count == 1 }
      h.now = 3.23
      h.subject.checkTimeouts()
      XCTAssertEqual(h.windows.count, 1)
      XCTAssertEqual(h.windows.first?.count, 1)
      XCTAssertEqual(h.windows.first?.first?.1.frameTimestamp, 1.22)
      XCTAssertEqual(h.windows.first?.first?.1.frameEvidence?.frameAgeAtAdmission, 0)
      XCTAssertTrue(h.failures.isEmpty)
      h.subject.checkTimeouts()
      XCTAssertEqual(h.windows.count, 1)
    }

    func testWindowMinimumIntervalSkipsTooCloseFramesAndRespectsCountBound() async throws {
      let h = makeHarness(window: .init(maximumCandidates: 2, duration: 2, minimumInterval: 0.20))
      try await admit(h)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.windowCandidates.count == 1 }
      try h.open(at: 1.30, marker: 30)
      await eventually { await h.worker.analysisCount == 2 }
      await h.worker.finishAnalysis()
      await eventually { h.subject.isQuiescent }
      await equal(h.worker.renderCount, 1)
      try h.open(at: 1.44, marker: 44)
      await eventually { await h.worker.analysisCount == 3 }
      await h.worker.finishAnalysis()
      await eventually { await h.worker.renderCount == 2 }
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.windows.count == 1 }
      try h.open(at: 1.50, marker: 50)
      await equal(h.worker.analysisCount, 3)
      XCTAssertEqual(h.windows[0].map { $0.1.frameTimestamp }, [1.22, 1.44])
    }

    func testEmptyWindowDeadlineFailsAndLateRendererCannotDeliver() async throws {
      let h = makeHarness(window: .engineeringV1)
      try await admit(h)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      h.now = 3.23
      h.subject.checkTimeouts()
      XCTAssertEqual(h.failures.map(\.reason), [.captureWindowEmpty])
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.subject.isQuiescent }
      XCTAssertTrue(h.windows.isEmpty)
      XCTAssertTrue(h.windowCandidates.isEmpty)
    }

    func testStoppingWindowErasesRetainedFramesAndFencesLateRendererAcrossRestart() async throws {
      let h = makeHarness(window: .init(maximumCandidates: 2, duration: 2, minimumInterval: 0.1))
      try await admit(h)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      await h.worker.finishRender(image: Harness.image())
      await eventually { h.windowCandidates.count == 1 }
      try h.open(at: 1.34, marker: 34)
      await eventually { await h.worker.analysisCount == 2 }
      await h.worker.finishAnalysis()
      await eventually { await h.worker.renderCount == 2 }
      h.subject.stop()
      XCTAssertTrue(h.windowCandidates.isEmpty)
      XCTAssertTrue(h.subject.start(after: 2))
      try h.blink(from: 2)
      await eventually { await h.worker.analysisCount == 3 }
      await h.worker.finishAnalysis()
      await h.worker.finishRender(image: Harness.image(marker: 34))
      await eventually { h.subject.isQuiescent }
      XCTAssertTrue(h.windowCandidates.isEmpty)
      XCTAssertTrue(h.windows.isEmpty)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 3 }
      await h.worker.finishRender(image: Harness.image(marker: 22))
      await eventually { h.windowCandidates.count == 1 }
      XCTAssertEqual(h.windowCandidates[0].1.frameTimestamp, 2.22)
    }

    func testGuideOrAnchorDiscontinuityErasesTheWholeWindow() async throws {
      for guideChange in [true, false] {
        let h = makeHarness(window: .engineeringV1)
        try await admit(h)
        h.subject.shutterTapped()
        await eventually { await h.worker.renderCount == 1 }
        await h.worker.finishRender(image: Harness.image())
        await eventually { h.windowCandidates.count == 1 }
        if guideChange {
          h.subject.updateGuide(oval: CGRect(x: 5, y: 5, width: 90, height: 90),
            viewport: CGSize(width: 100, height: 100), orientation: .landscapeLeft)
        } else {
          h.anchor = UUID()
          try h.open(at: 1.24, marker: 24)
        }
        XCTAssertTrue(h.windowCandidates.isEmpty)
        XCTAssertTrue(h.windows.isEmpty)
      }
    }

    func testNativeWindowSnapshotsMotionForEachOriginalFrameAndPausesBeforeDelivery() async throws {
      let h = makeHarness(window: .init(maximumCandidates: 2, duration: 2, minimumInterval: 0.1))
      h.subject.stop()
      var motionRequests: [(String, TimeInterval)] = []
      var pauses = 0
      let native = NativeSelfieSession(coordinator: h.subject, camera: .init(
        isSupported: { true }, authorizationStatus: { .authorized }, requestPermission: { true },
        run: { _ in /* Frames are supplied to the real coordinator below. */ },
        pause: { _ in pauses += 1 }), motionSnapshot: { digest, timestamp in
          motionRequests.append((digest, timestamp))
          return nil // No fabricated sensor evidence is used in this lifecycle test.
        })
      var delivered: [CapturedSelfie] = []
      var pausesAtDelivery = 0
      native.onReadiness = { h.readiness.append($0) }
      native.onCaptureWindow = { delivered = $0; pausesAtDelivery = pauses }
      native.setConsent(.permitted)
      native.setActive(true)
      try h.blink()
      await eventually { await h.worker.analysisCount == 1 }
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.captureReady == true }
      native.capture()
      await eventually { await h.worker.renderCount == 1 }
      await h.worker.finishRender(image: Harness.image(marker: 22))
      await eventually { motionRequests.count == 1 }
      XCTAssertTrue(delivered.isEmpty)
      try h.open(at: 1.34, marker: 34)
      await eventually { await h.worker.analysisCount == 2 }
      await h.worker.finishAnalysis()
      await eventually { await h.worker.renderCount == 2 }
      await h.worker.finishRender(image: Harness.image(marker: 34))
      await eventually { delivered.count == 2 }
      XCTAssertEqual(motionRequests.map { $0.1 }, [1.22, 1.34])
      XCTAssertEqual(motionRequests.map { $0.0 }, delivered.map(\.sha256))
      XCTAssertEqual(delivered.map { $0.admissionReceipt.frameTimestamp }, [1.22, 1.34])
      XCTAssertNotEqual(delivered[0].id, delivered[1].id)
      XCTAssertGreaterThan(pausesAtDelivery, 0)
      native.stop()
    }

    func testWindowRejectsRendererDimensionsThatDoNotMatchTheBudgetedOriginal() async throws {
      let h = makeHarness(window: .engineeringV1)
      try await admit(h)
      h.subject.shutterTapped()
      await eventually { await h.worker.renderCount == 1 }
      let oversized = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 4))
      await h.worker.finishRender(image: CIContext().createCGImage(oversized, from: oversized.extent))
      await eventually { h.failures.last?.reason == .renderingFailed }
      XCTAssertTrue(h.windowCandidates.isEmpty)
      XCTAssertTrue(h.windows.isEmpty)
    }

    func testWindowDeliveryIsFencedWhenCapturedObserverRevokesAndRegrantsConsent() async throws {
      let h = makeHarness(window: .init(maximumCandidates: 1, duration: 2, minimumInterval: 0.1))
      h.subject.stop()
      let native = NativeSelfieSession(coordinator: h.subject, camera: .init(
        isSupported: { true }, authorizationStatus: { .authorized }, requestPermission: { true },
        run: { _ in /* This test supplies deterministic coordinator frames, not a camera. */ },
        pause: { _ in /* No AR session was started by the controlled effect. */ }))
      var deliveries = 0
      native.onCaptureWindow = { _ in deliveries += 1 }
      native.onState = { [weak native] state in
        if case .captured = state {
          native?.setConsent(.withheld)
          native?.setConsent(.permitted)
        }
      }
      native.setConsent(.permitted)
      native.setActive(true)
      try h.blink()
      await eventually { await h.worker.analysisCount == 1 }
      await h.worker.finishAnalysis()
      await eventually { h.subject.isQuiescent }
      native.capture()
      await eventually { await h.worker.renderCount == 1 }
      await h.worker.finishRender(image: Harness.image())
      await eventually {
        if case .captured = native.state { return true }
        return false
      }
      XCTAssertEqual(deliveries, 0)
      native.stop()
    }

    func testWindowConfigurationBoundsAreOperationalAndInvalidConfigurationNeverStarts() {
      XCTAssertTrue(SelfieCaptureWindowPolicy.engineeringV1.isValid)
      for policy in [SelfieCaptureWindowPolicy(maximumCandidates: 13, duration: 2, minimumInterval: 0.2),
        .init(maximumCandidates: 0, duration: 2, minimumInterval: 0.2),
        .init(maximumCandidates: 8, duration: 3.1, minimumInterval: 0.2),
        .init(maximumCandidates: 8, duration: .nan, minimumInterval: 0.2),
        .init(maximumCandidates: 8, duration: 2, minimumInterval: 0),
        .init(maximumCandidates: 8, duration: 2, minimumInterval: .infinity)] {
        XCTAssertFalse(policy.isValid)
        let subject = SelfieCaptureCoordinator(policy: .engineeringV1, captureWindow: policy,
          analyze: { _ in .init(faceCount: 0, quality: nil, faceBox: nil, revision: 3, elapsed: 0) }, clock: { 0 })
        XCTAssertFalse(subject.start(after: 0))
      }
    }

    private func makeHarness(hold: TimeInterval = 1, window: SelfieCaptureWindowPolicy? = nil) -> Harness {
      let harness = Harness(hold: hold, window: window)
      addTeardownBlock { @MainActor in
        harness.subject.stop()
        await harness.worker.finishOutstanding()
      }
      return harness
    }

    private func equal<T: Equatable>(
      _ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line
    ) {
      XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func admit(_ h: Harness) async throws {
      try h.blink()
      await eventually { await h.worker.analysisCount == 1 }
      await h.worker.finishAnalysis()
      await eventually { h.readiness.last?.captureReady == true }
    }

    private func eventually(
      file: StaticString = #filePath, line: UInt = #line,
      _ predicate: @MainActor () async -> Bool
    ) async {
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while ContinuousClock.now < deadline {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
      }
      XCTFail("Expected coordinator event did not arrive", file: file, line: line)
    }
  }

  @MainActor
  private final class Harness {
    let worker = ControlledSelfieWorker()
    private let testClock = CoordinatorTestClock()
    var now: TimeInterval {
      get { testClock.now }
      set { testClock.now = newValue }
    }
    var anchor = UUID()
    var suppliesDepth = true
    var flatDepth = false
    var depthOffset = 0.016
    var captures: [(Data, SelfieAdmissionReceipt)] = []
    var windowCandidates: [(Data, SelfieAdmissionReceipt)] = []
    var windows: [[(Data, SelfieAdmissionReceipt)]] = []
    var readiness: [SelfieAdmissionGate.Readiness] = []
    var failures: [SelfieCameraFailure] = []
    let hold: TimeInterval
    private(set) var subject: SelfieCaptureCoordinator!

    init(hold: TimeInterval = 1, window: SelfieCaptureWindowPolicy? = nil) {
      self.hold = hold
      let worker = worker
      let value = SelfieCaptureCoordinator(
        policy: SelfieAdmissionPolicy(steadyHold: hold, requiresGuideContainment: true),
        captureWindow: window, analyze: { await worker.analyze($0) }, render: { await worker.render($0) },
        clock: { [testClock] in testClock.now })
      value.onFailure = { [weak self] in self?.failures.append($0) }
      value.onReadiness = { [weak self] in self?.readiness.append($0) }
      value.onCapture = { [weak self] in self?.captures.append(($0, $1)) }
      value.onWindowCandidate = { [weak self] in self?.windowCandidates.append(($0, $1)) }
      value.onWindowReset = { [weak self] in self?.windowCandidates.removeAll() }
      value.onWindowCompleted = { [weak self] in
        guard let self else { return }
        self.windows.append(self.windowCandidates)
      }
      subject = value
      subject.updateGuide(
        oval: CGRect(x: 0, y: 0, width: 100, height: 100),
        viewport: CGSize(width: 100, height: 100), orientation: .landscapeLeft)
      _ = subject.start(after: 1)
    }

    func blink(from start: TimeInterval = 1) throws {
      for index in 0..<10 { try send(at: start + Double(index) * 0.02, eyes: 0, marker: 0) }
      try send(at: start + 0.20, eyes: 0.9, marker: 20)
      try send(at: start + 0.22, eyes: 0, marker: 22)
    }

    func open(at time: TimeInterval, marker: UInt8) throws {
      try send(at: time, eyes: 0, marker: marker)
    }

    private func send(at time: TimeInterval, eyes: Float, marker: UInt8) throws {
      now = time
      var buffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
      guard status == kCVReturnSuccess, let buffer else { throw Failure.buffer }
      CVPixelBufferLockBaseAddress(buffer, [])
      memset(CVPixelBufferGetBaseAddress(buffer), Int32(marker), CVPixelBufferGetDataSize(buffer))
      CVPixelBufferUnlockBaseAddress(buffer, [])
      subject.observe(
        SelfieCaptureFrame(
          input: try SelfieFrameInput(buffer: buffer, orientation: .up,
            depth: suppliesDepth ? try SelfieDepthMap(data: try syntheticDepth { x, y in
              self.flatDepth ? 0.4 : 0.5 + (Int(x + y) % 2 == 0 ? 0.01 : -0.01)
            }, imageTimestamp: time, depthTimestamp: time - depthOffset) : nil),
          observation: .init(
            timestamp: time, anchorID: anchor, faceCount: 1, trackingObserved: true,
            leftEyeClosed: eyes, rightEyeClosed: eyes),
          displayTransform: .identity, anchorPoint: CGPoint(x: 50, y: 50)), now: time)
    }

    static func image(marker: UInt8 = 255) -> CGImage? {
      let value = CGFloat(marker) / 255
      let raster = CIImage(color: CIColor(red: value, green: value, blue: value)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
      return CIContext().createCGImage(raster, from: raster.extent)
    }

    enum Failure: Error { case buffer }
  }

  @MainActor
  private final class CoordinatorTestClock { var now = 1.0 }

  private actor ControlledSelfieWorker {
    private(set) var analysisMarkers: [UInt8] = []
    private(set) var renderMarkers: [UInt8] = []
    private var analyses: [CheckedContinuation<SelfieFrameAnalysis, Never>] = []
    private var inputs: [SelfieFrameInput] = []
    private var renders: [CheckedContinuation<CGImage?, Never>] = []
    var analysisCount: Int { analysisMarkers.count }
    var renderCount: Int { renderMarkers.count }

    func analyze(_ input: SelfieFrameInput) async -> SelfieFrameAnalysis {
      analysisMarkers.append(marker(input))
      inputs.append(input)
      return await withCheckedContinuation { analyses.append($0) }
    }

    func render(_ input: SelfieFrameInput) async -> CGImage? {
      renderMarkers.append(marker(input))
      return await withCheckedContinuation { renders.append($0) }
    }

    func finishAnalysis(
      quality: Float? = 0.8, faceCount: Int = 1,
      failure: SelfieCameraFailure? = nil
    ) {
      guard !analyses.isEmpty else { return }
      let input = inputs.removeFirst()
      let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
      analyses.removeFirst().resume(
        returning: SelfieFrameAnalysis(
          faceCount: faceCount, quality: quality,
          faceBox: box,
          revision: 3, elapsed: 0.01, failure: failure,
          depthEvidence: input.depth?.measure(faceBox: box, orientation: input.orientation, policy: .engineeringV1)))
    }

    func finishRender(image: CGImage?) {
      guard !renders.isEmpty else { return }
      renders.removeFirst().resume(returning: image)
    }

    func finishOutstanding() {
      while !analyses.isEmpty { finishAnalysis() }
      while !renders.isEmpty { finishRender(image: nil) }
    }

    private func marker(_ input: SelfieFrameInput) -> UInt8 {
      CVPixelBufferLockBaseAddress(input.buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(input.buffer, .readOnly) }
      return CVPixelBufferGetBaseAddress(input.buffer)!.load(as: UInt8.self)
    }
  }
#endif
