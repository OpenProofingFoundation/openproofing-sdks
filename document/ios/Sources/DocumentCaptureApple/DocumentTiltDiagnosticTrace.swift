#if DEBUG
  import Foundation

  /// Opt-in diagnostic projection only. The complete event is archived before this call.
  enum DocumentTiltDiagnosticTrace {
    static func record(_ update: DocumentTiltUpdate, sink: @Sendable (Data) -> Void) {
      guard let event = update.event
      else { return }
      let facts = DocumentTiltDiagnosticFacts(event: event, presentation: update.presentation)
      guard let bytes = try? JSONEncoder().encode(facts),
        let json = String(data: bytes, encoding: .utf8)
      else { return }
      sink(Data("IDENTITY_EVIDENCE_TILT \(json)\n".utf8))
    }
  }

  /// Deliberate scalar allowlist: no pixels, corners, OCR, or identity fields.
  private struct DocumentTiltDiagnosticFacts: Encodable {
    let runID: UUID
    let revision: UInt64
    let configurationVersion: String
    let phase: DocumentTiltPhase
    let reason: DocumentTiltReason?
    let captureTimestamp: DocumentCaptureClockTimestamp?
    let rawLogRatio: Double?
    let correctedLogRatio: Double?
    let signedDelta: Double?
    let baseline: DocumentTiltBaseline?
    let credited: Bool
    let associatedRefresh: Bool
    let analysisSequence: UInt64?
    let geometryRevision: UInt64?
    let availability: DocumentLiveGeometryObservation.Availability?
    let method: String?
    let requestFacts: [DocumentGeometryRequestFact]?
    let transition: DocumentLiveGeometryObservation.Transition?
    let trackingOutcome: DocumentLiveGeometryObservation.TrackingOutcome?
    let resetReasons: [DocumentLiveGeometryObservation.ResetReason]?
    let precedingAnalysisTimestamp: DocumentCaptureClockTimestamp?
    let consecutiveObservations: Int
    let dwellSeconds: Double

    init(event: DocumentTiltEvidenceEvent, presentation: DocumentTiltPresentation) {
      runID = event.runID
      revision = event.revision
      configurationVersion = event.configurationVersion
      phase = event.phase
      reason = event.reason
      captureTimestamp = event.captureTimestamp
      rawLogRatio = event.rawLogRatio
      correctedLogRatio = event.correctedLogRatio
      signedDelta = event.signedDelta
      baseline = event.baseline
      credited = event.credited
      associatedRefresh = event.associatedRefresh
      analysisSequence = event.observation?.analysisSequence
      geometryRevision = event.observation?.geometryRevision
      availability = event.observation?.availability
      method = event.observation?.geometry.method
      requestFacts = event.observation?.requestFacts
      transition = event.observation?.tracker.transition
      trackingOutcome = event.observation?.tracker.trackingOutcome
      resetReasons = event.observation?.tracker.resetReasons
      precedingAnalysisTimestamp = event.observation?.tracker.precedingAnalysisTimestamp
      consecutiveObservations = presentation.consecutiveObservations
      dwellSeconds = presentation.dwellSeconds
    }
  }
#endif
