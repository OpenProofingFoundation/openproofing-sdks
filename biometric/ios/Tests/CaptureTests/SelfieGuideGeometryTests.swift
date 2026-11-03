import CoreGraphics
import XCTest

@testable import BiometricCapture

final class SelfieGuideGeometryTests: XCTestCase {
  func testAllSupportedOrientationsMapToTheExpectedSensorCorner() {
    let face = CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1)
    let centers: [(UInt32, CGPoint)] = [
      (1, CGPoint(x: 15, y: 75)), (3, CGPoint(x: 85, y: 25)),
      (6, CGPoint(x: 75, y: 85)), (8, CGPoint(x: 25, y: 15)),
    ]
    for (orientation, center) in centers {
      let oval = CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
      XCTAssertTrue(
        SelfieGuideGeometry.contains(
          face: face, orientation: orientation,
          displayTransform: .identity, viewport: CGSize(width: 100, height: 100), oval: oval))
      XCTAssertTrue(
        SelfieGuideGeometry.matchesAnchor(
          face: face, orientation: orientation,
          displayTransform: .identity, viewport: CGSize(width: 100, height: 100), anchor: center))
      XCTAssertFalse(
        SelfieGuideGeometry.matchesAnchor(
          face: face, orientation: orientation,
          displayTransform: .identity, viewport: CGSize(width: 100, height: 100), anchor: .zero))
    }
  }

  func testPreviewCropAndMirrorAreAppliedBeforeContainment() {
    let transform = CGAffineTransform(a: -2, b: 0, c: 0, d: 1, tx: 1.5, ty: 0)
    let viewport = CGSize(width: 200, height: 100)
    let oval = CGRect(x: 130, y: 15, width: 40, height: 30)
    XCTAssertTrue(
      SelfieGuideGeometry.contains(
        face: CGRect(x: 0.35, y: 0.65, width: 0.05, height: 0.1),
        orientation: 1, displayTransform: transform, viewport: viewport, oval: oval))
    XCTAssertFalse(
      SelfieGuideGeometry.contains(
        face: CGRect(x: 0.1, y: 0.65, width: 0.05, height: 0.1),
        orientation: 1, displayTransform: transform, viewport: viewport, oval: oval))
  }

  func testOvalRejectsCornersOutsideEvenWhenBoundingRectContainsFace() {
    XCTAssertFalse(
      SelfieGuideGeometry.contains(
        face: CGRect(x: 0, y: 0, width: 1, height: 1),
        orientation: 1, displayTransform: .identity, viewport: CGSize(width: 100, height: 100),
        oval: CGRect(x: 0, y: 0, width: 100, height: 100)))
    XCTAssertFalse(
      SelfieGuideGeometry.contains(
        face: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1),
        orientation: 2, displayTransform: .identity, viewport: CGSize(width: 100, height: 100),
        oval: CGRect(x: 0, y: 0, width: 100, height: 100)))
  }
}
