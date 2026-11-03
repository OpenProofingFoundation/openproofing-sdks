import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DocumentCaptureApple

@Suite struct DocumentContextImagePreparerTests {
  @Test func nativeCropKeepsSourcePixelsAndSeparateLineage() async throws {
    let fixture = try fixture()
    let originalBytes = fixture.data
    let output = try await AppleDocumentContextImagePreparer.prepareRetained(
      data: fixture.data, sourceSHA256: hash(fixture.data), preparedDocument: fixture.prepared)
    let crop = try #require(output.derivation.contextCrop)
    #expect(output.derivation.supported && output.derivation.schemaVersion == 5)
    #expect(output.derivation.operation == .contextCrop)
    #expect(output.derivation.implementationVersion == "id1-native-context-bbox75-v1")
    #expect(crop.policyVersion == output.derivation.implementationVersion)
    let actualBounds: [Int] = [crop.left, crop.top, crop.width, crop.height]
    #expect(actualBounds == [42, 45, 116, 70])
    #expect(!crop.clippedToSourceBounds && crop.paddingFraction == (1 / sqrt(0.75) - 1) / 2)
    #expect(output.derivation.sourceSHA256 == hash(fixture.data))
    #expect(output.derivation.outputSHA256 == hash(output.data))
    #expect(output.derivation.sourceSHA256 != output.derivation.outputSHA256)
    #expect(output.derivation.geometry == fixture.prepared.derivation.geometry)
    #expect(output.derivation.id1Geometry == nil && !output.derivation.usesNonuniformScaling)
    #expect(output.derivation.outputPixelWidth == 116 && output.derivation.outputPixelHeight == 70)
    #expect(fixture.data == originalBytes)
    try assertNativePixels(fixture, output)
    let repeated = try await AppleDocumentContextImagePreparer.prepareRetained(
      data: fixture.data, sourceSHA256: hash(fixture.data), preparedDocument: fixture.prepared)
    #expect(repeated.data == output.data && repeated.derivation == output.derivation)
  }

  @Test func historicalTwentyPercentEvidenceRemainsValidWithoutRelabelling() async throws {
    let fixture = try fixture(), current = try prepare(fixture)
    let original = try AppleDocumentImagePreparer.uprightOriginal(data: fixture.data)
    let legacyBytes = try encode(#require(original.cropping(to: CGRect(x: 30, y: 38, width: 140, height: 84))))
    var metadata = try object(current.derivation)
    metadata["implementationVersion"] = "id1-native-context-20pct-v1"
    metadata["outputPixelWidth"] = 140
    metadata["outputPixelHeight"] = 84
    metadata["outputSHA256"] = hash(legacyBytes)
    var crop = try #require(metadata["contextCrop"] as? [String: Any])
    crop["policyVersion"] = "id1-native-context-20pct-v1"
    crop["left"] = 30; crop["top"] = 38; crop["width"] = 140; crop["height"] = 84
    crop["paddingFraction"] = 0.2
    metadata["contextCrop"] = crop
    let legacy = DerivedDocumentImage(data: legacyBytes, derivation: try derivation(metadata))
    #expect(legacy.derivation.supported)
    #expect(legacy.derivation != current.derivation)
    for policy in ["id1-native-context-bbox75-v1", "choose-best-v1"] {
      metadata["implementationVersion"] = policy
      crop["policyVersion"] = policy
      metadata["contextCrop"] = crop
      #expect(try !derivation(metadata).supported)
    }
    var relabelled = try object(current.derivation)
    var currentCrop = try #require(relabelled["contextCrop"] as? [String: Any])
    relabelled["implementationVersion"] = "id1-native-context-20pct-v1"
    currentCrop["policyVersion"] = "id1-native-context-20pct-v1"
    relabelled["contextCrop"] = currentCrop
    #expect(try !derivation(relabelled).supported)
  }

  @Test func everyExifOrientationUsesTheUprightSourceCanvasExactlyOnce() async throws {
    for orientation in 1...8 {
      let fixture = try fixture(orientation: orientation)
      let output = try await AppleDocumentContextImagePreparer.prepareRetained(
        data: fixture.data, sourceSHA256: hash(fixture.data), preparedDocument: fixture.prepared)
      let crop = try #require(output.derivation.contextCrop)
      #expect(output.derivation.sourceOrientation == orientation)
      #expect(crop.sourcePixelWidth == ([5, 6, 7, 8].contains(orientation) ? 160 : 200))
      #expect(crop.sourcePixelHeight == ([5, 6, 7, 8].contains(orientation) ? 200 : 160))
      try assertNativePixels(fixture, output)
    }
  }

  @Test func wideGamutAndGreyscaleKeepTheirSourceColourSpace() async throws {
    for space in [try #require(CGColorSpace(name: CGColorSpace.displayP3)), CGColorSpaceCreateDeviceGray()] {
      let fixture = try fixture(space: space)
      let output = try await AppleDocumentContextImagePreparer.prepareRetained(
        data: fixture.data, sourceSHA256: hash(fixture.data), preparedDocument: fixture.prepared)
      let original = try AppleDocumentImagePreparer.uprightOriginal(data: fixture.data)
      let decoded = try decode(output.data)
      #expect(decoded.colorSpace?.name == original.colorSpace?.name)
      #expect(decoded.colorSpace?.model == original.colorSpace?.model)
      #expect(decoded.bitsPerComponent == 8)
      try assertNativePixels(fixture, output)
    }
  }

  @Test func canonicalCornersAndCropMatchTheFixedPhysicalReplayArithmetic() throws {
    for orientation in 1...8 {
      let fixture = try fixture(orientation: orientation)
      let geometry = fixture.prepared.derivation.geometry
      let card = try ID1CardGeometry(observation: geometry)
      let converted = geometry.quadrilateral.points.map {
        DocumentPixelPoint(x: $0.x * Double(geometry.orientedPixelWidth),
          y: (1 - $0.y) * Double(geometry.orientedPixelHeight))
      }
      #expect(card.sourceCorners == converted)
      let xValues = card.sourceCorners.map(\.x), yValues = card.sourceCorners.map(\.y)
      let minX = try #require(xValues.min()), maxX = try #require(xValues.max())
      let minY = try #require(yValues.min()), maxY = try #require(yValues.max())
      let sourceRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
      let factor = 1 / sqrt(0.75)
      let replayCrop = CGRect(x: sourceRect.midX - sourceRect.width * factor / 2,
        y: sourceRect.midY - sourceRect.height * factor / 2,
        width: sourceRect.width * factor, height: sourceRect.height * factor).integral
      let output = try prepare(fixture)
      let actual = try #require(output.derivation.contextCrop)
      let actualBounds: [Int] = [actual.left, actual.top, actual.width, actual.height]
      let expectedBounds: [Int] = [Int(replayCrop.minX), Int(replayCrop.minY), Int(replayCrop.width), Int(replayCrop.height)]
      #expect(actualBounds == expectedBounds)
    }
  }

  @Test func partialMarginClippingIsTruthfulAndKeepsBackground() throws {
    let fixture = try fixture(box: CGRect(x: 10, y: 35, width: 150, height: 90), roi: CGRect(x: 0, y: 0, width: 1, height: 1))
    let output = try prepare(fixture)
    let crop = try #require(output.derivation.contextCrop)
    #expect(crop.clippedToSourceBounds && crop.left == 0 && crop.width == 172)
    #expect(crop.top < 35 && crop.top + crop.height > 125)
    #expect(output.derivation.supported)
    try assertNativePixels(fixture, output)
  }

  @Test func originalAndPreparedSubstitutionCannotProduceAContext() throws {
    let fixture = try fixture()
    for attack in ["hash", "bytes", "prepared-bytes", "prepared-source", "orientation", "canvas", "prepared-size"] {
      var data = fixture.data
      var sourceHash = hash(data)
      var prepared = fixture.prepared
      switch attack {
      case "hash": sourceHash = String(repeating: "f", count: 64)
      case "bytes": data.append(0)
      case "prepared-bytes":
        let other = try self.fixture(space: CGColorSpaceCreateDeviceGray())
        prepared = .init(data: other.prepared.data, derivation: prepared.derivation)
      default:
        var value = try object(prepared.derivation)
        if attack == "prepared-source" { value["sourceSHA256"] = String(repeating: "f", count: 64) }
        if attack == "orientation" { value["sourceOrientation"] = 8 }
        if attack == "prepared-size" { value["outputPixelWidth"] = 9 }
        if attack == "canvas" {
          var geometry = try #require(value["geometry"] as? [String: Any])
          geometry["orientedPixelWidth"] = 201
          value["geometry"] = geometry
        }
        prepared = .init(data: prepared.data, derivation: try derivation(value))
      }
      #expect(throws: DocumentImagePreparationError.self) {
        try AppleDocumentContextImagePreparer.prepare(data: data, sourceSHA256: sourceHash, preparedDocument: prepared)
      }
    }
  }

  @Test func alteredCropMetadataCannotChangeTheFixedPolicyOrBecomeAPreparedCard() throws {
    let fixture = try fixture()
    let output = try prepare(fixture)
    for field in ["policyVersion", "left", "top", "width", "height", "sourcePixelWidth", "sourcePixelHeight",
                  "paddingFraction", "clippedToSourceBounds", "implementationVersion", "outputPixelWidth",
                  "outputPixelHeight", "outputUniformTypeIdentifier", "usesNonuniformScaling", "sourceOrientation", "outputSHA256"] {
      var value = try object(output.derivation)
      var crop = try #require(value["contextCrop"] as? [String: Any])
      switch field {
      case "policyVersion": crop[field] = "choose-best-v1"
      case "paddingFraction": crop[field] = 0.5
      case "clippedToSourceBounds": crop[field] = true
      case "implementationVersion": value[field] = "unrecorded-resize"
      case "outputUniformTypeIdentifier": value[field] = "public.jpeg"
      case "usesNonuniformScaling": value[field] = true
      case "sourceOrientation": value[field] = 9
      case "outputSHA256": value[field] = "not-a-digest"
      case "outputPixelWidth", "outputPixelHeight": value[field] = 1
      default: crop[field] = (try #require(crop[field] as? Int)) + 1
      }
      value["contextCrop"] = crop
      #expect(try !derivation(value).supported, "\(field)")
    }
    #expect(throws: DocumentImagePreparationError.invalidDocumentGeometry) {
      try AppleDocumentContextImagePreparer.prepare(data: fixture.data, sourceSHA256: hash(fixture.data), preparedDocument: output)
    }
    var relabelled = try object(output.derivation)
    relabelled["schemaVersion"] = 3
    relabelled["operation"] = "perspectiveCorrection"
    #expect(try !derivation(relabelled).supported)
    #expect(try derivation(object(output.derivation)) == output.derivation)
    #expect(try object(fixture.prepared.derivation)["contextCrop"] == nil)
    #expect(fixture.prepared.derivation.supported)
  }

  @Test func preparedEncodingMustMatchItsDeclaredPNGIdentity() throws {
    let fixture = try fixture()
    let image = try decode(fixture.prepared.data)
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let jpeg = bytes as Data
    var value = try object(fixture.prepared.derivation)
    value["outputSHA256"] = hash(jpeg)
    let substituted = DerivedDocumentImage(data: jpeg, derivation: try derivation(value))
    #expect(throws: DocumentImagePreparationError.invalidDocumentGeometry) {
      try AppleDocumentContextImagePreparer.prepare(
        data: fixture.data, sourceSHA256: hash(fixture.data), preparedDocument: substituted)
    }
  }

  @Test func geometryWithoutAWholePixelOfBackgroundIsRejected() throws {
    let cases: [(CGRect, CGRect)] = [
      (CGRect(x: 0, y: 50, width: 100, height: 60), CGRect(x: -0.05, y: 0.25, width: 0.65, height: 0.5)),
      (CGRect(x: 50.4, y: 60.4, width: 0.1, height: 0.06),
       CGRect(x: 50.39 / 200, y: 1 - 60.47 / 160, width: 0.12 / 200, height: 0.08 / 160)),
    ]
    for (box, roi) in cases {
      let fixture = try fixture(box: box, roi: roi)
      #expect(DocumentPhotoGeometryPolicy.isCompleteID1Candidate(fixture.prepared.derivation.geometry))
      #expect(throws: DocumentImagePreparationError.invalidDocumentGeometry) { try prepare(fixture) }
    }
  }

  @Test func crossingOffCanvasAndUnsupportedGuideGeometryCannotChooseACrop() throws {
    let fixture = try fixture()
    for attack in ["crossing", "off-canvas", "guide"] {
      var value = try object(fixture.prepared.derivation)
      var geometry = try #require(value["geometry"] as? [String: Any])
      var quad = try #require(geometry["quadrilateral"] as? [String: Any])
      if attack == "crossing" {
        let top = quad["topRight"]
        quad["topRight"] = quad["bottomRight"]
        quad["bottomRight"] = top
      } else if attack == "off-canvas" {
        var point = try #require(quad["topLeft"] as? [String: Any])
        point["x"] = -0.1
        quad["topLeft"] = point
      } else {
        let unsupported = CGRect(x: -0.1, y: -0.1, width: 1.2, height: 1.2)
        geometry["regionOfInterest"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(unsupported))
      }
      geometry["quadrilateral"] = quad
      value["geometry"] = geometry
      let prepared = DerivedDocumentImage(data: fixture.prepared.data, derivation: try derivation(value))
      #expect(throws: DocumentImagePreparationError.invalidDocumentGeometry) {
        try AppleDocumentContextImagePreparer.prepare(data: fixture.data, sourceSHA256: hash(fixture.data), preparedDocument: prepared)
      }
    }
  }

  @Test func cancellationIsPreservedBeforeAndBetweenRasterStages() async throws {
    let fixture = try fixture()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await AppleDocumentContextImagePreparer.prepareRetained(
        data: fixture.data, sourceSHA256: hash(fixture.data), preparedDocument: fixture.prepared)
    }
    do { _ = try await task.value; Issue.record("Cancelled caller received a context") } catch is CancellationError {}
    for stop in 1...4 {
      var calls = 0
      #expect(throws: CancellationError.self) {
        try AppleDocumentContextImagePreparer.prepare(data: fixture.data, sourceSHA256: hash(fixture.data),
          preparedDocument: fixture.prepared, checkCancellation: {
            calls += 1
            if calls == stop { throw CancellationError() }
          })
      }
    }
  }

  private struct Fixture { let data: Data; let prepared: DerivedDocumentImage }

  private func fixture(orientation: Int? = nil, space: CGColorSpace = CGColorSpaceCreateDeviceRGB(),
    box: CGRect? = nil, roi: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)) throws -> Fixture {
    let grey = space.model == .monochrome
    let channels = grey ? 1 : 4
    var pixels = [UInt8](repeating: 255, count: 200 * 160 * channels)
    for index in stride(from: 0, to: pixels.count, by: channels) {
      pixels[index] = UInt8((index * 7) % 251)
      if !grey { pixels[index + 1] = UInt8((index * 3) % 251); pixels[index + 2] = UInt8((index * 11) % 251) }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let bitmap = grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let image = try #require(CGImage(width: 200, height: 160, bitsPerComponent: 8, bitsPerPixel: 8 * channels,
      bytesPerRow: 200 * channels, space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmap), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary })
    #expect(CGImageDestinationFinalize(destination))
    let data = bytes as Data
    let upright = try AppleDocumentImagePreparer.uprightOriginal(data: data)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    let actualBox = box ?? CGRect(x: (upright.width - 100) / 2, y: (upright.height - 60) / 2, width: 100, height: 60)
    func point(_ horizontal: CGFloat, _ vertical: CGFloat) -> DocumentNormalizedPoint {
      .init(x: Double(horizontal) / Double(upright.width), y: 1 - Double(vertical) / Double(upright.height))
    }
    let geometry = DocumentGeometryObservation(method: .visionDocumentSegmentation, implementationVersion: "synthetic-retained-geometry",
      requestRevision: 1, confidence: 1, normalizedCoordinateQuantization: nil, analysisPixelWidth: nil, analysisPixelHeight: nil,
      regionOfInterest: roi, orientedPixelWidth: upright.width, orientedPixelHeight: upright.height,
      quadrilateral: .init(topLeft: point(actualBox.minX, actualBox.minY), topRight: point(actualBox.maxX, actualBox.minY),
        bottomRight: point(actualBox.maxX, actualBox.maxY), bottomLeft: point(actualBox.minX, actualBox.maxY)))
    // Deliberately distinct: context pixels must never be taken from the prepared raster.
    let preparedBytes = try AppleDocumentImagePreparer.pngData(from: #require(upright.cropping(to: CGRect(x: 0, y: 0, width: 8, height: 6))))
    let prepared = DocumentImageDerivation(schemaVersion: 3, sourceSHA256: hash(data),
      sourceOrientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
      operation: .perspectiveCorrection, implementationVersion: "synthetic-prepared-fixture", geometry: geometry,
      outputPixelWidth: 8, outputPixelHeight: 6, outputUniformTypeIdentifier: UTType.png.identifier,
      usesNonuniformScaling: false, outputSHA256: hash(preparedBytes))
    return Fixture(data: data, prepared: .init(data: preparedBytes, derivation: prepared))
  }

  private func prepare(_ fixture: Fixture) throws -> DerivedDocumentImage {
    try AppleDocumentContextImagePreparer.prepare(data: fixture.data, sourceSHA256: hash(fixture.data), preparedDocument: fixture.prepared)
  }

  private func assertNativePixels(_ fixture: Fixture, _ output: DerivedDocumentImage) throws {
    let original = try AppleDocumentImagePreparer.uprightOriginal(data: fixture.data)
    let crop = try #require(output.derivation.contextCrop)
    let expected = try #require(original.cropping(to: CGRect(x: crop.left, y: crop.top, width: crop.width, height: crop.height)))
    let actual = try decode(output.data)
    let space = try #require(original.colorSpace)
    #expect(actual.width == expected.width && actual.height == expected.height)
    #expect(try raster(actual, space: space) == raster(expected, space: space))
  }

  private func raster(_ image: CGImage, space: CGColorSpace) throws -> Data {
    let channels = space.model == .monochrome ? 1 : 4
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * channels)
    try bytes.withUnsafeMutableBytes { storage in
      let bitmap = channels == 1 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
      let context = try #require(CGContext(data: storage.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * channels, space: space, bitmapInfo: bitmap))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return Data(bytes)
  }

  private func object(_ value: DocumentImageDerivation) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
  }
  private func derivation(_ value: [String: Any]) throws -> DocumentImageDerivation {
    try JSONDecoder().decode(DocumentImageDerivation.self, from: JSONSerialization.data(withJSONObject: value))
  }
  private func decode(_ data: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }
  private func encode(_ image: CGImage, type: String = UTType.png.identifier,
    properties: [CFString: Any]? = nil) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
  private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
