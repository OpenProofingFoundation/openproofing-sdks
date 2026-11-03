import CoreGraphics
import Foundation
import DocumentSDK
import ImageIO
import Testing

@testable import DocumentCaptureApple

@Test func portraitCropPreservesTopRowsAndPixelValuesWithoutVerticalInversion() throws {
  let image = try portraitRaster()
  let output = try ApplePortraitExtractor.render(
    image: image, sourceSHA256: "verified-document", observations: [face(y: 0.5)],
    requestRevision: 3)
  let candidate = try #require(output.candidates.first)
  #expect(
    candidate.metadata.geometry.pixelRect == PortraitPixelRect(x: 0, y: 0, width: 2, height: 2))
  #expect(candidate.metadata.outputSHA256 == ApplePortraitExtractor.digest(candidate.data))
  #expect(candidate.metadata.sourceSHA256 == "verified-document")
  let decoded = try ApplePortraitExtractor.verifiedImage(
    data: candidate.data, expectedSHA256: candidate.metadata.outputSHA256, width: 2, height: 2)
  #expect(decoded.bitsPerPixel == 8)
  let pixels = try #require(decoded.dataProvider?.data) as Data
  #expect(Array(pixels.prefix(2)) == [10, 20])
  #expect(Array(pixels[decoded.bytesPerRow..<(decoded.bytesPerRow + 2)]) == [50, 60])
}

@Test func portraitContextRetainsSurroundingSourcePixelsAndPaddingProvenance() throws {
  let output = try ApplePortraitExtractor.render(
    image: portraitRaster(), sourceSHA256: "verified-document", observations: [face(y: 0.5)],
    requestRevision: 3, paddingFraction: 0.2)
  let candidate = try #require(output.candidates.first)
  #expect(output.metadata.assessment.paddingFraction == 0.2)
  #expect(candidate.metadata.geometry.pixelRect == PortraitPixelRect(x: 0, y: 0, width: 3, height: 3))
  #expect(candidate.metadata.geometry.wasClipped)
  let decoded = try ApplePortraitExtractor.verifiedImage(
    data: candidate.data, expectedSHA256: candidate.metadata.outputSHA256, width: 3, height: 3)
  let pixels = try #require(decoded.dataProvider?.data) as Data
  #expect(Array(pixels.prefix(3)) == [10, 20, 30])
  #expect(Array(pixels[decoded.bytesPerRow..<(decoded.bytesPerRow + 3)]) == [50, 60, 70])
}

@Test func portraitRetainsAllAmbiguousCandidatesAndExplicitNoFace() throws {
  let image = try portraitRaster()
  let ambiguous = try ApplePortraitExtractor.render(
    image: image, sourceSHA256: "verified-document",
    observations: [face(y: 0), face(y: 0.5)], requestRevision: 3)
  #expect(ambiguous.candidates.count == 2)
  #expect(ambiguous.metadata.assessment.outcome == .ambiguous)
  #expect(ambiguous.metadata.assessment.selectedCandidateIndex == nil)
  let empty = try ApplePortraitExtractor.render(
    image: image, sourceSHA256: "verified-document", observations: [], requestRevision: 3)
  #expect(empty.metadata.assessment.outcome == .noFace)
  #expect(empty.candidates.isEmpty)
}

@Test func portraitInputRejectsHashDimensionAndOrientationMismatch() throws {
  let image = try portraitRaster()
  let data = try ApplePortraitExtractor.encodePNG(image)
  #expect(throws: PortraitExtractionError.sourceIntegrityMismatch) {
    try ApplePortraitExtractor.verifiedImage(
      data: data, expectedSHA256: "wrong", width: 4, height: 4)
  }
  #expect(throws: PortraitExtractionError.sourceDimensionsMismatch) {
    try ApplePortraitExtractor.verifiedImage(
      data: data, expectedSHA256: ApplePortraitExtractor.digest(data), width: 3, height: 4)
  }
  let oriented = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(oriented, "public.tiff" as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
  #expect(CGImageDestinationFinalize(destination))
  let bytes = oriented as Data
  #expect(throws: PortraitExtractionError.sourceMustBeUpright) {
    try ApplePortraitExtractor.verifiedImage(
      data: bytes, expectedSHA256: ApplePortraitExtractor.digest(bytes), width: 4, height: 4)
  }
}

private func face(y verticalPosition: Double) -> PortraitFaceObservation {
  PortraitFaceObservation(
    boundingBox: PortraitNormalizedRect(x: 0, y: verticalPosition, width: 0.5, height: 0.5), confidence: 1)
}

private func portraitRaster() throws -> CGImage {
  let data = Data([10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160])
  let provider = try #require(CGDataProvider(data: data as CFData))
  return try #require(
    CGImage(
      width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}
