import Foundation

/// Durable host selections and next action. Evidence remains in immutable lake records.
public struct CaptureJourneyCheckpoint: Codable, Equatable, Sendable {
  public enum Stage: String, Codable, Sendable {
    case front, back, review, portrait, selfie, results
  }

  public let workflowID: UUID
  public let revision: UInt64
  public let profile: String
  public let nextStage: Stage
  public let frontID: UUID?
  public let backID: UUID?
  public let portraitID: UUID?
  public let selfieID: UUID?
  public let comparisonID: UUID?
  public let updatedAt: Date

  public var valid: Bool {
    let identities = [frontID, backID, portraitID, selfieID, comparisonID].compactMap { $0 }
    guard revision > 0, !profile.isEmpty, Set(identities).count == identities.count else {
      return false
    }
    if nextStage == .front { return identities.isEmpty }
    if nextStage == .back { return frontID != nil && identities.count == 1 }
    guard frontID != nil || backID != nil else { return false }
    // Acquisition does not require optional portrait extraction or comparison.
    // A comparison reference still requires both of its source selections.
    if comparisonID != nil { return selfieID != nil && portraitID != nil }
    return true
  }

  public init(
    workflowID: UUID, revision: UInt64, profile: String, nextStage: Stage,
    frontID: UUID? = nil, backID: UUID? = nil, portraitID: UUID? = nil,
    selfieID: UUID? = nil, comparisonID: UUID? = nil, updatedAt: Date
  ) {
    self.workflowID = workflowID
    self.revision = revision
    self.profile = profile
    self.nextStage = nextStage
    self.frontID = frontID
    self.backID = backID
    self.portraitID = portraitID
    self.selfieID = selfieID
    self.comparisonID = comparisonID
    self.updatedAt = updatedAt
  }
}

public enum CaptureJourneyCheckpointError: Error {
  case staleRevision, invalidCheckpoint
}

