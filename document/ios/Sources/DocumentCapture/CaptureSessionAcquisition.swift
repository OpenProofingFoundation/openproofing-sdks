#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import DocumentSDK
  import CaptureEvidenceCustody
  import DocumentCaptureJournal

  extension CaptureSession {
    func capture(observation: DocumentCaptureQualityObservation?, livePDF417Candidate: String? = nil) {
      guard !erasing, phase == .capturing, ready, !busy, operation == nil, !nativeControlsBusy,
        let store
      else { return }
      // The presence gate, at the one place a still is admitted (S-02, RFC-0002 §4.5).
      guard !presenceGatesCapture || tiltGuidance.outcome == .completed else {
        issue = .documentPresenceRequired
        return
      }
      if configuration.requiresLocation { location.startUpdatesIfAuthorized() }
      let assertion = location.assertion()
      guard !configuration.requiresLocation || assertion != nil else {
        issue = .locationRequired
        return
      }
      guard let journal = journeyRecording, journal.status == "recording",
        let milestone = journal.reserveMilestone()
      else {
        suspendTerminatedRecording()
        return
      }
      disarmAutomaticCapture()
      camera.updateCaptureFeedback(.capturing)
      busy = true
      originalState = .capturing
      let chosenProfile = profile
      let activeCamera = camera
      let generation = cameraGeneration
      let request = DocumentCaptureRequest(
        side: chosenProfile.side,
        qualityGate: livePDF417Candidate != nil ? .livePDF417AutoCapture
          : (observation == nil ? .operatorInitiatedAdvisory : .qualityDrivenAutoCapture),
        requiredObservationIdentity: observation.map(DocumentCaptureObservationIdentity.init),
        livePDF417Candidate: livePDF417Candidate, locationAssertion: assertion)
      activeCaptureAttempt = request.attemptID
      // Freeze workflow linkage at admission: later host navigation cannot relink the original.
      let workflow = workflowID
      let precedingFront = retainedFrontCaptureID
      let revision = journeyRevision
      let presence = presenceRecord
      operation = Task { [self] in
        defer {
          journal.cancelMilestone(milestone)
          activeCaptureAttempt = nil
          originalState = .idle
          finishOperation()
        }
        do {
          let photo = try await capturePhoto(activeCamera, request)
          location.stop()
          originalState = .retaining
          try await store.admitLiveCapture(
            captureID: request.attemptID, scopeID: journal.recordingID)
          do {
            try await CaptureOriginalCustody.retain(
              photo, captureID: request.attemptID,
              profile: chosenProfile, workflowID: workflow, precedingFrontCaptureID: precedingFront,
              journeyRevision: revision, tuning: configuration.tuning, store: store,
              hostTime: configuration.clock.uptime, recording: journal,
              recordingMilestone: milestone, livePDF417Candidate: livePDF417Candidate,
              documentPresence: presence)
          } catch CaptureOriginalPersistenceError.recordingBindingFailed {
            if generation == cameraGeneration { issue = .originalSavedBindingFailed }
          }
          // Retention remains observable after cancellation without selecting a stale UI result.
          let identity = CaptureSessionAttemptIdentity(
            workflowID: workflow,
            captureID: request.attemptID, generation: generation)
          onEvent(.originalRetained(identity: identity, profile: chosenProfile))
          guard generation == cameraGeneration else { return }
          recoveryCaptureID = request.attemptID
          selectedCaptureID = request.attemptID
          camera.updateCaptureFeedback(.stored)
          if chosenProfile.backSide { completeDocumentRecording() } else { enterReview() }
          // Barcode reading uses the retained original directly, without OCR or
          // rectangle/usability prerequisites. Custody publication remains unchanged.
          if livePDF417Candidate == nil {
            enqueueProcessing(identity: identity, profile: chosenProfile, store: store)
          }
        } catch {
          guard generation == cameraGeneration else { return }
          issue = .captureFailed
          camera.updateCaptureFeedback(.failed)
          onEvent(.issue(.captureFailed))
        }
      }
    }

    func enqueueProcessing(
      identity: CaptureSessionAttemptIdentity, profile: CaptureRecords.Profile,
      store: CaptureEvidenceStore
    ) {
      processingIdentities[identity.captureID] = identity
      processingQueue.enqueue(
        .init(
          captureID: identity.captureID, workflowID: identity.workflowID, profile: profile,
          publicationEpoch: processingEpoch, store: store))
    }

    public func retryProcessing(captureID: UUID) async throws {
      guard !erasing, !busy, operation == nil, let store,
        !processingQueue.contains(captureID)
      else { throw PhotoCaptureError.cameraNotReady }
      let current = cameraGeneration
      let original = try await CaptureSignedRecords.original(id: captureID, workflowID: workflowID, store: store).record
      let manifest = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: original.manifest)
      guard manifest.captureID == captureID, manifest.schemaVersion == 1,
        manifest.workflowID == workflowID,
        manifest.fidelity.sha256 == CapturePayloadIntegrity.sha256(original.original)
      else { throw CaptureEvidenceStoreError.integrityFailure }
      try Task.checkCancellation()
      guard current == cameraGeneration, !erasing else { throw CancellationError() }
      enqueueProcessing(
        identity: .init(workflowID: workflowID, captureID: captureID, generation: current),
        profile: manifest.profile, store: store)
    }

    func configureProcessingQueue() {
      processingQueue.completion = { [weak self] job, result in
        guard let self, job.publicationEpoch == self.processingEpoch,
          let identity = self.processingIdentities.removeValue(forKey: job.captureID)
        else { return }
        switch result {
        case .success(let assessment):
          self.onEvent(.processingCompleted(identity: identity, assessment: assessment))
        case .failure:
          self.onEvent(.processingFailed(identity: identity))
        }
      }
    }
  }
#endif
