import CoreGraphics
import CoreImage
import DocumentOpenCVBridge
import ImageIO

enum OpenCVDocumentGeometryProposalSource {
  static let implementationVersion =
    "OSS-DocumentScanner@444bd810e77c571d66d2eecb3e13371e722ee538+opencv-mobile-4.12.0"

  // These are the checked-in still-image settings of the pinned upstream app.
  private static let resizeThreshold = DocumentCaptureDefaults.resizeThreshold
  private static let areaScaleMinFactor = DocumentCaptureDefaults.areaScaleMinFactor
  private static let analysisMaximumDimension = DocumentCaptureDefaults.analysisMaximumDimension

  // This straight-line adapter intentionally keeps raster creation, the single
  // upstream call, and coordinate reconstruction visible as one atomic path.
  // swiftlint:disable:next function_body_length
  static func propose(
    in image: CGImage,
    orientation: CGImagePropertyOrientation,
    regionOfInterest: CGRect
  ) -> DocumentGeometryObservation? {
    let oriented = AppleDocumentImagePreparer.orientedImage(image, orientation: orientation)
    let orientedSize = oriented.extent.size
    guard
      orientedSize.width > 0,
      orientedSize.height > 0
    else { return nil }

    let analysisScale = min(
      1,
      analysisMaximumDimension / max(orientedSize.width, orientedSize.height)
    )
    let analysisImage = oriented.transformed(
      by: CGAffineTransform(scaleX: analysisScale, y: analysisScale)
    )
    let width = Int(analysisImage.extent.width.rounded(.down))
    let height = Int(analysisImage.extent.height.rounded(.down))
    guard width > 0, height > 0 else { return nil }

    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    CIContext(options: [.cacheIntermediates: false]).render(
      analysisImage,
      toBitmap: &pixels,
      rowBytes: bytesPerRow,
      bounds: CGRect(x: 0, y: 0, width: width, height: height),
      format: .RGBA8,
      colorSpace: colorSpace
    )

    var output = IEOpenCVQuadrilateral()
    let found = pixels.withUnsafeBytes { bytes in
      IEOpenCVDetectDocumentQuadrilateralRGBA(
        bytes.bindMemory(to: UInt8.self).baseAddress,
        Int32(width),
        Int32(height),
        bytesPerRow,
        resizeThreshold,
        areaScaleMinFactor,
        &output
      )
    }
    guard found else { return nil }

    let resizeScale = max(
      Double(width) / Double(resizeThreshold),
      Double(height) / Double(resizeThreshold)
    )
    let analysisWidth = max(1, floor(Double(width) / resizeScale))
    let analysisHeight = max(1, floor(Double(height) / resizeScale))

    func imagePoint(_ point: IEOpenCVPoint) -> DocumentNormalizedPoint {
      return DocumentNormalizedPoint(
        x: point.x / Double(width),
        y: 1 - (point.y / Double(height))
      )
    }

    return DocumentGeometryObservation(
      method: .ossDocumentScannerOpenCV,
      implementationVersion: implementationVersion,
      requestRevision: nil,
      confidence: nil,
      normalizedCoordinateQuantization: DocumentNormalizedPoint(
        x: 1 / analysisWidth,
        y: 1 / analysisHeight
      ),
      analysisPixelWidth: width,
      analysisPixelHeight: height,
      regionOfInterest: regionOfInterest,
      orientedPixelWidth: Int(orientedSize.width.rounded()),
      orientedPixelHeight: Int(orientedSize.height.rounded()),
      quadrilateral: DocumentQuadrilateral(
        topLeft: imagePoint(output.topLeft),
        topRight: imagePoint(output.topRight),
        bottomRight: imagePoint(output.bottomRight),
        bottomLeft: imagePoint(output.bottomLeft)
      )
    )
  }
}
