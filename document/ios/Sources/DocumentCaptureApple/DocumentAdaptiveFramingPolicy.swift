import Foundation

/// Provisional whole-document framing. Pure math; never an authenticity verdict.
struct DocumentAdaptiveFramingPolicy {
  private typealias Tuning = DocumentCaptureTuning.Framing
  static func aspectFitFill(polygonArea: Double, bounds: CGRect, guide: CGRect) -> Double? {
    guard polygonArea.isFinite, polygonArea > 0, bounds.width > 0, bounds.height > 0,
      guide.width > 0, guide.height > 0
    else { return nil }
    let scale = min(guide.width / bounds.width, guide.height / bounds.height)
    let fitArea = bounds.width * bounds.height * scale * scale
    return polygonArea / Double(fitArea)
  }

  struct ZoomPlan {
    let zoom: Double
    let needsReposition: Bool
  }

  /// Minimum is the current native hardware zoom limit, never a subject-distance estimate.
  static func coordinatedZoom(
    current: Double, maximum: Double, minimum: Double, document: CGRect, guide: CGRect,
    tuning: DocumentCaptureTuningOverrides = .init()
  ) -> ZoomPlan {
    guard current.isFinite, current >= 1, maximum.isFinite, maximum >= 1,
      minimum.isFinite, minimum >= 1, !document.isEmpty, !guide.isEmpty
    else { return ZoomPlan(zoom: current, needsReposition: true) }
    let safe = guide.insetBy(
      dx: guide.width * tuning.zoomPlanningInsetFraction,
      dy: guide.height * tuning.zoomPlanningInsetFraction)
    guard safe.contains(CGPoint(x: 0.5, y: 0.5)),
      [document.minX, document.minY, document.maxX, document.maxY].allSatisfy({ $0.isFinite })
    else { return ZoomPlan(zoom: current, needsReposition: true) }
    var limit = maximum / current
    for point in [
      CGPoint(x: document.minX, y: document.minY),
      CGPoint(x: document.maxX, y: document.maxY)
    ] {
      if point.x < 0.5 { limit = min(limit, Double((0.5 - safe.minX) / (0.5 - point.x))) }
      if point.x > 0.5 { limit = min(limit, Double((safe.maxX - 0.5) / (point.x - 0.5))) }
      if point.y < 0.5 { limit = min(limit, Double((0.5 - safe.minY) / (0.5 - point.y))) }
      if point.y > 0.5 { limit = min(limit, Double((safe.maxY - 0.5) / (point.y - 0.5))) }
    }
    let safeMaximum = current * limit
    let desired = max(
      minimum,
      targetZoom(
        current: current, maximum: maximum, document: document, guide: guide, tuning: tuning))
    let bounded = min(maximum, max(minimum, min(desired, safeMaximum)))
    let step = min(
      maximum,
      max(
        minimum,
        min(
          current * Tuning.maximumZoomStepFactor,
          max(current / Tuning.maximumZoomStepFactor, bounded))))
    // The inset is a zoom-planning preference, not an invisible capture boundary.
    // At the hardware minimum, only the visible guide can require repositioning.
    let minimumScale = minimum / current
    let minimumBounds = CGRect(
      x: 0.5 + (document.minX - 0.5) * minimumScale,
      y: 0.5 + (document.minY - 0.5) * minimumScale,
      width: document.width * minimumScale, height: document.height * minimumScale)
    return ZoomPlan(zoom: step, needsReposition: !guide.contains(minimumBounds))
  }

  static func targetZoom(
    current: Double, maximum: Double, document: CGRect, guide: CGRect,
    tuning: DocumentCaptureTuningOverrides = .init()
  ) -> Double {
    guard current.isFinite, maximum.isFinite, current >= 1, maximum >= 1,
      !document.isEmpty, !guide.isEmpty,
      [
        document.minX, document.minY, document.maxX, document.maxY,
        guide.minX, guide.minY, guide.maxX, guide.maxY
      ].allSatisfy({ $0.isFinite })
    else { return current }
    let fill = max(document.width / guide.width, document.height / guide.height)
    guard fill < Tuning.minimumLinearFillBeforeZoom || fill > Tuning.maximumLinearFillBeforeZoom
    else { return current }
    var scale = min(
      Tuning.maximumZoomStepFactor,
      max(1 / Tuning.maximumZoomStepFactor, Tuning.targetLinearFill / Double(fill)))
    if scale > 1 {
      let safe = guide.insetBy(
        dx: guide.width * tuning.zoomPlanningInsetFraction,
        dy: guide.height * tuning.zoomPlanningInsetFraction)
      // Optical zoom is about the image center, not the document center.
      for point in [
        CGPoint(x: document.minX, y: document.minY),
        CGPoint(x: document.maxX, y: document.maxY)
      ] {
        if point.x < 0.5 { scale = min(scale, Double((0.5 - safe.minX) / (0.5 - point.x))) }
        if point.x > 0.5 { scale = min(scale, Double((safe.maxX - 0.5) / (point.x - 0.5))) }
        if point.y < 0.5 { scale = min(scale, Double((0.5 - safe.minY) / (0.5 - point.y))) }
        if point.y > 0.5 { scale = min(scale, Double((safe.maxY - 0.5) / (point.y - 0.5))) }
      }
      scale = max(1, scale)
    }
    return min(maximum, max(1, current * scale))
  }
}

public struct DocumentCameraControlSnapshot: Codable, Equatable, Sendable {
  /// Diagnostic failure requires deliberate controller reset; it never implies optical success.
  public var adaptiveFailureReason: String?
  public var opticalIdentity: String?
  public var focusModeRawValue: Int?
  public var focusPointX: Double?
  public var focusPointY: Double?
  public var lensPosition: Double?
  public var focusRequestCount: Int?
  public let sampledAt: Date
  public let zoomFactor: Double
  public let adjustingFocus: Bool
  public let adjustingExposure: Bool
  public let rampingZoom: Bool
  public var settled: Bool

  private enum CodingKeys: String, CodingKey {
    case adaptiveFailureReason
    case opticalIdentity
    case focusModeRawValue
    case focusPointX
    case focusPointY
    case lensPosition
    case focusRequestCount
    case sampledAt
    case zoomFactor
    case adjustingFocus = "isAdjustingFocus"
    case adjustingExposure = "isAdjustingExposure"
    case rampingZoom = "isRampingZoom"
    case settled = "isSettled"
  }
}
