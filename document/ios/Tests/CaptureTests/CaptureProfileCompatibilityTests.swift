#if os(iOS)
import Foundation
import XCTest
import DocumentCapture

final class CaptureProfileCompatibilityTests: XCTestCase {
  func testKnownLegacyProfilesDecodeAndNewRecordsUseStableCodes() throws {
    let values: [(String, CaptureRecords.Profile)] = [
      ("License front", .licenseFront), ("License back", .licenseBack),
      ("US passport card front", .passportCardFront), ("US passport card back", .passportCardBack),
      ("Passport page", .passport), ("Other document", .document),
    ]
    for (legacy, profile) in values {
      let bytes = try JSONEncoder().encode(legacy)
      XCTAssertEqual(try JSONDecoder().decode(CaptureRecords.Profile.self, from: bytes), profile)
      XCTAssertEqual(CaptureRecords.Profile.retainedIdentifier(legacy), profile)
      XCTAssertEqual(try JSONDecoder().decode(String.self, from: JSONEncoder().encode(profile)), profile.rawValue)
    }
    for unsupported in ["license_front_extra", "Unknown card", "US passport front", "liCense FRonT", "LICENSE_FRONT", "License_front"] {
      XCTAssertNil(CaptureRecords.Profile.retainedIdentifier(unsupported))
      XCTAssertThrowsError(try JSONDecoder().decode(CaptureRecords.Profile.self, from: JSONEncoder().encode(unsupported)))
    }
  }
}
#endif
