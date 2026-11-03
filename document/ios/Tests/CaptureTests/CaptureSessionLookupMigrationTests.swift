#if os(iOS)
  import Foundation
  import XCTest
  import DocumentCaptureJournal
  @testable import DocumentCapture
  @testable import DocumentCaptureApple
  @testable import CaptureEvidenceCustody

  @MainActor
  final class CaptureSessionLookupMigrationTests: XCTestCase {
    func testLiveOriginalProcessingAndPortraitVerificationAvoidUnrelatedArchive() async throws {
      let fixture = try MigrationFixture()
      let inputs = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer {
        fixture.cleanup()
        inputs.cleanup()
      }
      let engine = fixture.session
      let store = try engine.openCustody()
      engine.phase = .capturing
      try await engine.beginContinuousRecording(camera: engine.camera)
      let journal = try XCTUnwrap(engine.journeyRecording)
      var front = try inputs.manifest(profile: .licenseFront, workflowID: engine.workflowID)
      front.journeyRecording = journal.reference
      front.journeyBindingVersion = 1
      try await store.admitLiveCapture(captureID: front.captureID, scopeID: journal.recordingID)
      try await CaptureSignedRecords.retainOriginal(
        id: front.captureID, original: inputs.pixels, manifest: JSONEncoder().encode(front), store: store)
      try await CaptureStillBindingCustody.retain(
        captureID: front.captureID,
        sourceHash: front.fidelity.sha256, recordingID: journal.recordingID, outcome: .bound,
        store: store)
      try Data([0, 1, 2]).write(
        to: fixture.directory.appendingPathComponent(UUID().uuidString + ".evidence"))
      let operations = JourneyRecoveryIntegrationTests.operations(
        calls: RecoveryExtractionCounter())
      _ = try await CaptureDocumentRecovery.process(
        captureID: front.captureID, store: store, operations: operations)
      let binding = try await CaptureDocumentStages.records(
        "journeyStillBinding", captureID: front.captureID,
        sourceHash: front.fidelity.sha256, store: store)
      XCTAssertEqual(binding.count, 1)
      let portraits = try await CaptureDocumentStages.records(
        "portraitExtraction", captureID: front.captureID,
        sourceHash: front.fidelity.sha256, store: store)
      let portrait = try XCTUnwrap(portraits.first)
      let verified = try await CapturePortraitVerification.load(
        id: portrait.id, captureID: front.captureID,
        sourceHash: front.fidelity.sha256, store: store)
      XCTAssertFalse(verified.isEmpty)
      XCTAssertEqual(Set(verified.map(\.captureID)), [front.captureID])
      let scans = await store.metadataDirectoryScanCount
      XCTAssertEqual(scans, 0)
      engine.stop()
      await engine.waitForRecordingSettlement()
      let ended = try await store.liveLookupSnapshot(captureIDs: [front.captureID])
      XCTAssertNil(ended)
      do {
        _ = try await store.lookupSnapshot(captureIDs: [front.captureID])
        XCTFail("Ordinary discovery must reject unknown corrupt external evidence")
      } catch {}
      try await engine.erase()
    }

    func testCancelledRecordingStartReleasesLookupScope() async throws {
      let fixture = try MigrationFixture()
      defer { fixture.cleanup() }
      let engine = fixture.session
      let store = try engine.openCustody()
      do {
        try await engine.beginContinuousRecording(camera: engine.camera)
        XCTFail("Inactive session attached a recording")
      } catch is CancellationError {}
      let cancelled = try await store.liveLookupSnapshot(captureIDs: [])
      XCTAssertNil(cancelled)
      engine.phase = .capturing
      try await engine.beginContinuousRecording(camera: engine.camera)
      XCTAssertNotNil(engine.journeyRecording)
      engine.stop()
      await engine.waitForRecordingSettlement()
      let stopped = try await store.liveLookupSnapshot(captureIDs: [])
      XCTAssertNil(stopped)
      try await engine.erase()
    }

    func testResumedBackSeedsFrontOnceAndRefusesUnknownDependencyWithoutRescanning() async throws {
      let fixture = try MigrationFixture()
      let inputs = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer {
        fixture.cleanup()
        inputs.cleanup()
      }
      let engine = fixture.session
      let store = try engine.openCustody()
      let front = try inputs.manifest(profile: .licenseFront, workflowID: engine.workflowID)
      try await CaptureSignedRecords.retainOriginal(
        id: front.captureID, original: inputs.pixels, manifest: JSONEncoder().encode(front), store: store)
      let operations = JourneyRecoveryIntegrationTests.operations(
        calls: RecoveryExtractionCounter())
      _ = try await CaptureDocumentRecovery.process(
        captureID: front.captureID, store: store, operations: operations)
      engine.profile = .licenseBack
      engine.retainedFrontCaptureID = front.captureID
      engine.phase = .capturing
      let before = await store.metadataDirectoryScanCount
      try await engine.beginContinuousRecording(camera: engine.camera)
      let seeded = await store.metadataDirectoryScanCount
      XCTAssertEqual(seeded, before + 1)
      let journal = try XCTUnwrap(engine.journeyRecording)
      let back = try inputs.manifest(
        profile: .licenseBack, workflowID: engine.workflowID,
        precedingFrontCaptureID: front.captureID)
      try await store.admitLiveCapture(captureID: back.captureID, scopeID: journal.recordingID)
      try await CaptureSignedRecords.retainOriginal(
        id: back.captureID, original: inputs.pixels, manifest: JSONEncoder().encode(back), store: store)
      try Data([0]).write(
        to: fixture.directory.appendingPathComponent(UUID().uuidString + ".evidence"))
      _ = try await CaptureDocumentRecovery.process(
        captureID: back.captureID, store: store, operations: operations)
      let frontRecords = try await CaptureDocumentStages.records(
        "workflowAssessment", captureID: front.captureID,
        sourceHash: front.fidelity.sha256, store: store)
      XCTAssertFalse(frontRecords.isEmpty)
      do {
        _ = try await CaptureDocumentStages.records(
          "usability", captureID: UUID(), sourceHash: "unadmitted", store: store)
        XCTFail("Unknown active dependency must fail without global discovery")
      } catch CaptureEvidenceStoreError.outsideLiveLookupScope {}
      let after = await store.metadataDirectoryScanCount
      XCTAssertEqual(after, seeded)
      engine.stop()
      await engine.waitForRecordingSettlement()
      try await engine.erase()
    }

    func testFreshJourneyClearsPriorSelectionAndDoesNotReconcileOldArchive() async throws {
      let fixture = try MigrationFixture()
      defer { fixture.cleanup() }
      let engine = fixture.session
      let store = try engine.openCustody()
      let previous = UUID()
      engine.selectedCaptureID = previous
      engine.recoveryCaptureID = previous
      engine.retainedFrontCaptureID = previous
      engine.beginJourney(.licenseFront, workflowID: UUID())
      let starting = engine.operation
      engine.stop()
      await starting?.value
      await engine.waitForRecordingSettlement()
      XCTAssertNil(engine.selectedCaptureID)
      XCTAssertNil(engine.recoveryCaptureID)
      XCTAssertNil(engine.retainedFrontCaptureID)
      XCTAssertTrue(engine.processingQueue.captureIDs.isEmpty)
      try Data([0]).write(
        to: fixture.directory.appendingPathComponent(UUID().uuidString + ".evidence"))
      engine.phase = .capturing
      let before = await store.metadataDirectoryScanCount
      try await engine.beginContinuousRecording(camera: engine.camera)
      let after = await store.metadataDirectoryScanCount
      XCTAssertEqual(after, before)
      engine.stop()
      await engine.waitForRecordingSettlement()
      try await engine.erase()
    }

    func testFailedFrontRetryPreservesSelectedBackAndReusesDurableInputs() async throws {
      let inputs = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      let calls = RecoveryExtractionCounter()
      var operations = JourneyRecoveryIntegrationTests.operations(calls: calls)
      let prepare = operations.prepare
      var fail = true
      operations.prepare = { source in
        if fail { throw LookupFailure.expected }
        return try await prepare(source)
      }
      var completed: [UUID] = []
      var failed: [UUID] = []
      let fixture = try MigrationFixture(operations: operations) { event in
        switch event {
        case .processingCompleted(let identity, _): completed.append(identity.captureID)
        case .processingFailed(let identity): failed.append(identity.captureID)
        default: break
        }
      }
      defer {
        fixture.cleanup()
        inputs.cleanup()
      }
      let engine = fixture.session
      let store = try engine.openCustody()
      let front = try inputs.manifest(profile: .licenseFront, workflowID: engine.workflowID)
      let back = try inputs.manifest(
        profile: .licenseBack, workflowID: engine.workflowID,
        precedingFrontCaptureID: front.captureID)
      for record in [front, back] {
        try await CaptureSignedRecords.retainOriginal(
          id: record.captureID, original: inputs.pixels, manifest: JSONEncoder().encode(record), store: store)
      }
      try await engine.retryProcessing(captureID: front.captureID)
      await engine.processingQueue.waitUntilIdle()
      XCTAssertEqual(failed, [front.captureID])
      engine.selectedCaptureID = back.captureID
      engine.profile = .licenseBack
      fail = false
      try await engine.retryProcessing(captureID: front.captureID)
      XCTAssertEqual(engine.selectedCaptureID, back.captureID)
      await engine.processingQueue.waitUntilIdle()
      XCTAssertEqual(completed, [front.captureID])
      XCTAssertEqual(engine.selectedCaptureID, back.captureID)
      XCTAssertEqual(engine.profile, .licenseBack)
      let retained = try await store.read(id: back.captureID)
      XCTAssertEqual(retained.original, inputs.pixels)
      let assessments = try await CaptureDocumentStages.records(
        "workflowAssessment", captureID: front.captureID,
        sourceHash: front.fidelity.sha256, store: store)
      XCTAssertEqual(assessments.count, 1)
      try await engine.erase()
    }
  }
  private enum LookupFailure: Error { case expected }
#endif
