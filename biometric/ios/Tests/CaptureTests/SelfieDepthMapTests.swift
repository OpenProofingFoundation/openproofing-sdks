#if os(iOS)
  import AVFoundation
  import CoreVideo
  import ImageIO
  import XCTest
  @testable import BiometricCapture

  final class SelfieDepthMapTests: XCTestCase {
    func testVisionBottomLeftMappingExcludesReliefOutsideTheFace() throws {
      let depth = try syntheticDepth { x, y in
        y < 32 ? 0.3 : (0.5 + ((x / 2 + y / 2) % 2 == 0 ? 0.01 : -0.01))
      }
      let source = try SelfieDepthMap(data: depth, imageTimestamp: 10, depthTimestamp: 9.984)
      let bottom = source.measure(faceBox: CGRect(x: 0, y: 0, width: 1, height: 0.5),
        orientation: .up, policy: .engineeringV1)
      let top = source.measure(faceBox: CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
        orientation: .up, policy: .engineeringV1)
      XCTAssertEqual(bottom.assessment, .live)
      XCTAssertEqual(top.assessment, .flat, "Screen edges/background cannot manufacture face relief")
    }

    func testAllImageOrientationsRotateDepthBeforeSampling() throws {
      let source = try SelfieDepthMap(data: try syntheticDepth { x, y in
        x < 32 && y < 32 ? 0.5 + (Int(x + y) % 2 == 0 ? 0.01 : -0.01) : 0.3
      }, imageTimestamp: 10, depthTimestamp: 10)
      let boxes: [(CGImagePropertyOrientation, CGRect)] = [
        (.up, CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
        (.right, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
        (.down, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
        (.left, CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
      ]
      for (orientation, box) in boxes {
        let evidence = source.measure(faceBox: box, orientation: orientation, policy: .engineeringV1)
        // Sampling uses stride 2 in a 32px box, so the checkerboard above aliases. Use the
        // actual paired pixels as an independent orientation oracle instead of assuming relief.
        let oriented = source.data.applyingExifOrientation(orientation)
        let samples = SelfieDepthMap.samples(in: oriented.depthDataMap, faceBox: box, policy: .engineeringV1)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0.z > 0.45 }, "Wrong depth quadrant for \(orientation)")
        XCTAssertEqual(evidence.orientation, orientation.rawValue)
        XCTAssertEqual(evidence.filtered, source.data.isDepthDataFiltered)
      }
    }

    func testSamplingRejectsInvalidRegionsAndDropsNaNs() throws {
      let depth = try syntheticDepth { _, _ in .nan }
      let source = try SelfieDepthMap(data: depth, imageTimestamp: 10, depthTimestamp: 10)
      let result = source.measure(faceBox: CGRect(x: 0, y: 0, width: 1, height: 1),
        orientation: .up, policy: .engineeringV1)
      XCTAssertEqual(result.measurement.sampleCount, 0)
      XCTAssertEqual(result.assessment, .insufficientData)
      for box in [CGRect.zero, CGRect(x: -10, y: 0, width: 1, height: 1),
        CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)] {
        XCTAssertTrue(SelfieDepthMap.samples(in: depth.depthDataMap, faceBox: box, policy: .engineeringV1).isEmpty)
      }
    }
  }

  func syntheticDepth(_ sample: (Int, Int) -> Float) throws -> AVDepthData {
    let values = (0..<64).flatMap { row in (0..<64).map { sample($0, row) } }
    let bytes = values.withUnsafeBytes { Data($0) }
    return try AVDepthData(fromDictionaryRepresentation: [
      kCGImageAuxiliaryDataInfoData: bytes,
      kCGImageAuxiliaryDataInfoDataDescription: [
        kCGImagePropertyPixelFormat: kCVPixelFormatType_DepthFloat32,
        kCGImagePropertyWidth: 64, kCGImagePropertyHeight: 64, kCGImagePropertyBytesPerRow: 256,
      ],
    ])
  }
#endif
