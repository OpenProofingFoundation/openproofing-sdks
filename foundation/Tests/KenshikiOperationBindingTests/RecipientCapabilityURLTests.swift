import Foundation
import XCTest
@testable import KenshikiOperationBinding

final class RecipientCapabilityURLTests: XCTestCase {
  private let origin = URL(string: "https://recipient.invalid")!
  private let path = "/s/psv2_approved"

  func testExactRouteAndHTTPSOrigin() throws {
    try RecipientCapabilityURL.validate(URL(string: "https://recipient.invalid/s/psv2_approved")!, origin: origin, path: path)
    try RecipientCapabilityURL.validate(URL(string: "https://RECIPIENT.invalid:443/s/psv2_approved")!, origin: origin, path: path)
  }

  func testSameFinalTokenCannotAuthorizeOtherRoutesOrQueries() {
    for value in ["https://recipient.invalid/other/psv2_approved", "https://recipient.invalid/s/psv2_approved?redirect=elsewhere",
      "https://recipient.invalid/s/psv2_approved?", "https://recipient.invalid/s/psv2_approved#fragment",
      "https://recipient.invalid/s/psv2_approved#", "https://recipient.invalid/s/psv2_approved/",
      "https://recipient.invalid/s%2Fpsv2_approved", "https://recipient.invalid/s/%70sv2_approved"] {
      XCTAssertThrowsError(try RecipientCapabilityURL.validate(URL(string: value)!, origin: origin, path: path), value)
    }
  }

  func testOriginConfusionAndMalformedConfiguredOriginsFail() {
    for value in ["http://recipient.invalid/s/psv2_approved", "https://recipient.invalid.evil.invalid/s/psv2_approved",
      "https://user@recipient.invalid/s/psv2_approved", "https://recipient.invalid:444/s/psv2_approved"] {
      XCTAssertThrowsError(try RecipientCapabilityURL.validate(URL(string: value)!, origin: origin, path: path))
    }
    let valid = URL(string: "https://recipient.invalid/s/psv2_approved")!
    for configured in ["https://recipient.invalid/other", "https://user@recipient.invalid", "https://recipient.invalid?x=1",
      "https://recipient.invalid#fragment", "http://recipient.invalid"] {
      XCTAssertThrowsError(try RecipientCapabilityURL.validate(valid, origin: URL(string: configured)!, path: path))
    }
  }
}
