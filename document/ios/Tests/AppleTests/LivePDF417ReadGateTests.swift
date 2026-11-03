import CoreGraphics
import Foundation
import XCTest

@testable import DocumentCaptureApple

final class LivePDF417ReadGateTests: XCTestCase {
  private let guide = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
  private let inside = [
    CGPoint(x: 0.25, y: 0.35), CGPoint(x: 0.75, y: 0.35),
    CGPoint(x: 0.75, y: 0.65), CGPoint(x: 0.25, y: 0.65),
  ]

  // MARK: Barcode inside the guide

  func testBarcodePartlyOutsideGuideIsRefusedAndTheSameBarcodeWhollyInsideIsCounted() {
    let payload = barcode()
    var received: [String?] = []
    let delegate = LivePDF417MetadataDelegate(guideRegion: { [guide] in guide }) {
      received.append($0)
    }
    let partlyOutside: [[CGPoint]] = [
      // Half the symbol beyond the guide's right edge, as on the device.
      [CGPoint(x: 0.5, y: 0.35), CGPoint(x: 0.95, y: 0.35),
       CGPoint(x: 0.95, y: 0.65), CGPoint(x: 0.5, y: 0.65)],
      replacing(0, in: inside, with: CGPoint(x: 0.19, y: 0.35)),
      replacing(1, in: inside, with: CGPoint(x: 0.81, y: 0.35)),
      replacing(1, in: inside, with: CGPoint(x: 0.75, y: 0.29)),
      replacing(2, in: inside, with: CGPoint(x: 0.75, y: 0.71)),
    ]
    for corners in partlyOutside {
      delegate.receive([LivePDF417MetadataRead(payload: payload, corners: corners)])
    }
    XCTAssertEqual(received, Array(repeating: nil, count: partlyOutside.count))
    delegate.receive([LivePDF417MetadataRead(payload: payload, corners: inside)])
    XCTAssertEqual(received.last, payload)
    let onEdges = [
      CGPoint(x: guide.minX, y: guide.minY), CGPoint(x: guide.maxX, y: guide.minY),
      CGPoint(x: guide.maxX, y: guide.maxY), CGPoint(x: guide.minX, y: guide.maxY),
    ]
    XCTAssertTrue(LivePDF417GuideContainment.contains(corners: onEdges, in: guide))
  }

  func testNoPublishedGuideRefusesAWhollyFramedRead() {
    let payload = barcode()
    var published: CGRect?
    var received: [String?] = []
    let delegate = LivePDF417MetadataDelegate(guideRegion: { published }) { received.append($0) }
    delegate.receive([LivePDF417MetadataRead(payload: payload, corners: inside)])
    XCTAssertEqual(received, [nil])
    published = guide
    delegate.receive([LivePDF417MetadataRead(payload: payload, corners: inside)])
    XCTAssertEqual(received, [nil, payload])
  }

  func testExactlyFourFiniteCornersAreRequired() {
    let payload = barcode()
    var received: [String?] = []
    let delegate = LivePDF417MetadataDelegate(guideRegion: { [guide] in guide }) {
      received.append($0)
    }
    let malformed: [[CGPoint]] = [
      [], Array(inside.prefix(3)), inside + [CGPoint(x: 0.5, y: 0.5)],
      replacing(3, in: inside, with: CGPoint(x: CGFloat.nan, y: 0.5)),
    ]
    for corners in malformed {
      delegate.receive([LivePDF417MetadataRead(payload: payload, corners: corners)])
    }
    XCTAssertEqual(received, Array(repeating: nil, count: malformed.count))
    delegate.receive([LivePDF417MetadataRead(payload: payload, corners: inside)])
    XCTAssertEqual(received.last, payload)
  }

  // MARK: Two identical reads

  func testOneCountedReadDoesNotConfirmAndTwoIdenticalReadsWithinTheIntervalDo() {
    XCTAssertEqual(DocumentCaptureTuning.AutoCapture.livePDF417RequiredReads, 2)
    XCTAssertEqual(DocumentCaptureTuning.defaultValues["AutoCapture.livePDF417RequiredReads"], 2)
    var confirmation = LivePDF417ReadConfirmation()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertFalse(confirmation.observe("A", at: start))
    XCTAssertTrue(confirmation.observe("A", at: start.addingTimeInterval(0.5)))
    XCTAssertTrue(confirmation.observe("A", at: start.addingTimeInterval(0.55)))
  }

  func testDifferentPayloadRestartsTheCount() {
    var confirmation = LivePDF417ReadConfirmation()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertFalse(confirmation.observe("A", at: start))
    XCTAssertFalse(confirmation.observe("B", at: start.addingTimeInterval(0.03)))
    XCTAssertTrue(confirmation.observe("B", at: start.addingTimeInterval(0.06)))
  }

  func testRefusedReadBetweenRestartsTheCount() {
    var confirmation = LivePDF417ReadConfirmation()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertFalse(confirmation.observe("A", at: start))
    XCTAssertFalse(confirmation.observe(nil, at: start.addingTimeInterval(0.03)))
    XCTAssertFalse(confirmation.observe("A", at: start.addingTimeInterval(0.06)))
    XCTAssertTrue(confirmation.observe("A", at: start.addingTimeInterval(0.09)))
  }

  func testLongerGapOrEarlierClockRestartsTheCount() {
    var confirmation = LivePDF417ReadConfirmation()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertFalse(confirmation.observe("A", at: start))
    XCTAssertFalse(confirmation.observe("A", at: start.addingTimeInterval(0.501)))
    XCTAssertFalse(confirmation.observe("A", at: start.addingTimeInterval(0.4)))
    XCTAssertTrue(confirmation.observe("A", at: start.addingTimeInterval(0.45)))
  }

  // MARK: Frame analysis in live mode

  func testAnalyzerAnalysesLiveBarcodeFramesOnlyWhenAnalysisIsRequested() {
    XCTAssertFalse(
      analyzer(.init(livePDF417: true, includesAdaptiveCapture: true)).metadataOnlyCapture)
    XCTAssertFalse(
      analyzer(.init(livePDF417: true, includesLiveContentAnalysis: true)).metadataOnlyCapture)
    XCTAssertTrue(analyzer(.init(livePDF417: true)).metadataOnlyCapture)
    XCTAssertFalse(analyzer(.qualityOnly).metadataOnlyCapture)
  }

  private func analyzer(_ configuration: DocumentCameraDiagnosticsConfiguration)
    -> DocumentFrameAnalyzer
  {
    DocumentFrameAnalyzer(
      now: { Date() }, configuration: configuration, observationHandler: { _ in },
      focusHandler: { _ in })
  }

  private func replacing(_ index: Int, in corners: [CGPoint], with point: CGPoint) -> [CGPoint] {
    var result = corners
    result[index] = point
    return result
  }

  private func barcode() -> String {
    let body =
      "DLDBA09242030\nDBD09242020\nDBB01011980\nDAG1 SAMPLE ST\n"
      + "DAIEXAMPLE CITY\nDAJWA\nDAK98000\nDAQEXAMPLE123\nDACALICE\nDCSEXAMPLE\n\r"
    let header = "@\n\u{1e}\rANSI 636045090201"
    return header + "DL" + String(format: "%04d%04d", header.utf8.count + 10, body.utf8.count)
      + body
  }
}
