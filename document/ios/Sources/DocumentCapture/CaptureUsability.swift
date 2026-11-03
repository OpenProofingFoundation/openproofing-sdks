#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import DocumentSDK
  import CaptureEvidenceCustody

  /// A retained readability observation, never an identity or document-validity decision.
  public struct CaptureUsability: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable {
      case readableCandidate
      case rejected
      case notAssessed
    }

    public let schemaVersion: Int
    public let outcome: Outcome
    public let assessment: DocumentPhotoUsabilityAssessment?
    public let stillQuality: DocumentStillQuality?
    public let derivativeRecordID: UUID?
    public let limitations: [String]
    public var calibration: CaptureProcessingCalibration?

    public init(
      schemaVersion: Int,
      outcome: Outcome,
      assessment: DocumentPhotoUsabilityAssessment? = nil,
      stillQuality: DocumentStillQuality? = nil,
      derivativeRecordID: UUID? = nil,
      limitations: [String]
    ) {
      self.schemaVersion = schemaVersion
      self.outcome = outcome
      self.assessment = assessment
      self.stillQuality = stillQuality
      self.derivativeRecordID = derivativeRecordID
      self.limitations = limitations
    }
  }

  public struct CaptureDocumentSource: Sendable {
    public let data: Data
    public let fidelity: PhotoFidelityMetadata
    public let admission: DocumentCaptureAdmissionSnapshot?
    public let side: DocumentSide
    public let captureID: UUID
    public let profile: CaptureRecords.Profile

    public init(
      data: Data,
      fidelity: PhotoFidelityMetadata,
      admission: DocumentCaptureAdmissionSnapshot? = nil,
      side: DocumentSide,
      captureID: UUID,
      profile: CaptureRecords.Profile
    ) {
      self.data = data
      self.fidelity = fidelity
      self.admission = admission
      self.side = side
      self.captureID = captureID
      self.profile = profile
    }
  }

  @MainActor
  public enum CaptureEvaluation {
    public static func retain(
      source: CaptureDocumentSource, store: CaptureEvidenceStore,
      retainedOriginal: CaptureEvidenceRecord? = nil,
      operations: CaptureDocumentOperations = .init()
    ) async throws -> CaptureUsability {
      if let retainedOriginal, retainedOriginal.id != source.captureID { throw CaptureIntegrityError.integrityVerificationFailed }
      let retained = try await CaptureSignedRecords.original(id: source.captureID, store: store).record
      if let retainedOriginal,
        retainedOriginal.original != retained.original || retainedOriginal.manifest != retained.manifest {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      guard retained.id == source.captureID, retained.original == source.data,
        CaptureArtifactIntegrity.sha256(retained.original) == source.fidelity.sha256
      else { throw CaptureIntegrityError.integrityVerificationFailed }
      let manifest = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: retained.manifest)
      guard manifest.schemaVersion == 1, manifest.captureID == source.captureID,
        manifest.profile == source.profile, source.side == manifest.profile.side,
        manifest.side.map({ $0 == source.side.rawValue }) ?? true,
        manifest.fidelity == source.fidelity, manifest.admission == source.admission
      else { throw CaptureIntegrityError.integrityVerificationFailed }
      if let saved = try await CaptureDocumentStages.usability(
        captureID: source.captureID,
        sourceHash: source.fidelity.sha256, store: store)
      {
        return saved
      }
      var result: CaptureUsability
      switch source.profile {
      case .licenseFront, .licenseBack, .passport, .passportCardFront, .passportCardBack:
        result = try await evaluateLicense(
          source: source, store: store, operations: operations)
      case .document:
        result = CaptureUsability(
          schemaVersion: 1, outcome: .notAssessed, assessment: nil, stillQuality: nil,
          derivativeRecordID: nil,
          limitations: ["readability_not_assessed"])
      }
      result.calibration = operations.calibration
      try Task.checkCancellation()
      let link = CaptureRecords.ExtractionManifest(
        schemaVersion: 1, recordKind: "usability", captureID: source.captureID,
        sourceSHA256: source.fidelity.sha256)
      let encoded = try CaptureDocumentStages.encode(result)
      let recordID = try await CaptureDocumentStages.retain(
        kind: "usability", captureID: source.captureID,
        original: encoded, manifest: CaptureDocumentStages.encode(link), store: store,
        afterWrite: operations.afterWrite)
      let readback = try await store.read(id: recordID)
      guard readback.original == encoded else {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      return result
    }

    private static func evaluateLicense(
      source: CaptureDocumentSource, store: CaptureEvidenceStore,
      operations: CaptureDocumentOperations
    ) async throws -> CaptureUsability {
      do {
        let candidate = try await CaptureProcessingTelemetry.measure(
          source.captureID, step: "image_preparation"
        ) {
          try await operations.prepare(source)
        }
        try Task.checkCancellation()
        let link = CaptureRecords.DerivativeManifest(
          schemaVersion: 1, recordKind: "usabilityDerivative", captureID: source.captureID,
          sourceSHA256: source.fidelity.sha256, derivation: candidate.derivative.derivation)
        let derivativeID = try await CaptureDocumentStages.retain(
          kind: "usabilityDerivative",
          captureID: source.captureID, original: candidate.derivative.data,
          manifest: CaptureDocumentStages.encode(link), store: store,
          afterWrite: operations.afterWrite)
        return CaptureUsability(
          schemaVersion: 1,
          outcome: candidate.usability.analysisFailure != nil
            || candidate.usability.failures.contains(.analysisFailed)
            ? .notAssessed : (candidate.usability.usable ? .readableCandidate : .rejected),
          assessment: candidate.usability, stillQuality: candidate.quality,
          derivativeRecordID: derivativeID,
          limitations: [
            "provisional_geometry_readability"
          ]
        )
      } catch let error as DocumentImagePreparationError {
        guard [.guideUnavailable, .documentNotDetected, .invalidDocumentGeometry].contains(error)
        else { throw error }
        return CaptureUsability(
          schemaVersion: 1, outcome: .rejected,
          assessment: .preparationFailure(side: source.side, error: error), stillQuality: nil,
          derivativeRecordID: nil,
          limitations: ["preparation_refused_original_retained"])
      }
    }
  }
#endif
