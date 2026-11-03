#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import CaptureEvidenceCustody
  import DocumentCaptureJournal

  public enum CaptureDocumentRecoveryError: Error { case stageFailed }

  @MainActor
  public enum CaptureDocumentRecovery {
    public enum Stage: String {
      case original, usability, extraction, assessment
    }

    public static func process(
      captureID: UUID, store: CaptureEvidenceStore,
      operations: CaptureDocumentOperations = .init(),
      onStage: (Stage) -> Void = { _ in }
    ) async throws -> DocumentCaptureExpectationAssessment {
      let (original, manifest) = try await stage(.original, captureID: captureID, onStage: onStage)
      {
        let original = try await CaptureSignedRecords.original(id: captureID, store: store).record
        let manifest = try JSONDecoder().decode(
          CaptureRecords.Manifest.self, from: original.manifest)
        guard manifest.schemaVersion == 1, manifest.captureID == captureID,
          manifest.fidelity.sha256 == CaptureArtifactIntegrity.sha256(original.original),
          manifest.fidelity.fileByteCount == original.original.count
        else { throw CaptureIntegrityError.integrityVerificationFailed }
        try await CaptureTemporalEvidencePersistence.verify(manifest, store: store)
        try await CaptureRecordingVerification.verifyStart(
          manifestData: try JSONEncoder().encode(manifest), store: store)
        return (original, manifest)
      }
      let usability = try await stage(.usability, captureID: captureID, onStage: onStage) {
        try await CaptureEvaluation.retain(
          source: .init(
            data: original.original, fidelity: manifest.fidelity, admission: manifest.admission,
            side: manifest.profile.side, captureID: captureID, profile: manifest.profile),
          store: store,
          retainedOriginal: original, operations: operations)
      }
      let assessment = try await stage(.assessment, captureID: captureID, onStage: onStage) {
        try await CaptureDocumentWorkflow.assess(
          sourceHash: manifest.fidelity.sha256, captureID: captureID, profile: manifest.profile,
          usability: usability, store: store, operations: operations)
      }
      return assessment
    }

    /// Deferred report work; never a prerequisite for portrait/selfie acquisition.
    public static func processReport(
      captureID: UUID, store: CaptureEvidenceStore,
      operations: CaptureDocumentOperations = .init()
    ) async throws {
      try await stage(
        .extraction, captureID: captureID, onStage: { _ in },
        operation: {
          try await CaptureDocumentInspection.retainExtraction(
            captureID, store: store, operations: operations)
        })
    }

    private static func stage<Value>(
      _ stage: Stage, captureID _: UUID, onStage: (Stage) -> Void, operation: () async throws -> Value
    ) async throws -> Value {
      try Task.checkCancellation()
      onStage(stage)
      let value = try await operation()
      try Task.checkCancellation()
      return value
    }
  }
#endif
