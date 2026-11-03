import Testing

@testable import DocumentCaptureApple

@Test
func virtualDualWideIsPreferredWhenNoPhysicalCameraSupports48MP() throws {
  let wide = candidate("wide", lens: .wide, focusDistance: 200, width: 4032, height: 3024)
  let dual = candidate("dual", lens: .dualWide, focusDistance: 20, width: 4032, height: 3024)
  let triple = candidate("triple", lens: .triple, focusDistance: 20, width: 8064, height: 6048)
  let selection = try #require(DocumentCameraSelectionPolicy().select(from: [wide, triple, dual]))
  #expect(selection.candidate.identifier == "dual")
  #expect(selection.report.reason == .virtualDualWidePreferred)
  #expect(selection.report.targetWorkingDistanceMillimeters == nil)
}

@Test
func tripleIsPreferredWhenDualWideIsUnavailable() throws {
  let wide = candidate("wide", lens: .wide, focusDistance: 200, width: 4032, height: 3024)
  let triple = candidate("triple", lens: .triple, focusDistance: 20, width: 8064, height: 6048)
  let selection = try #require(DocumentCameraSelectionPolicy().select(from: [wide, triple]))
  #expect(selection.report.reason == .virtualTriplePreferred)
}

@Test
func withoutAVirtualDeviceWideIsChosenAndNoSubjectDistanceIsInferred() throws {
  let wide = candidate("wide", lens: .wide, focusDistance: 300, width: 8064, height: 6048)
  let ultra = candidate("ultra", lens: .ultraWide, focusDistance: 20, width: 4032, height: 3024)
  let selection = try #require(DocumentCameraSelectionPolicy().select(from: [wide, ultra]))
  #expect(selection.candidate.identifier == "wide")
  #expect(selection.report.reason == .physicalFallback)
  #expect(selection.report.targetWorkingDistanceMillimeters == nil)
  #expect(DocumentCameraSelectionPolicy().select(from: []) == nil)
}

@Test
func virtualDualWideBeatsHigherResolutionPhysicalCameras() throws {
  let wide = candidate("wide", lens: .wide, focusDistance: 200, width: 8064, height: 6048)
  let ultra = candidate("ultra", lens: .ultraWide, focusDistance: 20, width: 8064, height: 6048)
  let dual = candidate("dual", lens: .dualWide, focusDistance: 20, width: 5712, height: 4284)
  let selected = try #require(DocumentCameraSelectionPolicy().select(from: [dual, wide, ultra]))
  #expect(selected.candidate.identifier == "dual")
  #expect(selected.report.reason == .virtualDualWidePreferred)
  #expect(selected.report.targetWorkingDistanceMillimeters == nil)
}

@Test
func physicalUltraWideIsAvailableWithoutWide() throws {
  let ultra = candidate("ultra", lens: .ultraWide, focusDistance: 20, width: 4032, height: 3024)
  let selection = try #require(DocumentCameraSelectionPolicy().select(from: [ultra]))
  #expect(selection.candidate.identifier == "ultra")
}

@Test
func highestResolutionWideWinsWithIdentifierAsDeterministicTieBreaker() throws {
  let lower = candidate("a-lower", lens: .wide, focusDistance: 100, width: 4_032, height: 3_024)
  let tiedLater = candidate("z-tied", lens: .wide, focusDistance: 100, width: 8_064, height: 6_048)
  let tiedFirst = candidate("a-tied", lens: .wide, focusDistance: 100, width: 8_064, height: 6_048)
  let telephoto = candidate(
    "telephoto",
    lens: .telephoto,
    focusDistance: 100,
    width: 12_000,
    height: 9_000
  )

  let selection = try #require(
    DocumentCameraSelectionPolicy().select(from: [lower, tiedLater, telephoto, tiedFirst])
  )

  #expect(selection.candidate.identifier == "a-tied")
}

private func candidate(
  _ identifier: String,
  lens: DocumentCameraCapability.Lens,
  focusDistance: Int?,
  width: Int,
  height: Int
) -> DocumentCameraCandidate {
  DocumentCameraCandidate(
    identifier: identifier,
    capability: DocumentCameraCapability(
      lens: lens,
      localizedName: identifier,
      minimumFocusDistanceMillimeters: focusDistance,
      maximumPhotoWidth: width,
      maximumPhotoHeight: height,
      videoFieldOfViewDegrees: 80,
      lensAperture: 1.8,
      supportsContinuousAutoFocus: true,
      supportsFocusPointOfInterest: true
    )
  )
}
