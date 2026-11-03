import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import DocumentCaptureApple

struct DocumentSpatialProcessorTests {
  @Test func rgbExtractionPreservesTopRowAndChannelOrder() throws {
    let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                         0, 0, 255, 255, 255, 255, 255, 255]
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        .union(.byteOrder32Big), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    #expect(try DocumentSpatialProcessor.pixels(image) == [255, 0, 0, 0, 255, 0,
                                                          0, 0, 255, 255, 255, 255])
  }

  @Test func preflightRejectsWrongSourceBeforeAnalysis() throws {
    let data = try png(width: 5, height: 5)
    let correct = derivation(hash: digest(data), width: 5, height: 5)
    try DocumentSpatialProcessor.preflight(data: data, derivation: correct)
    #expect(throws: DocumentSpatialError.invalidInput) {
      try DocumentSpatialProcessor.preflight(data: data,
        derivation: derivation(hash: String(repeating: "0", count: 64), width: 5, height: 5))
    }
  }

  @Test func fullResolutionSourceAboveFourMillionPixelsPassesPreflightWithoutAnalysis() throws {
    let data = try png(width: 2001, height: 2000)
    try DocumentSpatialProcessor.preflight(data: data,
      derivation: derivation(hash: digest(data), width: 2001, height: 2000))
  }

  @Test func encodedSourceAboveThirtyTwoMegabytesPassesPreflightWithoutAnalysis() throws {
    var data = try png(width: 5, height: 5)
    data.append(Data(repeating: 0, count: 32_000_001))
    try DocumentSpatialProcessor.preflight(data: data,
      derivation: derivation(hash: digest(data), width: 5, height: 5))
  }

  @Test func invalidEncodedImageCannotBeAdmittedByMatchingHash() {
    let data = Data("not an image".utf8)
    #expect(throws: DocumentSpatialError.invalidInput) {
      try DocumentSpatialProcessor.preflight(data: data,
        derivation: derivation(hash: digest(data), width: 5, height: 5))
    }
  }

  @Test func actualNativeAnalysisPreservesSourceAndMatchesIndependentRotationAndMirror() async throws {
    let width = 128, height = 96
    let raw = scene(width: width, height: height)
    for orientation in [1, 2, 6] {
      let swapped = orientation == 6
      let outputWidth = swapped ? height : width, outputHeight = swapped ? width : height
      let source = try encoded(raw, width: width, height: height, orientation: orientation)
      let untouched = source
      let imageSource = try #require(CGImageSourceCreateWithData(source as CFData, nil))
      let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
      #expect(properties[kCGImagePropertyOrientation] as? Int == orientation)
      let result = try await DocumentSpatialProcessor.analyze(data: source,
        derivation: derivation(hash: digest(source), width: outputWidth, height: outputHeight))
      #expect(source == untouched)
      #expect(result.sourceSHA256 == digest(source))
      #expect(result.width == outputWidth)
      #expect(result.height == outputHeight)
      #expect(result.mask.count == width * height)
      #expect(result.mask.contains(0) && result.mask.contains(1))
      #expect(!result.points.isEmpty)
      #expect(result.offsets.count > 1)
      #expect(result.offsets.first == 0 && result.offsets.last == result.points.count)

      // Independent integer EXIF mappings, not the SDK's orientation helper.
      var upright = [UInt8](repeating: 0, count: raw.count)
      for y in 0..<height {
        for x in 0..<width {
          let targetX = orientation == 6 ? height - 1 - y : (orientation == 2 ? width - 1 - x : x)
          let targetY = orientation == 6 ? x : y
          for channel in 0..<4 {
            upright[(targetY * outputWidth + targetX) * 4 + channel] = raw[(y * width + x) * 4 + channel]
          }
        }
      }
      let reference = try encoded(upright, width: outputWidth, height: outputHeight, orientation: 1)
      let expected = try await DocumentSpatialProcessor.analyze(data: reference,
        derivation: derivation(hash: digest(reference), width: outputWidth, height: outputHeight))
      #expect(result.mask == expected.mask)
      #expect(result.points == expected.points)
      #expect(result.offsets == expected.offsets)
      if swapped {
        do {
          _ = try await DocumentSpatialProcessor.analyze(data: source,
            derivation: derivation(hash: digest(source), width: width, height: height))
          Issue.record("Encoded dimensions must not substitute for upright geometry dimensions")
        } catch { #expect(error as? DocumentSpatialError == .invalidInput) }
      }
    }
  }

  private func scene(width: Int, height: Int) -> [UInt8] {
    var result = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let card = x >= 12 && x < 116 && y >= 10 && y < 86
        let feature = card && x > 25 && x < 85 && y > 25 && y < 65 && (y % 11 < 3 || x % 19 < 2)
        let offset = (y * width + x) * 4
        result[offset] = card ? (feature ? 50 : 220) : 20
        result[offset + 1] = card ? (feature ? 80 : 230) : 30
        result[offset + 2] = card ? (feature ? 110 : 240) : 40
      }
    }
    return result
  }

  private func encoded(_ pixels: [UInt8], width: Int, height: Int, orientation: Int) throws -> Data {
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func png(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func derivation(hash: String, width: Int, height: Int) -> DocumentImageDerivation {
    let geometry = DocumentGeometryObservation(method: .visionDocumentSegmentation,
      implementationVersion: "synthetic-test", requestRevision: 1, confidence: 1,
      normalizedCoordinateQuantization: nil, analysisPixelWidth: nil, analysisPixelHeight: nil,
      regionOfInterest: CGRect(x: 0, y: 0, width: 1, height: 1),
      orientedPixelWidth: width, orientedPixelHeight: height,
      quadrilateral: DocumentQuadrilateral(topLeft: .init(x: 0.1, y: 0.9), topRight: .init(x: 0.9, y: 0.9),
        bottomRight: .init(x: 0.9, y: 0.1), bottomLeft: .init(x: 0.1, y: 0.1)))
    return DocumentImageDerivation(schemaVersion: 3, sourceSHA256: hash, sourceOrientation: 1,
      operation: .perspectiveCorrection, implementationVersion: "synthetic-test", geometry: geometry,
      outputPixelWidth: width, outputPixelHeight: height, outputUniformTypeIdentifier: "public.png",
      usesNonuniformScaling: false, outputSHA256: hash)
  }
}
