import Foundation

/// Per-session tuning. Defaults come only from DocumentCaptureTuning; settings never mutate
/// an active camera. Structural readability, guide containment and custody remain mandatory.
public struct DocumentCaptureTuningOverrides: Codable, Equatable, Sendable {
  public var minimumGuideFill = DocumentCaptureTuning.Quality.minimumGuideFill
  public var minimumMeanLuminance = DocumentCaptureTuning.Quality.minimumMeanLuminance
  public var maximumMeanLuminance = DocumentCaptureTuning.Quality.maximumMeanLuminance
  public var maximumClippedHighlightRatio = DocumentCaptureTuning.Quality
    .maximumClippedHighlightRatio
  public var minimumSharpness = DocumentCaptureTuning.Quality.minimumSharpness
  public var maximumStableMotion = DocumentCaptureTuning.Quality.maximumStableMotion
  public var qualityObservations = DocumentCaptureTuning.Quality.requiredStableObservations
  public var stabilityObservations = DocumentCaptureTuning.Stability.requiredObservations
  public var settleSeconds = DocumentCaptureTuning.Stability.postControlSettleSeconds
  public var maximumEdgeMovement = DocumentCaptureTuning.Stability.maximumEdgeMovement
  public var frontObservations = DocumentCaptureTuning.AutoCapture.frontRequiredObservations
  public var backObservations = DocumentCaptureTuning.AutoCapture.backRequiredObservations
  public var zoomPlanningInsetFraction = DocumentCaptureTuning.Framing.zoomPlanningInsetFraction

  public init() {}

  public var validationIssue: String? {
    let fractions = [minimumGuideFill, minimumSharpness, maximumStableMotion, maximumEdgeMovement]
    guard fractions.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }),
      minimumMeanLuminance.isFinite, maximumMeanLuminance.isFinite,
      minimumMeanLuminance >= 0, maximumMeanLuminance <= 1,
      minimumMeanLuminance < maximumMeanLuminance,
      maximumClippedHighlightRatio.isFinite, (0...1).contains(maximumClippedHighlightRatio),
      zoomPlanningInsetFraction.isFinite, (0..<0.5).contains(zoomPlanningInsetFraction)
    else { return "invalid_fraction_or_brightness_limits" }
    guard
      [qualityObservations, stabilityObservations, frontObservations, backObservations]
        .allSatisfy({ (1...30).contains($0) }), settleSeconds.isFinite,
      (0...10).contains(settleSeconds)
    else { return "invalid_observation_or_settling_limits" }
    return nil
  }

  public var effectiveValues: [String: Double] {
    var values = DocumentCaptureTuning.defaultValues
    values["Quality.minimumGuideFill"] = Double(minimumGuideFill)
    values["Quality.minimumMeanLuminance"] = Double(minimumMeanLuminance)
    values["Quality.maximumMeanLuminance"] = Double(maximumMeanLuminance)
    values["Quality.maximumClippedHighlightRatio"] = Double(maximumClippedHighlightRatio)
    values["Quality.minimumSharpness"] = Double(minimumSharpness)
    values["Quality.maximumStableMotion"] = Double(maximumStableMotion)
    values["Quality.requiredStableObservations"] = Double(qualityObservations)
    values["Stability.requiredObservations"] = Double(stabilityObservations)
    values["Stability.postControlSettleSeconds"] = Double(settleSeconds)
    values["Stability.maximumEdgeMovement"] = Double(maximumEdgeMovement)
    values["AutoCapture.frontRequiredObservations"] = Double(frontObservations)
    values["AutoCapture.backRequiredObservations"] = Double(backObservations)
    values["Framing.zoomPlanningInsetFraction"] = Double(zoomPlanningInsetFraction)
    return values
  }
}
