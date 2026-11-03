import Foundation
import ImageIO
import Vision

/// Barcode-only extraction from the exact retained original; no OCR, crop or quality gate.
public enum PDF417StillDecoder {
  /// Names this decoder in evidence it produced (`decoder_version`); change it when decoding changes.
  public static let implementationVersion = "apple-vision-pdf417-still-v1"

  public static func decode(original: Data) async throws -> [String] {
    try await DocumentImageProcessingQueue.shared.run { _ in
      let request = VNDetectBarcodesRequest()
      try DocumentVisionRequests.configurePDF417(request)
      let source = CGImageSourceCreateWithData(original as CFData, nil)
      let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }
      let raw = (properties as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32 ?? 1
      let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
      try VNImageRequestHandler(data: original, orientation: orientation).perform([request])
      return request.results?.compactMap(\.payloadStringValue) ?? []
    }
  }
}
