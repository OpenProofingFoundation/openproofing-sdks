#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import CaptureEvidenceCustody

  /// Composes existing extraction and custody. Recognition consumes only the
  /// verified document derivative, never unrelated text/faces in the full frame.
  @MainActor
  public enum CaptureDocumentWorkflow {
    public static func assess(
      sourceHash: String, captureID: UUID, profile: CaptureRecords.Profile,
      usability: CaptureUsability, store: CaptureEvidenceStore,
      operations: CaptureDocumentOperations = .init()
    ) async throws -> DocumentCaptureExpectationAssessment {
      let scoped: ScopedExtraction?
      var extractionSucceeded = true
      do {
        scoped = try await extractDocument(
          sourceHash: sourceHash, captureID: captureID,
          derivativeID: usability.derivativeRecordID, store: store, operations: operations)
      } catch is CancellationError { throw CancellationError() } catch {
        scoped = nil
        extractionSucceeded = false
      }
      let front = DocumentFrontLayoutEvidence.evaluate(
        recognizedText: scoped?.extraction.recognizedText ?? [],
        detectedFaceCount: scoped?.extraction.detectedFaceCount)
      let result = DocumentCaptureExpectationAssessment.evaluate(
        expectation: profile.expectation,
        pdf417Payloads: scoped?.extraction.pdf417Payloads ?? [],
        usability: usability.assessment, completeDocument: scoped != nil,
        frontLayoutCandidate: front.provisionalFrontLayoutCandidate,
        extractionSucceeded: extractionSucceeded)
      let link = CaptureRecords.ExtractionManifest(
        schemaVersion: 1, recordKind: "workflowAssessment", captureID: captureID,
        sourceSHA256: sourceHash)
      let envelope = AssessmentRecord(
        assessment: result, derivativeRecordID: usability.derivativeRecordID,
        documentExtractionRecordID: scoped?.recordID, frontLayoutEvidence: front)
      let encoded = try CaptureDocumentStages.encode(envelope)
      let recordID = try await CaptureDocumentStages.retain(
        kind: "workflowAssessment",
        captureID: captureID, original: encoded, manifest: CaptureDocumentStages.encode(link),
        store: store, afterWrite: operations.afterWrite)
      guard try await CaptureSignedRecords.stage(id: recordID, captureID: captureID, store: store).original == encoded else {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      try await CapturePortraitCustody.retain(
        captureID: captureID, sourceHash: sourceHash,
        derivativeID: usability.derivativeRecordID, store: store,
        retainedDerivative: scoped?.derivative, operations: operations)
      guard extractionSucceeded else { throw CaptureDocumentRecoveryError.stageFailed }
      return result
    }

    private struct ScopedExtraction {
      public let recordID: UUID
      public let extraction: ArtifactExtraction
      public let derivative: CaptureEvidenceRecord
    }

    private static func extractDocument(
      sourceHash: String, captureID: UUID, derivativeID: UUID?, store: CaptureEvidenceStore,
      operations: CaptureDocumentOperations
    ) async throws -> ScopedExtraction? {
      guard let derivativeID else { return nil }
      let derived = try await CaptureDocumentStages.derivative(derivativeID, captureID: captureID, sourceHash: sourceHash, store: store)
      let link = try JSONDecoder().decode(
        CaptureRecords.DerivativeManifest.self, from: derived.manifest)
      guard link.recordKind == "usabilityDerivative", link.captureID == captureID,
        link.sourceSHA256 == sourceHash, link.derivation.sourceSHA256 == sourceHash,
        CaptureArtifactIntegrity.sha256(derived.original) == link.derivation.outputSHA256
      else { throw CaptureIntegrityError.integrityVerificationFailed }
      var accepted: ScopedExtraction?
      for saved in try await CaptureDocumentStages.records(
        "documentExtraction", captureID: captureID,
        sourceHash: sourceHash, store: store)
      {
        let savedLink = try JSONDecoder().decode(DocumentExtractionLink.self, from: saved.manifest)
        guard savedLink.derivativeRecordID == derivativeID,
          savedLink.derivativeSHA256 == link.derivation.outputSHA256
        else { continue }
        guard
          let extraction = try CaptureDocumentStages.extraction(saved, source: derived.original)
        else { continue }
        if let accepted,
          try CaptureDocumentStages.encode(accepted.extraction)
            != CaptureDocumentStages.encode(extraction)
        {
          throw CaptureIntegrityError.integrityVerificationFailed
        }
        accepted =
          accepted
          ?? ScopedExtraction(recordID: saved.id, extraction: extraction, derivative: derived)
      }
      if let accepted { return accepted }
      let extraction = try await CaptureProcessingTelemetry.measure(
        captureID, step: "document_native_extraction"
      ) {
        try await operations.extract(derived.original)
      }
      try Task.checkCancellation()
      try CaptureDocumentStages.validateCurrentExtraction(extraction, source: derived.original)
      let manifest = DocumentExtractionLink(
        recordKind: "documentExtraction", captureID: captureID, sourceSHA256: sourceHash,
        derivativeRecordID: derivativeID, derivativeSHA256: link.derivation.outputSHA256)
      let encoded = try CaptureDocumentStages.encode(extraction)
      let recordID = try await CaptureDocumentStages.retain(
        kind: "documentExtraction",
        captureID: captureID, original: encoded, manifest: CaptureDocumentStages.encode(manifest),
        store: store, afterWrite: operations.afterWrite)
      guard try await CaptureSignedRecords.stage(id: recordID, captureID: captureID, store: store).original == encoded else {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      return ScopedExtraction(recordID: recordID, extraction: extraction, derivative: derived)
    }

    public struct AssessmentRecord: Codable {
      public let assessment: DocumentCaptureExpectationAssessment
      public let derivativeRecordID: UUID?
      public let documentExtractionRecordID: UUID?
      public let frontLayoutEvidence: DocumentFrontLayoutEvidence

      public init(
        assessment: DocumentCaptureExpectationAssessment,
        derivativeRecordID: UUID? = nil,
        documentExtractionRecordID: UUID? = nil,
        frontLayoutEvidence: DocumentFrontLayoutEvidence
      ) {
        self.assessment = assessment
        self.derivativeRecordID = derivativeRecordID
        self.documentExtractionRecordID = documentExtractionRecordID
        self.frontLayoutEvidence = frontLayoutEvidence
      }
    }

    public struct DocumentExtractionLink: Codable {
      public let schemaVersion = 1
      public let recordKind: String
      public let captureID: UUID
      public let sourceSHA256: String
      public let derivativeRecordID: UUID
      public let derivativeSHA256: String

      public init(
        recordKind: String,
        captureID: UUID,
        sourceSHA256: String,
        derivativeRecordID: UUID,
        derivativeSHA256: String
      ) {
        self.recordKind = recordKind
        self.captureID = captureID
        self.sourceSHA256 = sourceSHA256
        self.derivativeRecordID = derivativeRecordID
        self.derivativeSHA256 = derivativeSHA256
      }
    }
  }

  extension CaptureRecords.Profile {
    public var expectation: DocumentCaptureExpectation {
      switch self {
      case .passportCardFront: .passportCardFront
      case .passportCardBack: .passportCardBack
      case .licenseFront: .licenseFront
      case .licenseBack: .licenseBack
      case .passport: .passport
      case .document: .document
      }
    }
  }
#endif
