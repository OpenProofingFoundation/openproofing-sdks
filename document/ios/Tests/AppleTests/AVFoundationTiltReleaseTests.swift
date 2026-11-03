import Foundation
import Testing
import XCTest

@testable import DocumentCaptureApple

@Suite struct AVFoundationTiltReleaseTests {
  @Test func controlsReleaseDoesNotWaitForAnalysisButReplacementWaitsForArchive() async throws {
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
          tiltTransportPacket(sequence: 1), hostSeconds: 1)
      }
    }
    defer { gate.signal() }
    let released = TiltRampFlag()
    fixture.owner.endTiltGuidance(runID: runID, reason: .userCaptureNow) { released.set(true) }
    await fixture.ownerOperation {
      #expect(released.value)
      #expect(!fixture.owner.state.tiltGuidance.holding)
      #expect(fixture.owner.state.tiltGuidance.archiveDrainPending)
      #expect(fixture.owner.state.captureAdmissionRequested)
      #expect(fixture.owner.state.latestQualityObservation == nil)
    }
    #expect(fixture.sink.events.compactMap(\.tiltGuidance).count == 1)
    let replacement = UUID()
    let began = XCTestExpectation(description: "Replacement completed native activation")
    fixture.owner.beginTiltGuidance(
      runID: replacement, configuration: .provisionalV1, cancellation: .init(),
      completion: { result in
        fixture.results.append(result)
        began.fulfill()
      })
    await fixture.ownerOperation {}
    #expect(
      fixture.results.values.isEmpty, "Replacement waits without failing or overwriting archival")
    gate.signal()
    #expect(await XCTWaiter.fulfillment(of: [began], timeout: 2) == .completed)
    let updates = fixture.sink.events.compactMap(\.tiltGuidance).filter {
      $0.presentation.runID == runID
    }
    #expect(updates.count == 2)
    #expect(updates.last?.presentation.reason == .userCaptureNow)
    #expect(updates.allSatisfy { $0.event?.observation == nil })
    #expect(fixture.results.values.count == 1)
    let started = try #require(fixture.results.values.first).get()
    #expect(started.runID == replacement)
    await fixture.end(replacement, reason: .userSkipped)
    await fixture.drain()
  }

  @Test func duplicatePendingCleanupKeepsSkipReasonAndOneArchive() async {
    let fixture = TiltNativeFixture()
    await fixture.prepare()
    let gate = DispatchSemaphore(value: 0)
    await withCheckedContinuation { continuation in
      fixture.analyzer.analysisQueue.async {
        continuation.resume()
        gate.wait()
      }
    }
    defer { gate.signal() }
    let runID = UUID()
    fixture.owner.beginTiltGuidance(
      runID: runID, configuration: .provisionalV1, cancellation: .init(),
      completion: fixture.results.append)
    await fixture.ownerOperation {}
    let released = TiltRampFlag()
    fixture.owner.endTiltGuidance(runID: runID, reason: .userSkipped) { released.set(true) }
    fixture.owner.endTiltGuidance(runID: runID, reason: .cancelled) {}
    await fixture.ownerOperation { #expect(released.value) }
    #expect(fixture.results.values.count == 1)
    #expect(fixture.sink.events.compactMap(\.tiltGuidance).isEmpty)
    gate.signal()
    await fixture.drain()
    let updates = fixture.sink.events.compactMap(\.tiltGuidance)
    #expect(updates.map(\.presentation.revision) == [1, 2])
    #expect(updates.last?.presentation.reason == .userSkipped)
    #expect(updates.last?.presentation.phase == .skipped)
  }
}
