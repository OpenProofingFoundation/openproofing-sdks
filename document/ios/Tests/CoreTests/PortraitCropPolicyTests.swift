import Foundation
import Testing

@testable import DocumentSDK

@Test func portraitPolicyMapsUprightVisionLowerLeftToTopLeftPixels() throws {
  let value = PortraitCropPolicy.evaluate(
    faces: [face(0.125, 0.5, 0.25, 0.25)], imageWidth: 800, imageHeight: 400)
  let crop = try #require(value.candidates.first)
  #expect(crop.pixelRect == .init(x: 100, y: 100, width: 200, height: 100))
  #expect(crop.normalizedTopLeft == .init(x: 0.125, y: 0.25, width: 0.25, height: 0.25))
  #expect(crop.role == .faceRegion)
  #expect(value.outcome == .provisionalSingleFace)
  #expect(value.selectedCandidateIndex == 0)
}

@Test func portraitPolicyRoundsOutwardWithoutResizingOrAddingDefaultPadding() throws {
  let value = PortraitCropPolicy.evaluate(
    faces: [face(0.125, 0.25, 0.25, 0.5)], imageWidth: 13, imageHeight: 11)
  #expect(value.paddingFraction == 0)
  #expect(try #require(value.candidates.first).pixelRect == .init(x: 1, y: 2, width: 4, height: 7))
}

@Test func portraitPolicyKeepsMainAndGhostCandidatesAmbiguousRegardlessOfArea() {
  let value = PortraitCropPolicy.evaluate(
    faces: [face(0.0625, 0.125, 0.5, 0.5), face(0.75, 0.125, 0.0625, 0.125)],
    imageWidth: 800, imageHeight: 500)
  #expect(value.candidates.count == 2)
  #expect(value.candidates.map(\.faceIndex) == [0, 1])
  #expect(value.outcome == .ambiguous)
  #expect(value.selectedCandidateIndex == nil)
}

@Test func portraitPolicyClipsCrossingBoundsAndDoesNotSilentlySelectPartialFace() throws {
  let value = PortraitCropPolicy.evaluate(
    faces: [face(-0.125, 0.75, 0.5, 0.5)], imageWidth: 800, imageHeight: 400)
  let crop = try #require(value.candidates.first)
  #expect(crop.wasClipped)
  #expect(crop.pixelRect == .init(x: 0, y: 0, width: 300, height: 100))
  #expect(value.outcome == .ambiguous)
  #expect(value.selectedCandidateIndex == nil)
}

@Test func portraitPolicyDistinguishesNoFaceFromRejectedAndInvalidGeometry() {
  let none = PortraitCropPolicy.evaluate(faces: [], imageWidth: 800, imageHeight: 400)
  #expect(none.outcome == .noFace)
  let invalid = PortraitCropPolicy.evaluate(
    faces: [face(.nan, 0, 0.5, 0.5), face(2, 2, 0.5, 0.5), face(0, 0, -1, 0.5)],
    imageWidth: 800, imageHeight: 400)
  #expect(invalid.outcome == .invalidInput)
  #expect(invalid.unselectedFaceIndices == [0, 1, 2])
  #expect(invalid.candidates.isEmpty)
  #expect(PortraitCropPolicy.evaluate(faces: [], imageWidth: 0, imageHeight: 1).outcome == .invalidInput)
  #expect(PortraitCropPolicy.evaluate(faces: [], imageWidth: Int.max, imageHeight: 1).outcome == .invalidInput)
}

@Test func portraitPolicyDoesNotHideInvalidCompanionOrInvalidConfidence() {
  let invalidConfidence = PortraitFaceObservation(
    boundingBox: .init(x: 0.5, y: 0.5, width: 0.25, height: 0.25), confidence: .nan)
  let value = PortraitCropPolicy.evaluate(
    faces: [face(0.125, 0.5, 0.25, 0.25), invalidConfidence], imageWidth: 800, imageHeight: 400)
  #expect(value.candidates.count == 1)
  #expect(value.unselectedFaceIndices == [1])
  #expect(value.outcome == .ambiguous)
  #expect(value.selectedCandidateIndex == nil)
}

@Test func portraitPolicyRecordsRequestedPaddingWithoutClaimingPhotographBoundary() throws {
  let value = PortraitCropPolicy.evaluate(
    faces: [face(0.25, 0.25, 0.25, 0.25)], imageWidth: 800, imageHeight: 400, paddingFraction: 0.5)
  let crop = try #require(value.candidates.first)
  #expect(crop.pixelRect == .init(x: 100, y: 150, width: 400, height: 200))
  #expect(crop.role == .faceRegion)
  #expect(value.paddingFraction == 0.5)
}

/// Padding wide enough to exceed the image must clamp to the image and report the
/// clipping, not be rejected. The face detector needs the face to be a small part of its
/// input, and an upper bound on padding could not express that. Negative and non-finite
/// padding stay invalid, which the serialization test below pins.
@Test func portraitPolicyWidePaddingClampsToImageRatherThanRejecting() throws {
  let value = PortraitCropPolicy.evaluate(
    faces: [face(0.25, 0.25, 0.25, 0.25)], imageWidth: 800, imageHeight: 400, paddingFraction: 3)
  let crop = try #require(value.candidates.first)
  #expect(crop.pixelRect == .init(x: 0, y: 0, width: 800, height: 400))
  #expect(crop.wasClipped)
  #expect(value.paddingFraction == 3)
  #expect(value.unselectedFaceIndices.isEmpty)
  // Clipped means the requested context was not fully available, so the single face is no
  // longer provisional. That is existing policy, unchanged.
  #expect(value.outcome == .ambiguous)
}

@Test func portraitPolicyInvalidInputsAndValidResultsRemainSerializable() throws {
  for padding in [Double.nan, .infinity, -1, 0] {
    let value = PortraitCropPolicy.evaluate(
      faces: [face(0.25, 0.25, 0.25, 0.25)], imageWidth: 800, imageHeight: 400, paddingFraction: padding)
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(PortraitCropAssessment.self, from: data) == value)
    #expect(value.outcome == (padding == 0 ? .provisionalSingleFace : .invalidInput))
  }
}

private func face(_ left: Double, _ bottom: Double, _ width: Double, _ height: Double)
  -> PortraitFaceObservation {
  PortraitFaceObservation(boundingBox: .init(x: left, y: bottom, width: width, height: height), confidence: 0.9)
}
