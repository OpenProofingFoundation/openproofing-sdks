import CoreGraphics
import ImageIO
import Vision

// Normalized image coordinates intentionally use the conventional x/y names.
// swiftlint:disable identifier_name
public struct DocumentNormalizedPoint: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}
// swiftlint:enable identifier_name

public struct DocumentQuadrilateral: Codable, Equatable, Sendable {
  public let topLeft: DocumentNormalizedPoint
  public let topRight: DocumentNormalizedPoint
  public let bottomRight: DocumentNormalizedPoint
  public let bottomLeft: DocumentNormalizedPoint

  public init(
    topLeft: DocumentNormalizedPoint,
    topRight: DocumentNormalizedPoint,
    bottomRight: DocumentNormalizedPoint,
    bottomLeft: DocumentNormalizedPoint
  ) {
    self.topLeft = topLeft
    self.topRight = topRight
    self.bottomRight = bottomRight
    self.bottomLeft = bottomLeft
  }

  var points: [DocumentNormalizedPoint] {
    [topLeft, topRight, bottomRight, bottomLeft]
  }

  var boundingBox: CGRect {
    let xValues = points.map(\.x)
    let yValues = points.map(\.y)
    guard
      let minX = xValues.min(),
      let maxX = xValues.max(),
      let minY = yValues.min(),
      let maxY = yValues.max()
    else { return .zero }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}

public struct DocumentGeometryObservation: Codable, Equatable, Sendable {
  public enum DetectionMethod: String, Codable, Equatable, Sendable {
    case visionDocumentSegmentation
    case ossDocumentScannerOpenCV
  }

  public let method: DetectionMethod
  public let implementationVersion: String
  public let requestRevision: Int?
  public let confidence: Float?
  public let normalizedCoordinateQuantization: DocumentNormalizedPoint?
  public let analysisPixelWidth: Int?
  public let analysisPixelHeight: Int?
  public let regionOfInterest: CGRect
  public let orientedPixelWidth: Int
  public let orientedPixelHeight: Int
  public let quadrilateral: DocumentQuadrilateral
}

enum DocumentStillGeometryDetector {
  static func proposals(
    in image: CGImage,
    orientation: CGImagePropertyOrientation,
    regionOfInterest: CGRect
  ) -> [DocumentGeometryObservation] {
    var proposals: [DocumentGeometryObservation] = []
    if let visionProposal = visionProposal(
      in: image,
      orientation: orientation,
      regionOfInterest: regionOfInterest
    ) {
      proposals.append(visionProposal)
    }
    if let openCVProposal = OpenCVDocumentGeometryProposalSource.propose(
      in: image,
      orientation: orientation,
      regionOfInterest: regionOfInterest
    ) {
      proposals.append(openCVProposal)
    }
    return proposals
  }

  private static func visionProposal(
    in image: CGImage,
    orientation: CGImagePropertyOrientation,
    regionOfInterest: CGRect
  ) -> DocumentGeometryObservation? {
    let request = VNDetectDocumentSegmentationRequest()
    request.regionOfInterest = regionOfInterest
    do {
      try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
    } catch {
      return nil
    }

    let orientedSize = DocumentPhotoGeometryPolicy.orientedImageSize(
      width: image.width,
      height: image.height,
      orientation: orientation
    )
    guard
      let document = request.results?.first,
      let quadrilateral = imageNormalizedQuadrilateral(
        document,
        fromRegionOfInterest: regionOfInterest,
        orientedImageSize: orientedSize
      )
    else { return nil }

    return DocumentGeometryObservation(
      method: .visionDocumentSegmentation,
      implementationVersion: "Vision.VNDetectDocumentSegmentationRequest",
      requestRevision: request.revision,
      confidence: document.confidence,
      normalizedCoordinateQuantization: nil,
      analysisPixelWidth: nil,
      analysisPixelHeight: nil,
      regionOfInterest: regionOfInterest,
      orientedPixelWidth: Int(orientedSize.width.rounded()),
      orientedPixelHeight: Int(orientedSize.height.rounded()),
      quadrilateral: quadrilateral
    )
  }

  static func imageNormalizedQuadrilateral(
    _ observation: VNRectangleObservation,
    fromRegionOfInterest regionOfInterest: CGRect,
    orientedImageSize: CGSize
  ) -> DocumentQuadrilateral? {
    guard orientedImageSize.width > 0, orientedImageSize.height > 0 else { return nil }

    func convert(_ point: CGPoint) -> DocumentNormalizedPoint? {
      let imagePoint = VNImagePointForNormalizedPointUsingRegionOfInterest(
        point,
        Int(orientedImageSize.width.rounded()),
        Int(orientedImageSize.height.rounded()),
        regionOfInterest
      )
      let normalized = DocumentNormalizedPoint(
        x: imagePoint.x / orientedImageSize.width,
        y: imagePoint.y / orientedImageSize.height
      )
      guard normalized.x.isFinite, normalized.y.isFinite else { return nil }
      return normalized
    }

    guard
      let topLeft = convert(observation.topLeft),
      let topRight = convert(observation.topRight),
      let bottomRight = convert(observation.bottomRight),
      let bottomLeft = convert(observation.bottomLeft)
    else { return nil }
    return DocumentQuadrilateral(
      topLeft: topLeft,
      topRight: topRight,
      bottomRight: bottomRight,
      bottomLeft: bottomLeft
    )
  }
}

enum DocumentPhotoGeometryPolicy {
  private static let guideEdgeMarginFactor = DocumentCaptureTuning.Geometry.guideEdgeMarginFactor

  static func containsCompleteID1(
    in image: CGImage,
    orientation: CGImagePropertyOrientation,
    regionOfInterest: CGRect
  ) -> Bool {
    completeID1Candidate(
      from: DocumentStillGeometryDetector.proposals(
        in: image,
        orientation: orientation,
        regionOfInterest: regionOfInterest
      )
    ) != nil
  }

  static func completeID1Candidate(
    from proposals: [DocumentGeometryObservation]
  ) -> DocumentGeometryObservation? {
    proposals.first(where: isCompleteID1Candidate)
  }

  static func isCompleteID1Candidate(_ observation: DocumentGeometryObservation) -> Bool {
    let size = CGSize(
      width: observation.orientedPixelWidth,
      height: observation.orientedPixelHeight
    )
    guard isValidConvexQuadrilateral(observation.quadrilateral) else { return false }
    let detectorQuantization =
      observation.method == .ossDocumentScannerOpenCV
      ? observation.normalizedCoordinateQuantization
      : nil
    return isCompleteID1Candidate(
      observation.quadrilateral.boundingBox,
      inside: observation.regionOfInterest,
      orientedImageSize: size,
      normalizedCoordinateTolerance: detectorQuantization
    ) && hasID1EdgeAspect(observation.quadrilateral, orientedImageSize: size)
  }

  static func isCompleteID1Candidate(
    _ documentBounds: CGRect,
    inside guideRegion: CGRect,
    orientedImageSize: CGSize,
    normalizedCoordinateTolerance: DocumentNormalizedPoint? = nil
  ) -> Bool {
    guard
      !documentBounds.isEmpty,
      !guideRegion.isEmpty,
      orientedImageSize.width > 0,
      orientedImageSize.height > 0
    else { return false }

    let toleranceX = normalizedCoordinateTolerance?.x ?? 0
    let toleranceY = normalizedCoordinateTolerance?.y ?? 0
    guard
      toleranceX.isFinite,
      toleranceY.isFinite,
      toleranceX >= 0,
      toleranceY >= 0
    else { return false }
    let containmentRegion = guideRegion.insetBy(
      dx: (guideRegion.width * guideEdgeMarginFactor) - toleranceX,
      dy: (guideRegion.height * guideEdgeMarginFactor) - toleranceY
    )
    guard !containmentRegion.isEmpty else { return false }
    guard containmentRegion.contains(documentBounds) else { return false }

    let guideArea = guideRegion.width * guideRegion.height
    let documentArea = documentBounds.width * documentBounds.height
    guard documentArea / guideArea >= 0.25 else { return false }

    let pixelAspect =
      (documentBounds.width * orientedImageSize.width)
      / (documentBounds.height * orientedImageSize.height)
    return (1.3...1.9).contains(pixelAspect)
  }

  static func imageNormalizedRect(
    _ regionNormalizedRect: CGRect,
    fromRegionOfInterest regionOfInterest: CGRect,
    orientedImageSize: CGSize
  ) -> CGRect? {
    guard
      !regionNormalizedRect.isEmpty,
      !regionOfInterest.isEmpty,
      orientedImageSize.width > 0,
      orientedImageSize.height > 0
    else { return nil }

    let imageWidth = Int(orientedImageSize.width.rounded())
    let imageHeight = Int(orientedImageSize.height.rounded())
    guard imageWidth > 0, imageHeight > 0 else { return nil }

    let imageRect = VNImageRectForNormalizedRectUsingRegionOfInterest(
      regionNormalizedRect,
      imageWidth,
      imageHeight,
      regionOfInterest
    )
    let normalizedRect = CGRect(
      x: imageRect.minX / orientedImageSize.width,
      y: imageRect.minY / orientedImageSize.height,
      width: imageRect.width / orientedImageSize.width,
      height: imageRect.height / orientedImageSize.height
    )
    guard
      normalizedRect.minX.isFinite,
      normalizedRect.minY.isFinite,
      normalizedRect.width.isFinite,
      normalizedRect.height.isFinite,
      !normalizedRect.isEmpty
    else { return nil }
    return normalizedRect
  }

  static func orientedImageSize(
    width: Int,
    height: Int,
    orientation: CGImagePropertyOrientation
  ) -> CGSize {
    switch orientation {
    case .left, .leftMirrored, .right, .rightMirrored:
      CGSize(width: height, height: width)
    default:
      CGSize(width: width, height: height)
    }
  }

  static func isValidConvexQuadrilateral(_ quadrilateral: DocumentQuadrilateral) -> Bool {
    let points = quadrilateral.points.map(\.cgPoint)
    guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
    let crosses = points.indices.map { index -> CGFloat in
      let first = points[index]
      let second = points[(index + 1) % points.count]
      let third = points[(index + 2) % points.count]
      return ((second.x - first.x) * (third.y - second.y))
        - ((second.y - first.y) * (third.x - second.x))
    }
    return crosses.allSatisfy { $0 > 0 } || crosses.allSatisfy { $0 < 0 }
  }

  private static func hasID1EdgeAspect(
    _ quadrilateral: DocumentQuadrilateral,
    orientedImageSize: CGSize
  ) -> Bool {
    func distance(_ first: DocumentNormalizedPoint, _ second: DocumentNormalizedPoint) -> Double {
      hypot(
        (second.x - first.x) * orientedImageSize.width,
        (second.y - first.y) * orientedImageSize.height
      )
    }
    let width =
      (distance(quadrilateral.topLeft, quadrilateral.topRight)
        + distance(quadrilateral.bottomLeft, quadrilateral.bottomRight)) / 2
    let height =
      (distance(quadrilateral.topLeft, quadrilateral.bottomLeft)
        + distance(quadrilateral.topRight, quadrilateral.bottomRight)) / 2
    guard width > 0, height > 0 else { return false }
    return (DocumentCaptureTuning.Geometry.minimumID1EdgeAspect...DocumentCaptureTuning.Geometry.maximumID1EdgeAspect)
      .contains(max(width, height) / min(width, height))
  }
}
