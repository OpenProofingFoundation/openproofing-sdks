#if os(iOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NFCPassportReader

/// Generated colored pixels only: no document or face fixture is retained.
final class PassportPortraitExtractionTests: XCTestCase {
    func testJPEGWithCommentBeforeJFIFPreservesDecodableOriginalBytes() throws {
        let jpeg = try syntheticJPEG()
        let encoded = Array(jpeg.prefix(2)) + [0xff, 0xfe, 0x00, 0x06, 0x74, 0x65, 0x73, 0x74] + jpeg.dropFirst(2)
        try assertExtraction(Array(encoded))
    }

    func testJPEGWithoutJFIFApplicationSegmentPreservesDecodableOriginalBytes() throws {
        var jpeg = try syntheticJPEG()
        if jpeg.count > 6, jpeg[2] == 0xff, jpeg[3] == 0xe0 {
            let length = Int(jpeg[4]) * 256 + Int(jpeg[5])
            jpeg.removeSubrange(2..<(4 + length))
        }
        XCTAssertFalse(jpeg.starts(with: [0xff, 0xd8, 0xff, 0xe0]))
        try assertExtraction(jpeg)
    }

    func testOriginalJPEGIsPreservedAndTruncatedJPEGIsRefused() throws {
        let jpeg = try syntheticJPEG()
        try assertExtraction(jpeg)
        XCTAssertThrowsError(try DataGroup2(container(Array(jpeg.dropLast(2)))))
    }

    private func assertExtraction(_ jpeg: [UInt8]) throws {
        let original = container(jpeg)
        let extracted = try DataGroup2(original)
        XCTAssertEqual(extracted.data, original)
        XCTAssertEqual(extracted.imageData, jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(Data(extracted.imageData) as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 12)
        XCTAssertEqual(image.height, 8)
    }

    private func syntheticJPEG() throws -> [UInt8] {
        let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8,
            bytesPerRow: 48, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return Array(data as Data)
    }

    private func container(_ jpeg: [UInt8]) -> [UInt8] {
        func integer(_ value: Int, bytes: Int) -> [UInt8] {
            (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        func tlv(_ tag: [UInt8], _ value: [UInt8]) -> [UInt8] {
            let length = value.count < 128 ? [UInt8(value.count)] : [0x82] + integer(value.count, bytes: 2)
            return tag + length + value
        }
        let block = integer(32 + jpeg.count, bytes: 4) + Array(repeating: UInt8(0), count: 16)
            + [0x01, 0x00, 0x00, 0x0c, 0x00, 0x08, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00] + jpeg
        let record = [UInt8]("FAC\0".utf8) + [0x30, 0x31, 0x30, 0x00]
            + integer(14 + block.count, bytes: 4) + [0x00, 0x01] + block
        return tlv([0x75], tlv([0x7f, 0x61], tlv([0x02], [0x01])
            + tlv([0x7f, 0x60], tlv([0xa1], []) + tlv([0x5f, 0x2e], record))))
    }
}
#endif
