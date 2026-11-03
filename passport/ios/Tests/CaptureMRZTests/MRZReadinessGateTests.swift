import Foundation
import CoreGraphics
import XCTest
@testable import PassportMRZCapture

final class MRZReadinessGateTests: XCTestCase {
  private let lines = [["P<UTOSPECIMEN<<SYNTHETIC<<<<<<<<<<<<<<<<<<<<"],
                       ["X1234567<7UTO8506151F3201015<<<<<<<<<<<<<<08"]]
  private let guide = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
  private let rows = [CGRect(x: 0.15, y: 0.6, width: 0.7, height: 0.1),
                      CGRect(x: 0.15, y: 0.4, width: 0.7, height: 0.1)]

  private func frame(_ time: Double, candidates: [[String]]? = nil,
                     bounds: [CGRect]? = nil) -> MRZOCRFrame {
    .init(candidates: candidates ?? lines, timestamp: time, policy: .engineeringV1,
          orientation: .landscapeRight, rowBounds: bounds ?? rows)
  }

  func testFiveRankedNameAlternativesAllowStableBestRead() {
    var gate = MRZReadinessGate()
    let names = ["SPECIMEN", "EXAMPLES", "SPECMENS", "SPECIMFN", "SPECIHEN"]
      .map { lines[0][0].replacingOccurrences(of: "SPECIMEN", with: $0) }
    let candidates = [names, lines[1]]
    XCTAssertNil(gate.ingest(frame(1, candidates: candidates), rawGuideRegion: guide))
    XCTAssertNil(gate.ingest(frame(1.25, candidates: candidates), rawGuideRegion: guide))
    XCTAssertEqual(gate.ingest(frame(1.5, candidates: candidates), rawGuideRegion: guide)?.surname,
                   "SPECIMEN")
  }

  func testSingleReadCannotFireAndStableFullReadEmitsOnce() {
    var gate = MRZReadinessGate()
    XCTAssertNil(gate.ingest(frame(1), rawGuideRegion: guide))
    XCTAssertNil(gate.ingest(frame(1.25), rawGuideRegion: guide))
    XCTAssertNotNil(gate.ingest(frame(1.5), rawGuideRegion: guide))
    XCTAssertNil(gate.ingest(frame(2), rawGuideRegion: guide))
  }

  func testClippedOrOutsideRowsCannotAccumulateReadiness() {
    for bad in [CGRect(x: 0.05, y: 0.4, width: 0.7, height: 0.1),
                CGRect(x: 0.1, y: 0.4, width: 0.7, height: 0.1),
                CGRect(x: 0.15, y: 0.75, width: 0.7, height: 0.1)] {
      var gate = MRZReadinessGate()
      for time in [1.0, 1.25, 1.5, 2.0] {
        XCTAssertNil(gate.ingest(frame(time, bounds: [rows[0], bad]), rawGuideRegion: guide))
      }
    }
  }

  func testMissingRowChangedNameAndFrameGapResetHold() {
    for interruption in [frame(1.3, candidates: [lines[1]], bounds: [rows[1]]),
                         frame(1.3, candidates: [[lines[0][0].replacingOccurrences(of: "SPECIMEN", with: "EXAMPLES")], lines[1]])] {
      var gate = MRZReadinessGate()
      XCTAssertNil(gate.ingest(frame(1), rawGuideRegion: guide))
      XCTAssertNil(gate.ingest(frame(1.2), rawGuideRegion: guide))
      XCTAssertNil(gate.ingest(interruption, rawGuideRegion: guide))
      XCTAssertNil(gate.ingest(frame(1.5), rawGuideRegion: guide))
      XCTAssertNil(gate.ingest(frame(1.75), rawGuideRegion: guide))
      XCTAssertNotNil(gate.ingest(frame(2), rawGuideRegion: guide))
    }
    var gate = MRZReadinessGate()
    XCTAssertNil(gate.ingest(frame(1), rawGuideRegion: guide))
    XCTAssertNil(gate.ingest(frame(2), rawGuideRegion: guide))
    XCTAssertNil(gate.ingest(frame(2.25), rawGuideRegion: guide))
    XCTAssertNotNil(gate.ingest(frame(2.5), rawGuideRegion: guide))
  }

  func testReversedSeparatedAndMisalignedRowsCannotTrigger() {
    let invalid = [
      [rows[1], rows[0]],
      [CGRect(x: 0.15, y: 0.65, width: 0.7, height: 0.03),
       CGRect(x: 0.15, y: 0.3, width: 0.7, height: 0.03)],
      [CGRect(x: 0.15, y: 0.6, width: 0.4, height: 0.1),
       CGRect(x: 0.45, y: 0.4, width: 0.4, height: 0.1)]]
    for bounds in invalid {
      var gate = MRZReadinessGate()
      for time in [1.0, 1.25, 1.5] {
        XCTAssertNil(gate.ingest(frame(time, bounds: bounds), rawGuideRegion: guide))
      }
    }
  }

  func testMergedTwoLineObservationStillRequiresStableCompleteInGuideRead() {
    var gate = MRZReadinessGate()
    let merged = [[lines[0][0] + lines[1][0]]]
    let bound = [CGRect(x: 0.15, y: 0.4, width: 0.7, height: 0.3)]
    XCTAssertNil(gate.ingest(frame(1, candidates: merged, bounds: bound), rawGuideRegion: guide))
    XCTAssertNil(gate.ingest(frame(1.25, candidates: merged, bounds: bound), rawGuideRegion: guide))
    XCTAssertNotNil(gate.ingest(frame(1.5, candidates: merged, bounds: bound), rawGuideRegion: guide))
  }

  func testValidatedNumericOCREquivalentsDoNotResetStableHold() {
    var gate = MRZReadinessGate()
    var alternate = Array(lines[1][0])
    alternate[15] = "O"
    XCTAssertNil(gate.ingest(frame(1), rawGuideRegion: guide))
    XCTAssertNil(gate.ingest(frame(1.25, candidates: [lines[0], [String(alternate)]]), rawGuideRegion: guide))
    XCTAssertNotNil(gate.ingest(frame(1.5), rawGuideRegion: guide))
  }

  func testFastDuplicateAndNonfiniteFramesDoNotEstablishHold() {
    var gate = MRZReadinessGate()
    for time in [1.0, 1.01, 1.02, 1.02, Double.nan, 1.4, 1.5] {
      XCTAssertNil(gate.ingest(frame(time), rawGuideRegion: guide))
    }
    XCTAssertNil(gate.ingest(frame(1.6, bounds: []), rawGuideRegion: guide))
  }

  func testMetadataToVisionConversionForEveryOrientation() {
    let raw = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
    let expected: [(MRZCaptureOrientation, CGRect)] = [
      (.landscapeRight, CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.4)),
      (.landscapeLeft, CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.4)),
      (.portrait, CGRect(x: 0.4, y: 0.6, width: 0.4, height: 0.3)),
      (.portraitUpsideDown, CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.3))]
    for (orientation, rect) in expected {
      let actual = MRZReadinessGate.visionRegion(raw, orientation: orientation)
      XCTAssertEqual(actual.minX, rect.minX, accuracy: 1e-9)
      XCTAssertEqual(actual.minY, rect.minY, accuracy: 1e-9)
      XCTAssertEqual(actual.width, rect.width, accuracy: 1e-9)
      XCTAssertEqual(actual.height, rect.height, accuracy: 1e-9)
    }
  }
}
