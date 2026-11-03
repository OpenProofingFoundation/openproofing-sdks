import Testing

@testable import DocumentCaptureApple

@Test
func missingDocumentFailsClosedRegardlessOfOtherMetrics() {
  let assessment = DocumentCaptureQualityPolicy().assess(
    metrics: metrics(fill: nil),
    previousStableFrameCount: 3
  )

  #expect(!assessment.ready)
  #expect(assessment.blockingReasons == [.documentNotFound])
  #expect(assessment.stableFrameCount == 0)
}

@Test
func qualityProblemsReturnSpecificBlockingReasonsAndResetStability() {
  let assessment = DocumentCaptureQualityPolicy().assess(
    metrics: metrics(
      fill: 0.2,
      sharpness: 0.01,
      motion: 0.2,
      clippedHighlightRatio: 0.12,
      luminance: 0.1
    ),
    previousStableFrameCount: 3
  )

  #expect(!assessment.ready)
  #expect(assessment.blockingReasons.contains(.moveCloser))
  #expect(assessment.blockingReasons.contains(.tooDark))
  #expect(assessment.blockingReasons.contains(.glare))
  #expect(assessment.blockingReasons.contains(.holdSteady))
  #expect(assessment.blockingReasons.contains(.softFocus))
  #expect(assessment.stableFrameCount == 0)
}

@Test
func ordinaryHandheldMotionDoesNotOverrideStrongSharpness() {
  let assessment = DocumentCaptureQualityPolicy(requiredStableFrameCount: 1).assess(
    metrics: metrics(fill: 0.55, sharpness: 0.09, motion: 0.1),
    previousStableFrameCount: 0
  )

  #expect(assessment.ready)
  #expect(!assessment.blockingReasons.contains(.holdSteady))
}

@Test
func captureBecomesReadyOnlyAfterConsecutivePassingFrames() {
  let policy = DocumentCaptureQualityPolicy(requiredStableFrameCount: 4)
  var stableFrameCount = 0

  for expectedCount in 1...4 {
    let assessment = policy.assess(
      metrics: metrics(fill: 0.55),
      previousStableFrameCount: stableFrameCount
    )
    stableFrameCount = assessment.stableFrameCount
    #expect(assessment.ready == (expectedCount == 4))
    #expect(assessment.stableFrameCount == expectedCount)
  }
}

@Test
func previewConfigurationEnforcesPrivacyFriendlyMinimumInterval() {
  let configuration = DocumentCameraDiagnosticsConfiguration(
    includesPreviewFrames: true,
    previewFrameIntervalSeconds: 0.01
  )

  #expect(configuration.includesPreviewFrames)
  #expect(configuration.previewFrameIntervalSeconds == 0.5)
}

@Test
func detectedDocumentFailsClosedUntilGuideCoordinatesAreAvailable() {
  let assessment = DocumentCaptureQualityPolicy().assess(
    metrics: metrics(fill: 0.3, hasGuide: false),
    previousStableFrameCount: 3
  )

  #expect(assessment.blockingReasons == [.guideUnavailable])
  #expect(assessment.stableFrameCount == 0)
}

@Test
func documentOutsideGuideCannotBecomeCaptureReady() {
  let assessment = DocumentCaptureQualityPolicy().assess(
    metrics: metrics(fill: 0.3, isInsideGuide: false),
    previousStableFrameCount: 3
  )

  #expect(assessment.blockingReasons.contains(.alignWithGuide))
  #expect(!assessment.ready)
}

private func metrics(
  fill: Double?,
  sharpness: Double = 0.08,
  motion: Double? = 0.005,
  clippedHighlightRatio: Double = 0.01,
  luminance: Double = 0.55,
  hasGuide: Bool = true,
  isInsideGuide: Bool = true
) -> DocumentCaptureQualityMetrics {
  DocumentCaptureQualityMetrics(
    documentFillRatio: fill,
    documentGuideFillRatio: hasGuide ? fill.map { min($0 / 0.5, 0.75) } : nil,
    documentInsideGuide: hasGuide ? fill.map { _ in isInsideGuide } : nil,
    guideCenterX: hasGuide ? fill.map { _ in 0.5 } : nil,
    guideCenterY: hasGuide ? fill.map { _ in 0.5 } : nil,
    guideWidth: hasGuide ? fill.map { _ in 0.8 } : nil,
    guideHeight: hasGuide ? fill.map { _ in 0.5 } : nil,
    documentAspectRatio: fill == nil ? nil : 1.586,
    sharpness: sharpness,
    motion: motion,
    clippedHighlightRatio: clippedHighlightRatio,
    meanLuminance: luminance,
    documentCenterX: fill == nil ? nil : 0.5,
    documentCenterY: fill == nil ? nil : 0.5
  )
}
