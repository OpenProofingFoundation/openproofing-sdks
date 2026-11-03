import Foundation

extension DocumentFrameAnalyzer {
  /// Commands share the ingress/analysis drain used by graph teardown and sink detachment.
  func beginTiltGuidance(
    runID: UUID, configuration: DocumentTiltConfiguration,
    completion: @escaping @Sendable (DocumentTiltPresentation?) -> Void
  ) {
    tiltGuidanceTransport.prepare(runID: runID)
    ingressQueue.async { [self] in
      analysisQueue.async { [self] in
        let value = tiltGuidanceTransport.begin(runID: runID, configuration: configuration)
        updateGeometryAnalysisMode()
        completion(value)
      }
    }
  }

  /// Invalidates synchronously; completion acknowledges actual ordered archival, not native release.
  func endTiltGuidance(
    runID: UUID, reason: DocumentTiltReason,
    unstartedConfiguration: DocumentTiltConfiguration? = nil,
    completion: @escaping @Sendable () -> Void
  ) {
    if unstartedConfiguration != nil { tiltGuidanceTransport.prepare(runID: runID) }
    tiltGuidanceTransport.invalidate(runID: runID, reason: reason)
    ingressQueue.async { [self] in
      analysisQueue.async { [self] in
        if let unstartedConfiguration {
          _ = tiltGuidanceTransport.begin(runID: runID, configuration: unstartedConfiguration)
        } else {
          tiltGuidanceTransport.end(runID: runID, reason: reason)
        }
        updateGeometryAnalysisMode()
        completion()
      }
    }
  }
}
