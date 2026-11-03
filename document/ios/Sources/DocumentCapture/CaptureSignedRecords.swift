#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import CaptureEvidenceCustody
  import KenshikiEvidenceManifest

  /// Capture's strict publication boundary. AEAD authenticates storage; the signed manifest
  /// additionally binds the writer, workflow and source bytes. It is not server authorization.
  @MainActor
  public enum CaptureSignedRecords {
    public static func retainOriginal(id: UUID, original: Data, manifest: Data,
      store: CaptureEvidenceStore) async throws {
      let value = try originalManifest(id: id, original: original, manifest: manifest)
      guard let workflowID = value.workflowID else { throw CaptureIntegrityError.integrityVerificationFailed }
      let signing = try await store.requireSigningConfiguration()
      let context = try await signing.context(workflowID: workflowID, attemptID: id, observedAt: value.processedAt)
      let digest = CaptureArtifactIntegrity.sha256(original)
      let publication = try CaptureEvidenceManifest(context: context, recordID: id,
        recordKind: "captureOriginal", payloadSHA256: digest,
        capabilityManifestSHA256: CaptureArtifactIntegrity.sha256(manifest),
        sources: [.init(recordID: id, role: "captureOriginal", sha256: digest)],
        policyIDs: ["capture-original-publication.v1"])
      try await store.storeSigned(id: id, original: original, manifest: manifest,
        publication: publication, signing: signing)
    }

    public static func original(id: UUID, workflowID expectedWorkflowID: UUID? = nil,
      store: CaptureEvidenceStore) async throws -> SignedCaptureEvidenceRecord {
      // Routing metadata only selects the expected context; the signed read reauthenticates
      // this exact manifest and bytes, and an owner-provided workflow takes precedence.
      let candidate = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: await store.metadata(id: id))
      guard let workflowID = candidate.workflowID,
        expectedWorkflowID.map({ $0 == workflowID }) ?? true else {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      let signing = try await store.requireSigningConfiguration()
      let retained = try await store.readSigned(id: id, workflowID: workflowID, attemptID: id, signing: signing)
      _ = try originalManifest(id: id, original: retained.record.original, manifest: retained.record.manifest)
      guard retained.publication.manifest.recordKind == "captureOriginal" else {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      return retained
    }

    public static func stage(id: UUID, captureID: UUID, store: CaptureEvidenceStore) async throws
      -> CaptureEvidenceRecord {
      try await signedStage(id: id, captureID: captureID, store: store).record
    }

    public static func signedStage(id: UUID, captureID: UUID, store: CaptureEvidenceStore) async throws
      -> SignedCaptureEvidenceRecord {
      let parent = try await original(id: captureID, store: store)
      let signing = try await store.requireSigningConfiguration()
      let result = try await store.readSigned(id: id,
        workflowID: parent.publication.manifest.context.workflowID, attemptID: captureID, signing: signing)
      guard result.publication.manifest.context == parent.publication.manifest.context,
        result.publication.manifest.sources.contains(where: {
          $0.recordID == captureID && $0.sha256 == parent.publication.manifest.payloadSHA256
        }) else { throw CaptureIntegrityError.integrityVerificationFailed }
      return result
    }

    public static func retainStage(id: UUID, kind: String, captureID: UUID, original: Data,
      manifest: Data, store: CaptureEvidenceStore) async throws {
      let parent = try await self.original(id: captureID, store: store)
      let source = EvidenceArtifactReference(recordID: captureID, role: "captureOriginal",
        sha256: parent.publication.manifest.payloadSHA256)
      let output = EvidenceArtifactReference(recordID: id, role: kind,
        sha256: CaptureArtifactIntegrity.sha256(original))
      var sources = [source]
      var derivatives: [EvidenceArtifactReference] = []
      var lineage: [EvidenceLineageStep] = []
      if kind == "usabilityDerivative" {
        let link = try JSONDecoder().decode(CaptureRecords.DerivativeManifest.self, from: manifest)
        guard link.derivation.sourceSHA256 == source.sha256,
          link.derivation.outputSHA256 == output.sha256, link.derivation.supported else {
          throw CaptureIntegrityError.integrityVerificationFailed
        }
        derivatives = [output]
        lineage = [.init(inputRecordID: captureID, outputRecordID: id,
          transformationSHA256: CaptureArtifactIntegrity.sha256(try CaptureDocumentStages.encode(link.derivation)))]
      } else if kind == "portraitCrop" {
        let link = try JSONDecoder().decode(CapturePortraitCustody.Link.self, from: manifest)
        guard let parentID = link.derivativeRecordID, let parentHash = link.derivativeSHA256,
          let derivation = link.derivation else { throw CaptureIntegrityError.integrityVerificationFailed }
        let prepared = try await stage(id: parentID, captureID: captureID, store: store)
        guard CaptureArtifactIntegrity.sha256(prepared.original) == parentHash else {
          throw CaptureIntegrityError.integrityVerificationFailed
        }
        sources.append(.init(recordID: parentID, role: "usabilityDerivative", sha256: parentHash))
        derivatives = [output]
        lineage = [.init(inputRecordID: parentID, outputRecordID: id,
          transformationSHA256: CaptureArtifactIntegrity.sha256(try CaptureDocumentStages.encode(derivation)))]
      } else {
        // Analysis/report payloads are source-linked observations. They are not image transforms.
        sources.append(output)
      }
      let publication = try CaptureEvidenceManifest(context: parent.publication.manifest.context,
        recordID: id, recordKind: kind, payloadSHA256: output.sha256,
        capabilityManifestSHA256: CaptureArtifactIntegrity.sha256(manifest),
        sources: sources, derivatives: derivatives, lineage: lineage,
        policyIDs: ["capture-stage-publication.v1"])
      try await store.storeSigned(id: id, original: original, manifest: manifest,
        publication: publication, signing: store.requireSigningConfiguration())
    }

    private static func originalManifest(id: UUID, original: Data, manifest: Data) throws -> CaptureRecords.Manifest {
      let value = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: manifest)
      guard value.schemaVersion == 1, value.captureID == id, value.workflowID != nil,
        value.fidelity.sha256 == CaptureArtifactIntegrity.sha256(original),
        value.fidelity.fileByteCount == original.count else {
        throw CaptureIntegrityError.integrityVerificationFailed
      }
      return value
    }
  }
#endif
