import XCTest

@testable import PassportSDK

final class PassportAccessKeyTests: XCTestCase {
  func testICAOTD3Example() throws {
    // ICAO Doc 9303 Part 3, Figure 1: document number L898902C3, check digit 6.
    XCTAssertEqual(
      try PassportAccessKey(
        documentNumber: "L898902C3", birthDateYYMMDD: "740812",
        expiryDateYYMMDD: "120415"
      ).value, "L898902C3674081221204159")
  }

  func testPaddingRetainsTheCheckDigit() throws {
    let short = try PassportAccessKey(
      documentNumber: "L898902C", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415")
    let padded = try PassportAccessKey(
      documentNumber: "L898902C<", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415")
    XCTAssertEqual(short, padded)
  }

  func testNeverSilentlyTruncatesOrCoercesAccessMaterial() {
    for number in ["", "<<<<<<<<<", "ABCDEFGHIJ", "l898902c", "L898 02C", "L898902Ç"] {
      XCTAssertThrowsError(
        try PassportAccessKey(
          documentNumber: number, birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415")
      ) {
        XCTAssertEqual($0 as? PassportReadFailure, .invalidAccessKey)
      }
    }
    for date in ["74081", "7408123", "74O812", "٧٤٠٨١٢"] {
      XCTAssertThrowsError(
        try PassportAccessKey(
          documentNumber: "L898902C", birthDateYYMMDD: date, expiryDateYYMMDD: "120415"))
    }
  }
}
