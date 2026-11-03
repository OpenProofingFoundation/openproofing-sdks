import Foundation

/// Acquisition-local routing observations, not a complete directory index or custody proof.
/// Stores no pixel payloads or full manifests. Ordinary queries never consult this catalog.
struct CaptureEvidenceLiveLookup {
  let id: UUID
  var captureIDs: Set<UUID> = []
  private var candidates: [UUID: CaptureEvidenceLookupSnapshot.Candidate] = [:]

  init(id: UUID, captureIDs: Set<UUID>, seed: CaptureEvidenceLookupSnapshot) {
    self.id = id
    self.captureIDs = captureIDs
    candidates = Dictionary(uniqueKeysWithValues: seed.candidates.map { ($0.id, $0) })
  }

  mutating func record(id: UUID, manifest: Data) {
    guard let fields = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any],
      let text = fields["captureID"] as? String, let captureID = UUID(uuidString: text),
      captureIDs.contains(captureID)
    else { return }
    candidates[id] = .init(
      id: id, captureID: captureID, recordKind: fields["recordKind"] as? String)
  }

  func snapshot(captureIDs requested: Set<UUID>) throws -> CaptureEvidenceLookupSnapshot {
    guard requested.isSubset(of: captureIDs) else {
      throw CaptureEvidenceStoreError.outsideLiveLookupScope
    }
    return CaptureEvidenceLookupSnapshot(
      candidates: candidates.values.filter {
        requested.contains($0.captureID)
      })
  }
}
