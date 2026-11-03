import Foundation

/// Immutable candidate discovery from one scoped reconciliation. This is not an
/// evidence or filesystem transaction: later publications require a new snapshot,
/// and selected records must still be authenticated with `read` and link checks.
/// Filtering this value performs no filesystem work and retains no image payloads.
public struct CaptureEvidenceLookupSnapshot: Sendable {
  struct Candidate: Sendable {
    let id: UUID
    let captureID: UUID
    let recordKind: String?
  }
  let candidates: [Candidate]

  init(candidates: [Candidate]) { self.candidates = candidates }

  init(entries: [UUID: CaptureEvidenceIndex.Entry], captureIDs: Set<UUID>) {
    candidates = entries.compactMap { id, entry in
      guard let captureID = entry.captureID, captureIDs.contains(captureID) else { return nil }
      return Candidate(id: id, captureID: captureID, recordKind: entry.recordKind)
    }
  }

  /// Nil filters match all candidates within the snapshot's original capture scope.
  public func matchingRecordIDs(captureID: UUID? = nil, recordKind: String? = nil) -> [UUID] {
    candidates.filter {
      (captureID == nil || $0.captureID == captureID)
        && (recordKind == nil || $0.recordKind == recordKind)
    }.map(\.id).sorted { $0.uuidString < $1.uuidString }
  }
}
