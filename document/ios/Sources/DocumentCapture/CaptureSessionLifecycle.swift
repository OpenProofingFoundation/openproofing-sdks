#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import CaptureEvidenceCustody
  import DocumentCaptureJournal

  extension CaptureSession {
    func beginContinuousRecording(camera: DocumentCamera) async throws {
      guard let store else { throw PhotoCaptureError.cameraNotReady }
      let generation = cameraGeneration
      let journal = try await CaptureRecordingJournal.start(
        workflowID: workflowID, store: store,
        clock: configuration.clock, policy: configuration.recordingPolicy)
      let dependencies = Set([selectedCaptureID, retainedFrontCaptureID].compactMap { $0 }).union(
        processingQueue.captureIDs)
      do {
        try await store.beginLiveLookupScope(id: journal.recordingID, seedCaptureIDs: dependencies)
      } catch {
        _ = try? await journal.finish(reason: "lookup_scope_start_failed")
        throw error
      }
      guard !Task.isCancelled, generation == cameraGeneration, phase != .inactive else {
        _ = try? await journal.finish(reason: "cancelled_during_start")
        await store.endLiveLookupScope(id: journal.recordingID)
        throw CancellationError()
      }
      journeyRecording = journal
      recordingState = .recording
      let identifier = journal.recordingID
      journal.setStatusHandler { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, let current = self.journeyRecording,
            current.recordingID == identifier
          else { return }
          if current.status != "recording" { self.suspendTerminatedRecording() }
        }
      }
      camera.setJourneyRecordingSink(journal)
      markRecording("document_capture_started")
    }

    public func markRecording(_ kind: String, contextCode: String? = nil) {
      journeyRecording?.appendEvent(
        .init(
          kind: kind, hostTimeSeconds: configuration.clock.uptime(),
          sessionID: camera.sessionID.rawValue.uuidString, contextCode: contextCode))
    }

    func finishContinuousRecording(reason: String, stopAfterCapture: Bool = false) {
      guard let journal = journeyRecording, let store else { return }
      journeyRecording = nil
      let activeCamera = camera
      recordingState = .settling
      let previous = recordingSettlement
      let pendingCapture = operation
      recordingSettlement = Task { [weak self] in
        await previous?.value
        await activeCamera.detachJourneyRecordingSink()
        await pendingCapture?.value
        if stopAfterCapture { activeCamera.stop() }
        do {
          let result = try await journal.finish(reason: reason)
          await store.endLiveLookupScope(id: journal.recordingID)
          guard let self, self.journeyRecording == nil else { return }
          self.recordingState = result.status == "complete" ? .complete : .partial
          self.onEvent(.recordingSettled(result))
        } catch {
          await store.endLiveLookupScope(id: journal.recordingID)
          guard let self, self.journeyRecording == nil else { return }
          self.recordingState = .failed
        }
      }
    }

    @discardableResult
    func requireRecording(_ identifier: UUID? = nil, camera: DocumentCamera) throws -> UUID {
      guard let current = journeyRecording, current.status == "recording",
        identifier == nil || current.recordingID == identifier
      else {
        camera.stop()
        throw CancellationError()
      }
      return current.recordingID
    }

    public func enterReview() {
      stopTiltObservation()
      phase = .reviewing
      disarmAutomaticCapture()
      camera.setCaptureAdmissionEnabled(false)
      markRecording("capture_review")
    }

    public func transitionToBack() {
      guard !busy, operation == nil, profile.twoSided, let selectedCaptureID else { return }
      retainedFrontCaptureID = selectedCaptureID
      transitionToBack(profile.backProfile)
    }

    func transitionToBack(_ next: CaptureRecords.Profile) {
      guard !busy, operation == nil else { return }
      guard !(next == .licenseBack && configuration.licenseBackCaptureMode == .livePDF417),
        ready, let recording = journeyRecording, recording.status == "recording" else {
        stop(cancelProcessing: false)
        profile = next
        start()
        return
      }
      stopTiltObservation()
      phase = .preparingBack
      disarmAutomaticCapture()
      camera.setCaptureAdmissionEnabled(false)
      markRecording("back_requested")
      profile = next
      let generation = cameraGeneration
      let activeCamera = camera
      busy = true
      operation = Task { [self] in
        defer { finishOperation() }
        do {
          try await analysisUpdater(
            activeCamera,
            Self.analysisConfiguration(profile: next, tuning: configuration.tuning))
          try Task.checkCancellation()
          guard generation == cameraGeneration, ready, phase == .preparingBack,
            journeyRecording?.recordingID == recording.recordingID,
            journeyRecording?.status == "recording"
          else { return }
          resetCaptureCoordinator()
          phase = .capturing
          activeCamera.setCaptureAdmissionEnabled(true)
          prepareAutomaticCapture()
          markRecording("back_capture_armed")
        } catch {
          guard generation == cameraGeneration else { return }
          issue = .analysisTransitionFailed
          stop()
        }
      }
    }

    public func retake(_ profile: CaptureRecords.Profile, preserveProcessing: Bool = false) {
      guard !busy, operation == nil else { return }
      stop(cancelProcessing: !preserveProcessing)
      self.profile = profile
      start()
    }

    func suspendTerminatedRecording() {
      startup = nil
      stopTiltObservation()
      geometryTask?.cancel()
      camera.setCaptureAdmissionEnabled(false)
      let finishingPhoto = activeCaptureAttempt != nil
      let notifyTermination = !finishingPhoto && issue != .recordingTerminated
      if !finishingPhoto { camera.stop() }
      ready = false
      phase = selectedCaptureID == nil ? .inactive : .reviewing
      disarmAutomaticCapture()
      issue = finishingPhoto ? nil : .recordingTerminated
      finishContinuousRecording(reason: "recording_terminated", stopAfterCapture: finishingPhoto)
      if notifyTermination { onEvent(.issue(.recordingTerminated)) }
    }

    public func completeDocumentRecording() {
      startup = nil
      stopTiltObservation()
      geometryTask?.cancel()
      markRecording("document_capture_completed")
      phase = .completed
      ready = false
      disarmAutomaticCapture()
      camera.setCaptureAdmissionEnabled(false)
      camera.stop()
      finishContinuousRecording(reason: "completed")
    }
  }
#endif
