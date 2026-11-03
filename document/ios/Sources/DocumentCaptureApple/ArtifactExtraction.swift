import Foundation
import DocumentSDK
import ImageIO
import Vision

/// Retained-image extraction and machine-readable consistency observations, not authenticity.
public struct ArtifactExtraction: Codable, Sendable {
  public let schemaVersion: Int
  public let fidelity: PhotoFidelityMetadata
  public let imagePropertiesPlist: Data
  public let pdf417Payloads: [String]
  public let recognizedText: [String]
  public let barcodeRequestRevision: Int
  public let textRequestRevision: Int
  /// Nil on older records where face detection was not performed.
  public let detectedFaceCount: Int?
  public let faceRequestRevision: Int?
  /// Nil on older records; raw OCR/payload observations remain separately retained.
  public let parsedPDF417: [AAMVAPDF417Result]?
  /// Nil on older records. The issuer printed across a US licence front.
  public var licenseFront: LicenseFrontVisualFields?

  /// Host-supplied structured reader observation, absent on earlier records and native-only derivatives.
  public var structuredDocument: StructuredDocumentObservation?

  /// Runs native extraction without blocking Swift's cooperative executor.
  public static func extractAsync(original: Data) async throws -> Self {
    try await DocumentImageProcessingQueue.shared.run { _ in
      try extract(original: original)
    }
  }

  /// Blocking extraction on caller-supplied original bytes, normally read back
  /// from custody. Async callers should use `extractAsync(original:)`.
  public static func extract(original: Data) throws -> Self {
    // One image source serves both the curated subset and the retained
    // property list; each auxiliary probe materializes that auxiliary image,
    // so it is performed once and shared.
    guard let source = CGImageSourceCreateWithData(original as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
      let typedProperties = properties as? [CFString: Any]
    else { throw PhotoCaptureError.imageMetadataUnavailable }
    let fidelity = try PhotoFidelityMetadata.make(
      from: original, source: source, properties: typedProperties,
      auxiliaryDataTypes: CapturedPhotoPlatformMetadata.auxiliaryTypes(of: source))
    let metadata = try PropertyListSerialization.data(
      fromPropertyList: properties, format: .binary, options: 0)
    let barcode = VNDetectBarcodesRequest()
    try DocumentVisionRequests.configurePDF417(barcode)
    let text = VNRecognizeTextRequest()
    text.recognitionLevel = .accurate
    text.usesLanguageCorrection = false
    let faces = VNDetectFaceRectanglesRequest()
    try DocumentVisionRequests.configureFaces(faces)
    let orientation = CGImagePropertyOrientation(rawValue: UInt32(fidelity.orientation ?? 1)) ?? .up
    try VNImageRequestHandler(data: original, orientation: orientation).perform([
      barcode, text, faces
    ])
    let payloads = barcode.results?.compactMap(\.payloadStringValue) ?? []
    let lines = text.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    return Self(
      schemaVersion: 4, fidelity: fidelity, imagePropertiesPlist: metadata,
      pdf417Payloads: payloads, recognizedText: lines,
      barcodeRequestRevision: barcode.revision, textRequestRevision: text.revision,
      detectedFaceCount: faces.results?.count, faceRequestRevision: faces.revision,
      parsedPDF417: payloads.map(AAMVAPDF417Parser.parse),
      licenseFront: LicenseFrontVisualFields.extract(lines: lines))
  }
}
