#if os(iOS)
  import DocumentCaptureJournal
  import CryptoKit
  import Foundation
  import DocumentSDK
  import UIKit
  import XCTest
  @testable import DocumentCaptureApple
  @_spi(CaptureTestFixture) @testable import CaptureEvidenceCustody
  @testable import DocumentCapture

  @MainActor
  final class CaptureJourneyRecoveryTests: XCTestCase {
    func testRelaunchCanRecoverFrontAndEveryBackWithoutChangingSelection() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let front = try await fixture.original(profile: .licenseFront)
      let firstBack = try await fixture.original(profile: .licenseBack, revision: 1, front: front)
      let secondBack = try await fixture.original(profile: .licenseBack, revision: 2, front: front)
      try await fixture.checkpoint(
        stage: .review, profile: .licenseFront, front: front, back: secondBack, revision: 2)
      let reopened = try CaptureSignedFixture.store(directory: fixture.directory, key: fixture.key)
      let before = try await reopened.journeyCheckpoint(workflowID: fixture.workflow)
      let recoveredFront = try await CaptureJourneyRecovery.retainedFront(
        captureID: front, workflowID: fixture.workflow, store: reopened)
      XCTAssertEqual(recoveredFront.captureID, front)
      XCTAssertEqual(recoveredFront.record.original, fixture.bytes)
      for backID in [firstBack, secondBack] {
        let back = try await CaptureJourneyRecovery.retainedBack(
          captureID: backID, frontCaptureID: front, workflowID: fixture.workflow, store: reopened)
        XCTAssertEqual(back.record.original, fixture.bytes)
        XCTAssertEqual(back.manifest.precedingFrontCaptureID, front)
        XCTAssertNil(back.checkpointRevision, "Archived back lookup cannot admit it to a newer attempt")
      }
      let after = try await reopened.journeyCheckpoint(workflowID: fixture.workflow)
      XCTAssertEqual(after, before)
    }

    func testArchivedBackCannotBeRelinkedToAnotherRetainedFront() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let front = try await fixture.original(profile: .licenseFront)
      let wrongFront = try await fixture.original(profile: .licenseFront)
      let back = try await fixture.original(profile: .licenseBack, front: wrongFront)
      try await fixture.checkpoint(stage: .back, profile: .licenseFront, front: front)
      do {
        _ = try await CaptureJourneyRecovery.retainedBack(
          captureID: back, frontCaptureID: front, workflowID: fixture.workflow, store: fixture.store)
        XCTFail("Back was relinked to another front")
      } catch CaptureJourneyCheckpointError.invalidCheckpoint {}
      do {
        _ = try await CaptureJourneyRecovery.retainedFront(
          captureID: wrongFront, workflowID: fixture.workflow, store: fixture.store)
        XCTFail("Front bypassed the durable selection")
      } catch CaptureJourneyCheckpointError.invalidCheckpoint {}
    }

    func testCurrentBackDiscoveryRecoversOriginalWithoutHostReceiptMetadata() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let front = try await fixture.original(profile: .licenseFront)
      let back = try await fixture.original(profile: .licenseBack, revision: 2, front: front)
      try await fixture.checkpoint(stage: .back, profile: .licenseFront, front: front, revision: 2)
      let reopened = try CaptureSignedFixture.store(directory: fixture.directory, key: fixture.key)
      let found = try await CaptureJourneyRecovery.currentBack(
        frontCaptureID: front, workflowID: fixture.workflow, store: reopened)
      XCTAssertEqual(found?.captureID, back)
      XCTAssertEqual(found?.record.original, fixture.bytes)
      XCTAssertEqual(found?.checkpointRevision, 2)
      let checkpoint = try await reopened.journeyCheckpoint(workflowID: fixture.workflow)
      XCTAssertNil(checkpoint?.backID, "Read-only recovery must not invent the host's next action")
    }

    func testCurrentBackDiscoveryRejectsOldRevisionAndAmbiguousCurrentAttempts() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let front = try await fixture.original(profile: .licenseFront)
      _ = try await fixture.original(profile: .licenseBack, revision: 1, front: front)
      try await fixture.checkpoint(stage: .back, profile: .licenseFront, front: front, revision: 2)
      let old = try await CaptureJourneyRecovery.currentBack(
        frontCaptureID: front, workflowID: fixture.workflow, store: fixture.store)
      XCTAssertNil(old)
      let current = try await fixture.original(profile: .licenseBack, revision: 2, front: front)
      let found = try await CaptureJourneyRecovery.currentBack(
        frontCaptureID: front, workflowID: fixture.workflow, store: fixture.store)
      XCTAssertEqual(found?.captureID, current)
      _ = try await fixture.original(profile: .licenseBack, revision: 2, front: front)
      do {
        _ = try await CaptureJourneyRecovery.currentBack(
          frontCaptureID: front, workflowID: fixture.workflow, store: fixture.store)
        XCTFail("Ambiguous captures selected by discovery")
      } catch CaptureJourneyCheckpointError.invalidCheckpoint {}
    }

    func testCurrentBackHonorsExplicitReviewSelectionAfterRevisionAdvanced() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let front = try await fixture.original(profile: .licenseFront)
      let back = try await fixture.original(profile: .licenseBack, revision: 1, front: front)
      try await fixture.checkpoint(
        stage: .review, profile: .licenseFront, front: front, back: back, revision: 2)
      let selected = try await CaptureJourneyRecovery.currentBack(
        frontCaptureID: front, workflowID: fixture.workflow, store: fixture.store)
      XCTAssertEqual(selected?.captureID, back)
      XCTAssertEqual(selected?.manifest.journeyRevision, 1)
      XCTAssertEqual(selected?.checkpointRevision, 2)
    }

    func testDurableSelectionOverridesUnrelatedLatestCandidate() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let chosen = try await fixture.original(profile: .document)
      try await fixture.checkpoint(stage: .review, profile: .document, front: chosen)
      // An irrelevant candidate need not even exist.
      let result = try await fixture.resolve(UUID())
      XCTAssertEqual(result.selected?.captureID, chosen)
      XCTAssertEqual(result.checkpoint?.frontID, chosen)
      XCTAssertNil(result.pendingCaptureStage)
    }

    func testFrontRetakeRejectsOldAndFutureAttemptRevisions() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      try await fixture.checkpoint(stage: .front, profile: .document, revision: 3)
      for revision in [UInt64(2), 4] {
        let candidate = try await fixture.original(profile: .document, revision: revision)
        let result = try await fixture.resolve(candidate)
        XCTAssertNil(result.selected)
        XCTAssertEqual(result.pendingCaptureStage, .front)
      }
      let committedBeforeCheckpoint = try await fixture.original(profile: .document, revision: 3)
      let result = try await fixture.resolve(committedBeforeCheckpoint)
      XCTAssertEqual(result.selected?.captureID, committedBeforeCheckpoint)
      XCTAssertNil(result.pendingCaptureStage)
      XCTAssertEqual(
        result.checkpoint?.nextStage, .front, "Resolution does not invent a persisted transition")
    }

    func testBackRetakePreservesFrontWhileRejectingOldBack() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let front = try await fixture.original(profile: .licenseFront)
      let oldBack = try await fixture.original(profile: .licenseBack, revision: 1, front: front)
      try await fixture.checkpoint(stage: .back, profile: .licenseFront, front: front, revision: 2)
      let pending = try await fixture.resolve(oldBack)
      XCTAssertEqual(pending.pendingCaptureStage, .back)
      XCTAssertEqual(pending.selected?.captureID, front)
      let session = try fixture.session()
      try session.restoreVerifiedOriginal(XCTUnwrap(pending.selected))
      XCTAssertEqual(session.journeyRevision, 2, "Back retry keeps the current checkpoint revision")
      session.stop()
      let currentBack = try await fixture.original(profile: .licenseBack, revision: 2, front: front)
      let resolved = try await fixture.resolve(currentBack)
      XCTAssertNil(resolved.pendingCaptureStage)
      XCTAssertEqual(resolved.selected?.captureID, currentBack)
      XCTAssertEqual(resolved.selected?.manifest.precedingFrontCaptureID, front)
    }

    func testCurrentBackCannotReplaceCheckpointFrontAssociation() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let front = try await fixture.original(profile: .licenseFront)
      let anotherFront = try await fixture.original(profile: .licenseFront)
      let back = try await fixture.original(profile: .licenseBack, revision: 2, front: anotherFront)
      try await fixture.checkpoint(stage: .back, profile: .licenseFront, front: front, revision: 2)
      await assertInvalid { try await fixture.resolve(back) }
    }

    func testCrossWorkflowAndProfileSelectionsAreRejected() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let otherWorkflow = try await fixture.original(profile: .document, workflow: UUID())
      await assertInvalid { try await fixture.resolve(otherWorkflow) }
      let wrongProfile = try await fixture.original(profile: .document)
      try await fixture.checkpoint(stage: .review, profile: .licenseFront, front: wrongProfile)
      await assertInvalid { try await fixture.resolve(UUID()) }
    }

    func testBackRequiresAuthenticatedFrontInSameWorkflow() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let wrongFront = try await fixture.original(profile: .licenseFront, workflow: UUID())
      let back = try await fixture.original(profile: .licenseBack, front: wrongFront)
      try await fixture.checkpoint(
        stage: .review, profile: .licenseFront, front: wrongFront, back: back)
      await assertInvalid { try await fixture.resolve(back) }
    }

    func testOriginalBytesMustMatchManifestBeforeRecovery() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let damaged = try await fixture.original(profile: .document, storedBytes: Data([1, 2, 3]))
      await assertInvalid { try await fixture.resolve(damaged) }
    }

    func testVerifiedOriginalRestoresSynchronouslyWithoutSecondCustodyRead() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let chosen = try await fixture.original(profile: .licenseFront, revision: 5)
      let resolved = try await fixture.resolve(chosen)
      let original = try XCTUnwrap(resolved.selected)
      let count = await fixture.store.authenticatedReadCount
      let session = try fixture.session()
      try session.restoreVerifiedOriginal(original)
      let after = await fixture.store.authenticatedReadCount
      XCTAssertEqual(after, count)
      XCTAssertNil(session.operation)
      XCTAssertNil(session.custody, "Verified review need not open another runtime namespace")
      XCTAssertEqual(session.workflowID, fixture.workflow)
      XCTAssertEqual(session.profile, .licenseFront)
      XCTAssertEqual(session.selectedCaptureID, chosen)
      XCTAssertEqual(session.retainedFrontCaptureID, chosen)
      XCTAssertEqual(session.journeyRevision, 5)
      XCTAssertEqual(session.phase, .reviewing)
      session.stop()
    }

    func testVerifiedRestoreCannotInterruptAdmittedPhotoOrErase() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let id = try await fixture.original(profile: .document)
      let result = try await fixture.resolve(id)
      let original = try XCTUnwrap(result.selected)
      let session = try fixture.session()
      session.activeCaptureAttempt = UUID()
      XCTAssertThrowsError(try session.restoreVerifiedOriginal(original))
      XCTAssertNil(session.selectedCaptureID)
      session.activeCaptureAttempt = nil
      session.erasing = true
      XCTAssertThrowsError(try session.restoreVerifiedOriginal(original))
      XCTAssertNil(session.selectedCaptureID)
      session.erasing = false
      session.stop()
    }

    private func assertInvalid(_ resolve: () async throws -> CaptureJourneyRecovery.Resolution)
      async
    {
      do {
        _ = try await resolve()
        XCTFail("Invalid original selection accepted")
      } catch CaptureJourneyCheckpointError.invalidCheckpoint {} catch {
        XCTFail("Unexpected failure: \(error)")
      }
    }

    @MainActor
    func testLegacyProfileCheckpointResumesWithoutRewritingSignedOriginalOrSelections() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let front = try await fixture.original(profile: .licenseFront, legacyProfile: "License front")
      let before = try await fixture.store.read(id: front).manifest
      let checkpoint = CaptureJourneyCheckpoint(
        workflowID: fixture.workflow, revision: 1, profile: "License front",
        nextStage: .back, frontID: front, updatedAt: Date(timeIntervalSince1970: 123))
      try await fixture.store.saveJourneyCheckpoint(checkpoint, expectedRevision: nil)
      let recovered = try await CaptureJourneyRecovery.retainedFront(
        captureID: front, workflowID: fixture.workflow, store: fixture.store)
      XCTAssertEqual(recovered.profile, .licenseFront)
      let resolution = try await fixture.resolve(front)
      XCTAssertEqual(resolution.profile, .licenseFront)
      let after = try await fixture.store.read(id: front).manifest
      XCTAssertEqual(after, before)
      let retained = try await fixture.store.journeyCheckpoint(workflowID: fixture.workflow)
      XCTAssertEqual(retained, checkpoint)
      let discovered = try await CaptureJourneyRecovery.retainedFronts(profile: .licenseFront, store: fixture.store)
      XCTAssertEqual(discovered.map(\.captureID), [front])
    }

    @MainActor
    private struct Fixture {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      let workflow = UUID()
      let key = SymmetricKey(size: .bits256)
      let store: CaptureEvidenceStore
      let bytes: Data
      init() throws {
        store = try CaptureSignedFixture.store(directory: directory, key: key)
        bytes = try XCTUnwrap(
          UIGraphicsImageRenderer(size: .init(width: 32, height: 32)).image { context in
            UIColor.gray.setFill()
            context.fill(.init(x: 0, y: 0, width: 32, height: 32))
          }.pngData())
      }
      func original(
        profile: CaptureRecords.Profile, revision: UInt64? = nil,
        front: UUID? = nil, workflow: UUID? = nil, storedBytes: Data? = nil, legacyProfile: String? = nil
      ) async throws -> UUID {
        let id = UUID()
        let manifest = CaptureRecords.Manifest(
          schemaVersion: 1, captureID: id, profile: profile,
          sessionID: CaptureSessionID(),
          captureTimestamp: .init(
            value: 1, timescale: 1, flags: 1,
            epoch: 0, clock: .captureSessionSynchronizationClock),
          processedAt: Date(timeIntervalSince1970: 123),
          fidelity: try PhotoFidelityMetadata.make(from: bytes),
          motionStatus: "fixture", workflowID: workflow ?? self.workflow,
          precedingFrontCaptureID: front, journeyRevision: revision)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        if let legacyProfile { object["profile"] = legacyProfile }
        let manifestBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try await CaptureSignedFixture.original(
          id: id, bytes: storedBytes ?? bytes, manifest: manifestBytes, store: store)
        return id
      }
      func checkpoint(
        stage: CaptureJourneyCheckpoint.Stage, profile: CaptureRecords.Profile,
        front: UUID? = nil, back: UUID? = nil, revision: UInt64 = 1
      ) async throws {
        for current in 1...revision {
          try await store.saveJourneyCheckpoint(
            .init(
              workflowID: workflow, revision: current,
              profile: profile.rawValue, nextStage: stage, frontID: front, backID: back,
              updatedAt: Date(timeIntervalSince1970: 123)),
            expectedRevision: current == 1 ? nil : current - 1)
        }
      }
      func resolve(_ id: UUID) async throws -> CaptureJourneyRecovery.Resolution {
        try await CaptureJourneyRecovery.resolve(
          workflowID: workflow, candidateCaptureID: id, store: store)
      }
      func session() throws -> CaptureSession {
        CaptureSession(
          configuration: .init(
            notifications: NotificationCenter(),
            custody: try .init(applicationID: "synthetic.capture-sdk.fixture",
              directory: directory,
              keychainService: "synthetic." + UUID().uuidString, keychainAccount: "verified-recovery", accessGroup: "TEST.capture-sdk.fixture"),
            signing: try .testing(applicationID: "synthetic.capture-sdk.fixture", installationID: "synthetic-installation"),
            clock: .init(now: { Date(timeIntervalSince1970: 123) }, uptime: { 123 }),
            consent: .permitted)).withFixtureCustody()
      }
      func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
  }
#endif
