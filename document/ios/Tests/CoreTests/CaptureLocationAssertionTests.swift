import Foundation
import DocumentSDK
import Testing

private let fixedAt = Date(timeIntervalSince1970: 1_788_968_831)

private func assertion(
  latitude: Double = 47.6062,
  longitude: Double = -122.3321,
  accuracy: Double? = nil,
  altitude: Double? = nil,
  verticalAccuracy: Double? = nil
) -> CaptureLocationAssertion {
  CaptureLocationAssertion(
    latitudeDegrees: latitude,
    longitudeDegrees: longitude,
    horizontalAccuracyMeters: accuracy,
    altitudeMeters: altitude,
    verticalAccuracyMeters: verticalAccuracy,
    fixedAt: fixedAt,
    source: .hostDeviceLocationService)
}

@Test func acceptsCoordinatesAtTheirRangeBoundaries() {
  #expect(assertion(latitude: 90, longitude: 180).wellFormed)
  #expect(assertion(latitude: -90, longitude: -180).wellFormed)
  #expect(assertion(latitude: 0, longitude: 0).wellFormed)
}

@Test func rejectsCoordinatesOutsideTheirRange() {
  #expect(assertion(latitude: 90.1).wellFormed == false)
  #expect(assertion(latitude: -90.1).wellFormed == false)
  #expect(assertion(longitude: 180.1).wellFormed == false)
  #expect(assertion(longitude: -180.1).wellFormed == false)
}

@Test func rejectsNonFiniteComponents() {
  #expect(assertion(latitude: .nan).wellFormed == false)
  #expect(assertion(longitude: .infinity).wellFormed == false)
  #expect(assertion(accuracy: .nan).wellFormed == false)
  #expect(assertion(altitude: .infinity).wellFormed == false)
  #expect(assertion(verticalAccuracy: .nan).wellFormed == false)
}

@Test func rejectsANegativeAccuracyRadius() {
  #expect(assertion(accuracy: -0.5).wellFormed == false)
  #expect(assertion(accuracy: 0).wellFormed)
}

@Test func rejectsANegativeVerticalAccuracyRadius() {
  // Both radii are checked identically: a negative one reports that the value
  // it qualifies is invalid.
  #expect(assertion(verticalAccuracy: -0.5).wellFormed == false)
  #expect(assertion(verticalAccuracy: 0).wellFormed)
}

@Test func rejectsThePlatformInvalidAltitudePair() {
  // Platform location services report an invalid altitude as a negative
  // vertical accuracy while leaving the altitude itself at zero. Accepting
  // that pair would embed an assertion of exactly sea level.
  let invalidAltitude = assertion(altitude: 0, verticalAccuracy: -1)

  #expect(invalidAltitude.wellFormed == false)
}

@Test func acceptsAnAbsentAccuracyRatherThanRequiringZero() {
  // Absent must remain distinguishable from a claimed perfect fix.
  let value = assertion()

  #expect(value.horizontalAccuracyMeters == nil)
  #expect(value.wellFormed)
}

@Test func negativeAltitudeIsWellFormed() {
  #expect(assertion(altitude: -420).wellFormed)
}

@Test func roundTripsThroughJSONWithItsSourceAndFixTime() throws {
  let original = assertion(accuracy: 8.5, altitude: 30, verticalAccuracy: 3)

  let encoded = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(CaptureLocationAssertion.self, from: encoded)

  #expect(decoded == original)
  #expect(decoded.source == .hostDeviceLocationService)
  #expect(decoded.fixedAt == fixedAt)
}

@Test func locationRecordRoundTripsEachDisposition() throws {
  for disposition: CaptureLocationRecord.Disposition in [
    .embeddedInEncodedBytes, .refusedMalformedAssertion, .requestedButAbsentFromEncodedBytes
  ] {
    let record = CaptureLocationRecord(assertion: assertion(), disposition: disposition)

    let encoded = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(CaptureLocationRecord.self, from: encoded)

    #expect(decoded == record)
    #expect(decoded.disposition == disposition)
  }
}

@Test func refusedNonfiniteAssertionsSurviveDefaultJSONPersistence() throws {
  for invalid in [Double.nan, .infinity, -.infinity] {
    let input = assertion(
      latitude: invalid, longitude: invalid, accuracy: invalid,
      altitude: invalid, verticalAccuracy: invalid)
    #expect(!input.wellFormed)
    let record = CaptureLocationRecord(assertion: input, disposition: .refusedMalformedAssertion)
    let bytes = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(CaptureLocationRecord.self, from: bytes)
    #expect(decoded.disposition == .refusedMalformedAssertion)
    #expect(!decoded.assertion.wellFormed)
    for value in [
      decoded.assertion.latitudeDegrees, decoded.assertion.longitudeDegrees,
      decoded.assertion.horizontalAccuracyMeters, decoded.assertion.altitudeMeters,
      decoded.assertion.verticalAccuracyMeters
    ] {
      let retained = try #require(value)
      #expect(invalid.isNaN ? retained.isNaN : retained == invalid)
    }
  }
}

@Test func invalidFixDatesAreRefusedAndRemainPersistable() throws {
  for invalid in [Double.nan, .infinity, -.infinity] {
    let input = CaptureLocationAssertion(
      latitudeDegrees: 0, longitudeDegrees: 0,
      fixedAt: Date(timeIntervalSinceReferenceDate: invalid), source: .hostManualEntry)
    #expect(!input.wellFormed)
    let record = CaptureLocationRecord(assertion: input, disposition: .refusedMalformedAssertion)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(CaptureLocationRecord.self, from: encoder.encode(record))
    #expect(!decoded.assertion.wellFormed)
    let retained = decoded.assertion.fixedAt.timeIntervalSinceReferenceDate
    #expect(invalid.isNaN ? retained.isNaN : retained == invalid)
  }
}

@Test func finiteLocationKeepsLegacyJSONShapeAndDateStrategies() throws {
  let input = assertion(accuracy: 8, altitude: 20, verticalAccuracy: 2)
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let bytes = try encoder.encode(input)
  let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
  #expect(json["latitudeDegrees"] as? Double == input.latitudeDegrees)
  #expect(json["fixedAt"] is String)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  #expect(try decoder.decode(CaptureLocationAssertion.self, from: bytes) == input)
}
