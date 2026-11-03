import Foundation

extension CaptureLocationAssertion {
  private enum CodingKeys: String, CodingKey {
    case latitudeDegrees, longitudeDegrees, horizontalAccuracyMeters, altitudeMeters
    case verticalAccuracyMeters, fixedAt, source
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(LocationNumber(latitudeDegrees), forKey: .latitudeDegrees)
    try values.encode(LocationNumber(longitudeDegrees), forKey: .longitudeDegrees)
    try values.encodeIfPresent(
      horizontalAccuracyMeters.map(LocationNumber.init), forKey: .horizontalAccuracyMeters)
    try values.encodeIfPresent(altitudeMeters.map(LocationNumber.init), forKey: .altitudeMeters)
    try values.encodeIfPresent(
      verticalAccuracyMeters.map(LocationNumber.init), forKey: .verticalAccuracyMeters)
    if fixedAt.timeIntervalSinceReferenceDate.isFinite {
      try values.encode(fixedAt, forKey: .fixedAt)
    } else {
      try values.encode(LocationNumber(fixedAt.timeIntervalSinceReferenceDate), forKey: .fixedAt)
    }
    try values.encode(source, forKey: .source)
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    latitudeDegrees = try values.decode(LocationNumber.self, forKey: .latitudeDegrees).value
    longitudeDegrees = try values.decode(LocationNumber.self, forKey: .longitudeDegrees).value
    horizontalAccuracyMeters = try values.decodeIfPresent(
      LocationNumber.self, forKey: .horizontalAccuracyMeters)?.value
    altitudeMeters = try values.decodeIfPresent(LocationNumber.self, forKey: .altitudeMeters)?.value
    verticalAccuracyMeters = try values.decodeIfPresent(
      LocationNumber.self, forKey: .verticalAccuracyMeters)?.value
    if let token = try? values.decode(String.self, forKey: .fixedAt),
      let special = LocationNumber.specialValue(token) {
      fixedAt = Date(timeIntervalSinceReferenceDate: special)
    } else {
      fixedAt = try values.decode(Date.self, forKey: .fixedAt)
    }
    source = try values.decode(Source.self, forKey: .source)
  }
}

/// Finite measurements keep their existing numeric representation. Explicit
/// tokens preserve refused nonfinite inputs without requiring every manifest
/// encoder to change its floating-point strategy or silently replacing a value.
private struct LocationNumber: Codable {
  let value: Double

  init(_ value: Double) { self.value = value }

  func encode(to encoder: any Encoder) throws {
    var valueContainer = encoder.singleValueContainer()
    if value.isFinite {
      try valueContainer.encode(value)
    } else {
      try valueContainer.encode(value.isNaN ? "NaN" : (value > 0 ? "+Infinity" : "-Infinity"))
    }
  }

  init(from decoder: any Decoder) throws {
    let valueContainer = try decoder.singleValueContainer()
    if let number = try? valueContainer.decode(Double.self) {
      value = number
    } else if let special = Self.specialValue(try valueContainer.decode(String.self)) {
      value = special
    } else {
      throw DecodingError.dataCorruptedError(
        in: valueContainer, debugDescription: "invalid_location_number")
    }
  }

  static func specialValue(_ token: String) -> Double? {
    switch token {
    case "NaN": .nan
    case "+Infinity": .infinity
    case "-Infinity": -.infinity
    default: nil
    }
  }
}
