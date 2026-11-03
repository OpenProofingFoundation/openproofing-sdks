#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import DocumentCaptureJournal

  extension CaptureSession {
    func admitTiltBudget(runID: UUID, generation: Int) -> Bool {
      guard let journal = journeyRecording else {
        // Production camera startup always supplies the required journal before optional guidance.
        finishTiltForBudget()
        return false
      }
      clearTiltBudgetWatch()
      tiltGuidance.budgetWatchID = runID
      // The presence policy's reserve when one is configured, else the fixed practice reserve.
      let policy = configuration.documentPresence?.tiltBudget ?? .provisionalV1
      let snapshot = journal.watchTiltBudget(owner: runID, policy: policy) { [weak self] snapshot in
        Task { @MainActor [weak self] in
          guard let self, self.cameraGeneration == generation,
            self.journeyRecording?.recordingID == snapshot.recordingID,
            self.tiltGuidance.budgetWatchID == runID,
            self.phase == .capturing, !self.tiltGuidance.releasedForSession,
            self.tiltGuidance.outcome != .completed, self.tiltGuidance.outcome != .skipped
          else { return }
          self.recordTiltBudget(snapshot, kind: "tilt_budget_reached")
          self.finishTiltForBudget()
        }
      }
      guard snapshot.tiltBudgetAvailable else {
        recordTiltBudget(snapshot, kind: "tilt_budget_declined")
        finishTiltForBudget()
        return false
      }
      recordTiltBudget(snapshot, kind: "tilt_budget_admitted")
      return true
    }

    func clearTiltBudgetWatch() {
      if let owner = tiltGuidance.budgetWatchID {
        journeyRecording?.clearTiltBudgetWatch(owner: owner)
      }
      tiltGuidance.budgetWatchID = nil
    }

    private func recordTiltBudget(
      _ snapshot: CaptureRecordingJournal.TiltBudgetSnapshot, kind: String
    ) {
      guard let data = try? JSONEncoder().encode(snapshot),
        let contextCode = String(data: data, encoding: .utf8)
      else { return }
      markRecording(kind, contextCode: contextCode)
    }

    private func finishTiltForBudget() {
      // Under a presence policy an exhausted reserve stops the front still instead of releasing it.
      if presenceGatesCapture { issue = .documentPresenceUnavailable }
      releaseTilt(reason: .recordingBudget, captureNow: false)
    }
  }

#endif
