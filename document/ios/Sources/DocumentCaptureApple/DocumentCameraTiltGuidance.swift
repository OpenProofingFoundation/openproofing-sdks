import Foundation

extension DocumentCamera {
  /// Obtain after camera start and before begin. Values are latest-only, scoped by runID/revision.
  /// Stop/failure finishes the subscription; the caller fences any final buffered old value.
  public var tiltGuidanceUpdates: AsyncStream<DocumentTiltPresentation> {
    tiltGuidanceDelivery.stream
  }

  /// Optional movement observation; it neither suspends manual shutter admission nor fires a still.
  /// New live attempts default to fresh-detection V2. V1 requires explicit legacy selection.
  public func beginTiltGuidance(
    runID: UUID, configuration: DocumentTiltConfiguration = .provisionalV2
  ) async throws -> DocumentTiltPresentation {
    try Task.checkCancellation()
    guard isRunning, !isCaptureInFlight, tiltGuidanceAttemptID == nil, configuration.valid,
      let controller = sessionController as? any CameraSessionTiltGuidanceControlling
    else { throw PhotoCaptureError.cameraNotReady }
    let operationGeneration = generation
    let cancellation = DocumentTiltStartCancellation()
    tiltGuidanceAttemptID = runID
    tiltGuidanceDelivery.begin(runID: runID)
    do {
      let result = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          controller.beginTiltGuidance(
            runID: runID, configuration: configuration, cancellation: cancellation
          ) {
            continuation.resume(with: $0)
          }
        }
      } onCancel: {
        cancellation.cancel()
        controller.endTiltGuidance(runID: runID, reason: .cancelled) {}
      }
      try ensureCurrent(operationGeneration)
      guard tiltGuidanceAttemptID == runID else { throw CancellationError() }
      return result
    } catch {
      await endTiltGuidance(runID: runID, reason: .cancelled)
      throw error
    }
  }

  /// ID-matched native-controls release; stale cleanup cannot stop a replacement run.
  /// Returns after source invalidation and readiness reset, not after ordered evidence archival.
  /// Archival remains in the analyzer drain used by stopAndWait and sink detachment. A new optional
  /// guidance begin waits within the existing native adjustment timeout for that prior-run drain,
  /// then rechecks native admission. Cancellation and lifecycle changes revoke the waiting begin.
  public func endTiltGuidance(runID: UUID, reason: DocumentTiltReason = .cancelled) async {
    if tiltGuidanceAttemptID == runID { tiltGuidanceAttemptID = nil }
    guard let controller = sessionController as? any CameraSessionTiltGuidanceControlling else {
      return
    }
    await withCheckedContinuation { continuation in
      controller.endTiltGuidance(runID: runID, reason: reason) { continuation.resume() }
    }
  }
}

extension DocumentCamera {
  func activateTiltGuidanceDelivery(generation operationGeneration: Int) {
    tiltGuidanceDelivery.activate(generation: operationGeneration)
    (sessionController as? any CameraSessionTiltGuidanceControlling)?
      .setTiltGuidanceHandler { [tiltGuidanceDelivery] value in
        tiltGuidanceDelivery.yield(value, generation: operationGeneration)
      }
  }
}
