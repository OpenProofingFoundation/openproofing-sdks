import Foundation
import DocumentSDK
import ImageIO

/// Maps a host location assertion onto the documented EXIF GPS keys.
///
/// `AVCapturePhotoSettings.metadata` raises an Objective-C exception for any
/// key outside `CGImageProperties`, so this builder emits only documented GPS
/// keys and refuses a malformed assertion outright rather than writing a
/// partial or clamped fix.
enum CaptureLocationGPSMetadata {
  /// The GPS sub-dictionary for one assertion, or nil when the assertion is
  /// malformed and must not be written.
  static func gpsDictionary(for assertion: CaptureLocationAssertion) -> [String: Any]? {
    guard assertion.wellFormed else { return nil }

    var gps: [String: Any] = [
      kCGImagePropertyGPSLatitude as String: abs(assertion.latitudeDegrees),
      kCGImagePropertyGPSLatitudeRef as String: assertion.latitudeDegrees < 0 ? "S" : "N",
      kCGImagePropertyGPSLongitude as String: abs(assertion.longitudeDegrees),
      kCGImagePropertyGPSLongitudeRef as String: assertion.longitudeDegrees < 0 ? "W" : "E",
      kCGImagePropertyGPSDateStamp as String: utcStamp("yyyy:MM:dd", for: assertion.fixedAt),
      kCGImagePropertyGPSTimeStamp as String: utcStamp("HH:mm:ss", for: assertion.fixedAt)
    ]
    if let accuracy = assertion.horizontalAccuracyMeters {
      gps[kCGImagePropertyGPSHPositioningError as String] = accuracy
    }
    if let altitude = assertion.altitudeMeters {
      // EXIF stores altitude as a magnitude plus a reference: 0 above sea
      // level, 1 below.
      gps[kCGImagePropertyGPSAltitude as String] = abs(altitude)
      gps[kCGImagePropertyGPSAltitudeRef as String] = altitude < 0 ? 1 : 0
    }
    return gps
  }

  /// Tolerance in degrees for comparing a read-back coordinate with the one
  /// asserted.
  ///
  /// EXIF stores coordinates as rationals, so a written value does not survive
  /// as the exact `Double` supplied. 1e-6 degrees is under 0.2 m of latitude.
  static let coordinateTolerance = DocumentCaptureDefaults.coordinateTolerance

  /// Whether encoded-image properties read back from retained bytes carry this
  /// assertion's own coordinate.
  ///
  /// Presence of a GPS dictionary is not sufficient. A partial block, or one
  /// written by something other than this assertion, must not read as
  /// confirmation that the host's location reached the bytes, so the
  /// coordinate and both hemisphere references are compared.
  static func encodedPropertiesCarry(
    _ assertion: CaptureLocationAssertion,
    properties: [CFString: Any]
  ) -> Bool {
    guard
      let gps = gpsSubdictionary(in: properties),
      let latitude = number(in: gps, for: kCGImagePropertyGPSLatitude),
      let longitude = number(in: gps, for: kCGImagePropertyGPSLongitude),
      let latitudeRef = string(in: gps, for: kCGImagePropertyGPSLatitudeRef),
      let longitudeRef = string(in: gps, for: kCGImagePropertyGPSLongitudeRef),
      latitudeRef == (assertion.latitudeDegrees < 0 ? "S" : "N"),
      longitudeRef == (assertion.longitudeDegrees < 0 ? "W" : "E")
    else { return false }
    return abs(latitude - abs(assertion.latitudeDegrees)) <= coordinateTolerance
      && abs(longitude - abs(assertion.longitudeDegrees)) <= coordinateTolerance
  }

  /// The GPS sub-dictionary keyed by `String`, accepting either key type
  /// because a read-back dictionary's nesting is bridged, not guaranteed.
  private static func gpsSubdictionary(in properties: [CFString: Any]) -> [String: Any]? {
    guard let gps = properties[kCGImagePropertyGPSDictionary] else { return nil }
    if let typed = gps as? [CFString: Any] {
      var bridged: [String: Any] = [:]
      for (key, value) in typed {
        bridged[key as String] = value
      }
      return bridged.isEmpty ? nil : bridged
    }
    if let untyped = gps as? [String: Any] {
      return untyped.isEmpty ? nil : untyped
    }
    return nil
  }

  private static func number(in gps: [String: Any], for key: CFString) -> Double? {
    (gps[key as String] as? NSNumber)?.doubleValue
  }

  private static func string(in gps: [String: Any], for key: CFString) -> String? {
    gps[key as String] as? String
  }

  private static func utcStamp(_ format: String, for date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    if format == "yyyy:MM:dd" {
      return String(format: "%04d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
  }
}
