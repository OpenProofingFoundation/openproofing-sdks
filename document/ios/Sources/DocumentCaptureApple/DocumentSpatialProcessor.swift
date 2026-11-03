import CoreGraphics
import CryptoKit
import Foundation
import DocumentOpenCVBridge
import ImageIO

/// Reuses the SDK's serialized image worker. Cancellation is checked before queued
/// decoding and after blocking OpenCV work; OpenCV itself cannot be interrupted.
public enum DocumentSpatialProcessor {
  public static func analyze(data: Data, derivation: DocumentImageDerivation) async throws -> DocumentSpatialAnalysis {
    try await SpatialAdmission.shared.run(data: data, derivation: derivation)
  }

  fileprivate static func process(
    data: Data, derivation: DocumentImageDerivation
  ) async throws -> DocumentSpatialAnalysis {
    try await DocumentImageProcessingQueue.shared.run { checkCancellation in
      try preflight(data: data, derivation: derivation)
      try checkCancellation()
      let image = try AppleDocumentImagePreparer.uprightOriginal(data: data)
      guard image.width == derivation.geometry.orientedPixelWidth,
        image.height == derivation.geometry.orientedPixelHeight else { throw DocumentSpatialError.invalidInput }
      let rgb = try pixels(image)
      try checkCancellation()
      return try analyzeRGB(rgb, width: image.width, height: image.height, derivation: derivation)
    }
  }

  static func preflight(data: Data, derivation: DocumentImageDerivation) throws {
    guard derivation.supported,
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == derivation.sourceSHA256,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0 else { throw DocumentSpatialError.invalidInput }
    _ = try DocumentSpatialAnalysis.checkedPixelCount(width: width, height: height)
  }

  static func pixels(_ image: CGImage) throws -> [UInt8] {
    let pixelCount = try DocumentSpatialAnalysis.checkedPixelCount(width: image.width, height: image.height)
    guard let colorSpace = image.colorSpace, colorSpace.model == .rgb else { throw DocumentSpatialError.invalidInput }
    var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
    let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    guard rendered else { throw DocumentSpatialError.processingFailure }
    var rgb = [UInt8](repeating: 0, count: pixelCount * 3)
    for index in 0..<pixelCount {
      rgb[index * 3] = rgba[index * 4]
      rgb[index * 3 + 1] = rgba[index * 4 + 1]
      rgb[index * 3 + 2] = rgba[index * 4 + 2]
    }
    return rgb
  }

  private static func analyzeRGB(_ rgb: [UInt8], width: Int, height: Int,
                                 derivation: DocumentImageDerivation) throws -> DocumentSpatialAnalysis {
    let quad = derivation.geometry.quadrilateral
    let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft].flatMap {
      [$0.x * Double(width), (1 - $0.y) * Double(height)]
    }
    var output: OpaquePointer?
    let status = rgb.withUnsafeBufferPointer { bytes in
      corners.withUnsafeBufferPointer { prior in
        IEOpenCVAnalyzeCardRGB(bytes.baseAddress, bytes.count, Int32(width), Int32(height),
          width * 3, prior.baseAddress, &output)
      }
    }
    defer { IEOpenCVCardAnalysisRelease(output) }
    guard status == 0, let output else {
      throw status == 2 ? DocumentSpatialError.resourceLimit : DocumentSpatialError.processingFailure
    }
    var count = 0
    let pointPointer = IEOpenCVCardAnalysisPoints(output, &count)
    let points = UnsafeBufferPointer(start: pointPointer, count: count).map {
      DocumentSpatialAnalysis.Pixel(x: Int($0.x), y: Int($0.y))
    }
    let offsetPointer = IEOpenCVCardAnalysisOffsets(output, &count)
    let offsets = UnsafeBufferPointer(start: offsetPointer, count: count).map { Int($0) }
    let maskPointer = IEOpenCVCardAnalysisMask(output, &count)
    let mask = Array(UnsafeBufferPointer(start: maskPointer, count: count))
    return try DocumentSpatialAnalysis(sourceSHA256: derivation.sourceSHA256, width: width, height: height,
      points: points, offsets: offsets, mask: mask)
  }
}

// At most one source is retained for spatial work, including time queued behind
// capture preparation. Rapid view toggles cannot build an unbounded image queue.
private actor SpatialAdmission {
  static let shared = SpatialAdmission()
  private var busy = false
  func run(data: Data, derivation: DocumentImageDerivation) async throws -> DocumentSpatialAnalysis {
    try Task.checkCancellation()
    guard !busy else { throw DocumentSpatialError.analysisInProgress }
    busy = true
    defer { busy = false }
    return try await DocumentSpatialProcessor.process(data: data, derivation: derivation)
  }
}
