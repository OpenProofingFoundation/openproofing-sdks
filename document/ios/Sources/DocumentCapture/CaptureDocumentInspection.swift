#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import CaptureEvidenceCustody

  @MainActor
  public enum CaptureDocumentInspection {
    public static func retainExtraction(
      _ id: UUID, store: CaptureEvidenceStore, retainedOriginal: CaptureEvidenceRecord? = nil,
      operations: CaptureDocumentOperations = .init()
    ) async throws {
      if let retainedOriginal, retainedOriginal.id != id { throw CaptureIntegrityError.integrityVerificationFailed }
      let record = try await CaptureSignedRecords.original(id: id, store: store).record
      if let retainedOriginal,
        retainedOriginal.original != record.original || retainedOriginal.manifest != record.manifest {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      let manifest = try JSONDecoder().decode(
        CaptureRecords.Manifest.self, from: record.manifest)
      guard record.id == id, manifest.schemaVersion == 1, manifest.captureID == id,
        manifest.fidelity.fileByteCount == record.original.count,
        CaptureArtifactIntegrity.sha256(record.original) == manifest.fidelity.sha256
      else {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      var accepted: ArtifactExtraction?
      for saved in try await CaptureDocumentStages.records(
        "extraction", captureID: id,
        sourceHash: manifest.fidelity.sha256, store: store)
      {
        guard let result = try CaptureDocumentStages.extraction(saved, source: record.original)
        else { continue }
        if let accepted,
          try CaptureDocumentStages.encode(accepted) != CaptureDocumentStages.encode(result)
        {
          throw CaptureIntegrityError.integrityVerificationFailed
        }
        accepted = result
      }
      if accepted != nil { return }
      var extraction = try await CaptureProcessingTelemetry.measure(
        id, step: "original_native_extraction"
      ) {
        try await operations.extract(record.original)
      }
      if let structured = operations.structured {
        extraction.structuredDocument = try await CaptureProcessingTelemetry.measure(
          id, step: "structured_extraction"
        ) {
          try await structured(record.original)
        }
      }
      try Task.checkCancellation()
      try CaptureDocumentStages.validateCurrentExtraction(extraction, source: record.original)
      let link = CaptureRecords.ExtractionManifest(
        schemaVersion: 1, recordKind: "extraction", captureID: id,
        sourceSHA256: manifest.fidelity.sha256)
      _ = try await CaptureDocumentStages.retain(
        kind: "extraction", captureID: id,
        original: CaptureDocumentStages.encode(extraction),
        manifest: CaptureDocumentStages.encode(link), store: store,
        afterWrite: operations.afterWrite)
    }
  }
#endif
