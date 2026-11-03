#if os(iOS)
  import Foundation
  import CaptureEvidenceCustody

  /// Capture-bound app reads share acquisition discovery, including supplementary UI.
  /// Ordinary archive APIs keep external-writer discovery outside the live scope.
  @MainActor
  public enum CaptureRecordLookup {
    public static func recordIDs(
      captureID: UUID, recordKind: String? = nil, store: CaptureEvidenceStore
    ) async throws -> [UUID] {
      if let live = try await store.liveLookupSnapshot(captureIDs: [captureID]) {
        return live.matchingRecordIDs(captureID: captureID, recordKind: recordKind)
      }
      return try await store.matchingRecordIDs(captureID: captureID, recordKind: recordKind)
    }
  }
#endif
