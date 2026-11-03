#if os(iOS)
  import Foundation
  import XCTest
  @testable import CaptureEvidenceCustody
  @testable import DocumentCapture

  @MainActor
  final class CaptureJourneyFrontDiscoveryTests: XCTestCase {
    private typealias Fixture = JourneyRecoveryIntegrationTests.RecoveryFixture

    func testReopenedCustodyDiscoversFrontWithoutHostCheckpointOrProviderResult() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      try await fixture.retain(manifest)
      let reopened = try fixture.reopen()
      let fronts = try await CaptureJourneyRecovery.retainedFronts(profile: .licenseFront, store: reopened)
      XCTAssertEqual(fronts.map(\.captureID), [manifest.captureID])
      XCTAssertEqual(fronts.first?.record.original, fixture.pixels)
      XCTAssertNil(fronts.first?.checkpointRevision)
      let checkpoint = try await reopened.journeyCheckpoint(workflowID: try XCTUnwrap(manifest.workflowID))
      XCTAssertNil(checkpoint, "Discovery must not create an acquisition or host checkpoint")
    }

    func testDiscoveryFiltersBacksAndOtherProfilesAndReturnsCandidatesWithoutChoosingOne() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let first = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let second = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      for manifest in [first, second,
        try fixture.manifest(profile: .licenseBack, workflowID: first.workflowID, precedingFrontCaptureID: first.captureID),
        try fixture.manifest(profile: .passportCardFront, workflowID: UUID()),
        try fixture.manifest(profile: .passport, workflowID: UUID())] {
        try await fixture.retain(manifest)
      }
      let fronts = try await CaptureJourneyRecovery.retainedFronts(profile: .licenseFront, store: fixture.store)
      XCTAssertEqual(Set(fronts.map(\.captureID)), [first.captureID, second.captureID])
      for profile in [CaptureRecords.Profile.licenseBack, .passport, .document] {
        do {
          _ = try await CaptureJourneyRecovery.retainedFronts(profile: profile, store: fixture.store)
          XCTFail("A non-front profile was admitted")
        } catch CaptureJourneyCheckpointError.invalidCheckpoint {}
      }
    }

    func testCheckpointSelectionSupersedesAnotherRetainedFrontWithoutTimestampSelection() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let workflow = UUID()
      let chosen = try fixture.manifest(profile: .licenseFront, workflowID: workflow)
      let superseded = try fixture.manifest(profile: .licenseFront, workflowID: workflow)
      try await fixture.retain(chosen)
      try await fixture.retain(superseded)
      let checkpoint = CaptureJourneyCheckpoint(workflowID: workflow, revision: 1,
        profile: CaptureRecords.Profile.licenseFront.rawValue, nextStage: .back,
        frontID: chosen.captureID, backID: nil, updatedAt: Date(timeIntervalSince1970: 1))
      try await fixture.store.saveJourneyCheckpoint(checkpoint, expectedRevision: nil)
      let reopened = try fixture.reopen()
      let fronts = try await CaptureJourneyRecovery.retainedFronts(profile: .licenseFront, store: reopened)
      XCTAssertEqual(fronts.map(\.captureID), [chosen.captureID])
      XCTAssertEqual(fronts.first?.checkpointRevision, 1)
      let after = try await reopened.journeyCheckpoint(workflowID: workflow)
      XCTAssertEqual(after, checkpoint)
    }

    func testCurrentAdmittedPendingFrontIsDiscoveredBeforeSelectionWasSaved() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let workflow = UUID()
      var current = try fixture.manifest(profile: .licenseFront, workflowID: workflow)
      current.journeyRevision = 1
      try await fixture.retain(current)
      let checkpoint = CaptureJourneyCheckpoint(workflowID: workflow, revision: 1,
        profile: CaptureRecords.Profile.licenseFront.rawValue, nextStage: .front,
        frontID: nil, backID: nil, updatedAt: Date(timeIntervalSince1970: 1))
      try await fixture.store.saveJourneyCheckpoint(checkpoint, expectedRevision: nil)
      let reopened = try fixture.reopen()
      let fronts = try await CaptureJourneyRecovery.retainedFronts(profile: .licenseFront, store: reopened)
      XCTAssertEqual(fronts.map(\.captureID), [current.captureID])
      XCTAssertEqual(fronts.first?.checkpointRevision, 1)
      let after = try await reopened.journeyCheckpoint(workflowID: workflow)
      XCTAssertEqual(after, checkpoint, "Discovery does not commit the interrupted selection")
    }

    func testEarlierPendingFrontCannotCompleteCurrentCheckpointRevision() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let workflow = UUID()
      var old = try fixture.manifest(profile: .licenseFront, workflowID: workflow)
      old.journeyRevision = 1
      try await fixture.retain(old)
      for revision in UInt64(1)...2 {
        let checkpoint = CaptureJourneyCheckpoint(workflowID: workflow, revision: revision,
          profile: CaptureRecords.Profile.licenseFront.rawValue, nextStage: .front,
          frontID: nil, backID: nil, updatedAt: Date(timeIntervalSince1970: 1))
        try await fixture.store.saveJourneyCheckpoint(checkpoint,
          expectedRevision: revision == 1 ? nil : revision - 1)
      }
      let fronts = try await CaptureJourneyRecovery.retainedFronts(profile: .licenseFront, store: fixture.store)
      XCTAssertTrue(fronts.isEmpty)
    }

    func testCorruptOriginalNeverProducesAPartialCandidateList() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let valid = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let corrupted = try fixture.manifest(profile: .licenseFront, workflowID: UUID(),
        declaredHash: String(repeating: "a", count: 64))
      try await fixture.retain(valid)
      try await fixture.retain(corrupted)
      do {
        _ = try await CaptureJourneyRecovery.retainedFronts(profile: .licenseFront, store: fixture.store)
        XCTFail("Corrupt original was silently omitted or accepted")
      } catch CaptureJourneyCheckpointError.invalidCheckpoint {}
    }

    func testMalformedAuthenticatedManifestAndRevokedCustodyFailClosed() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      try await fixture.retain(manifest)
      // An authenticated envelope whose original-role metadata is malformed is not an empty store.
      let malformedID = UUID()
      let metadata: [String: Any] = ["captureID": malformedID.uuidString, "profile": "License front", "fidelity": [String: String]()]
      let encoded = try JSONSerialization.data(withJSONObject: metadata)
      try await fixture.store.store(id: malformedID, original: fixture.pixels, manifest: encoded)
      do {
        _ = try await CaptureJourneyRecovery.retainedFronts(profile: .licenseFront, store: fixture.store)
        XCTFail("Malformed authenticated metadata was silently omitted")
      } catch {}
      try await fixture.store.revokeAndRemoveAll()
      do {
        _ = try await CaptureJourneyRecovery.retainedFronts(profile: .licenseFront, store: fixture.store)
        XCTFail("Revoked custody was treated as an empty archive")
      } catch CaptureEvidenceStoreError.custodyRevoked {}
    }

    func testAlreadyCancelledDiscoveryReturnsNoOriginal() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      try await fixture.retain(manifest)
      let operation = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        _ = try await CaptureJourneyRecovery.retainedFronts(profile: .licenseFront, store: fixture.store)
      }
      do {
        _ = try await operation.value
        XCTFail("Cancelled discovery returned evidence")
      } catch is CancellationError {}
    }
  }
#endif
