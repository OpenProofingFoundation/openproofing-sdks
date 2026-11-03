import Foundation
import Testing

@testable import DocumentCaptureApple

@Test
func portraitGuideMatchesClockwiseRotatedVideoBuffer() {
  let native = DocumentCameraGuideRegion(minX: 0.31, minY: 0.21, width: 0.27, height: 0.57)

  let converted = native.convertedToVideoBuffer(orientation: .portrait)

  #expect(abs(converted.minX - 0.22) < 0.000_001)
  #expect(abs(converted.minY - 0.31) < 0.000_001)
  #expect(abs(converted.width - 0.57) < 0.000_001)
  #expect(abs(converted.height - 0.27) < 0.000_001)
}

@Test
func guideRotationPreservesAreaAndNormalizedBounds() {
  let native = DocumentCameraGuideRegion(minX: 0.13, minY: 0.22, width: 0.61, height: 0.34)
  for orientation in DocumentCameraOrientation.allCases {
    let converted = native.convertedToVideoBuffer(orientation: orientation)
    #expect(converted.width * converted.height == native.width * native.height)
    #expect(converted.minX >= 0)
    #expect(converted.minY >= 0)
    #expect(converted.minX + converted.width <= 1)
    #expect(converted.minY + converted.height <= 1)
  }
}

@Test
func everyGuideRotationRoundTripsToCaptureDeviceCoordinates() {
  let native = DocumentCameraGuideRegion(minX: 0.13, minY: 0.22, width: 0.61, height: 0.34)
  for orientation in DocumentCameraOrientation.allCases {
    let roundTrip = native.convertedToVideoBuffer(orientation: orientation)
      .convertedToCaptureDevice(orientation: orientation)
    #expect(approximatelyEqual(roundTrip.minX, native.minX))
    #expect(approximatelyEqual(roundTrip.minY, native.minY))
    #expect(approximatelyEqual(roundTrip.width, native.width))
    #expect(approximatelyEqual(roundTrip.height, native.height))
  }
}

@Test
func focusPointIsConvertedBackFromEveryRotatedVideoBuffer() {
  let captureDevicePoint = CGPoint(x: 0.23, y: 0.67)
  expectFocusPoint(
    .landscapeLeft,
    videoPoint: CGPoint(x: 0.23, y: 0.67),
    captureDevicePoint: captureDevicePoint
  )
  expectFocusPoint(
    .portrait,
    videoPoint: CGPoint(x: 0.33, y: 0.23),
    captureDevicePoint: captureDevicePoint
  )
  expectFocusPoint(
    .landscapeRight,
    videoPoint: CGPoint(x: 0.77, y: 0.33),
    captureDevicePoint: captureDevicePoint
  )
  expectFocusPoint(
    .portraitUpsideDown,
    videoPoint: CGPoint(x: 0.67, y: 0.77),
    captureDevicePoint: captureDevicePoint
  )
}

@Test
func invalidGuideRegionsFailValidationInsteadOfReusingPixelsOutsideTheGuide() {
  #expect(
    DocumentCameraGuideRegion(minX: -0.01, minY: 0.2, width: 0.5, height: 0.3)
      .normalizedTopLeftRect == nil
  )
  #expect(
    DocumentCameraGuideRegion(minX: 0.7, minY: 0.2, width: 0.31, height: 0.3)
      .normalizedTopLeftRect == nil
  )
  #expect(
    DocumentCameraGuideRegion(minX: 0.2, minY: 0.2, width: .nan, height: 0.3)
      .normalizedTopLeftRect == nil
  )
}

@Test
func subpixelGuideJitterDoesNotInvalidateCaptureGeometry() {
  let region = DocumentCameraGuideRegion(minX: 0.2, minY: 0.3, width: 0.5, height: 0.3)
  let layoutJitter = DocumentCameraGuideRegion(
    minX: 0.200_04,
    minY: 0.299_96,
    width: 0.500_02,
    height: 0.300_03
  )
  let materialMovement = DocumentCameraGuideRegion(
    minX: 0.201,
    minY: 0.3,
    width: 0.5,
    height: 0.3
  )

  #expect(region.isEffectivelyEqual(to: layoutJitter))
  #expect(!region.isEffectivelyEqual(to: materialMovement))
}

@Test
func visionContainmentRejectsAnyPointOutsideTheExactGuide() {
  let detector = DocumentRegionDetector()
  detector.updateGuideRegion(
    bufferTopLeft: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.3)
  )
  let topLeft = CGPoint(x: 0.2, y: 0.7)
  let topRight = CGPoint(x: 0.8, y: 0.7)
  let bottomRight = CGPoint(x: 0.8, y: 0.4)
  let bottomLeft = CGPoint(x: 0.2, y: 0.4)
  let inside = [topLeft, topRight, bottomRight, bottomLeft]
  let outside = inside + [CGPoint(x: 0.199_999, y: 0.55)]

  #expect(detector.areCornersInsideGuide(inside) == true)
  #expect(detector.areCornersInsideGuide(outside) == false)
}

private func expectFocusPoint(
  _ orientation: DocumentCameraOrientation,
  videoPoint: CGPoint,
  captureDevicePoint: CGPoint
) {
  let converted = orientation.captureDevicePoint(fromVideoBuffer: videoPoint)
  #expect(approximatelyEqual(converted.x, captureDevicePoint.x))
  #expect(approximatelyEqual(converted.y, captureDevicePoint.y))
}

private func approximatelyEqual(_ first: Double, _ second: Double) -> Bool {
  abs(first - second) < 0.000_001
}
