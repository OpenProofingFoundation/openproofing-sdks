// Coordinate axes use conventional x/y names.
// swiftlint:disable identifier_name
import Foundation
import DocumentSDK
import DocumentOpenCVBridge

/// Continuous coordinates from the oriented source's top-left image edge.
/// The centre of its first pixel is (0.5, 0.5).
public struct DocumentPixelPoint: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// Coordinates on the nominal ID-1 plane, top-left origin, x right and y down.
public struct CardMillimeterPoint: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public enum ID1GeometryError: Error { case invalidGeometry, pointOutsideCard, renderingFailed }

/// Nominal ISO/IEC 7810 ID-1 dimensions; output sampling inherited from the
/// retained 2026-10-23 capture implementation, with no population calibration.
/// Matrices do not establish physical size or lens calibration.
public struct ID1CardGeometry: Codable, Equatable, Sendable, CalibrationProfile {
  public static let profileIdentifier = "id1-normalization-50px-per-mm-v1"
  public static let calibrationStatus = "nominal_geometry_provisional_sampling"
  public static let populationDescription = "none"
  public static let widthMillimeters = 85.60
  public static let heightMillimeters = 53.98
  public static let pixelsPerMillimeter = 50.0
  public static let pixelWidth = 4280
  public static let pixelHeight = 2699

  public let sourceToCardMillimeters: [Double]
  public let cardMillimetersToSource: [Double]
  public let sourceCorners: [DocumentPixelPoint]
  public let sourcePixelWidth: Int
  public let sourcePixelHeight: Int
  public let implementationVersion: String
  public let distortionStatus: String
  public let nominalWidthMillimeters: Double
  public let nominalHeightMillimeters: Double
  public let outputPixelsPerMillimeter: Double
  public let coordinateConvention: String
  public let rasterEncoding: String

  public init(observation: DocumentGeometryObservation) throws {
    guard DocumentPhotoGeometryPolicy.isCompleteID1Candidate(observation) else {
      throw ID1GeometryError.invalidGeometry
    }
    sourcePixelWidth = observation.orientedPixelWidth
    sourcePixelHeight = observation.orientedPixelHeight
    sourceCorners = observation.quadrilateral.points.map {
      DocumentPixelPoint(
        x: $0.x * Double(observation.orientedPixelWidth),
        y: (1 - $0.y) * Double(observation.orientedPixelHeight))
    }
    guard
      sourceCorners.allSatisfy({
        (0...Double(observation.orientedPixelWidth)).contains($0.x)
          && (0...Double(observation.orientedPixelHeight)).contains($0.y)
      })
    else { throw ID1GeometryError.invalidGeometry }
    var forward = [Double](repeating: 0, count: 9)
    var inverse = forward
    let points = sourceCorners.flatMap { [$0.x, $0.y] }
    guard IEOpenCVID1Matrices(points, &forward, &inverse) else {
      throw ID1GeometryError.invalidGeometry
    }
    sourceToCardMillimeters = forward
    cardMillimetersToSource = inverse
    implementationVersion = "opencv-mobile-4.12.0-id1-50pxmm-v1"
    distortionStatus = "uncalibrated_source_lens_distortion"
    nominalWidthMillimeters = Self.widthMillimeters
    nominalHeightMillimeters = Self.heightMillimeters
    outputPixelsPerMillimeter = Self.pixelsPerMillimeter
    coordinateConvention = "top_left_edge_x_right_y_down_half_pixel_centers"
    rasterEncoding = "srgb_rgba8_opencv_inter_linear_single_resample"
  }

  public var valid: Bool {
    guard sourcePixelWidth > 0, sourcePixelHeight > 0, sourceCorners.count == 4,
      nominalWidthMillimeters == Self.widthMillimeters,
      nominalHeightMillimeters == Self.heightMillimeters,
      outputPixelsPerMillimeter == Self.pixelsPerMillimeter,
      sourceToCardMillimeters.count == 9, cardMillimetersToSource.count == 9,
      sourceToCardMillimeters.allSatisfy(\.isFinite), cardMillimetersToSource.allSatisfy(\.isFinite)
    else { return false }
    let expected = [
      CardMillimeterPoint(x: 0, y: 0), .init(x: Self.widthMillimeters, y: 0),
      .init(x: Self.widthMillimeters, y: Self.heightMillimeters),
      .init(x: 0, y: Self.heightMillimeters)
    ]
    return zip(sourceCorners, expected).allSatisfy { source, card in
      guard (0...Double(sourcePixelWidth)).contains(source.x),
        (0...Double(sourcePixelHeight)).contains(source.y),
        let forward = try? cardPoint(from: source), let reverse = try? sourcePoint(from: card)
      else { return false }
      return hypot(forward.x - card.x, forward.y - card.y) < 0.0001
        && hypot(reverse.x - source.x, reverse.y - source.y) < 0.01
    }
  }

  func matches(_ observation: DocumentGeometryObservation) -> Bool {
    let expected = observation.quadrilateral.points.map {
      DocumentPixelPoint(
        x: $0.x * Double(observation.orientedPixelWidth),
        y: (1 - $0.y) * Double(observation.orientedPixelHeight))
    }
    return sourceCorners == expected && sourcePixelWidth == observation.orientedPixelWidth
      && sourcePixelHeight == observation.orientedPixelHeight
  }

  public func cardPoint(from source: DocumentPixelPoint) throws -> CardMillimeterPoint {
    let point = try Self.project(source.x, source.y, matrix: sourceToCardMillimeters)
    guard Self.isOnCard(point) else { throw ID1GeometryError.pointOutsideCard }
    return point
  }

  public func sourcePoint(from card: CardMillimeterPoint) throws -> DocumentPixelPoint {
    guard Self.isOnCard(card) else { throw ID1GeometryError.pointOutsideCard }
    let point = try Self.project(card.x, card.y, matrix: cardMillimetersToSource)
    return .init(x: point.x, y: point.y)
  }

  public func distanceMillimeters(from first: DocumentPixelPoint, to second: DocumentPixelPoint)
    throws -> Double {
    let start = try cardPoint(from: first)
    let end = try cardPoint(from: second)
    return hypot(end.x - start.x, end.y - start.y)
  }

  // OpenCV samples integer-centred pixels. Compose source +0.5 and output -0.5
  // so the retained matrices can consistently describe continuous image edges.
  var sourceToOutputPixelCenters: [Double] {
    let matrix = sourceToCardMillimeters
    var result = matrix
    for row in 0..<3 { result[row * 3 + 2] += 0.5 * (matrix[row * 3] + matrix[row * 3 + 1]) }
    for column in 0..<3 {
      result[column] = Self.pixelsPerMillimeter * result[column] - 0.5 * result[6 + column]
      result[3 + column] = Self.pixelsPerMillimeter * result[3 + column] - 0.5 * result[6 + column]
    }
    return result
  }

  private static func isOnCard(_ point: CardMillimeterPoint) -> Bool {
    point.x.isFinite && point.y.isFinite
      && (-0.0001...widthMillimeters + 0.0001).contains(point.x)
      && (-0.0001...heightMillimeters + 0.0001).contains(point.y)
  }

  private static func project(_ x: Double, _ y: Double, matrix: [Double]) throws
    -> CardMillimeterPoint {
    guard matrix.count == 9, matrix.allSatisfy(\.isFinite), x.isFinite, y.isFinite else {
      throw ID1GeometryError.invalidGeometry
    }
    let divisor = matrix[6] * x + matrix[7] * y + matrix[8]
    guard abs(divisor) > 1e-12 else { throw ID1GeometryError.invalidGeometry }
    let point = CardMillimeterPoint(
      x: (matrix[0] * x + matrix[1] * y + matrix[2]) / divisor,
      y: (matrix[3] * x + matrix[4] * y + matrix[5]) / divisor)
    guard point.x.isFinite, point.y.isFinite else { throw ID1GeometryError.invalidGeometry }
    return point
  }
}

// swiftlint:enable identifier_name
