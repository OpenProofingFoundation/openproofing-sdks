#if os(iOS)
  import Foundation
  import DocumentCaptureApple

  extension CaptureSession {
    func observeGeometry(from camera: DocumentCamera, generation: Int) {
      observeGeometry(camera.geometryObservations, generation: generation)
    }

    func observeGeometry(
      _ observations: AsyncStream<DocumentLiveGeometryObservation>, generation: Int
    ) {
      stopGeometryObservation()
      let subscriptionID = geometryObservationID
      geometryTask = Task { [weak self] in
        defer { self?.finishGeometryObservation(subscriptionID: subscriptionID) }
        for await observation in observations {
          guard !Task.isCancelled, let self else { return }
          self.receiveGeometry(observation, generation: generation)
        }
      }
    }

    func receiveGeometry(_ observation: DocumentLiveGeometryObservation, generation: Int) {
      guard generation == cameraGeneration else { return }
      latestGeometry = observation
    }

    func finishGeometryObservation(subscriptionID: UUID) {
      guard subscriptionID == geometryObservationID else { return }
      geometryTask = nil
      latestGeometry = nil
    }

    func stopGeometryObservation() {
      geometryObservationID = UUID()
      geometryTask?.cancel()
      geometryTask = nil
      latestGeometry = nil
    }
  }
#endif
