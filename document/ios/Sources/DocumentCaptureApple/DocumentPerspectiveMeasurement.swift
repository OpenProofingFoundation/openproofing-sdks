import Foundation

public enum DocumentPerspectiveMeasurementError: Error, Equatable, Sendable {
  case invalidTimestamp
  case invalidDimensions
  case invalidQuadrilateral
}

/// Projected 2D shape in the delivered buffer. These values are neither 3D pose nor physical angles.
/// Corner roles must stay consistent across comparisons; detector relabeling can swap ratio signs.
/// Strict convexity is numerical admission, not a calibrated geometric quality or uncertainty floor.
public struct DocumentPerspectiveMeasurement: Equatable, Sendable {
  public enum UncertaintyStatus: String, Sendable { case notEstimated }
  public static let implementationVersion = "pixel-opposite-edge-log-ratios-v1"

  public let deliveredTopLeftQuadrilateral: DocumentQuadrilateral
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let captureTimestamp: DocumentCaptureClockTimestamp
  public let rightToLeftEdgeLogRatio: Double
  public let bottomToTopEdgeLogRatio: Double
  public let meanHorizontalEdgePixels: Double
  public let meanVerticalEdgePixels: Double
  public let horizontalToVerticalEdgeRatio: Double
  /// Arithmetic mean of the four pixel-space corners, not the polygon's area centroid.
  public let cornerMeanPixels: DocumentPixelPoint
  /// Direction of summed TL→TR and BL→BR vectors, in image pixels with y increasing downward.
  public let imagePlaneAngleRadians: Double
  /// Detector confidence is not measurement uncertainty; no error estimate is manufactured.
  public var uncertaintyStatus: UncertaintyStatus { .notEstimated }

  public init(
    deliveredTopLeftQuadrilateral: DocumentQuadrilateral, pixelWidth: Int, pixelHeight: Int,
    captureTimestamp: DocumentCaptureClockTimestamp
  ) throws {
    guard captureTimestamp.isNumeric else {
      throw DocumentPerspectiveMeasurementError.invalidTimestamp
    }
    guard pixelWidth > 0, pixelHeight > 0 else {
      throw DocumentPerspectiveMeasurementError.invalidDimensions
    }
    let quad = deliveredTopLeftQuadrilateral
    guard DocumentPhotoGeometryPolicy.isValidConvexQuadrilateral(quad),
      quad.points.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) })
    else { throw DocumentPerspectiveMeasurementError.invalidQuadrilateral }
    let points = quad.points.map {
      DocumentPixelPoint(x: $0.x * Double(pixelWidth), y: $0.y * Double(pixelHeight))
    }
    let top = Self.distance(points[0], points[1])
    let right = Self.distance(points[1], points[2])
    let bottom = Self.distance(points[3], points[2])
    let left = Self.distance(points[0], points[3])
    let horizontal = (top + bottom) / 2
    let vertical = (left + right) / 2
    let axisHorizontal = (points[1].x - points[0].x) + (points[2].x - points[3].x)
    let axisVertical = (points[1].y - points[0].y) + (points[2].y - points[3].y)
    guard [top, right, bottom, left].allSatisfy({ $0.isFinite && $0 > 0 }),
      (horizontal / vertical).isFinite, hypot(axisHorizontal, axisVertical) > 0
    else { throw DocumentPerspectiveMeasurementError.invalidQuadrilateral }
    self.deliveredTopLeftQuadrilateral = quad
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.captureTimestamp = captureTimestamp
    rightToLeftEdgeLogRatio = log(right) - log(left)
    bottomToTopEdgeLogRatio = log(bottom) - log(top)
    meanHorizontalEdgePixels = horizontal
    meanVerticalEdgePixels = vertical
    horizontalToVerticalEdgeRatio = horizontal / vertical
    cornerMeanPixels = .init(
      x: points.reduce(0) { $0 + $1.x } / 4, y: points.reduce(0) { $0 + $1.y } / 4)
    imagePlaneAngleRadians = atan2(axisVertical, axisHorizontal)
  }

  private static func distance(
    _ first: DocumentPixelPoint, _ second: DocumentPixelPoint
  ) -> Double {
    hypot(second.x - first.x, second.y - first.y)
  }
}
