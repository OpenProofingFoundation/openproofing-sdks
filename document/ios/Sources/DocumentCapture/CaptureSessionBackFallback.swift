#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import CaptureEvidenceCustody

  extension CaptureSession {
    /// Start another side without replacing the retained front or deleting earlier attempts.
    /// The pending-back selection is committed before camera admission. Cancellation after
    /// publication leaves a recoverable pending step; it never rolls back encrypted originals.
    /// Startup remains asynchronous: await waitUntilIdle() and inspect ready/issue to present it.
    public func beginBackCapture(frontCaptureID: UUID, workflowID: UUID) async throws {
      guard !erasing, !busy, operation == nil, activeCaptureAttempt == nil,
        originalState == .idle
      else { throw PhotoCaptureError.cameraNotReady }
      try await stopAndWait()
      let generation = cameraGeneration
      let store = try openCustody()
      let front = try await CaptureJourneyRecovery.retainedFront(
        captureID: frontCaptureID, workflowID: workflowID, store: store)
      try Task.checkCancellation()
      guard generation == cameraGeneration, !erasing, !busy, operation == nil else {
        throw CancellationError()
      }
      let progress = CaptureJourneyProgress(store: store, now: configuration.clock.now)
      let checkpoint = try await progress.commit(
        .init(
          workflowID: workflowID, profile: front.profile.rawValue,
          stage: .back, frontID: frontCaptureID))
      try Task.checkCancellation()
      guard generation == cameraGeneration, !erasing, !busy, operation == nil else {
        throw CancellationError()
      }
      try restoreVerifiedOriginal(front.bound(to: checkpoint))
      transitionToBack()
    }
  }
#endif
