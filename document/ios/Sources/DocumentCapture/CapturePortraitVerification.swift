#if os(iOS)
  import Foundation
  import ImageIO
  import DocumentCaptureApple
  import CaptureEvidenceCustody

  /// Verified retained portrait references; the host owns decoding and display.
  public struct CapturePortraitArtifact: Sendable {
    public let recordID: UUID
    public let captureID: UUID
    public let derivation: PortraitImageDerivation

    public init(
      recordID: UUID,
      captureID: UUID,
      derivation: PortraitImageDerivation
    ) {
      self.recordID = recordID
      self.captureID = captureID
      self.derivation = derivation
    }
  }

  @MainActor
  public enum CapturePortraitVerification {
    public static func load(
      id: UUID, captureID: UUID, sourceHash: String, store: CaptureEvidenceStore
    ) async throws -> [CapturePortraitArtifact] {
      let retained = try await CaptureSignedRecords.stage(id: id, captureID: captureID, store: store)
      let link = try JSONDecoder().decode(CapturePortraitCustody.Link.self, from: retained.manifest)
      guard retained.id == id, link.schemaVersion == 1, link.recordKind == "portraitExtraction",
        link.captureID == captureID, link.sourceSHA256 == sourceHash
      else { throw CaptureIntegrityError.integrityVerificationFailed }
      let record = try JSONDecoder().decode(
        CapturePortraitCustody.Record.self, from: retained.original)
      guard record.outcome == "completed", let extraction = record.extraction else { return [] }
      guard let parentID = link.derivativeRecordID, let parentHash = link.derivativeSHA256 else {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      let parent = try await CaptureDocumentStages.derivative(parentID, captureID: captureID,
        sourceHash: sourceHash, store: store)
      let parentLink = try JSONDecoder().decode(
        CaptureRecords.DerivativeManifest.self, from: parent.manifest)
      guard parent.id == parentID, parentLink.recordKind == "usabilityDerivative",
        parentLink.captureID == captureID, parentLink.sourceSHA256 == sourceHash,
        parentLink.derivation.sourceSHA256 == sourceHash,
        parentLink.derivation.outputSHA256 == parentHash,
        CaptureArtifactIntegrity.sha256(parent.original) == parentHash,
        extraction.schemaVersion == 1, extraction.sourceSHA256 == parentHash,
        extraction.assessment.candidates.count == record.crops.count
      else { throw CaptureIntegrityError.integrityVerificationFailed }
      var artifacts: [CapturePortraitArtifact] = []
      for (index, crop) in record.crops.enumerated() {
        let data = try await CaptureSignedRecords.stage(id: crop.recordID, captureID: captureID, store: store)
        let cropLink = try JSONDecoder().decode(
          CapturePortraitCustody.Link.self, from: data.manifest)
        guard cropLink.schemaVersion == 1, cropLink.recordKind == "portraitCrop",
          cropLink.captureID == captureID, cropLink.sourceSHA256 == sourceHash,
          cropLink.derivativeRecordID == parentID, cropLink.derivativeSHA256 == parentHash,
          cropLink.derivation == crop.derivation,
          crop.derivation.schemaVersion == 1, crop.derivation.sourceSHA256 == parentHash,
          crop.derivation.geometry == extraction.assessment.candidates[index],
          CaptureArtifactIntegrity.sha256(data.original) == crop.derivation.outputSHA256,
          let source = CGImageSourceCreateWithData(data.original as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == crop.derivation.outputPixelWidth,
          image.height == crop.derivation.outputPixelHeight
        else { throw CaptureIntegrityError.integrityVerificationFailed }
        artifacts.append(
          .init(recordID: crop.recordID, captureID: captureID, derivation: crop.derivation))
      }
      return artifacts
    }
  }
#endif
