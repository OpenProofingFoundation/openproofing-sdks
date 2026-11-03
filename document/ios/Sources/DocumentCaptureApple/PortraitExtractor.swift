// Native request/orientation pattern adapted from Apple's Detecting Objects in Still Images.
// Copyright © 2024 Apple Inc. See ThirdPartyNotices/Apple-DetectingObjectsInStillImages.txt.
import CoreGraphics
import CryptoKit
import Foundation
import DocumentSDK
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Extracts provisional face-region candidates from an upright document derivative.
/// Original full-frame images and orientation transforms are intentionally outside this API.
public struct ApplePortraitExtractor: Sendable {
  static let implementationVersion = "apple-vision-face-region-png-v2"

  public init() {}

  public func extract(
    data: Data, derivation: DocumentImageDerivation, paddingFraction: Double = PortraitCropDefaults.paddingFraction
  ) async throws -> PortraitExtractionResult {
    return try await DocumentImageProcessingQueue.shared.run { checkCancellation in
      try checkCancellation()
      let image = try Self.verifiedImage(
        data: data, expectedSHA256: derivation.outputSHA256,
        width: derivation.outputPixelWidth, height: derivation.outputPixelHeight)
      let request = VNDetectFaceRectanglesRequest()
      try DocumentVisionRequests.configureFaces(request)
      // The preparer has already oriented the pixels. Passing the ORIGINAL
      // capture's EXIF orientation here would apply the transform twice.
      try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
      guard let faces = request.results else {
        throw PortraitExtractionError.detectionResultsUnavailable
      }
      let observations = faces.map { face in
        PortraitFaceObservation(
          boundingBox: PortraitNormalizedRect(
            x: Double(face.boundingBox.minX), y: Double(face.boundingBox.minY),
            width: Double(face.boundingBox.width), height: Double(face.boundingBox.height)),
          confidence: Double(face.confidence))
      }
      try checkCancellation()
      return try Self.render(
        image: image, sourceSHA256: derivation.outputSHA256,
        observations: observations, requestRevision: request.revision, paddingFraction: paddingFraction)
    }
  }

  static func verifiedImage(
    data: Data, expectedSHA256: String, width: Int, height: Int
  ) throws -> CGImage {
    guard digest(data) == expectedSHA256 else {
      throw PortraitExtractionError.sourceIntegrityMismatch
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw PortraitExtractionError.imageUndecodable }
    guard image.width == width, image.height == height else {
      throw PortraitExtractionError.sourceDimensionsMismatch
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    guard orientation == nil || orientation == 1 else {
      throw PortraitExtractionError.sourceMustBeUpright
    }
    return image
  }

  static func render(
    image: CGImage, sourceSHA256: String,
    observations: [PortraitFaceObservation], requestRevision: Int, paddingFraction: Double = PortraitCropDefaults.paddingFraction
  ) throws -> PortraitExtractionResult {
    let assessment = PortraitCropPolicy.evaluate(
      faces: observations, imageWidth: image.width, imageHeight: image.height, paddingFraction: paddingFraction)
    let candidates = try assessment.candidates.map { geometry in
      try makeCandidate(image: image, sourceSHA256: sourceSHA256, geometry: geometry)
    }
    return PortraitExtractionResult(
      metadata: PortraitExtractionMetadata(
        schemaVersion: 1, sourceSHA256: sourceSHA256,
        sourcePixelWidth: image.width, sourcePixelHeight: image.height,
        implementationVersion: implementationVersion, faceRequestRevision: requestRevision,
        observations: observations, assessment: assessment),
      candidates: candidates)
  }

  private static func makeCandidate(
    image: CGImage, sourceSHA256: String, geometry: PortraitCropCandidate
  ) throws -> PortraitImageCandidate {
    let bounds = geometry.pixelRect
    let rect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    guard let crop = image.cropping(to: rect),
      crop.width == bounds.width, crop.height == bounds.height
    else { throw PortraitExtractionError.cropFailed }
    let data = try encodePNG(crop)
    return PortraitImageCandidate(
      data: data,
      metadata: PortraitImageDerivation(
        schemaVersion: 1, sourceSHA256: sourceSHA256,
        implementationVersion: implementationVersion, geometry: geometry,
        outputSHA256: digest(data), outputPixelWidth: crop.width, outputPixelHeight: crop.height,
        outputUniformTypeIdentifier: UTType.png.identifier))
  }

  static func encodePNG(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil)
    else { throw PortraitExtractionError.encodingFailed }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw PortraitExtractionError.encodingFailed
    }
    return data as Data
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
