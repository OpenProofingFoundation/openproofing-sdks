import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import DocumentCaptureApple

final class LivePDF417MetadataTests: XCTestCase {
  func testEveryTruncatedPrefixKeepsScanningThenCompletePayloadPassesUnchanged() {
    var accepted: [String] = []
    let delegate = LivePDF417MetadataDelegate(guideRegion: { nil }) { payload in
      if let payload { accepted.append(payload) }
    }
    let complete = barcode()
    for length in 0..<complete.utf8.count {
      let prefix = String(decoding: complete.utf8.prefix(length), as: UTF8.self)
      delegate.receive([prefix])
    }
    XCTAssertTrue(accepted.isEmpty, "No truncated prefix may trigger capture")
    delegate.receive([complete])
    XCTAssertEqual(accepted, [complete])
  }

  func testMissingAmbiguousAndMalformedReadClearPreviousCandidate() {
    let complete = barcode()
    var candidate: String?
    let delegate = LivePDF417MetadataDelegate(guideRegion: { nil }) { candidate = $0 }
    let invalidReads: [[String?]] = [
      [], [nil], [""], ["not an ID"], [String(complete.dropLast())],
      [complete, complete], [complete, nil],
    ]
    for read in invalidReads {
      delegate.receive([complete])
      XCTAssertEqual(candidate, complete)
      delegate.receive(read)
      XCTAssertNil(candidate)
    }
  }

  func testCroppedBarcodeDecodesExactlyOrDoesNotDecode() async throws {
    let payload = barcode()
    let filter = try XCTUnwrap(CIFilter(name: "CIPDF417BarcodeGenerator"))
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    let barcodeImage = try XCTUnwrap(filter.outputImage)
      .transformed(by: CGAffineTransform(scaleX: 5, y: 5))
    let renderer = CIContext(options: [.cacheIntermediates: false])
    let image = try XCTUnwrap(renderer.createCGImage(barcodeImage, from: barcodeImage.extent))
    let complete = try await PDF417StillDecoder.decode(original: png(image))
    XCTAssertEqual(complete, [payload], "Positive control must decode the complete original")
    for fraction in [0.1, 0.3, 0.5, 0.7] {
      let width = Double(image.width)
      let height = Double(image.height)
      let crops = [
        CGRect(x: width * fraction, y: 0, width: width * (1 - fraction), height: height),
        CGRect(x: 0, y: 0, width: width * (1 - fraction), height: height),
        CGRect(x: 0, y: height * fraction, width: width, height: height * (1 - fraction)),
        CGRect(x: 0, y: 0, width: width, height: height * (1 - fraction)),
      ]
      for rect in crops {
        let cropped = try XCTUnwrap(image.cropping(to: rect))
        let decoded = try await PDF417StillDecoder.decode(original: png(cropped))
        // Error correction may recover a damaged symbol. Partial text is never acceptable.
        XCTAssertTrue(decoded.isEmpty || decoded == [payload], "Crop: \(rect)")
      }
    }
  }

  private func png(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func barcode() -> String {
    let body =
      "DLDBA09242030\nDBD09242020\nDBB01011980\nDAG1 SAMPLE ST\n"
      + "DAIEXAMPLE CITY\nDAJWA\nDAK98000\nDAQEXAMPLE123\nDACALICE\nDCSEXAMPLE\n\r"
    let header = "@\n\u{1e}\rANSI 636045090201"
    return header + "DL" + String(format: "%04d%04d", header.utf8.count + 10, body.utf8.count)
      + body
  }
}
