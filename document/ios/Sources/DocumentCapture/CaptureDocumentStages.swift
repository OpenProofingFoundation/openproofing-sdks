#if os(iOS)
  import CryptoKit
  import Foundation
  import DocumentCaptureApple
  import CaptureEvidenceCustody

  /// Verified stage reuse. Index entries select candidates; their payloads and links decide reuse.
  @MainActor
  public enum CaptureDocumentStages {
    public typealias Extract = @Sendable (Data) async throws -> ArtifactExtraction

    public nonisolated static func extract(_ data: Data) async throws -> ArtifactExtraction {
      try await ArtifactExtraction.extractAsync(original: data)
    }

    public typealias AfterWrite = (String, UUID) async throws -> Void

    public static func records(
      _ kind: String, captureID: UUID, sourceHash: String, store: CaptureEvidenceStore,
      lookup: CaptureEvidenceLookupSnapshot? = nil
    ) async throws -> [CaptureEvidenceRecord] {
      var result: [CaptureEvidenceRecord] = []
      let ids: [UUID]
      if let lookup {
        ids = lookup.matchingRecordIDs(captureID: captureID, recordKind: kind)
      } else {
        ids = try await CaptureRecordLookup.recordIDs(
          captureID: captureID, recordKind: kind, store: store)
      }
      for id in ids {
        try Task.checkCancellation()
        let record = try await CaptureSignedRecords.stage(id: id, captureID: captureID, store: store)
        let link = try JSONDecoder().decode(
          CaptureRecords.ExtractionManifest.self, from: record.manifest)
        guard link.schemaVersion == 1, link.captureID == captureID,
          link.recordKind == kind, link.sourceSHA256 == sourceHash
        else {
          throw CaptureIntegrityError.integrityVerificationFailed
        }
        result.append(record)
      }
      return result
    }

    public static func derivative(
      _ id: UUID, captureID: UUID, sourceHash: String, store: CaptureEvidenceStore
    ) async throws
      -> CaptureEvidenceRecord
    {
      let record = try await CaptureSignedRecords.stage(id: id, captureID: captureID, store: store)
      let link = try JSONDecoder().decode(
        CaptureRecords.DerivativeManifest.self, from: record.manifest)
      guard link.schemaVersion == 1, link.recordKind == "usabilityDerivative",
        link.captureID == captureID,
        link.sourceSHA256 == sourceHash, link.derivation.supported,
        link.derivation.operation != .contextCrop,
        link.derivation.sourceSHA256 == sourceHash,
        CaptureArtifactIntegrity.sha256(record.original) == link.derivation.outputSHA256
      else {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      return record
    }

    /// Loads the existing SDK preparation after verifying its custody and source link.
    public static func preparedImage(
      captureID: UUID, sourceHash: String, store: CaptureEvidenceStore
    ) async throws -> DerivedDocumentImage? {
      guard let usability = try await usability(captureID: captureID, sourceHash: sourceHash, store: store),
        let id = usability.derivativeRecordID else { return nil }
      let record = try await derivative(id, captureID: captureID, sourceHash: sourceHash, store: store)
      let link = try JSONDecoder().decode(CaptureRecords.DerivativeManifest.self, from: record.manifest)
      return DerivedDocumentImage(data: record.original, derivation: link.derivation)
    }

    public static func usability(captureID: UUID, sourceHash: String, store: CaptureEvidenceStore)
      async throws
      -> CaptureUsability?
    {
      var accepted: CaptureUsability?
      for record in try await records(
        "usability", captureID: captureID, sourceHash: sourceHash, store: store)
      {
        let result = try JSONDecoder().decode(CaptureUsability.self, from: record.original)
        guard result.schemaVersion == 1 else {
          throw CaptureIntegrityError.integrityVerificationFailed
        }
        if let id = result.derivativeRecordID {
          _ = try await derivative(id, captureID: captureID, sourceHash: sourceHash, store: store)
        }
        if let accepted, try encode(accepted) != encode(result) {
          throw CaptureIntegrityError.integrityVerificationFailed
        }
        accepted = result
      }
      return accepted
    }

    public static func extraction(_ record: CaptureEvidenceRecord, source: Data) throws
      -> ArtifactExtraction?
    {
      let result = try JSONDecoder().decode(ArtifactExtraction.self, from: record.original)
      guard [1, 2, 3, 4].contains(result.schemaVersion),
        result.fidelity.sha256 == CaptureArtifactIntegrity.sha256(source),
        result.fidelity.fileByteCount == source.count
      else {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      if let structured = result.structuredDocument,
        structured.sourceSHA256 != result.fidelity.sha256
      {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      return result.schemaVersion == 4 ? result : nil
    }

    /// Newly computed observations must use this capability's current schema and exact source.
    static func validateCurrentExtraction(_ result: ArtifactExtraction, source: Data) throws {
      guard result.schemaVersion == 4,
        result.fidelity.sha256 == CaptureArtifactIntegrity.sha256(source),
        result.fidelity.fileByteCount == source.count
      else { throw CaptureIntegrityError.integrityVerificationFailed }
      if let structured = result.structuredDocument,
        structured.sourceSHA256 != result.fidelity.sha256
      { throw CaptureIntegrityError.integrityVerificationFailed }
    }

    /// Content-derived identity makes replay of an interrupted write idempotent.
    public static func retain(
      kind: String, captureID: UUID, original: Data, manifest: Data, store: CaptureEvidenceStore,
      afterWrite: AfterWrite = { _, _ in }
    ) async throws -> UUID {
      let binding = Data((captureID.uuidString + "/" + kind + "/").utf8) + original + manifest
      let bytes = Array(SHA256.hash(data: binding).prefix(16))
      let id = UUID(
        uuid: (
          bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
          bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
      do {
        try await CaptureSignedRecords.retainStage(id: id, kind: kind, captureID: captureID,
          original: original, manifest: manifest, store: store)
      } catch CaptureEvidenceStoreError.duplicate {
        let existing = try await CaptureSignedRecords.stage(id: id, captureID: captureID, store: store)
        guard existing.original == original, existing.manifest == manifest else {
          throw CaptureIntegrityError.integrityVerificationFailed
        }
      }
      try await afterWrite(kind, id)
      try Task.checkCancellation()
      return id
    }

    public nonisolated static func encode<T: Encodable>(_ value: T) throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(value)
    }
  }
#endif
