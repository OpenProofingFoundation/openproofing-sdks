#if os(iOS)
  import Foundation
  import CaptureEvidenceCustody

  extension CaptureJourneyRecovery {
    /// Discover authenticated retained fronts without selecting one by capture time or running
    /// processing. Returns selected fronts and originals admitted to the current pending front
    /// revision before selection was saved. A selected front supersedes other originals in its
    /// workflow. Missing checkpoints do not require a host receipt or a completed provider result.
    public static func retainedFronts(
      profile: CaptureRecords.Profile, store: CaptureEvidenceStore
    ) async throws -> [Original] {
      guard profile.twoSided else { throw CaptureJourneyCheckpointError.invalidCheckpoint }
      try Task.checkCancellation()
      struct Fence { let checkpoint: CaptureJourneyCheckpoint? }
      var fences: [UUID: Fence] = [:]
      var fronts: [Original] = []
      for captureID in try await store.originalRecordIDs() {
        try Task.checkCancellation()
        let metadata = try await store.metadata(id: captureID)
        let manifest = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: metadata)
        guard manifest.profile == profile else { continue }
        let workflowID = manifest.workflowID ?? captureID
        let fence: Fence
        if let existing = fences[workflowID] {
          fence = existing
        } else {
          fence = Fence(checkpoint: try await store.journeyCheckpoint(workflowID: workflowID))
          fences[workflowID] = fence
        }
        let front: Original
        if let checkpoint = fence.checkpoint, checkpoint.frontID == nil {
          guard checkpoint.nextStage == .front, CaptureRecords.Profile.retainedIdentifier(checkpoint.profile) == profile,
            checkpoint.workflowID == workflowID, manifest.journeyRevision == checkpoint.revision
          else { continue }
          let resolution = try await resolve(workflowID: workflowID,
            candidateCaptureID: captureID, store: store)
          guard resolution.checkpoint == checkpoint else { throw CaptureJourneyCheckpointError.staleRevision }
          guard let selected = resolution.selected, selected.captureID == captureID,
            resolution.pendingCaptureStage == nil
          else { throw CaptureJourneyCheckpointError.invalidCheckpoint }
          front = selected
        } else {
          if let checkpoint = fence.checkpoint, checkpoint.frontID != captureID { continue }
          front = try await retainedFront(captureID: captureID, workflowID: workflowID, store: store)
        }
        // The authenticated full manifest, not routing metadata alone, determines admission.
        guard front.profile == profile else { throw CaptureJourneyCheckpointError.invalidCheckpoint }
        fronts.append(front)
      }
      // Every observed workflow is fenced, including ones whose superseded originals were skipped.
      for (workflowID, fence) in fences {
        try Task.checkCancellation()
        guard try await store.journeyCheckpoint(workflowID: workflowID) == fence.checkpoint else {
          throw CaptureJourneyCheckpointError.staleRevision
        }
      }
      try Task.checkCancellation()
      return fronts
    }
  }
#endif
