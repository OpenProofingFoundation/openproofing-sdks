import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation
import DocumentSDK
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DocumentCaptureApple

@Test func retainedImageExtractionDecodesPDF417AndKeepsOriginalFidelity() async throws {
  let payload = extractionLicensePayload()
  let filter = try #require(CIFilter(name: "CIPDF417BarcodeGenerator"))
  filter.setValue(Data(payload.utf8), forKey: "inputMessage")
  let barcode = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 5, y: 5))
  let renderer = CIContext(options: [.cacheIntermediates: false])
  let image = try #require(renderer.createCGImage(barcode, from: barcode.extent))
  let original = try extractionPNG(image)
  let result = try await ArtifactExtraction.extractAsync(original: original)
  #expect(result.schemaVersion == 4)
  #expect(result.pdf417Payloads == [payload])
  #expect(result.parsedPDF417?.first?.status == .readable)
  #expect(result.parsedPDF417?.first?.rawPayload == payload)
  #expect(result.detectedFaceCount == 0)
  #expect(result.fidelity.fileByteCount == original.count)
  #expect(result.fidelity.pixelWidth == image.width)
  #expect(result.fidelity.pixelHeight == image.height)
  #expect(result.fidelity == (try PhotoFidelityMetadata.make(from: original)))
}

@Test func retainedImageExtractionKeepsRawOCRWithoutPassportInterpretation() async throws {
  let lines = [
    "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<",
    "L898902C36USA7408122F1204159ZE184226B<<<<<10",
  ]
  let context = try #require(
    CGContext(
      data: nil, width: 2400, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  )
  context.setFillColor(CGColor(gray: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 2400, height: 500))
  // Menlo's filler glyphs are split and one is lost by iOS 27.2 OCR. Courier New
  // supplies a readable positive control; the observed loss stays tested below.
  let font = CTFontCreateWithName("CourierNewPSMT" as CFString, 70, nil)
  for (index, line) in lines.enumerated() {
    let attributed = NSAttributedString(
      string: line,
      attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1),
      ])
    context.textPosition = CGPoint(x: 150, y: 320 - index * 140)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
  }
  let original = try extractionPNG(try #require(context.makeImage()))
  let result = try await ArtifactExtraction.extractAsync(original: original)
  #expect(result.schemaVersion == 4)
  #expect(!result.recognizedText.isEmpty)
  #expect(result.recognizedText == lines)
  #expect(result.detectedFaceCount == 0)
  #expect(result.licenseFront?.issuingJurisdiction == nil)
  #expect(result.structuredDocument == nil)
  let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
  #expect(encoded["passportMRZ"] == nil)
  #expect(result.fidelity == (try PhotoFidelityMetadata.make(from: original)))

}

@Test func livePDF417RequestDecodesPixelsBeforeReducingToMetrics() throws {
  let payload = extractionLicensePayload()
  let filter = try #require(CIFilter(name: "CIPDF417BarcodeGenerator"))
  filter.setValue(Data(payload.utf8), forKey: "inputMessage")
  let image = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 5, y: 5))
  var storage: CVPixelBuffer?
  #expect(
    CVPixelBufferCreate(
      kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height),
      kCVPixelFormatType_32BGRA, nil, &storage) == kCVReturnSuccess)
  let buffer = try #require(storage)
  CIContext(options: [.cacheIntermediates: false]).render(image, to: buffer)
  let metrics = DocumentLiveContentAnalyzer().analyze(
    buffer, regionOfInterest: CGRect(x: 0, y: 0, width: 1, height: 1), target: .licensePDF417)
  #expect(metrics.decodedPDF417Count == 1)
  #expect(metrics.decodedPDF417CharacterCount == payload.count)
  #expect(metrics.recognizedCharacterCount == 0)
}

private func extractionPNG(_ image: CGImage) throws -> Data {
  let bytes = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  try #require(CGImageDestinationFinalize(destination))
  return bytes as Data
}

private func extractionLicensePayload() -> String {
  let codes = [
    "DCA", "DCB", "DCD", "DBA", "DCS", "DAC", "DAD", "DBD", "DBB", "DBC", "DAY",
    "DAU", "DAG", "DAI", "DAJ", "DAK", "DAQ", "DCF", "DCG", "DDE", "DDF", "DDG",
  ]
  let body = "DL" + codes.map { $0 + "SAMPLE\n" }.joined() + "\r"
  return "@\n\u{1e}\rANSI 636000090001DL" + String(format: "0031%04d", body.utf8.count) + body
}
