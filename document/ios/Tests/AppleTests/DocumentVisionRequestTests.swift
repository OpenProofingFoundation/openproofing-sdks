import Foundation
import Vision
import XCTest
import CoreGraphics
import CryptoKit
@testable import DocumentCaptureApple

final class DocumentVisionRequestTests: XCTestCase {
  func testRetainedImageActuallyDetectsFaceWithConfiguredComputeDevice() async throws {
    let sourcePath = ProcessInfo.processInfo.environment["DOCUMENT_TEST_FACE_IMAGE_PATH"]
    var packageRoot = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { packageRoot.deleteLastPathComponent() }
    let url = sourcePath.map { URL(fileURLWithPath: $0) }
      ?? packageRoot.appendingPathComponent(".build/test-assets/vision-public-astronaut.png")
    let original = try Data(contentsOf: url)
    XCTAssertEqual(Self.digest(original), "88431cd9653ccd539741b555fb0a46b61558b301d4110412b5bc28b5e3ea6cb5")
    let extraction = try await ArtifactExtraction.extractAsync(original: original)
    XCTAssertEqual(extraction.detectedFaceCount, 1)
    XCTAssertEqual(extraction.faceRequestRevision, VNDetectFaceRectanglesRequest().revision)
    XCTAssertEqual(extraction.fidelity.fileByteCount, original.count)
    XCTAssertEqual(extraction.fidelity.sha256, Self.digest(original))
  }

  func testSyntheticImageExecutesConfiguredFaceRequestAndRetainsFidelity() async throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
    let original = try ApplePortraitExtractor.encodePNG(XCTUnwrap(context.makeImage()))
    let extraction = try await ArtifactExtraction.extractAsync(original: original)
    XCTAssertEqual(extraction.detectedFaceCount, 0)
    XCTAssertEqual(extraction.faceRequestRevision, VNDetectFaceRectanglesRequest().revision)
    XCTAssertEqual(extraction.fidelity.pixelWidth, 256)
    XCTAssertEqual(extraction.fidelity.pixelHeight, 256)
    XCTAssertEqual(extraction.fidelity.fileByteCount, original.count)
    XCTAssertEqual(extraction.fidelity.sha256, Self.digest(original))
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
