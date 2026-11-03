import CaptureEvidenceCustody
import Foundation

extension CaptureEvidenceStore {
  /// The capability validates selections; shared custody binds and stores opaque bytes.
  public func journeyCheckpoint(workflowID: UUID) throws -> CaptureJourneyCheckpoint? {
    do {
      guard let retained = try checkpoint(workflowID: workflowID) else { return nil }
      let value = try JSONDecoder().decode(CaptureJourneyCheckpoint.self, from: retained.payload)
      guard value.workflowID == workflowID, value.revision == retained.revision, value.valid else {
        throw CaptureJourneyCheckpointError.invalidCheckpoint
      }
      return value
    } catch is DecodingError {
      throw CaptureJourneyCheckpointError.invalidCheckpoint
    } catch CaptureCheckpointError.invalidCheckpoint {
      throw CaptureJourneyCheckpointError.invalidCheckpoint
    }
  }

  /// Foundation owns revision comparison, encryption, locking and publication fencing.
  public func saveJourneyCheckpoint(
    _ value: CaptureJourneyCheckpoint, expectedRevision: UInt64?
  ) throws {
    guard value.valid else { throw CaptureJourneyCheckpointError.invalidCheckpoint }
    do {
      if try journeyCheckpoint(workflowID: value.workflowID) == value { return }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let retained = try CaptureCheckpointRecord(
        workflowID: value.workflowID, revision: value.revision,
        payload: encoder.encode(value))
      try saveCheckpoint(retained, expectedRevision: expectedRevision)
    } catch CaptureCheckpointError.staleRevision {
      throw CaptureJourneyCheckpointError.staleRevision
    } catch CaptureCheckpointError.invalidCheckpoint {
      throw CaptureJourneyCheckpointError.invalidCheckpoint
    }
  }
}
