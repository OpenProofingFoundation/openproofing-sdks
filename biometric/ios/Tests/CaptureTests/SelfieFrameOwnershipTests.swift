#if os(iOS)
import AVFoundation
import CoreVideo
import ImageIO
import XCTest
@testable import BiometricCapture

final class SelfieFrameOwnershipTests: XCTestCase {
  func testCallerMutationCannotChangeOwnedColorFrameOrItsPadding() throws {
    let source = try buffer(width: 3, height: 2, format: kCVPixelFormatType_32BGRA)
    fill(source, byte: 17)
    let frame = try SelfieFrameInput(buffer: source, orientation: .right)
    fill(source, byte: 99)
    XCTAssertEqual(frame.orientation, .right)
    CVPixelBufferLockBaseAddress(frame.buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame.buffer, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame.buffer))
    let stride = CVPixelBufferGetBytesPerRow(frame.buffer)
    for row in 0..<2 {
      for column in 0..<12 { XCTAssertEqual(base.load(fromByteOffset: row * stride + column, as: UInt8.self), 17) }
      for column in 12..<stride { XCTAssertEqual(base.load(fromByteOffset: row * stride + column, as: UInt8.self), 0) }
    }
  }

  func testCallerMutationCannotChangePairedDepthSnapshot() throws {
    let depth = try syntheticDepth { _, _ in 0.5 }
    let snapshot = try SelfieDepthMap(data: depth, imageTimestamp: 2, depthTimestamp: 1.984)
    let original = depth.depthDataMap
    fill(original, byte: 0)
    let owned = snapshot.data.depthDataMap
    CVPixelBufferLockBaseAddress(owned, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(owned, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(owned))
    XCTAssertEqual(base.load(as: Float.self), 0.5)
    XCTAssertEqual(snapshot.imageTimestamp, 2)
    XCTAssertEqual(snapshot.depthTimestamp, 1.984)
  }

  func testDepthSnapshotPreservesOriginalFilterFact() throws {
    let original = try syntheticDepth { _, _ in 0.5 }
    let sourceWasFiltered = original.isDepthDataFiltered
    let snapshot = try SelfieDepthMap(data: original, imageTimestamp: 2, depthTimestamp: 1.984)
    let evidence = snapshot.measure(faceBox: CGRect(x: 0, y: 0, width: 1, height: 1),
      orientation: .up, policy: .engineeringV1)
    XCTAssertEqual(evidence.filtered, sourceWasFiltered)
    if sourceWasFiltered { XCTAssertEqual(evidence.assessment, .insufficientData) }
  }

  func testExtremeDepthSamplingPoliciesAndLongThinMapsAreRefused() throws {
    func policy(_ count: Int) -> SelfieDepthPolicy {
      .init(identifier: "synthetic", minimumResidualRMS: 0.004, minimumSamples: 64,
        nearLimit: 0.15, farLimit: 1.2, maximumDepthAge: 0.25, samplesPerAxis: count)
    }
    for count in [Int.max, 65, 1, 0, -1] {
      XCTAssertFalse(policy(count).isValid)
    }
    let map = try buffer(width: 8192, height: 2, format: kCVPixelFormatType_DepthFloat32)
    XCTAssertTrue(SelfieDepthMap.samples(in: map,
      faceBox: CGRect(x: 0, y: 0, width: 1, height: 1), policy: policy(64)).isEmpty)
  }

  func testUnsupportedColorFormatIsRefused() throws {
    let source = try buffer(width: 2, height: 2, format: kCVPixelFormatType_DepthFloat32)
    XCTAssertThrowsError(try SelfieFrameInput(buffer: source, orientation: .up)) {
      XCTAssertEqual($0 as? SelfieFrameSnapshotError, .unsupportedFormat)
    }
  }

  func testPlanarColorSnapshotOwnsBothPlanes() throws {
    for format in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
      let source = try buffer(width: 4, height: 4, format: format)
      fill(source, byte: 31)
      let frame = try SelfieFrameInput(buffer: source, orientation: .up)
      fill(source, byte: 200)
      CVPixelBufferLockBaseAddress(frame.buffer, .readOnly)
      for plane in 0..<2 {
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame.buffer, plane))
        XCTAssertEqual(base.load(as: UInt8.self), 31)
      }
      CVPixelBufferUnlockBaseAddress(frame.buffer, .readOnly)
    }
  }

  private func buffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &result), kCVReturnSuccess)
    return try XCTUnwrap(result)
  }

  private func fill(_ buffer: CVPixelBuffer, byte: UInt8) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if CVPixelBufferIsPlanar(buffer) {
      for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
          memset(base, Int32(byte), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
      }
    } else if let base = CVPixelBufferGetBaseAddress(buffer) {
      memset(base, Int32(byte), CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
  }
}
#endif
