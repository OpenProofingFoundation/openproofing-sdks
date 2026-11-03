import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension DocumentImageDerivation {
  /// Integer pixel edges on the retained original drawn upright: top-left origin, x right,
  /// y down. The fixed margin is relative to the document's axis-aligned source bounding box,
  /// not to the normalized ID-1 raster. Clipping never removes the required background ring.
  public struct ContextCrop: Codable, Equatable, Sendable {
    public static let supportedPolicyVersion = "id1-native-context-bbox75-v1"
    public let policyVersion: String
    public let sourcePixelWidth: Int
    public let sourcePixelHeight: Int
    public let left: Int
    public let top: Int
    public let width: Int
    public let height: Int
    public let paddingFraction: Double
    public let clippedToSourceBounds: Bool

    static func expected(
      for geometry: DocumentGeometryObservation, policyVersion: String = supportedPolicyVersion
    ) -> Self? {
      let factor: Double
      let padding: Double
      switch policyVersion {
      case supportedPolicyVersion:
        // The document bounding box occupies 75% of the requested crop area. Actual
        // quadrilateral coverage depends on perspective; pixels are never rectified here.
        factor = 1 / sqrt(0.75)
        padding = (factor - 1) / 2
      case "id1-native-context-20pct-v1":
        // Retained evidence keeps the exact historical arithmetic and identity.
        factor = 1 / sqrt(1 / (1.4 * 1.4))
        padding = 0.2
      default: return nil
      }
      let canvasWidth = geometry.orientedPixelWidth
      let canvasHeight = geometry.orientedPixelHeight
      let guide = geometry.regionOfInterest
      guard (1...Int(Int32.max)).contains(canvasWidth),
        (1...Int(Int32.max)).contains(canvasHeight),
        !guide.isEmpty, [guide.minX, guide.minY, guide.maxX, guide.maxY].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
        DocumentPhotoGeometryPolicy.isCompleteID1Candidate(geometry),
        geometry.quadrilateral.points.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) })
      else { return nil }
      let points = geometry.quadrilateral.points.map {
        CGPoint(x: $0.x * Double(canvasWidth), y: (1 - $0.y) * Double(canvasHeight))
      }
      guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
        let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
        minX < maxX, minY < maxY else { return nil }
      // Keep the physical replay's centered expansion and outward integral rounding.
      // Algebraic rewrites can move an edge by an ULP.
      let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
      let requested = CGRect(x: bounds.midX - bounds.width * factor / 2,
        y: bounds.midY - bounds.height * factor / 2,
        width: bounds.width * factor, height: bounds.height * factor).integral
      let requestedLeft = Int(requested.minX)
      let requestedTop = Int(requested.minY)
      let requestedRight = Int(requested.maxX)
      let requestedBottom = Int(requested.maxY)
      let left = max(0, requestedLeft)
      let top = max(0, requestedTop)
      let right = min(canvasWidth, requestedRight)
      let bottom = min(canvasHeight, requestedBottom)
      // At least one full source pixel outside the document's integer bounding box on each
      // side. A document at the source/crop edge cannot masquerade as a contextual image.
      guard left < Int(floor(minX)), top < Int(floor(minY)),
        right > Int(ceil(maxX)), bottom > Int(ceil(maxY)) else { return nil }
      return Self(policyVersion: policyVersion,
        sourcePixelWidth: canvasWidth, sourcePixelHeight: canvasHeight,
        left: left, top: top, width: right - left, height: bottom - top, paddingFraction: padding,
        clippedToSourceBounds: left != requestedLeft || top != requestedTop
          || right != requestedRight || bottom != requestedBottom)
    }
  }

  var isSupportedContextCrop: Bool {
    guard operation == .contextCrop, let crop = contextCrop,
      crop == ContextCrop.expected(for: geometry, policyVersion: crop.policyVersion), id1Geometry == nil,
      implementationVersion == crop.policyVersion,
      outputPixelWidth == crop.width, outputPixelHeight == crop.height,
      outputUniformTypeIdentifier == UTType.png.identifier, !usesNonuniformScaling,
      sourceOrientation.map({ (1...8).contains($0) }) ?? true
    else { return false }
    return [sourceSHA256, outputSHA256].allSatisfy {
      $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
  }
}

/// One predetermined context raster of a retained ID-1 capture. No detector, perspective warp,
/// resizing, provider-result selection or admission decision occurs here. Pixels are an integer
/// crop of `uprightOriginal` in the source colour space; the original's custody remains intact.
public enum AppleDocumentContextImagePreparer {
  public static func prepareRetained(
    data: Data, sourceSHA256: String, preparedDocument: DerivedDocumentImage
  ) async throws -> DerivedDocumentImage {
    try await DocumentImageProcessingQueue.shared.run { checkCancellation in
      try prepare(data: data, sourceSHA256: sourceSHA256, preparedDocument: preparedDocument,
        checkCancellation: checkCancellation)
    }
  }

  static func prepare(
    data: Data, sourceSHA256: String, preparedDocument: DerivedDocumentImage,
    checkCancellation: () throws -> Void = { try Task.checkCancellation() }
  ) throws -> DerivedDocumentImage {
    try checkCancellation()
    let prepared = preparedDocument.derivation
    guard digest(data) == sourceSHA256, prepared.sourceSHA256 == sourceSHA256,
      digest(preparedDocument.data) == prepared.outputSHA256
    else { throw DocumentImagePreparationError.sourceIntegrityMismatch }
    guard prepared.supported, prepared.operation != .contextCrop,
      prepared.outputUniformTypeIdentifier == UTType.png.identifier, !prepared.usesNonuniformScaling,
      let crop = DocumentImageDerivation.ContextCrop.expected(for: prepared.geometry)
    else { throw DocumentImagePreparationError.invalidDocumentGeometry }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { throw DocumentImagePreparationError.imageUndecodable }
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    guard orientation == prepared.sourceOrientation else {
      throw DocumentImagePreparationError.invalidDocumentGeometry
    }
    try validatePreparedRaster(preparedDocument)
    try checkCancellation()
    let original = try AppleDocumentImagePreparer.uprightOriginal(data: data)
    guard original.width == crop.sourcePixelWidth, original.height == crop.sourcePixelHeight,
      let image = original.cropping(to: CGRect(x: crop.left, y: crop.top, width: crop.width, height: crop.height)),
      image.width == crop.width, image.height == crop.height
    else { throw DocumentImagePreparationError.invalidDocumentGeometry }
    try checkCancellation()
    let encoded = try AppleDocumentImagePreparer.pngData(from: image)
    try checkCancellation()
    let derivation = DocumentImageDerivation(schemaVersion: 5, sourceSHA256: sourceSHA256,
      sourceOrientation: orientation, operation: .contextCrop,
      implementationVersion: DocumentImageDerivation.ContextCrop.supportedPolicyVersion,
      geometry: prepared.geometry, outputPixelWidth: image.width, outputPixelHeight: image.height,
      outputUniformTypeIdentifier: UTType.png.identifier, usesNonuniformScaling: false,
      outputSHA256: digest(encoded), id1Geometry: nil, contextCrop: crop)
    guard derivation.supported else { throw DocumentImagePreparationError.invalidDocumentGeometry }
    return DerivedDocumentImage(data: encoded, derivation: derivation)
  }

  private static func validatePreparedRaster(_ prepared: DerivedDocumentImage) throws {
    guard let source = CGImageSourceCreateWithData(prepared.data as CFData, nil),
      (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == prepared.derivation.outputPixelWidth,
      image.height == prepared.derivation.outputPixelHeight
    else { throw DocumentImagePreparationError.invalidDocumentGeometry }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    guard orientation == nil || orientation == 1 else {
      throw DocumentImagePreparationError.invalidDocumentGeometry
    }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
