import Foundation
import DocumentSDK
import ImageIO
import Testing

@testable import DocumentCaptureApple

/// 2026-09-09 15:47:11 UTC, the instant of the reviewed SHF capture, which
/// recorded 08:47:11 at offset -07:00.
private let fixedAt = Date(timeIntervalSince1970: 1_788_968_831)

private func assertion(
  latitude: Double,
  longitude: Double,
  accuracy: Double? = nil,
  altitude: Double? = nil
) -> CaptureLocationAssertion {
  CaptureLocationAssertion(
    latitudeDegrees: latitude,
    longitudeDegrees: longitude,
    horizontalAccuracyMeters: accuracy,
    altitudeMeters: altitude,
    fixedAt: fixedAt,
    source: .hostDeviceLocationService)
}

private func value(_ gps: [String: Any], _ key: CFString) -> Any? {
  gps[key as String]
}

@Test func mapsNorthEastCoordinatesToMagnitudeAndReference() throws {
  let gps = try #require(
    CaptureLocationGPSMetadata.gpsDictionary(
      for: assertion(latitude: 47.6062, longitude: 122.3321)))

  #expect(value(gps, kCGImagePropertyGPSLatitude) as? Double == 47.6062)
  #expect(value(gps, kCGImagePropertyGPSLatitudeRef) as? String == "N")
  #expect(value(gps, kCGImagePropertyGPSLongitude) as? Double == 122.3321)
  #expect(value(gps, kCGImagePropertyGPSLongitudeRef) as? String == "E")
}

@Test func mapsSouthWestCoordinatesToPositiveMagnitudes() throws {
  // EXIF stores a magnitude plus a hemisphere reference, never a signed value.
  let gps = try #require(
    CaptureLocationGPSMetadata.gpsDictionary(
      for: assertion(latitude: -33.8688, longitude: -151.2093)))

  #expect(value(gps, kCGImagePropertyGPSLatitude) as? Double == 33.8688)
  #expect(value(gps, kCGImagePropertyGPSLatitudeRef) as? String == "S")
  #expect(value(gps, kCGImagePropertyGPSLongitude) as? Double == 151.2093)
  #expect(value(gps, kCGImagePropertyGPSLongitudeRef) as? String == "W")
}

@Test func recordsHorizontalAccuracyWhenSupplied() throws {
  let gps = try #require(
    CaptureLocationGPSMetadata.gpsDictionary(
      for: assertion(latitude: 47.6, longitude: 122.3, accuracy: 12.5)))

  #expect(value(gps, kCGImagePropertyGPSHPositioningError) as? Double == 12.5)
}

@Test func omitsAccuracyRatherThanWritingZeroWhenAbsent() throws {
  let gps = try #require(
    CaptureLocationGPSMetadata.gpsDictionary(for: assertion(latitude: 47.6, longitude: 122.3)))

  #expect(value(gps, kCGImagePropertyGPSHPositioningError) == nil)
  #expect(value(gps, kCGImagePropertyGPSAltitude) == nil)
  #expect(value(gps, kCGImagePropertyGPSAltitudeRef) == nil)
}

@Test func mapsAltitudeBelowSeaLevelToReferenceOne() throws {
  let below = try #require(
    CaptureLocationGPSMetadata.gpsDictionary(
      for: assertion(latitude: 31.5, longitude: 35.5, altitude: -420.0)))
  let above = try #require(
    CaptureLocationGPSMetadata.gpsDictionary(
      for: assertion(latitude: 31.5, longitude: 35.5, altitude: 120.0)))

  #expect(value(below, kCGImagePropertyGPSAltitude) as? Double == 420.0)
  #expect(value(below, kCGImagePropertyGPSAltitudeRef) as? Int == 1)
  #expect(value(above, kCGImagePropertyGPSAltitude) as? Double == 120.0)
  #expect(value(above, kCGImagePropertyGPSAltitudeRef) as? Int == 0)
}

@Test func writesUTCDateAndTimeStampsIndependentOfDeviceSettings() throws {
  let gps = try #require(
    CaptureLocationGPSMetadata.gpsDictionary(for: assertion(latitude: 0, longitude: 0)))

  #expect(value(gps, kCGImagePropertyGPSDateStamp) as? String == "2026:09:09")
  #expect(value(gps, kCGImagePropertyGPSTimeStamp) as? String == "15:47:11")
}

@Test func refusesCoordinatesOutsideTheirRange() {
  #expect(
    CaptureLocationGPSMetadata.gpsDictionary(for: assertion(latitude: 91, longitude: 0)) == nil)
  #expect(
    CaptureLocationGPSMetadata.gpsDictionary(for: assertion(latitude: 0, longitude: 181)) == nil)
}

@Test func refusesNonFiniteComponentsRatherThanClampingThem() {
  #expect(
    CaptureLocationGPSMetadata.gpsDictionary(
      for: assertion(latitude: .nan, longitude: 0)) == nil)
  #expect(
    CaptureLocationGPSMetadata.gpsDictionary(
      for: assertion(latitude: 0, longitude: .infinity)) == nil)
  #expect(
    CaptureLocationGPSMetadata.gpsDictionary(
      for: assertion(latitude: 0, longitude: 0, accuracy: .nan)) == nil)
  #expect(
    CaptureLocationGPSMetadata.gpsDictionary(
      for: assertion(latitude: 0, longitude: 0, altitude: .nan)) == nil)
}

@Test func refusesNegativeAccuracyRadius() {
  #expect(
    CaptureLocationGPSMetadata.gpsDictionary(
      for: assertion(latitude: 0, longitude: 0, accuracy: -1)) == nil)
}

@Test func emitsOnlyDocumentedGPSKeys() throws {
  // AVCapturePhotoSettings.metadata raises an exception for any key outside
  // CGImageProperties, so the emitted set is pinned.
  let gps = try #require(
    CaptureLocationGPSMetadata.gpsDictionary(
      for: assertion(latitude: 47.6, longitude: 122.3, accuracy: 5, altitude: 30)))
  let permitted = Set(
    [
      kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef,
      kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef,
      kCGImagePropertyGPSAltitude, kCGImagePropertyGPSAltitudeRef,
      kCGImagePropertyGPSHPositioningError, kCGImagePropertyGPSDateStamp,
      kCGImagePropertyGPSTimeStamp
    ].map { $0 as String })

  #expect(Set(gps.keys).isSubset(of: permitted))
  #expect(gps.count == 9)
}

private func encodedProperties(
  latitude: Double,
  latitudeRef: String,
  longitude: Double,
  longitudeRef: String
) -> [CFString: Any] {
  [
    kCGImagePropertyGPSDictionary: [
      kCGImagePropertyGPSLatitude: latitude,
      kCGImagePropertyGPSLatitudeRef: latitudeRef,
      kCGImagePropertyGPSLongitude: longitude,
      kCGImagePropertyGPSLongitudeRef: longitudeRef
    ] as [CFString: Any]
  ]
}

@Test func confirmsAReadBackCoordinateMatchingTheAssertion() {
  let seattle = assertion(latitude: 47.6062, longitude: -122.3321)
  let properties = encodedProperties(
    latitude: 47.6062, latitudeRef: "N", longitude: 122.3321, longitudeRef: "W")

  #expect(CaptureLocationGPSMetadata.encodedPropertiesCarry(seattle, properties: properties))
}

@Test func confirmsAReadBackCoordinateWithinRationalRoundingTolerance() {
  // EXIF stores rationals, so a written value does not survive as the exact
  // Double supplied.
  let seattle = assertion(latitude: 47.6062, longitude: -122.3321)
  let properties = encodedProperties(
    latitude: 47.606_200_4, latitudeRef: "N", longitude: 122.332_099_6, longitudeRef: "W")

  #expect(CaptureLocationGPSMetadata.encodedPropertiesCarry(seattle, properties: properties))
}

@Test func refusesAReadBackCoordinateThatIsNotTheAssertion() {
  let seattle = assertion(latitude: 47.6062, longitude: -122.3321)
  let elsewhere = encodedProperties(
    latitude: 33.8688, latitudeRef: "S", longitude: 151.2093, longitudeRef: "E")

  #expect(
    CaptureLocationGPSMetadata.encodedPropertiesCarry(seattle, properties: elsewhere) == false)
}

@Test func refusesAReadBackCoordinateInTheWrongHemisphere() {
  // Magnitudes match; only the reference differs. A hemisphere flip is a
  // different place, not a rounding difference.
  let seattle = assertion(latitude: 47.6062, longitude: -122.3321)
  let flipped = encodedProperties(
    latitude: 47.6062, latitudeRef: "S", longitude: 122.3321, longitudeRef: "W")

  #expect(
    CaptureLocationGPSMetadata.encodedPropertiesCarry(seattle, properties: flipped) == false)
}

@Test func refusesAPartialGPSBlockAsConfirmation() {
  // A present-but-incomplete dictionary must not read as confirmation that the
  // host's location reached the bytes.
  let seattle = assertion(latitude: 47.6062, longitude: -122.3321)
  let stampOnly: [CFString: Any] = [
    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSDateStamp: "2026:09:09"]
      as [CFString: Any]
  ]

  #expect(
    CaptureLocationGPSMetadata.encodedPropertiesCarry(seattle, properties: stampOnly) == false)
}

@Test func refusesAnAbsentOrEmptyGPSBlock() {
  let seattle = assertion(latitude: 47.6062, longitude: -122.3321)

  #expect(CaptureLocationGPSMetadata.encodedPropertiesCarry(seattle, properties: [:]) == false)
  #expect(
    CaptureLocationGPSMetadata.encodedPropertiesCarry(
      seattle, properties: [kCGImagePropertyGPSDictionary: [CFString: Any]()]) == false)
}
