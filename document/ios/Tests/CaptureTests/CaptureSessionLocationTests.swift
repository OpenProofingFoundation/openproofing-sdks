#if os(iOS)
  import CoreLocation
  import XCTest

  @testable import DocumentCapture

  @MainActor
  final class CaptureSessionLocationTests: XCTestCase {
    func testFreshFixPreservesAccuracyAndTimestamp() throws {
      let now = Date()
      let fix = CLLocation(
        coordinate: .init(latitude: 47, longitude: -122), altitude: 0,
        horizontalAccuracy: 12, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-2))
      let assertion = try XCTUnwrap(CaptureSessionLocation.assertion(from: fix, now: now))
      XCTAssertEqual(assertion.fixedAt, fix.timestamp)
      XCTAssertEqual(assertion.horizontalAccuracyMeters, 12)
      XCTAssertNil(assertion.altitudeMeters)
      XCTAssertNil(assertion.verticalAccuracyMeters)
    }

    func testStaleFutureAndInvalidFixesCannotEnterCaptureRequest() {
      let now = Date()
      for (age, accuracy) in [(11.0, 5.0), (-1, 5), (0, -1), (0, Double.nan)] {
        let fix = CLLocation(
          coordinate: .init(latitude: 47, longitude: -122), altitude: 100,
          horizontalAccuracy: accuracy, verticalAccuracy: 10,
          timestamp: now.addingTimeInterval(-age))
        XCTAssertNil(CaptureSessionLocation.assertion(from: fix, now: now))
      }
    }
  }

#endif
