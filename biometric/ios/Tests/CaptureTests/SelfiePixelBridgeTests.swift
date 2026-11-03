import BiometricSDK
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import BiometricCapture

final class SelfiePixelBridgeTests: XCTestCase {
  func testDistinctEncodedAndPackedPixelDigestsAndChannelOrder() throws {
    let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 20, 40, 60, 255]
    let png = try encode(bytes, width: 2, height: 2)
    let result = try decode(png)
    XCTAssertEqual(result.pixels.bytes, [255, 0, 0, 0, 255, 0, 0, 0, 255, 20, 40, 60])
    XCTAssertEqual(result.pixels.rowStrideBytes, 6)
    XCTAssertEqual(result.pixels.orientation, 1)
    XCTAssertEqual(result.sourceEncodedSHA256, digest(png))
    XCTAssertEqual(result.pixels.sha256, digest(Data(result.pixels.bytes)))
    XCTAssertNotEqual(result.pixels.sha256, result.sourceEncodedSHA256)
    XCTAssertEqual(result.derivationProfile, "apple-imageio-srgb-rgb8-oriented-png-v1")
    XCTAssertEqual(result.colorSpace, "srgb")
    XCTAssertEqual(result.alphaConversion, "premultiplied_over_black")
    XCTAssertEqual(result.interpolation, "none")
  }

  func testSnapshotDoesNotRetainCallerMutableEncodedStorage() throws {
    var png = try encode([8, 16, 32, 255], width: 1, height: 1)
    let result = try decode(png)
    png.resetBytes(in: 0..<png.count)
    var escaped = result.pixels.bytes
    escaped[0] = 200
    XCTAssertEqual(result.pixels.bytes, [8, 16, 32])
    XCTAssertEqual(result.pixels.sha256, digest(Data([8, 16, 32])))
  }

  func testAlphaIsExplicitlyCompositedOverBlack() throws {
    let png = try encode([200, 100, 50, 128, 255, 255, 255, 0], width: 2, height: 1)
    let result = try decode(png)
    for (actual, expected) in zip(result.pixels.bytes, [100, 50, 25, 0, 0, 0]) {
      XCTAssertLessThanOrEqual(abs(Int(actual) - expected), 1)
    }
  }

  func testEmbeddedOrientationIsRejectedRatherThanAppliedTwice() throws {
    for orientation in 2...8 {
      let png = try encode([255, 0, 0, 255, 0, 0, 255, 255], width: 2, height: 1,
        orientation: orientation)
      XCTAssertThrowsError(try decode(png)) {
        XCTAssertEqual($0 as? SelfiePixelFailure, .unsupportedOrientation)
      }
    }
  }

  func testSourceSubstitutionIsRejectedBeforeDecode() throws {
    let png = try encode([8, 16, 32, 255], width: 1, height: 1)
    XCTAssertThrowsError(try SelfiePixelBridge.decodeOrientedPNG(png,
      expectedSourceSHA256: String(repeating: "0", count: 64))) {
      XCTAssertEqual($0 as? SelfiePixelFailure, .sourceMismatch)
    }
  }

  func testMalformedAndTruncatedPNGAndNonPNGAreRefused() throws {
    let png = try encode([8, 16, 32, 255], width: 1, height: 1)
    for bytes in [Data(), Data([0, 1, 2]), Data(png.prefix(8)), Data(png.prefix(png.count / 2))] {
      XCTAssertThrowsError(try decode(bytes))
    }
  }

  func testOversizedIHDRIsRefusedWithoutRasterAllocation() throws {
    var png = try encode([8, 16, 32, 255], width: 1, height: 1)
    // A valid IHDR CRC ensures the dimension ceiling, rather than checksum
    // rejection, stops the decoder before it allocates raster storage.
    png.replaceSubrange(16..<20, with: [0, 1, 0, 0])
    let checksum = crc32(png[12..<29])
    png.replaceSubrange(29..<33, with: (0..<4).map { UInt8(truncatingIfNeeded: checksum >> (24 - $0 * 8)) })
    XCTAssertThrowsError(try decode(png)) {
      XCTAssertEqual($0 as? SelfiePixelFailure, .resourceLimit)
    }
  }

  func testEightMegapixelCeilingIsCheckedBeforeDecode() throws {
    var png = try encode([8, 16, 32, 255], width: 1, height: 1)
    // 4096x2049 exceeds the pixel cap while each dimension remains permitted.
    png.replaceSubrange(16..<24, with: [0, 0, 16, 0, 0, 0, 8, 1])
    let checksum = crc32(png[12..<29])
    png.replaceSubrange(29..<33, with: (0..<4).map { UInt8(truncatingIfNeeded: checksum >> (24 - $0 * 8)) })
    XCTAssertThrowsError(try decode(png)) {
      XCTAssertEqual($0 as? SelfiePixelFailure, .resourceLimit)
    }
  }

  func testEncodedResourceCeilingIsCheckedBeforeHashAndDecode() throws {
    let bytes = Data(repeating: 0, count: 33_554_433)
    XCTAssertThrowsError(try SelfiePixelBridge.decodeOrientedPNG(bytes,
      expectedSourceSHA256: String(repeating: "0", count: 64))) {
      XCTAssertEqual($0 as? SelfiePixelFailure, .resourceLimit)
    }
  }

  private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffffffff
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
    }
    return crc ^ 0xffffffff
  }

  private func decode(_ data: Data) throws -> SelfiePixelSnapshot {
    try SelfiePixelBridge.decodeOrientedPNG(data, expectedSourceSHA256: digest(data))
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func encode(_ rgba: [UInt8], width: Int, height: Int,
    orientation: Int = 1) throws -> Data {
    let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image,
      [kCGImagePropertyOrientation: orientation] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return Data(referencing: data)
  }
}
