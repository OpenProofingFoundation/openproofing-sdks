import Foundation
import Testing
import XCTest

@testable import DocumentCaptureApple

@Suite struct AVFoundationTiltRetryAdmissionTests {
  @Test func oneWaitingBeginSurvivesStaleEndAndRejectsDuplicateBegin() async throws {
    let (fixture, old, gate) = try await releasedWithHeldArchive()
    defer { gate.signal() }
    let waiting = UUID()
    let first = TiltStartResults()
    let began = XCTestExpectation(description: "Waiting replacement completed native activation")
    let duplicate = TiltStartResults()
    fixture.owner.beginTiltGuidance(
      runID: waiting, configuration: .provisionalV2, cancellation: .init(),
      completion: { result in
        first.append(result)
        began.fulfill()
      })
    fixture.owner.beginTiltGuidance(
      runID: waiting, configuration: .provisionalV2, cancellation: .init(),
      completion: duplicate.append)
    await fixture.end(old, reason: .cancelled)
    await fixture.end(UUID(), reason: .cancelled)
    #expect(first.values.isEmpty)
    assertRejected(duplicate)
    await fixture.ownerOperation {
      #expect(!fixture.owner.state.tiltGuidance.holding)
      #expect(fixture.owner.state.tiltGuidance.archiveDrainPending)
      #expect(fixture.owner.state.captureAdmissionRequested)
    }
    gate.signal()
    #expect(await XCTWaiter.fulfillment(of: [began], timeout: 2) == .completed)
    let result = try #require(first.values.first).get()
    #expect(result.runID == waiting)
    #expect(first.values.count == 1)
    await fixture.end(waiting, reason: .sessionStopped)
    await fixture.drain()
  }

  @Test(arguments: ["token", "end", "stop", "clock", "configuration", "admission", "timeout"])
  func waitingBeginCannotActivateAfterInvalidation(_ boundary: String) async throws {
    let (fixture, _, gate) = try await releasedWithHeldArchive()
    defer { gate.signal() }
    let waiting = UUID()
    let cancellation = DocumentTiltStartCancellation()
    fixture.owner.beginTiltGuidance(
      runID: waiting, configuration: .provisionalV2, cancellation: cancellation,
      completion: fixture.results.append)
    await fixture.ownerOperation {}
    #expect(fixture.results.values.isEmpty, "The waiting begin must not fail before the boundary")
    switch boundary {
    case "token": cancellation.cancel()
    case "end": await fixture.end(waiting, reason: .cancelled)
    case "stop":
      fixture.owner.stop()
      await fixture.ownerOperation {}
    case "clock":
      await fixture.ownerOperation { fixture.owner.temporalClockDidChange(to: nil) }
    case "configuration":
      await fixture.ownerOperation {
        fixture.owner.cancelTiltGuidance(reason: .nativeControlsChanged)
      }
    case "admission":
      await fixture.ownerOperation { fixture.owner.state.nativeOperationUncertain = true }
    case "timeout":
      await fixture.ownerOperation {
        fixture.owner.pollTiltGuidance(
          now: DocumentTemporalRecorder.hostNow()
            + DocumentCaptureTuning.Controls.adjustmentTimeoutSeconds + 1)
      }
    default: Issue.record("Unknown boundary")
    }
    if ["end", "stop", "clock", "configuration", "timeout"].contains(boundary) {
      assertRejected(fixture.results)
    }
    gate.signal()
    await fixture.drain()
    assertRejected(fixture.results)
    await fixture.ownerOperation { #expect(!fixture.owner.state.tiltGuidance.holding) }
    #expect(
      !fixture.sink.events.compactMap(\.tiltGuidance).contains {
        $0.presentation.runID == waiting
      }, "A waiting request that never acquired controls must not create a measurement attempt")
  }

  @Test func sameIDEndCancelsWaitingBeginEvenWhenItMatchesArchivedRun() async throws {
    let (fixture, old, gate) = try await releasedWithHeldArchive()
    defer { gate.signal() }
    fixture.owner.beginTiltGuidance(
      runID: old, configuration: .provisionalV2, cancellation: .init(),
      completion: fixture.results.append)
    await fixture.ownerOperation {}
    #expect(fixture.results.values.isEmpty)
    await fixture.end(old, reason: .cancelled)
    assertRejected(fixture.results)
    gate.signal()
    await fixture.drain()
    assertRejected(fixture.results)
    await fixture.ownerOperation { #expect(!fixture.owner.state.tiltGuidance.holding) }
  }

  #if os(iOS)
    @Test func geometryChangeRevokesWaitingBeginBeforeDrain() async throws {
      let (fixture, _, gate) = try await releasedWithHeldArchive()
      defer { gate.signal() }
      let waiting = UUID()
      fixture.owner.beginTiltGuidance(
        runID: waiting, configuration: .provisionalV2, cancellation: .init(),
        completion: fixture.results.append)
      await fixture.ownerOperation {
        #expect(fixture.results.values.isEmpty)
        fixture.owner.refreshAnalysisGeometry()
      }
      assertRejected(fixture.results)
      gate.signal()
      await fixture.drain()
      assertRejected(fixture.results)
      await fixture.ownerOperation { #expect(!fixture.owner.state.tiltGuidance.holding) }
      #expect(
        !fixture.sink.events.compactMap(\.tiltGuidance).contains {
          $0.presentation.runID == waiting
        })
    }
  #endif

  private func releasedWithHeldArchive() async throws -> (
    TiltNativeFixture, UUID, DispatchSemaphore
  ) {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    let old = UUID()
    _ = try await fixture.begin(old)
    let gate = DispatchSemaphore(value: 0)
    await withCheckedContinuation { continuation in
      fixture.analyzer.analysisQueue.async {
        continuation.resume()
        #expect(gate.wait(timeout: .now() + 10) == .success)
      }
    }
    await fixture.end(old, reason: .cancelled)
    await fixture.ownerOperation {
      #expect(!fixture.owner.state.tiltGuidance.holding)
      #expect(fixture.owner.state.tiltGuidance.archiveDrainPending)
      #expect(fixture.owner.state.captureAdmissionRequested)
    }
    return (fixture, old, gate)
  }

  private func assertRejected(_ results: TiltStartResults) {
    #expect(results.values.count == 1)
    guard let result = results.values.first else { return }
    switch result {
    case .success: Issue.record("Invalidated waiting begin acquired native controls")
    case .failure(let error): #expect(error == .cameraNotReady)
    }
  }
}
