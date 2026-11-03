#if os(iOS)
  import DocumentCaptureJournal
  import Foundation
  import DocumentCaptureApple
  import CaptureEvidenceCustody

  public enum CaptureOriginalPersistenceError: Error {
    case recordingBindingFailed
  }

  @MainActor
  public enum CaptureOriginalCustody {
    public static func retain(
      _ photo: CapturedDocumentPhoto, captureID: UUID, profile: CaptureRecords.Profile,
      workflowID: UUID, precedingFrontCaptureID: UUID?, journeyRevision: UInt64?,
      tuning: DocumentCaptureTuningOverrides, store: CaptureEvidenceStore,
      hostTime: @Sendable () -> Double,
      recording: CaptureRecordingJournal? = nil, recordingMilestone: UUID? = nil,
      livePDF417Candidate: String? = nil, documentPresence: CaptureDocumentPresenceRecord? = nil
    ) async throws {
      guard recording == nil || recordingMilestone != nil else {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      guard photo.side == profile.side,
        CaptureArtifactIntegrity.sha256(photo.data) == photo.fidelity.sha256,
        recording.map({ $0.reference.workflowID == workflowID }) ?? true
      else { throw CaptureIntegrityError.integrityVerificationFailed }
      if let admission = photo.admission {
        guard admission.attemptID == captureID, admission.side == photo.side,
          admission.sessionID == photo.sessionID
        else { throw CaptureIntegrityError.integrityVerificationFailed }
      }
      var manifest = CaptureRecords.Manifest(
        schemaVersion: 1, captureID: captureID, profile: profile,
        sessionID: photo.sessionID, captureTimestamp: photo.captureTimestamp,
        processedAt: photo.processedAt, fidelity: photo.fidelity, admission: photo.admission,
        motionStatus: recording != nil
          ? "journey_recording_linked"
          : photo.temporalEvidence.map {
            $0.manifest.motionSamples.isEmpty
              ? "core_motion_no_samples" : "core_motion_samples_retained"
          } ?? "not_collected",
        workflowID: workflowID, precedingFrontCaptureID: precedingFrontCaptureID)
      manifest.livePDF417Candidate = livePDF417Candidate
      manifest.documentPresence = documentPresence
      manifest.origin = photo.origin
      manifest.side = profile.side.rawValue
      manifest.journeyRecording = recording?.reference
      manifest.journeyBindingVersion = recording == nil ? nil : 1
      manifest.journeyRevision = journeyRevision
      manifest.captureTuning = tuning.effectiveValues
      manifest.tuningProfileIdentifier = DocumentCaptureTuning.profileIdentifier
      manifest.tuningCalibrationStatus = DocumentCaptureTuning.calibrationStatus
      manifest.platformMetadata = photo.platformMetadata
      manifest.location = photo.location
      if let evidence = photo.temporalEvidence {
        manifest.temporalEvidence = try await CaptureTemporalEvidencePersistence.retain(
          evidence, manifest: manifest, store: store)
      }
      try Task.checkCancellation()
      try await CaptureSignedRecords.retainOriginal(
        id: captureID, original: photo.data, manifest: JSONEncoder().encode(manifest), store: store)
      if let recording, let recordingMilestone {
        do {
          try await recording.appendStillRetained(
            .init(
              kind: "still_retained",
              hostTimeSeconds: hostTime(),
              binding: .init(
                sessionID: photo.sessionID.rawValue.uuidString,
                attemptID: captureID.uuidString, side: photo.side.rawValue,
                stillSHA256: photo.fidelity.sha256, stillTimestamp: photo.captureTimestamp,
                stillHostTimeSeconds: nil)), reservation: recordingMilestone)
          try await CaptureStillBindingCustody.retain(
            captureID: captureID, sourceHash: photo.fidelity.sha256,
            recordingID: recording.recordingID, outcome: .bound, store: store)
        } catch {
          try? await CaptureStillBindingCustody.retain(
            captureID: captureID, sourceHash: photo.fidelity.sha256,
            recordingID: recording.recordingID, outcome: .failed, store: store)
          throw CaptureOriginalPersistenceError.recordingBindingFailed
        }
      }
    }
  }
#endif
