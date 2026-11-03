#if os(iOS)
  import Foundation
  import KenshikiEvidenceManifest
  import CaptureEvidenceCustody
  import DocumentCaptureApple

  /// Resolves durable acquisition selections. It does not choose UI navigation or evaluate identity.
  @MainActor
  public enum CaptureJourneyRecovery {
    /// Produced only by authenticated SDK resolution; callers cannot manufacture or mutate it.
    public struct Original {
      public let record: CaptureEvidenceRecord
      public let manifest: CaptureRecords.Manifest
      public let checkpointRevision: UInt64?
      init(
        record: CaptureEvidenceRecord, manifest: CaptureRecords.Manifest,
        checkpointRevision: UInt64? = nil
      ) {
        self.record = record
        self.manifest = manifest
        self.checkpointRevision = checkpointRevision
      }
      func bound(to checkpoint: CaptureJourneyCheckpoint) -> Self {
        .init(record: record, manifest: manifest, checkpointRevision: checkpoint.revision)
      }
      public var captureID: UUID { record.id }
      public var profile: CaptureRecords.Profile { manifest.profile }
    }

    public struct Resolution {
      public let checkpoint: CaptureJourneyCheckpoint?
      public let profile: CaptureRecords.Profile
      /// The durable selection, or the retained front while another capture is pending.
      public let selected: Original?
      /// Non-nil only when the candidate cannot complete the checkpoint's acquisition attempt.
      public let pendingCaptureStage: CaptureJourneyCheckpoint.Stage?
    }

    public static func resolve(
      workflowID: UUID, candidateCaptureID: UUID, store: CaptureEvidenceStore
    ) async throws -> Resolution {
      guard let checkpoint = try await store.journeyCheckpoint(workflowID: workflowID) else {
        let candidate = try await original(candidateCaptureID, workflowID: workflowID, store: store)
        if candidate.profile.backSide, let frontID = candidate.manifest.precedingFrontCaptureID {
          _ = try await original(
            frontID, workflowID: workflowID,
            profile: candidate.profile.frontProfile, store: store)
        }
        return .init(
          checkpoint: nil, profile: candidate.profile, selected: candidate,
          pendingCaptureStage: nil)
      }
      guard let profile = CaptureRecords.Profile.retainedIdentifier(checkpoint.profile) else {
        throw CaptureJourneyCheckpointError.invalidCheckpoint
      }
      var selectedID = checkpoint.backID ?? checkpoint.frontID
      var selectedProfile = checkpoint.backID == nil ? profile : profile.backProfile
      var admittedCandidate: Original?
      if checkpoint.nextStage == .front || checkpoint.nextStage == .back {
        let candidate = try await original(candidateCaptureID, workflowID: workflowID, store: store)
        let expectedProfile = checkpoint.nextStage == .back ? profile.backProfile : profile
        let currentAttempt =
          candidate.manifest.journeyRevision == checkpoint.revision
          && candidate.manifest.workflowID == checkpoint.workflowID
          && candidate.profile == expectedProfile
        guard currentAttempt else {
          let front: Original?
          if let frontID = checkpoint.frontID {
            front = try await original(
              frontID, workflowID: workflowID, profile: profile, store: store)
          } else {
            front = nil
          }
          return .init(
            checkpoint: checkpoint, profile: profile, selected: front?.bound(to: checkpoint),
            pendingCaptureStage: checkpoint.nextStage)
        }
        selectedID = candidateCaptureID
        selectedProfile = expectedProfile
        admittedCandidate = candidate
      }
      guard let selectedID else { throw CaptureJourneyCheckpointError.invalidCheckpoint }
      let selected: Original
      if let admittedCandidate {
        selected = admittedCandidate
      } else {
        selected = try await original(
          selectedID, workflowID: workflowID,
          profile: selectedProfile, store: store)
      }
      if selectedProfile.backSide {
        guard let frontID = checkpoint.frontID,
          selected.manifest.precedingFrontCaptureID == frontID
        else {
          throw CaptureJourneyCheckpointError.invalidCheckpoint
        }
        _ = try await original(frontID, workflowID: workflowID, profile: profile, store: store)
      }
      return .init(
        checkpoint: checkpoint, profile: profile, selected: selected.bound(to: checkpoint),
        pendingCaptureStage: nil)
    }

    /// Resolve the retained front even when the journey currently selects a back image.
    /// A checkpoint selecting another front cannot relink this original to that journey.
    public static func retainedFront(
      captureID: UUID, workflowID: UUID, store: CaptureEvidenceStore
    ) async throws -> Original {
      let front = try await original(captureID, workflowID: workflowID, store: store)
      guard front.profile.twoSided else { throw CaptureJourneyCheckpointError.invalidCheckpoint }
      guard let checkpoint = try await store.journeyCheckpoint(workflowID: workflowID) else {
        return front
      }
      guard CaptureRecords.Profile.retainedIdentifier(checkpoint.profile) == front.profile, checkpoint.frontID == captureID else {
        throw CaptureJourneyCheckpointError.invalidCheckpoint
      }
      return front.bound(to: checkpoint)
    }

    /// Authenticate a particular retained back and its front linkage, including older attempts.
    /// This does not select the back or claim it completed the current checkpoint revision.
    public static func retainedBack(
      captureID: UUID, frontCaptureID: UUID, workflowID: UUID, store: CaptureEvidenceStore
    ) async throws -> Original {
      let front = try await retainedFront(
        captureID: frontCaptureID, workflowID: workflowID, store: store)
      let back = try await original(
        captureID, workflowID: workflowID, profile: front.profile.backProfile, store: store)
      guard back.manifest.precedingFrontCaptureID == frontCaptureID else {
        throw CaptureJourneyCheckpointError.invalidCheckpoint
      }
      return back
    }

    /// Discover an admitted back whose host receipt may have been interrupted. Never starts
    /// capture or processing and never selects an earlier attempt by timestamp. The host drains
    /// admitted camera work before calling this, then explicitly offers continuation.
    public static func currentBack(
      frontCaptureID: UUID, workflowID: UUID, store: CaptureEvidenceStore
    ) async throws -> Original? {
      let front = try await retainedFront(
        captureID: frontCaptureID, workflowID: workflowID, store: store)
      guard let checkpoint = try await store.journeyCheckpoint(workflowID: workflowID) else {
        return nil
      }
      guard checkpoint.frontID == frontCaptureID,
        CaptureRecords.Profile.retainedIdentifier(checkpoint.profile) == front.profile
      else { throw CaptureJourneyCheckpointError.invalidCheckpoint }
      let selected: Original?
      if let backID = checkpoint.backID {
        selected = try await retainedBack(
          captureID: backID, frontCaptureID: frontCaptureID, workflowID: workflowID, store: store)
      } else if checkpoint.nextStage == .back {
        var current: Original?
        for candidateID in try await store.originalRecordIDs() {
          try Task.checkCancellation()
          let data = try await store.metadata(id: candidateID)
          let manifest = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: data)
          guard manifest.profile == front.profile.backProfile,
            manifest.workflowID == workflowID,
            manifest.precedingFrontCaptureID == frontCaptureID,
            manifest.journeyRevision == checkpoint.revision
          else { continue }
          guard current == nil else { throw CaptureJourneyCheckpointError.invalidCheckpoint }
          current = try await original(
            candidateID, workflowID: workflowID, profile: front.profile.backProfile, store: store)
        }
        selected = current
      } else {
        selected = nil
      }
      try Task.checkCancellation()
      guard try await store.journeyCheckpoint(workflowID: workflowID) == checkpoint else {
        throw CaptureJourneyCheckpointError.staleRevision
      }
      return selected?.bound(to: checkpoint)
    }

    private static func original(
      _ captureID: UUID, workflowID: UUID, profile: CaptureRecords.Profile? = nil,
      store: CaptureEvidenceStore
    ) async throws -> Original {
      let record: CaptureEvidenceRecord
      do {
        record = try await CaptureSignedRecords.original(id: captureID, workflowID: workflowID, store: store).record
      } catch CaptureIntegrityError.integrityVerificationFailed {
        throw CaptureJourneyCheckpointError.invalidCheckpoint
      } catch CaptureEvidenceStoreError.unsignedHistoricalRecord {
        throw CaptureJourneyCheckpointError.invalidCheckpoint
      } catch EvidenceManifestError.bindingMismatch {
        throw CaptureJourneyCheckpointError.invalidCheckpoint
      }
      let manifest = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: record.manifest)
      guard manifest.schemaVersion == 1, manifest.captureID == captureID,
        manifest.workflowID == workflowID,
        profile.map({ manifest.profile == $0 }) ?? true,
        manifest.side.map({ $0 == manifest.profile.side.rawValue }) ?? true,
        manifest.fidelity.fileByteCount == record.original.count,
        CaptureArtifactIntegrity.sha256(record.original) == manifest.fidelity.sha256
      else {
        throw CaptureJourneyCheckpointError.invalidCheckpoint
      }
      return .init(record: record, manifest: manifest)
    }
  }

  extension CaptureSession {
    /// Adopt an SDK-authenticated original without another read. This releases capture admission
    /// synchronously; callers needing native ownership transfer still await stopAndWait().
    public func restoreVerifiedOriginal(_ original: CaptureJourneyRecovery.Original) throws {
      guard !erasing, !busy, operation == nil, activeCaptureAttempt == nil,
        originalState == .idle
      else { throw PhotoCaptureError.cameraNotReady }
      stop()
      let manifest = original.manifest
      workflowID = manifest.workflowID ?? original.captureID
      profile = manifest.profile
      journeyRevision = original.checkpointRevision ?? manifest.journeyRevision
      retainedFrontCaptureID =
        manifest.profile.twoSided
        ? original.captureID : manifest.precedingFrontCaptureID
      selectedCaptureID = original.captureID
      recoveryCaptureID = original.captureID
      phase = .reviewing
      issue = nil
    }
  }
#endif
