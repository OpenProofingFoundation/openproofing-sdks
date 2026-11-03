import CoreMedia
import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

private let fixedAt = Date(timeIntervalSince1970: 1_788_968_831)

@Test func retainsTheCompletePropertyDictionaryFromEncodedBytes() throws {
  let encoded = try tinyPNGFixture()

  let metadata = CapturedPhotoPlatformMetadata.make(
    encoded: encoded, captureMetadata: .none)
  let plist = try #require(metadata.encodedPropertiesPlist)
  let decoded = try #require(
    try PropertyListSerialization.propertyList(
      from: plist, options: [], format: nil) as? [String: Any])

  // The curated fidelity record keeps a fixed subset; this one must keep
  // whatever the platform reported, so the raw keys survive.
  #expect(decoded["PixelWidth"] as? Int == 1)
  #expect(decoded["PixelHeight"] as? Int == 1)
}

@Test func reportsNoAuxiliaryImagesForAPlainFixture() throws {
  let metadata = CapturedPhotoPlatformMetadata.make(
    encoded: try tinyPNGFixture(), captureMetadata: .none)

  #expect(metadata.auxiliaryDataTypes.isEmpty)
}

@Test func recordsUnavailablePropertiesRatherThanFailingTheCapture() {
  // Undecodable bytes must not throw here: losing metadata is not a reason to
  // lose an otherwise retained original.
  let metadata = CapturedPhotoPlatformMetadata.make(
    encoded: Data("not an image".utf8), captureMetadata: .none)

  #expect(metadata.encodedPropertiesPlist == nil)
  #expect(metadata.auxiliaryDataTypes.isEmpty)
  #expect(metadata.captureMetadataPlist == nil)
}

@Test func serializesPlatformSuppliedCaptureMetadata() throws {
  let serialized = CapturedPhotoPlatformMetadata.serialize(["Orientation": 6, "Depth": 8])
  let plist = try #require(serialized.data)
  let decoded = try #require(
    try PropertyListSerialization.propertyList(
      from: plist, options: [], format: nil) as? [String: Any])

  #expect(decoded["Orientation"] as? Int == 6)
  #expect(decoded["Depth"] as? Int == 8)
  #expect(serialized.droppedKeys.isEmpty)
}

@Test func reportsNoDataForEmptyPlatformMetadata() {
  #expect(CapturedPhotoPlatformMetadata.serialize([:]) == .none)
}

@Test func keepsRepresentableEntriesAndNamesTheDroppedOnes() throws {
  // One unrepresentable value must not discard the rest: the maker note is
  // exactly what this record exists to keep.
  let serialized = CapturedPhotoPlatformMetadata.serialize([
    "MakerApple": ["8": [1.0, 2.0, 3.0]],
    "Orientation": 6,
    "bad": NSObject()
  ])
  let plist = try #require(serialized.data)
  let decoded = try #require(
    try PropertyListSerialization.propertyList(
      from: plist, options: [], format: nil) as? [String: Any])

  #expect(serialized.droppedKeys == ["bad"])
  #expect(decoded["Orientation"] as? Int == 6)
  #expect(decoded["MakerApple"] != nil)
  #expect(decoded["bad"] == nil)
}

@Test func reportsNoDataWhenEveryEntryIsUnrepresentable() {
  let serialized = CapturedPhotoPlatformMetadata.serialize(["bad": NSObject()])

  #expect(serialized.data == nil)
  #expect(serialized.droppedKeys == ["bad"])
}

@Test func recordsDroppedKeysOnTheRetainedMetadata() {
  let metadata = CapturedPhotoPlatformMetadata.make(
    properties: nil,
    auxiliaryDataTypes: [],
    captureMetadata: CapturedPhotoPlatformMetadata.serialize(["bad": NSObject()]))

  // A named key distinguishes a value that could not be kept from one the
  // platform never reported.
  #expect(metadata.unrepresentableKeys == ["bad"])
  #expect(metadata.captureMetadataPlist == nil)
}

@Test func carriesCapturePhotoMetadataThroughAssembly() throws {
  let captureMetadata = CapturedPhotoPlatformMetadata.serialize(["Orientation": 6])

  let photo = try CapturedDocumentPhotoAssembler(now: { Date() }).assemble(
    data: try tinyPNGFixture(),
    sessionID: CaptureSessionID(),
    side: .front,
    captureTimestamp: fixtureCaptureTimestamp(),
    captureMetadata: captureMetadata)

  #expect(photo.platformMetadata?.captureMetadataPlist == captureMetadata.data)
  #expect(photo.platformMetadata?.encodedPropertiesPlist != nil)
  #expect(photo.platformMetadata?.unrepresentableKeys.isEmpty == true)
}

@Test func derivesTheGainMapFactFromTheSharedAuxiliaryProbe() throws {
  // The curated subset must not run a second probe: each probe materializes
  // the auxiliary image it finds.
  let photo = try CapturedDocumentPhotoAssembler(now: { Date() }).assemble(
    data: try tinyPNGFixture(),
    sessionID: CaptureSessionID(),
    side: .front,
    captureTimestamp: fixtureCaptureTimestamp())

  #expect(photo.platformMetadata?.auxiliaryDataTypes.isEmpty == true)
  #expect(photo.fidelity.optical?.hdrGainMapPresent == false)
}

@Test func assemblyRecordsNoLocationWhenNoneIsSupplied() throws {
  let photo = try CapturedDocumentPhotoAssembler(now: { Date() }).assemble(
    data: try tinyPNGFixture(),
    sessionID: CaptureSessionID(),
    side: .front,
    captureTimestamp: fixtureCaptureTimestamp())

  #expect(photo.location == nil)
}

@Test func assemblyRefusesAMalformedLocationAssertion() throws {
  let malformed = CaptureLocationAssertion(
    latitudeDegrees: 200, longitudeDegrees: 0, fixedAt: fixedAt,
    source: .hostDeviceLocationService)

  let photo = try CapturedDocumentPhotoAssembler(now: { Date() }).assemble(
    data: try tinyPNGFixture(),
    sessionID: CaptureSessionID(),
    side: .front,
    captureTimestamp: fixtureCaptureTimestamp(),
    locationAssertion: malformed)

  #expect(photo.location?.disposition == .refusedMalformedAssertion)
  #expect(photo.location?.assertion == malformed)
}

@Test func assemblyReportsARequestedLocationMissingFromTheEncodedBytes() throws {
  // The fixture carries no GPS, so a well-formed assertion must be reported as
  // absent from the bytes rather than assumed embedded because it was asked
  // for.
  let requested = CaptureLocationAssertion(
    latitudeDegrees: 47.6062, longitudeDegrees: -122.3321,
    horizontalAccuracyMeters: 8, fixedAt: fixedAt,
    source: .hostDeviceLocationService)

  let photo = try CapturedDocumentPhotoAssembler(now: { Date() }).assemble(
    data: try tinyPNGFixture(),
    sessionID: CaptureSessionID(),
    side: .front,
    captureTimestamp: fixtureCaptureTimestamp(),
    locationAssertion: requested)

  #expect(photo.location?.disposition == .requestedButAbsentFromEncodedBytes)
}

@Test func refusedNonfiniteLocationDoesNotPreventCaptureManifestPersistence() throws {
  let original = try tinyPNGFixture()
  let invalid = CaptureLocationAssertion(
    latitudeDegrees: .nan, longitudeDegrees: 0, fixedAt: fixedAt,
    source: .hostManualEntry)
  let photo = try CapturedDocumentPhotoAssembler(now: { Date() }).assemble(
    data: original, sessionID: CaptureSessionID(), side: .front,
    captureTimestamp: fixtureCaptureTimestamp(), locationAssertion: invalid)
  struct Manifest: Codable {
    let fidelity: PhotoFidelityMetadata
    let platformMetadata: CapturedPhotoPlatformMetadata?
    let location: CaptureLocationRecord?
  }
  let manifest = Manifest(fidelity: photo.fidelity,
    platformMetadata: photo.platformMetadata, location: photo.location)
  let retained = try JSONDecoder().decode(Manifest.self, from: JSONEncoder().encode(manifest))
  #expect(photo.data == original)
  #expect(retained.fidelity.sha256 == photo.fidelity.sha256)
  #expect(retained.platformMetadata == photo.platformMetadata)
  #expect(retained.location?.disposition == .refusedMalformedAssertion)
  #expect(retained.location?.assertion.latitudeDegrees.isNaN == true)
}
