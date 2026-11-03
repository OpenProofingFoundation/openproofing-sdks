import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import DocumentSDK
import ImageIO
import UniformTypeIdentifiers

public enum DocumentImagePreparationError: String, Error, Equatable, Sendable {
  case imageUndecodable
  case sourceIntegrityMismatch
  case guideUnavailable
  case documentNotDetected
  case invalidDocumentGeometry
  case perspectiveCorrectionFailed
  case derivativeEncodingFailed
}

public struct DocumentStillQuality: Codable, Equatable, Sendable {
  public let sharpness: Double
  public let meanLuminance: Double
  public let clippedHighlightRatio: Double
}

public struct DocumentImageDerivation: Codable, Equatable, Sendable {
  public enum Operation: String, Codable, Equatable, Sendable {
    case perspectiveCorrection
    case id1Normalization
    case contextCrop
  }

  public let schemaVersion: Int
  public let sourceSHA256: String
  public let sourceOrientation: Int?
  public let operation: Operation
  public let implementationVersion: String
  public let geometry: DocumentGeometryObservation
  public let outputPixelWidth: Int
  public let outputPixelHeight: Int
  public let outputUniformTypeIdentifier: String
  public let usesNonuniformScaling: Bool
  public let outputSHA256: String
  public var id1Geometry: ID1CardGeometry?
  /// Present only for a native, unwarped context crop (schema 5). Older derivations omit it.
  public var contextCrop: ContextCrop?

  public var supported: Bool {
    if schemaVersion == 5 { return isSupportedContextCrop }
    guard contextCrop == nil else { return false }
    if schemaVersion == 3 { return operation == .perspectiveCorrection && id1Geometry == nil }
    return schemaVersion == 4 && operation == .id1Normalization && id1Geometry?.valid == true
      && outputPixelWidth == ID1CardGeometry.pixelWidth
      && outputPixelHeight == ID1CardGeometry.pixelHeight
      && id1Geometry?.sourcePixelWidth == geometry.orientedPixelWidth
      && id1Geometry?.sourcePixelHeight == geometry.orientedPixelHeight
      && id1Geometry?.matches(geometry) == true
  }
}

public struct DerivedDocumentImage: Sendable {
  public let data: Data
  public let derivation: DocumentImageDerivation

  public init(data: Data, derivation: DocumentImageDerivation) {
    self.data = data
    self.derivation = derivation
  }
}

public struct PreparedDocumentCandidate: Sendable {
  public let original: CapturedDocumentPhoto
  public let derivative: DerivedDocumentImage
  public let quality: DocumentStillQuality
  public let usability: DocumentPhotoUsabilityAssessment
}

public protocol DocumentImagePreparing: Sendable {
  func prepare(_ photo: CapturedDocumentPhoto) async throws -> PreparedDocumentCandidate
}

public struct AppleDocumentImagePreparer: DocumentImagePreparing, Sendable {
  public enum Profile: Sendable { case license, passport, passportCard }
  public let profile: Profile

  public init(profile: Profile = .license) { self.profile = profile }

  public func prepare(_ photo: CapturedDocumentPhoto) async throws -> PreparedDocumentCandidate {
    let data = photo.data
    let side = photo.side
    let orientation = photo.fidelity.orientation
    let sourceSHA256 = photo.fidelity.sha256
    guard
      let regionOfInterest = DocumentPhotoUsabilityEvaluator.visionRegionOfInterest(
        from: photo.admission
      )
    else {
      throw DocumentImagePreparationError.guideUnavailable
    }

    let prepared = try await DocumentImageProcessingQueue.shared.run { checkCancellation in
      try Self.prepare(
        data: data,
        side: side,
        orientation: orientation,
        sourceSHA256: sourceSHA256,
        regionOfInterest: regionOfInterest,
        profile: profile,
        checkCancellation: checkCancellation
      )
    }
    try Task.checkCancellation()
    return PreparedDocumentCandidate(
      original: photo,
      derivative: prepared.derivative,
      quality: prepared.quality,
      usability: prepared.usability
    )
  }

  public struct PreparedImage: Sendable {
    public let derivative: DerivedDocumentImage
    public let quality: DocumentStillQuality
    public let usability: DocumentPhotoUsabilityAssessment
  }

  /// Reprocess retained bytes with their original admission geometry. Does not create
  /// a live capture or replace its original provenance.
  public func prepareRetained(
    data: Data, side: DocumentSide, fidelity: PhotoFidelityMetadata,
    admission: DocumentCaptureAdmissionSnapshot?
  ) async throws -> PreparedImage {
    guard let region = DocumentPhotoUsabilityEvaluator.visionRegionOfInterest(from: admission)
    else {
      throw DocumentImagePreparationError.guideUnavailable
    }
    return try await DocumentImageProcessingQueue.shared.run { checkCancellation in
      try Self.prepare(
        data: data, side: side, orientation: fidelity.orientation,
        sourceSHA256: fidelity.sha256, regionOfInterest: region, profile: profile,
        checkCancellation: checkCancellation)
    }
  }

  static func prepare(
    data: Data,
    side: DocumentSide,
    orientation: Int?,
    sourceSHA256: String,
    regionOfInterest: CGRect,
    profile: Profile = .license,
    checkCancellation: () throws -> Void = { try Task.checkCancellation() }
  ) throws -> PreparedImage {
    try checkCancellation()
    guard sha256(data) == sourceSHA256 else {
      throw DocumentImagePreparationError.sourceIntegrityMismatch
    }
    let image = try decodeImage(data)
    let imageOrientation =
      orientation
      .flatMap { CGImagePropertyOrientation(rawValue: UInt32($0)) }
      ?? .up
    let proposals = DocumentStillGeometryDetector.proposals(
      in: image,
      orientation: imageOrientation,
      regionOfInterest: regionOfInterest
    )
    try checkCancellation()
    guard !proposals.isEmpty else {
      throw DocumentImagePreparationError.documentNotDetected
    }
    guard let geometry = DocumentPhotoGeometryPolicy.completeID1Candidate(from: proposals) else {
      throw DocumentImagePreparationError.invalidDocumentGeometry
    }

    let (correctedImage, id1Geometry) = try correctedRaster(
      orientedImage(image, orientation: imageOrientation), geometry: geometry, profile: profile)
    try checkCancellation()
    let derivative = try makeDerivative(
      from: correctedImage,
      sourceSHA256: sourceSHA256,
      sourceOrientation: orientation,
      geometry: geometry, id1Geometry: id1Geometry
    )
    let quality = DocumentStillQualityAnalyzer.analyze(correctedImage)
    let usability =
      (profile == .passport || (profile == .passportCard && side == .back))
      ? DocumentPhotoUsabilityEvaluator.evaluatePassport(
        data: derivative.data, card: profile == .passportCard)
      : DocumentPhotoUsabilityEvaluator.evaluate(
        data: derivative.data, side: side, orientation: nil)
    try checkCancellation()
    return PreparedImage(
      derivative: derivative,
      quality: quality,
      usability: usability
    )
  }

  private static func correctedRaster(
    _ oriented: CIImage, geometry: DocumentGeometryObservation, profile: Profile
  ) throws -> (CGImage, ID1CardGeometry?) {
    let context = CIContext(options: [.cacheIntermediates: false])
    let correctedImage: CGImage
    let id1Geometry: ID1CardGeometry?
    if profile != .passport {
      do {
        let mapping = try ID1CardGeometry(observation: geometry)
        correctedImage = try ID1ImageNormalizer.render(oriented, geometry: mapping)
        id1Geometry = mapping
      } catch { throw DocumentImagePreparationError.perspectiveCorrectionFailed }
    } else {
      let corrected = try perspectiveCorrected(oriented, geometry: geometry)
      guard let image = context.createCGImage(corrected, from: corrected.extent.integral) else {
        throw DocumentImagePreparationError.perspectiveCorrectionFailed
      }
      correctedImage = image
      id1Geometry = nil
    }
    return (correctedImage, id1Geometry)
  }

  private static func decodeImage(_ data: Data) throws -> CGImage {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw DocumentImagePreparationError.imageUndecodable
    }
    return image
  }

  private static func makeDerivative(
    from image: CGImage,
    sourceSHA256: String,
    sourceOrientation: Int?,
    geometry: DocumentGeometryObservation, id1Geometry: ID1CardGeometry?
  ) throws -> DerivedDocumentImage {
    let data = try pngData(from: image)
    return DerivedDocumentImage(
      data: data,
      derivation: DocumentImageDerivation(
        schemaVersion: id1Geometry == nil ? 3 : 4,
        sourceSHA256: sourceSHA256,
        sourceOrientation: sourceOrientation,
        operation: id1Geometry == nil ? .perspectiveCorrection : .id1Normalization,
        implementationVersion: id1Geometry?.implementationVersion
          ?? "apple-core-image-ci-perspective-correction-v1",
        geometry: geometry,
        outputPixelWidth: image.width,
        outputPixelHeight: image.height,
        outputUniformTypeIdentifier: UTType.png.identifier,
        usesNonuniformScaling: false,
        outputSHA256: sha256(data), id1Geometry: id1Geometry
      )
    )
  }

  static func perspectiveCorrected(
    _ image: CIImage,
    geometry: DocumentGeometryObservation
  ) throws -> CIImage {
    let width = image.extent.width
    let height = image.extent.height
    guard
      Int(width.rounded()) == geometry.orientedPixelWidth,
      Int(height.rounded()) == geometry.orientedPixelHeight
    else {
      throw DocumentImagePreparationError.invalidDocumentGeometry
    }

    func pixelPoint(_ point: DocumentNormalizedPoint) -> CGPoint {
      CGPoint(x: point.x * width, y: point.y * height)
    }

    let filter = CIFilter.perspectiveCorrection()
    filter.inputImage = image
    filter.topLeft = pixelPoint(geometry.quadrilateral.topLeft)
    filter.topRight = pixelPoint(geometry.quadrilateral.topRight)
    filter.bottomRight = pixelPoint(geometry.quadrilateral.bottomRight)
    filter.bottomLeft = pixelPoint(geometry.quadrilateral.bottomLeft)
    filter.crop = true
    guard let output = filter.outputImage, !output.extent.isEmpty else {
      throw DocumentImagePreparationError.perspectiveCorrectionFailed
    }
    return zeroOrigin(output)
  }

  static func orientedImage(
    _ image: CGImage,
    orientation: CGImagePropertyOrientation
  ) -> CIImage {
    zeroOrigin(CIImage(cgImage: image).oriented(orientation))
  }

  /// The original photo at full resolution, drawn upright by `orientedImage(_:orientation:)`
  /// using the orientation that `PhotoFidelityMetadata` records for the same bytes. Nothing is
  /// cropped, rectified or resampled. A consumer that would otherwise redraw the photo upright
  /// itself (a vendor document reader, on its caller's thread) can do this ahead of time, off
  /// the main actor.
  ///
  /// The render keeps the SOURCE's own colour space, in a format matched to its colour model:
  /// RGBA8 for an RGB source, 8-bit grey (L8) for a greyscale one. Rendering into sRGB, as the
  /// ID-1 normalizer does, colour-converts every pixel: on a Display P3 48 MP licence frame, 111
  /// of 146 million channels changed, by up to 39 levels, relative to a plain upright redraw.
  /// Kept in the source colour space, the same frame matched that redraw in every channel, so a
  /// consumer analysing this image analyses the pixels it would have produced itself.
  ///
  /// Throws `imageUndecodable` when the bytes do not decode, carry an orientation tag that
  /// names no orientation, have a colour model other than RGB or greyscale, or cannot be
  /// rendered; `PhotoCaptureError.imageMetadataUnavailable` when the image properties are
  /// unreadable.
  public static func uprightOriginal(data: Data) throws -> CGImage {
    let image = try decodeImage(data)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CapturedPhotoPlatformMetadata.encodedProperties(of: source)
    else { throw PhotoCaptureError.imageMetadataUnavailable }
    let fidelity = try PhotoFidelityMetadata.make(
      from: data, source: source, properties: properties, auxiliaryDataTypes: [])
    // No tag means upright, by the EXIF definition. A tag that is present but names no
    // orientation cannot be drawn upright, and is not guessed.
    let orientation: CGImagePropertyOrientation
    if let tag = fidelity.orientation {
      guard let raw = UInt32(exactly: tag), let parsed = CGImagePropertyOrientation(rawValue: raw)
      else { throw DocumentImagePreparationError.imageUndecodable }
      orientation = parsed
    } else {
      orientation = .up
    }
    let oriented = orientedImage(image, orientation: orientation)
    guard let colorSpace = image.colorSpace else {
      throw DocumentImagePreparationError.imageUndecodable
    }
    let format: CIFormat
    switch colorSpace.model {
    case .rgb: format = .RGBA8
    case .monochrome: format = .L8
    default: throw DocumentImagePreparationError.imageUndecodable
    }
    guard
      let upright = CIContext(options: [.cacheIntermediates: false]).createCGImage(
        oriented, from: oriented.extent, format: format, colorSpace: colorSpace)
    else { throw DocumentImagePreparationError.imageUndecodable }
    return upright
  }

  private static func zeroOrigin(_ image: CIImage) -> CIImage {
    image.transformed(
      by: CGAffineTransform(
        translationX: -image.extent.minX,
        y: -image.extent.minY
      )
    )
  }

  static func pngData(from image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      throw DocumentImagePreparationError.derivativeEncodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw DocumentImagePreparationError.derivativeEncodingFailed
    }
    return data as Data
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

enum DocumentStillQualityAnalyzer {
  static func analyze(_ image: CGImage) -> DocumentStillQuality {
    let width = 64
    let height = 48
    var samples = [UInt8](repeating: 0, count: width * height)
    let rendered = samples.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let baseAddress = bytes.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
      else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else {
      return DocumentStillQuality(sharpness: 0, meanLuminance: 0, clippedHighlightRatio: 0)
    }

    let count = max(samples.count, 1)
    let mean = Double(samples.reduce(0) { $0 + Int($1) }) / Double(count * 255)
    let clipped =
      Double(samples.count(where: { $0 >= DocumentCaptureTuning.Quality.clippedLumaSample })) / Double(count)
    var gradientSum = 0
    var gradientCount = 0
    for row in 1..<height {
      for column in 1..<width {
        let index = (row * width) + column
        gradientSum += abs(Int(samples[index]) - Int(samples[index - 1]))
        gradientSum += abs(Int(samples[index]) - Int(samples[index - width]))
        gradientCount += 2
      }
    }
    return DocumentStillQuality(
      sharpness: Double(gradientSum) / Double(max(gradientCount, 1) * 255),
      meanLuminance: mean,
      clippedHighlightRatio: clipped
    )
  }
}
