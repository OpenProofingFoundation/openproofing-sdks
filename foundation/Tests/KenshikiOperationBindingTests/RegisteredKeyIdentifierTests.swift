import Foundation
import XCTest

@testable import KenshikiOperationBinding

final class RegisteredKeyIdentifierTests: XCTestCase {
  func testCompatibilityIdentifierTimestampAndAlphabetBoundaries() throws {
    let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    for milliseconds: UInt64 in [0, 1, 1_700_000_000_000, 281_474_976_710_655] {
      let value = RegisteredKeyEnrollmentCustody.makeClientID(
        now: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
      XCTAssertEqual(value.count, 26)
      let decoded = try value.prefix(10).reduce(UInt64(0)) { accumulated, character in
        let digit = try XCTUnwrap(alphabet.firstIndex(of: character))
        return accumulated * 32 + UInt64(digit)
      }
      XCTAssertEqual(decoded, milliseconds)
      XCTAssertTrue(value.allSatisfy(alphabet.contains))
    }
  }
}
