#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import CaptureEvidenceCustody

  /// Host composition only. Detection and crop policy belong to the public SDK.
  @MainActor
  public enum CapturePortraitCustody {
    public struct Link: Codable {
      public let schemaVersion: Int
      public let recordKind: String
      public let captureID: UUID
      public let sourceSHA256: String
      public let derivativeRecordID: UUID?
      public let derivativeSHA256: String?
      public let derivation: PortraitImageDerivation?

      public init(
        schemaVersion: Int,
        recordKind: String,
        captureID: UUID,
        sourceSHA256: String,
        derivativeRecordID: UUID? = nil,
        derivativeSHA256: String? = nil,
        derivation: PortraitImageDerivation? = nil
      ) {
        self.schemaVersion = schemaVersion
        self.recordKind = recordKind
        self.captureID = captureID
        self.sourceSHA256 = sourceSHA256
        self.derivativeRecordID = derivativeRecordID
        self.derivativeSHA256 = derivativeSHA256
        self.derivation = derivation
      }
    }

    public struct Record: Codable {
      public let outcome: String
      public let extraction: PortraitExtractionMetadata?
      public let crops: [Crop]

      public init(
        outcome: String,
        extraction: PortraitExtractionMetadata? = nil,
        crops: [Crop]
      ) {
        self.outcome = outcome
        self.extraction = extraction
        self.crops = crops
      }
    }

    public struct Crop: Codable {
      public let recordID: UUID
      public let derivation: PortraitImageDerivation

      public init(
        recordID: UUID,
        derivation: PortraitImageDerivation
      ) {
        self.recordID = recordID
        self.derivation = derivation
      }
    }

    public static func retain(
      captureID: UUID, sourceHash: String, derivativeID: UUID?, store: CaptureEvidenceStore,
      retainedDerivative: CaptureEvidenceRecord? = nil,
      operations: CaptureDocumentOperations = .init()
    ) async throws {
      if try await alreadyCompleted(
        captureID: captureID, sourceHash: sourceHash,
        derivativeID: derivativeID, store: store)
      {
        return
      }
      var derivativeHash: String?
      let result: Record
      do {
        if let derivativeID {
          let input = try await verifiedInput(
            derivativeID, captureID: captureID, sourceHash: sourceHash,
            retained: retainedDerivative, store: store)
          let parent = try JSONDecoder().decode(
            CaptureRecords.DerivativeManifest.self, from: input.manifest)
          derivativeHash = parent.derivation.outputSHA256
          let extracted = try await CaptureProcessingTelemetry.measure(
            captureID, step: "portrait_extraction"
          ) {
            try await operations.portrait(input.original, parent.derivation)
          }
          try Task.checkCancellation()
          var crops: [Crop] = []
          for candidate in extracted.candidates {
            let link = Link(
              schemaVersion: 1, recordKind: "portraitCrop", captureID: captureID,
              sourceSHA256: sourceHash, derivativeRecordID: derivativeID,
              derivativeSHA256: derivativeHash, derivation: candidate.metadata)
            let id = try await CaptureDocumentStages.retain(
              kind: "portraitCrop", captureID: captureID,
              original: candidate.data, manifest: CaptureDocumentStages.encode(link), store: store,
              afterWrite: operations.afterWrite)
            crops.append(Crop(recordID: id, derivation: candidate.metadata))
          }
          result = Record(outcome: "completed", extraction: extracted.metadata, crops: crops)
        } else {
          result = Record(outcome: "preparedDocumentUnavailable", extraction: nil, crops: [])
        }
      } catch is CancellationError { throw CancellationError() } catch {
        result = Record(outcome: "extractionFailed", extraction: nil, crops: [])
      }
      let link = Link(
        schemaVersion: 1, recordKind: "portraitExtraction", captureID: captureID,
        sourceSHA256: sourceHash, derivativeRecordID: derivativeID,
        derivativeSHA256: derivativeHash)
      _ = try await CaptureDocumentStages.retain(
        kind: "portraitExtraction", captureID: captureID,
        original: CaptureDocumentStages.encode(result),
        manifest: CaptureDocumentStages.encode(link),
        store: store, afterWrite: operations.afterWrite)
      guard result.outcome != "extractionFailed" else {
        throw CaptureDocumentRecoveryError.stageFailed
      }
    }
    private static func verifiedInput(
      _ derivativeID: UUID, captureID: UUID, sourceHash: String,
      retained: CaptureEvidenceRecord?, store: CaptureEvidenceStore
    ) async throws -> CaptureEvidenceRecord {
      let input: CaptureEvidenceRecord
      input = try await CaptureDocumentStages.derivative(derivativeID, captureID: captureID,
        sourceHash: sourceHash, store: store)
      if let retained, retained.original != input.original || retained.manifest != input.manifest {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      let parent = try JSONDecoder().decode(
        CaptureRecords.DerivativeManifest.self, from: input.manifest)
      guard input.id == derivativeID, parent.schemaVersion == 1,
        parent.recordKind == "usabilityDerivative",
        parent.captureID == captureID, parent.sourceSHA256 == sourceHash,
        parent.derivation.sourceSHA256 == sourceHash,
        CaptureArtifactIntegrity.sha256(input.original) == parent.derivation.outputSHA256
      else { throw CaptureIntegrityError.integrityVerificationFailed }
      return input
    }
    private static func alreadyCompleted(
      captureID: UUID, sourceHash: String, derivativeID: UUID?, store: CaptureEvidenceStore
    ) async throws -> Bool {
      for saved in try await CaptureDocumentStages.records(
        "portraitExtraction", captureID: captureID,
        sourceHash: sourceHash, store: store)
      {
        let link = try JSONDecoder().decode(Link.self, from: saved.manifest)
        let record = try JSONDecoder().decode(Record.self, from: saved.original)
        guard link.derivativeRecordID == derivativeID, record.outcome == "completed" else {
          continue
        }
        _ = try await CapturePortraitVerification.load(
          id: saved.id, captureID: captureID,
          sourceHash: sourceHash, store: store)
        return true
      }
      return false
    }
  }
#endif
