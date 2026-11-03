import Foundation
import Testing

@testable import DocumentCaptureApple

@Test func tuningRejectsInvalidValuesAndRetainsExactConfiguration() throws {
  var tuning = DocumentCaptureTuningOverrides()
  #expect(tuning.validationIssue == nil)
  #expect(tuning.effectiveValues == DocumentCaptureTuning.defaultValues)
  tuning.minimumSharpness = 0.019
  let restored = try JSONDecoder().decode(
    DocumentCaptureTuningOverrides.self, from: JSONEncoder().encode(tuning))
  #expect(restored == tuning)
  #expect(restored.effectiveValues["Quality.minimumSharpness"] == 0.019)
  tuning.settleSeconds = .nan
  #expect(tuning.validationIssue != nil)
  tuning = .init()
  tuning.frontObservations = 0
  #expect(tuning.validationIssue != nil)
  tuning = .init()
  tuning.minimumMeanLuminance = tuning.maximumMeanLuminance
  #expect(tuning.validationIssue != nil)
}

@Test func tuningChangesQualityGateWithoutRemovingGuideRequirement() {
  var tuning = DocumentCaptureTuningOverrides()
  tuning.minimumSharpness = 0.01
  tuning.qualityObservations = 1
  func metrics(inside: Bool) -> DocumentCaptureQualityMetrics {
    .init(
      documentFillRatio: 0.5, documentGuideFillRatio: 0.64,
      documentInsideGuide: inside, guideCenterX: 0.5, guideCenterY: 0.5, guideWidth: 0.8,
      guideHeight: 0.5, documentAspectRatio: 1.5, sharpness: 0.02, motion: 0,
      clippedHighlightRatio: 0, meanLuminance: 0.5, documentCenterX: 0.5, documentCenterY: 0.5)
  }
  let normal = DocumentCaptureQualityPolicy().assess(
    metrics: metrics(inside: true), previousStableFrameCount: 5)
  #expect(normal.blockingReasons.contains(.softFocus))
  let adjusted = DocumentCaptureQualityPolicy(tuning: tuning)
  #expect(adjusted.assess(metrics: metrics(inside: true), previousStableFrameCount: 0).ready)
  #expect(!adjusted.assess(metrics: metrics(inside: false), previousStableFrameCount: 5).ready)
}
