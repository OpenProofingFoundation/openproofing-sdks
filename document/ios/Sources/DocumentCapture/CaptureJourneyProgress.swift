import Foundation
import CaptureEvidenceCustody

/// An immutable host intent. The SDK owns publication and retry; the host owns the
/// navigation action that may run only after publication succeeds.
public struct CaptureJourneyIntent: Sendable, Equatable {
  public let workflowID: UUID
  public let profile: String
  public let stage: CaptureJourneyCheckpoint.Stage
  public let frontID: UUID?
  public let backID: UUID?
  public let portraitID: UUID?
  public let selfieID: UUID?
  public let comparisonID: UUID?

  public init(
    workflowID: UUID, profile: String, stage: CaptureJourneyCheckpoint.Stage,
    frontID: UUID? = nil, backID: UUID? = nil, portraitID: UUID? = nil,
    selfieID: UUID? = nil, comparisonID: UUID? = nil
  ) {
    self.workflowID = workflowID
    self.profile = profile
    self.stage = stage
    self.frontID = frontID
    self.backID = backID
    self.portraitID = portraitID
    self.selfieID = selfieID
    self.comparisonID = comparisonID
  }

  func checkpoint(revision: UInt64, date: Date) -> CaptureJourneyCheckpoint {
    .init(
      workflowID: workflowID, revision: revision, profile: profile, nextStage: stage,
      frontID: frontID, backID: backID, portraitID: portraitID, selfieID: selfieID,
      comparisonID: comparisonID, updatedAt: date)
  }
}

public enum CaptureJourneyProgressError: Error {
  case transitionInProgress, retryRequired, noPendingTransition, invalidated
}

/// Extracted from JourneyCheckpointPersistence: freeze selections before any await,
/// serialize revision admission, and retry an identical snapshot after uncertain publication.
@MainActor
public final class CaptureJourneyProgress {
  public enum State: Sendable { case idle, saving, retryRequired }
  public private(set) var state: State = .idle
  public private(set) var checkpoint: CaptureJourneyCheckpoint?
  private let store: CaptureEvidenceStore
  private let now: @Sendable () -> Date
  private var generation = UUID()
  private var intent: CaptureJourneyIntent?
  private var pending: (value: CaptureJourneyCheckpoint, expected: UInt64?)?
  private var operationActive = false

  public init(store: CaptureEvidenceStore, now: @escaping @Sendable () -> Date) {
    self.store = store
    self.now = now
  }

  public func commit(_ intent: CaptureJourneyIntent) async throws -> CaptureJourneyCheckpoint {
    guard !operationActive else { throw CaptureJourneyProgressError.transitionInProgress }
    guard self.intent == nil else { throw CaptureJourneyProgressError.retryRequired }
    self.intent = intent
    return try await perform()
  }

  public func retry() async throws -> CaptureJourneyCheckpoint {
    guard !operationActive else { throw CaptureJourneyProgressError.transitionInProgress }
    guard intent != nil else { throw CaptureJourneyProgressError.noPendingTransition }
    return try await perform()
  }

  /// Invalidates publication to the caller, not an already committed evidence snapshot.
  public func invalidate() {
    generation = UUID()
    intent = nil
    pending = nil
    checkpoint = nil
    state = .idle
  }

  private func perform() async throws -> CaptureJourneyCheckpoint {
    guard let intent else { throw CaptureJourneyProgressError.noPendingTransition }
    operationActive = true
    state = .saving
    let generation = generation
    defer { operationActive = false }
    do {
      if pending == nil {
        let latest = try await store.journeyCheckpoint(workflowID: intent.workflowID)
        try Task.checkCancellation()
        guard generation == self.generation else { throw CaptureJourneyProgressError.invalidated }
        guard latest?.revision != UInt64.max else {
          throw CaptureJourneyCheckpointError.invalidCheckpoint
        }
        pending = (
          intent.checkpoint(revision: (latest?.revision ?? 0) + 1, date: now()), latest?.revision
        )
      }
      guard let pending else { throw CaptureJourneyProgressError.noPendingTransition }
      try Task.checkCancellation()
      try await store.saveJourneyCheckpoint(pending.value, expectedRevision: pending.expected)
      guard generation == self.generation else { throw CaptureJourneyProgressError.invalidated }
      checkpoint = pending.value
      self.pending = nil
      self.intent = nil
      state = .idle
      return pending.value
    } catch {
      if generation == self.generation { state = .retryRequired }
      throw error
    }
  }
}
