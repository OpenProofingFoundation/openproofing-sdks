import XCTest

@testable import PassportSDK

/// S-06, NFC-04 and RFC-0002 §4.2: a failed Active or Chip Authentication refuses the read. A
/// recorded failure beside a returned observation is a silent downgrade to passive-only.
final class PassportChipAuthenticityTests: XCTestCase {
  func testFailedActiveAuthenticationRefusesTheRead() {
    for chip in [PassportProtocolObservation.notPerformed, .succeeded] {
      XCTAssertThrowsError(
        try PassportChipAuthenticity.require(activeAuthentication: .failed, chipAuthentication: chip)
      ) { XCTAssertEqual($0 as? PassportReadFailure, .activeAuthenticationFailed) }
    }
  }

  func testFailedChipAuthenticationRefusesTheRead() {
    for active in [PassportProtocolObservation.notPerformed, .succeeded] {
      XCTAssertThrowsError(
        try PassportChipAuthenticity.require(activeAuthentication: active, chipAuthentication: .failed)
      ) { XCTAssertEqual($0 as? PassportReadFailure, .chipAuthenticationFailed) }
    }
  }

  func testSucceededOrNotPerformedProtocolsReturnTheRead() throws {
    let states: [PassportProtocolObservation] = [.notPerformed, .succeeded]
    for active in states {
      for chip in states {
        XCTAssertNoThrow(
          try PassportChipAuthenticity.require(activeAuthentication: active, chipAuthentication: chip))
      }
    }
  }
}
