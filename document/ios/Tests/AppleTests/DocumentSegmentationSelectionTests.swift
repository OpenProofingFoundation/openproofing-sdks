import Foundation
import Testing
import Vision

@testable import DocumentCaptureApple

struct DocumentSegmentationSelectionTests {
  @Test func movementChoosesContainedCardInsteadOfLargerSurroundingRectangle() throws {
    let detector = DocumentRegionDetector(adaptive: true)
    detector.updateGuideRegion(bufferTopLeft: CGRect(x: 0.15, y: 0.25, width: 0.7, height: 0.5))
    detector.updateAnalysisMode(.freshDetection)
    let background = rectangle(left: 0.025, right: 0.975, bottom: 0.05, top: 0.95)
    let card = rectangle(left: 0.25, right: 0.75, bottom: 0.35, top: 0.65)
    for observations in [[background, card], [card, background]] {
      let selected = try #require(detector.selectRectangle(from: observations))
      #expect(selected.observation === card)
    }
  }

  @Test func imageSizedSegmentationCannotSuppressCardFallback() {
    let detector = DocumentRegionDetector(adaptive: true)
    detector.updateGuideRegion(bufferTopLeft: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6))
    // The SHF failure covered 98.6% of image width and 99.2% of height.
    let frame = rectangle(left: 0.007, right: 0.993, bottom: 0.004, top: 0.996)
    #expect(detector.segmentedDocument(from: frame) == nil)
  }

  @Test func containedPerspectiveCardRemainsEligible() throws {
    let detector = DocumentRegionDetector(adaptive: true)
    detector.updateGuideRegion(bufferTopLeft: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6))
    let card = VNRectangleObservation(
      requestRevision: 1, topLeft: CGPoint(x: 0.2, y: 0.75),
      topRight: CGPoint(x: 0.8, y: 0.7), bottomRight: CGPoint(x: 0.8, y: 0.3),
      bottomLeft: CGPoint(x: 0.2, y: 0.25))
    let accepted = try #require(detector.segmentedDocument(from: card))
    #expect(accepted.observation === card)
  }

  @Test func missingGuideCannotAcceptSegmentation() {
    let detector = DocumentRegionDetector(adaptive: true)
    #expect(
      detector.segmentedDocument(from: rectangle(left: 0.2, right: 0.8, bottom: 0.3, top: 0.7))
        == nil)
  }

  private func rectangle(left: Double, right: Double, bottom: Double, top: Double)
    -> VNRectangleObservation
  {
    VNRectangleObservation(
      requestRevision: 1, topLeft: CGPoint(x: left, y: top),
      topRight: CGPoint(x: right, y: top), bottomRight: CGPoint(x: right, y: bottom),
      bottomLeft: CGPoint(x: left, y: bottom))
  }
}
