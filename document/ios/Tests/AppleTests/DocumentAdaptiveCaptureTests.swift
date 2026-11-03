import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

@Test func zoomKeepsTheWholeOffCenterDocumentInsideGuide() {
  let guide = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
  for offset in stride(from: 0.12, through: 0.65, by: 0.025) {
    let document = CGRect(x: offset, y: 0.3, width: 0.2, height: 0.2)
    let target = DocumentAdaptiveFramingPolicy.targetZoom(
      current: 1, maximum: 2,
      document: document, guide: guide)
    let projected = CGRect(
      x: 0.5 + (document.minX - 0.5) * target,
      y: 0.5 + (document.minY - 0.5) * target,
      width: document.width * target, height: document.height * target)
    #expect(guide.contains(projected))
    #expect(target <= 1.12)
  }
}

@Test func zoomOutAndDeadbandPreventRunawayMagnification() {
  let guide = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
  #expect(
    DocumentAdaptiveFramingPolicy.targetZoom(
      current: 2, maximum: 2,
      document: guide, guide: guide) < 2)
  #expect(
    DocumentAdaptiveFramingPolicy.targetZoom(
      current: 1.4, maximum: 2,
      document: CGRect(x: 0.18, y: 0.18, width: 0.64, height: 0.64), guide: guide) == 1.4)
}

@Test func portraitAndSquareReadinessUseAspectPreservingFit() throws {
  let guide = CGRect(x: 0, y: 0, width: 0.8, height: 0.5)
  for ratio in [0.707, 1, 1.586] {
    let document = CGRect(x: 0.1, y: 0.05, width: 0.4 * ratio, height: 0.4)
    let fill = try #require(
      DocumentAdaptiveFramingPolicy.aspectFitFill(
        polygonArea: Double(document.width * document.height), bounds: document, guide: guide))
    #expect(abs(fill - 0.64) < 0.001)
  }
}

@Test func adaptiveReadinessRequiresFreshStablePostControlFrames() {
  var policy = DocumentAdaptiveReadinessPolicy()
  let changedAt = Date(timeIntervalSince1970: 100)
  for sequence in 1...6 {
    let ready = policy.observe(
      fixture(sequence), controlsAdjusting: sequence == 5, changedAt: changedAt)
    #expect(!ready)
  }
  let seventh = policy.observe(fixture(7), controlsAdjusting: false, changedAt: changedAt)
  #expect(!seventh)
  let eighth = policy.observe(fixture(8), controlsAdjusting: false, changedAt: changedAt)
  #expect(eighth)
  let changed = policy.observe(
    fixture(9, revision: 2), controlsAdjusting: false, changedAt: changedAt)
  #expect(!changed)
  let gap = policy.observe(fixture(20), controlsAdjusting: false, changedAt: changedAt)
  #expect(!gap)
}

@Test func qualityAutoRequiresSettledControlsAndLatchesOnce() {
  var coordinator = DocumentAutoCaptureCoordinator(
    requireQualityReadiness: true,
    requiresContentSignal: false, maximumAttemptsPerSide: 1)
  coordinator.begin(side: .front)
  #expect(coordinator.observe(side: .front, observation: fixture(1, settled: false)) == .observing)
  #expect(coordinator.observe(side: .front, observation: fixture(2)) == .observing)
  #expect(coordinator.observe(side: .front, observation: fixture(3)) == .trigger(attempt: 1))
  #expect(coordinator.observe(side: .front, observation: fixture(4)) == .observing)
  _ = coordinator.captureCompleted(usable: true)
  #expect(coordinator.observe(side: .front, observation: fixture(5)) == .observing)
}

@Test func qualityAutoAdmissionRejectsUnsettledOrWrongTrigger() {
  let current = fixture(1)
  func failure(
    _ observation: DocumentCaptureQualityObservation,
    identity: DocumentCaptureObservationIdentity?
  ) -> PhotoCaptureError? {
    DocumentCaptureAdmissionPolicy().failure(
      in: .init(
        isConfigured: true, isRunning: true,
        isCaptureInFlight: false, isGuideAvailable: true, currentGeometryRevision: 1,
        observation: observation, qualityGate: .qualityDrivenAutoCapture,
        requiredObservationIdentity: identity, admissionTime: observation.timestamp))
  }
  #expect(
    failure(current, identity: DocumentCaptureObservationIdentity(observation: current)) == nil)
  #expect(failure(current, identity: nil) == .captureQualityNotReady)
  let unstable = fixture(1, settled: false)
  #expect(
    failure(unstable, identity: DocumentCaptureObservationIdentity(observation: unstable))
      == .captureQualityNotReady)
  #expect(
    failure(current, identity: DocumentCaptureObservationIdentity(observation: fixture(2)))
      == .captureQualityNotReady)
}

private func fixture(_ sequence: Int, revision: UInt64 = 1, settled: Bool = true)
  -> DocumentCaptureQualityObservation {
  let date = Date(timeIntervalSince1970: 100 + Double(sequence) * 0.2)
  return DocumentCaptureQualityObservation(
    sequence: UInt64(sequence), geometryRevision: revision,
    timestamp: date,
    metrics: DocumentCaptureQualityMetrics(
      documentFillRatio: 0.5, documentGuideFillRatio: 0.64,
      documentInsideGuide: true, guideCenterX: 0.5, guideCenterY: 0.5, guideWidth: 0.8,
      guideHeight: 0.5, documentAspectRatio: 1.5, sharpness: 0.1, motion: 0.01,
      clippedHighlightRatio: 0, meanLuminance: 0.5, documentCenterX: 0.5, documentCenterY: 0.5),
    assessment: .init(ready: true, blockingReasons: [], stableFrameCount: 4),
    cameraControl: .init(
      sampledAt: date, zoomFactor: 1, adjustingFocus: !settled,
      adjustingExposure: false, rampingZoom: false, settled: settled),
    documentBounds: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4))
}

@Test func focusRecoveryRetriesBlurWithoutRequiringDocumentMovement() {
  let center = CGPoint(x: 0.5, y: 0.5)
  #expect(
    DocumentFocusRecoveryPolicy.needsFocus(
      previous: nil, target: center,
      sharpness: 0.05, sinceLastRequest: 0))
  #expect(
    DocumentFocusRecoveryPolicy.needsFocus(
      previous: center, target: center,
      sharpness: 0.01, sinceLastRequest: 1.6))
  #expect(
    !DocumentFocusRecoveryPolicy.needsFocus(
      previous: center, target: center,
      sharpness: 0.01, sinceLastRequest: 0.5))
  #expect(
    !DocumentFocusRecoveryPolicy.needsFocus(
      previous: center, target: center,
      sharpness: 0.05, sinceLastRequest: 5))
}

@Test func slowAnalysisCanGuideFocusButCannotAuthorizeShutter() {
  let observation = fixture(1)
  let later = observation.timestamp.addingTimeInterval(0.4)
  #expect(DocumentFocusRecoveryPolicy.permitsControl(observedAt: observation.timestamp, now: later))
  #expect(!DocumentCaptureObservationFreshness.fresh(observation, at: later))
  #expect(
    !DocumentFocusRecoveryPolicy.permitsControl(
      observedAt: observation.timestamp,
      now: observation.timestamp.addingTimeInterval(1.1)))
  #expect(
    !DocumentFocusRecoveryPolicy.permitsControl(
      observedAt: observation.timestamp,
      now: observation.timestamp.addingTimeInterval(-0.1)))
}

@Test func visibleGuideRatherThanInvisibleInsetControlsRepositioning() {
  let guide = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
  for ratio in [0.707, 1.0, 1.586] {
    let document = CGRect(x: 0.11, y: 0.15, width: 0.44 * ratio, height: 0.44)
    for minimum in [1.0, 1.5] {
      let plan = DocumentAdaptiveFramingPolicy.coordinatedZoom(
        current: minimum, maximum: 2, minimum: minimum, document: document, guide: guide)
      #expect(!plan.needsReposition)
      #expect(plan.zoom == minimum)
    }
  }
  let clipped = CGRect(x: 0.08, y: 0.2, width: 0.65, height: 0.6)
  let minimum = DocumentAdaptiveFramingPolicy.coordinatedZoom(
    current: 1, maximum: 2, minimum: 1, document: clipped, guide: guide)
  #expect(minimum.needsReposition)
  let recoverable = DocumentAdaptiveFramingPolicy.coordinatedZoom(
    current: 1.5, maximum: 2, minimum: 1, document: clipped, guide: guide)
  #expect(!recoverable.needsReposition)
  #expect(recoverable.zoom < 1.5)
}

@Test func runtimeTuningControlsSettlingAndStabilityConfirmation() {
  var tuning = DocumentCaptureTuningOverrides()
  tuning.settleSeconds = 0
  tuning.stabilityObservations = 1
  var adjusted = DocumentAdaptiveReadinessPolicy(tuning: tuning)
  var normal = DocumentAdaptiveReadinessPolicy()
  let changedAt = Date(timeIntervalSince1970: 100)
  let first = adjusted.observe(fixture(1), controlsAdjusting: false, changedAt: changedAt)
  let second = adjusted.observe(fixture(2), controlsAdjusting: false, changedAt: changedAt)
  let normalFirst = normal.observe(fixture(1), controlsAdjusting: false, changedAt: changedAt)
  let normalSecond = normal.observe(fixture(2), controlsAdjusting: false, changedAt: changedAt)
  let adjusting = adjusted.observe(fixture(3), controlsAdjusting: true, changedAt: changedAt)
  #expect(!first)
  #expect(second)
  #expect(!normalFirst && !normalSecond)
  #expect(!adjusting)
}
