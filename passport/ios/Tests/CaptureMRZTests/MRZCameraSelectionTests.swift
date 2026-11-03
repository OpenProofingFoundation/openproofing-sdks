import XCTest
@testable import PassportMRZCapture
#if os(iOS)
  import AVFoundation
#endif

/// Selection fixtures ported from the identity SDK's DocumentCameraSelectionPolicyTests.
/// These are policy/adapter tests; they do not claim physical camera or focus qualification.
final class MRZCameraSelectionTests: XCTestCase {
  func testVirtualDualWidePreferredOverHigherResolutionTriple() throws {
    let wide = candidate("wide", .wide, 4032, 3024)
    let dual = candidate("dual", .dualWide, 4032, 3024)
    let triple = candidate("triple", .triple, 8064, 6048)
    XCTAssertEqual(try XCTUnwrap(MRZCameraSelection.select(from: [wide, triple, dual])).identifier, "dual")
  }

  func testTriplePreferredWhenDualWideUnavailable() throws {
    let wide = candidate("wide", .wide, 4032, 3024)
    let triple = candidate("triple", .triple, 8064, 6048)
    XCTAssertEqual(try XCTUnwrap(MRZCameraSelection.select(from: [wide, triple])).identifier, "triple")
  }

  func testPhysicalWideFallbackWithoutSubjectDistanceInferenceAndEmptyDiscovery() throws {
    let wide = candidate("wide", .wide, 8064, 6048)
    let ultra = candidate("ultra", .ultraWide, 4032, 3024)
    XCTAssertEqual(try XCTUnwrap(MRZCameraSelection.select(from: [wide, ultra])).identifier, "wide")
    XCTAssertNil(MRZCameraSelection.select(from: []))
  }

  func testVirtualDualWideBeatsHigherResolutionPhysicalCameras() throws {
    let wide = candidate("wide", .wide, 8064, 6048)
    let ultra = candidate("ultra", .ultraWide, 8064, 6048)
    let dual = candidate("dual", .dualWide, 5712, 4284)
    XCTAssertEqual(try XCTUnwrap(MRZCameraSelection.select(from: [dual, wide, ultra])).identifier, "dual")
  }

  func testPhysicalUltraWideAvailableWithoutWide() throws {
    let ultra = candidate("ultra", .ultraWide, 4032, 3024)
    XCTAssertEqual(try XCTUnwrap(MRZCameraSelection.select(from: [ultra])).identifier, "ultra")
  }

  func testHighestResolutionWideWinsWithStableIdentifierTieBreaker() throws {
    let lower = candidate("a-lower", .wide, 4032, 3024)
    let later = candidate("z-tied", .wide, 8064, 6048)
    let first = candidate("a-tied", .wide, 8064, 6048)
    let telephoto = candidate("telephoto", .telephoto, 12000, 9000)
    for candidates in [[lower, later, telephoto, first], [first, telephoto, later, lower]] {
      XCTAssertEqual(try XCTUnwrap(MRZCameraSelection.select(from: candidates)).identifier, "a-tied")
    }
  }

  func testVirtualSwitchOverZoomUsesNativeBoundsAndMissingBaselineFallback() {
    XCTAssertEqual(MRZCameraSelection.baselineZoom(minimum: 1, maximum: 10, firstSwitchOver: 2), 2)
    XCTAssertEqual(MRZCameraSelection.baselineZoom(minimum: 2, maximum: 10, firstSwitchOver: 1), 2)
    XCTAssertEqual(MRZCameraSelection.baselineZoom(minimum: 1, maximum: 3, firstSwitchOver: 4), 3)
    XCTAssertEqual(MRZCameraSelection.baselineZoom(minimum: 1, maximum: 10, firstSwitchOver: nil), 1)
    XCTAssertEqual(MRZCameraSelection.baselineZoom(minimum: 2, maximum: 10, firstSwitchOver: nil), 2)
  }

  #if os(iOS)
    func testNativeDeviceTypeMappingPreservesVirtualAndPhysicalLensKinds() {
      XCTAssertEqual(MRZCameraSelection.lens(for: .builtInDualWideCamera), .dualWide)
      XCTAssertEqual(MRZCameraSelection.lens(for: .builtInTripleCamera), .triple)
      XCTAssertEqual(MRZCameraSelection.lens(for: .builtInWideAngleCamera), .wide)
      XCTAssertEqual(MRZCameraSelection.lens(for: .builtInUltraWideCamera), .ultraWide)
      XCTAssertEqual(MRZCameraSelection.lens(for: .builtInTelephotoCamera), .telephoto)
    }
  #endif

  private func candidate(_ identifier: String, _ lens: MRZCameraLens, _ width: Int, _ height: Int)
    -> MRZCameraCandidate {
    .init(identifier: identifier, lens: lens, maximumPhotoWidth: width, maximumPhotoHeight: height)
  }
}
