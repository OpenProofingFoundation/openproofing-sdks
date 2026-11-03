#if os(iOS)
  import Foundation
  import DocumentSDK
  import CaptureEvidenceCustody

  /// Durable source-bound acknowledgement; a journal reference alone is not binding proof.
  @MainActor
  public enum CaptureStillBindingCustody {
    public enum Outcome: String, Codable { case bound, failed }
    struct Record: Codable, Equatable {
      let schemaVersion: Int
      let recordingID: UUID
      let outcome: Outcome
    }
    static let kind = "journeyStillBinding"

    public static func retain(
      captureID: UUID, sourceHash: String, recordingID: UUID,
      outcome: Outcome, store: CaptureEvidenceStore
    ) async throws {
      let link = CaptureRecords.ExtractionManifest(
        schemaVersion: 1,
        recordKind: kind, captureID: captureID, sourceSHA256: sourceHash)
      _ = try await CaptureDocumentStages.retain(
        kind: kind, captureID: captureID,
        original: CaptureDocumentStages.encode(
          Record(
            schemaVersion: 1,
            recordingID: recordingID, outcome: outcome)),
        manifest: CaptureDocumentStages.encode(link), store: store)
    }

  }
#endif
