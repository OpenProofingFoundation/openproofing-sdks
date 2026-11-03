import Foundation

extension AVFoundationCameraSessionController: CameraSessionGeometryEpochProviding {
  func setPreviewGeometryInvalidationHandler(
    _ handler: @escaping @MainActor @Sendable (UInt64) -> Void
  ) {
    sessionQueue.async { [self] in
      state.previewInvalidationHandler = handler
      let revision = state.opticalRevision
      Task { @MainActor in handler(revision) }
    }
  }

  @MainActor func updatePreviewGeometry(
    orientation: DocumentCameraOrientation, region: DocumentCameraGuideRegion?,
    sourceGeneration: UInt64
  ) {
    sessionQueue.async { [self] in
      #if os(iOS)
        guard sourceGeneration == state.opticalRevision else { return }
        guard let region, region.normalizedTopLeftRect != nil else {
          state.captureDeviceGuideRegion = nil
          refreshAnalysisGeometry()
          return
        }
        // Reject geometry while a still is in flight; request the same current
        // epoch again after the terminal delegate instead of changing its outputs.
        guard state.processors.isEmpty else {
          state.previewRefreshPending = true
          return
        }
        if state.captureOrientation == orientation,
          state.captureDeviceGuideRegion?.isEffectivelyEqual(to: region) == true {
          return
        }
        state.captureOrientation = orientation
        guard applyVerifiedOutputOrientation() else {
          state.captureDeviceGuideRegion = nil
          refreshAnalysisGeometry()
          return
        }
        state.captureDeviceGuideRegion = region
        refreshAnalysisGeometry()
      #endif
    }
  }
}
