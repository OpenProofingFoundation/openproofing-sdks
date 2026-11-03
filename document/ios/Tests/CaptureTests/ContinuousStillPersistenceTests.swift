#if os(iOS)
  import Foundation
  import CaptureEvidenceCustody
  import XCTest

  @testable import DocumentCapture
  import DocumentCaptureJournal
  @testable import DocumentCaptureApple

  @MainActor
  final class ContinuousStillPersistenceTests: XCTestCase {
    func testDisabledWindowDeliveryStoresOriginalAndContinuousStillLinks() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let workflowID = try XCTUnwrap(manifest.workflowID)
      let journal = try await CaptureRecordingJournal.start(
        workflowID: workflowID, store: fixture.store,
        clock: .init(now: { Date() }, uptime: { ProcessInfo.processInfo.systemUptime }))
      let recorder = DocumentTemporalRecorder(configuration: .init(enabled: false))
      recorder.setJourneySink(journal)
      let original = photo(manifest, bytes: fixture.pixels)
      let milestone = try XCTUnwrap(journal.reserveMilestone())
      defer { journal.cancelMilestone(milestone) }
      recorder.beginCapture()
      let delivered = photo(
        manifest, bytes: fixture.pixels,
        evidence: recorder.finishForDelivery(original))
      XCTAssertNil(delivered.temporalEvidence)
      try await CaptureOriginalCustody.retain(
        delivered, captureID: manifest.captureID,
        profile: .licenseFront, workflowID: workflowID, precedingFrontCaptureID: nil,
        journeyRevision: nil, tuning: .init(), store: fixture.store,
        hostTime: { ProcessInfo.processInfo.systemUptime }, recording: journal,
        recordingMilestone: milestone)
      _ = try await journal.finish(reason: "test_stop")
      let reopened = try fixture.reopen()
      let record = try await reopened.read(id: manifest.captureID)
      let saved = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: record.manifest)
      XCTAssertEqual(record.original, fixture.pixels)
      XCTAssertEqual(saved.origin, delivered.origin)
      XCTAssertEqual(saved.admission?.userRequestedAt, delivered.requestedAt)
      XCTAssertNil(saved.temporalEvidence)
      XCTAssertEqual(saved.journeyRecording, journal.reference)
      XCTAssertEqual(saved.motionStatus, "journey_recording_linked")
      let verified = try await CaptureRecordingVerification.verify(
        journal.reference, store: reopened)
      XCTAssertEqual(verified.stillIDs, [manifest.captureID])
    }

    func testLegacyManifestDoesNotInventLiveOrigin() throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let bytes = try JSONEncoder().encode(manifest)
      let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      XCTAssertNil(fields["origin"])
      let decoded = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: bytes)
      XCTAssertNil(decoded.origin)
    }

    func testOldDisabledEnvelopeReproducesRejectionWithoutPublishingOriginal() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let recorder = DocumentTemporalRecorder(configuration: .init(enabled: false))
      let original = photo(manifest, bytes: fixture.pixels)
      let oldDelivery = photo(manifest, bytes: fixture.pixels, evidence: recorder.finish(original))
      XCTAssertFalse(try XCTUnwrap(oldDelivery.temporalEvidence).manifest.configuration.enabled)
      do {
        try await CaptureOriginalCustody.retain(
          oldDelivery, captureID: manifest.captureID,
          profile: .licenseFront, workflowID: try XCTUnwrap(manifest.workflowID),
          precedingFrontCaptureID: nil, journeyRevision: nil, tuning: .init(), store: fixture.store,
          hostTime: { ProcessInfo.processInfo.systemUptime })
        XCTFail("Disabled legacy evidence unexpectedly accepted")
      } catch CaptureIntegrityError.integrityVerificationFailed {}
      let ids = try await fixture.store.list()
      XCTAssertTrue(ids.isEmpty)
    }

    func testWrongAttemptOrSideRejectedBeforeAnyCustodyWrite() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let original = photo(manifest, bytes: fixture.pixels)
      for (id, profile) in [
        (UUID(), CaptureRecords.Profile.licenseFront),
        (manifest.captureID, CaptureRecords.Profile.licenseBack),
      ] {
        do {
          try await CaptureOriginalCustody.retain(
            original, captureID: id, profile: profile,
            workflowID: try XCTUnwrap(manifest.workflowID), precedingFrontCaptureID: nil,
            journeyRevision: nil, tuning: .init(), store: fixture.store, hostTime: { 1 })
          XCTFail("Mismatched photo identity accepted")
        } catch CaptureIntegrityError.integrityVerificationFailed {}
      }
      let ids = try await fixture.store.list()
      XCTAssertTrue(ids.isEmpty)
    }

    private func photo(
      _ manifest: CaptureRecords.Manifest, bytes: Data, evidence: DocumentTemporalEvidence? = nil
    ) -> CapturedDocumentPhoto {
      let request = CameraPhotoCaptureRequest(
        sessionID: manifest.sessionID, side: .front,
        qualityGate: .qualityDrivenAutoCapture, attemptID: manifest.captureID,
        userRequestedAt: manifest.processedAt)
      return CapturedDocumentPhoto(
        sessionID: manifest.sessionID, side: .front,
        requestedAt: manifest.processedAt, captureTimestamp: manifest.captureTimestamp,
        processedAt: manifest.processedAt, data: bytes, fidelity: manifest.fidelity,
        admission: .init(
          request: request, admittedAt: manifest.processedAt,
          photoSettingsUniqueID: 1, observation: nil), temporalEvidence: evidence)
    }
  }
#endif
