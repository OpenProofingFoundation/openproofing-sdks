import Foundation
import Testing

@testable import DocumentCaptureApple

private func syntheticOpticalState() -> PhotoFidelityMetadata.OpticalState {
  PhotoFidelityMetadata.OpticalState(
    focalLengthMillimeters: 2.22,
    focalLengthIn35mmFilm: 18,
    lensSpecification: [2.22, 6.765, 1.78, 2.2],
    digitalZoomRatio: 1.339238263950399,
    compositeImage: 2,
    hdrGainMapPresent: true)
}

private func syntheticMetadata(
  optical: PhotoFidelityMetadata.OpticalState?
) -> PhotoFidelityMetadata {
  PhotoFidelityMetadata(
    pixelWidth: 4032, pixelHeight: 3024, fileByteCount: 20,
    uniformTypeIdentifier: "public.heic", orientation: 6, cameraModel: "synthetic",
    lensModel: "synthetic dual wide camera 2.22mm f/2.2", exposureTimeSeconds: nil,
    fNumber: 2.2, isoSpeed: 200, sha256: "synthetic", optical: optical)
}

@Test
func readsDimensionsTypeAndDigestFromEncodedImage() throws {
  let encoded = try tinyPNGFixture()

  let metadata = try PhotoFidelityMetadata.make(from: encoded)

  #expect(metadata.pixelWidth == 1)
  #expect(metadata.pixelHeight == 1)
  #expect(metadata.fileByteCount == encoded.count)
  #expect(metadata.uniformTypeIdentifier == "public.png")
  #expect(metadata.sha256.count == 64)
}

@Test
func refusesBytesThatAreNotAnEncodedImage() {
  #expect(throws: PhotoCaptureError.imageMetadataUnavailable) {
    try PhotoFidelityMetadata.make(from: Data("not an image".utf8))
  }
}

@Test
func reportsUnknownOpticalStateRatherThanSubstitutingValues() throws {
  // A fixture with no EXIF is the indeterminate case: every optical value must
  // stay absent rather than defaulting to a number that would later read as a
  // measurement.
  let metadata = try PhotoFidelityMetadata.make(from: tinyPNGFixture())
  let optical = try #require(metadata.optical)

  #expect(optical.focalLengthMillimeters == nil)
  #expect(optical.focalLengthIn35mmFilm == nil)
  #expect(optical.lensSpecification == nil)
  #expect(optical.digitalZoomRatio == nil)
  #expect(optical.compositeImage == nil)
}

@Test
func reportsAbsenceOfAnHDRGainMapWithoutClaimingHeadroom() throws {
  let metadata = try PhotoFidelityMetadata.make(from: tinyPNGFixture())
  let optical = try #require(metadata.optical)

  #expect(optical.hdrGainMapPresent == false)
}

@Test
func opticalStateRoundTripsThroughCodable() throws {
  let metadata = syntheticMetadata(optical: syntheticOpticalState())

  let encoded = try JSONEncoder().encode(metadata)
  let decoded = try JSONDecoder().decode(PhotoFidelityMetadata.self, from: encoded)

  #expect(decoded == metadata)
  #expect(decoded.optical?.compositeImage == 2)
  #expect(decoded.optical?.digitalZoomRatio == 1.339238263950399)
  #expect(decoded.optical?.lensSpecification == [2.22, 6.765, 1.78, 2.2])
  #expect(decoded.optical?.focalLengthIn35mmFilm == 18)
}

@Test
func decodesRetainedRecordsWrittenBeforeOpticalStateExisted() throws {
  let encoded = try JSONEncoder().encode(syntheticMetadata(optical: syntheticOpticalState()))
  var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  json.removeValue(forKey: "optical")
  let legacy = try JSONSerialization.data(withJSONObject: json)

  let decoded = try JSONDecoder().decode(PhotoFidelityMetadata.self, from: legacy)

  #expect(decoded.sha256 == "synthetic")
  #expect(decoded.pixelWidth == 4032)
  #expect(decoded.optical == nil)
}
