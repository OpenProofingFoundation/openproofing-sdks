import Foundation

/// A location the host supplied for one capture.
///
/// This is an assertion, not a measurement by the capture stack. AVFoundation
/// reports no location with a photo, so any recorded location is a value the
/// host obtained elsewhere and asked this SDK to bind to the capture.
///
/// Binding makes the value tamper-evident *after* capture, because the retained
/// original's digest covers the bytes it is written into. It does not establish
/// that the value was true *at* capture: platform location can be simulated
/// without modifying a device. Downstream may treat a bound location as a
/// signal. It is not a control, and it is not evidence of where a document was
/// presented.
public struct CaptureLocationAssertion: Codable, Equatable, Sendable {
  /// Where the host says it obtained the value. Recorded as supplied; the SDK
  /// cannot verify it.
  public enum Source: String, Codable, Equatable, Sendable {
    case hostDeviceLocationService
    case hostManualEntry
    case hostSimulated
  }

  public let latitudeDegrees: Double
  public let longitudeDegrees: Double
  /// Radius of the host's reported horizontal confidence in metres.
  ///
  /// Absent is recorded rather than a substituted zero, which would read as a
  /// perfect fix.
  public let horizontalAccuracyMeters: Double?
  public let altitudeMeters: Double?
  /// Radius of the host's reported vertical confidence in metres.
  ///
  /// A host whose altitude is invalid must pass nil for both this and
  /// `altitudeMeters`. Platform location services report an invalid altitude
  /// as a negative vertical accuracy while leaving the altitude itself at
  /// zero; that pair is refused rather than written, because writing it would
  /// assert a fix at exactly sea level.
  public let verticalAccuracyMeters: Double?
  /// When the host's own fix was taken. This is not the capture timestamp and
  /// must not be substituted for one.
  public let fixedAt: Date
  public let source: Source

  public init(
    latitudeDegrees: Double,
    longitudeDegrees: Double,
    horizontalAccuracyMeters: Double? = nil,
    altitudeMeters: Double? = nil,
    verticalAccuracyMeters: Double? = nil,
    fixedAt: Date,
    source: Source
  ) {
    self.latitudeDegrees = latitudeDegrees
    self.longitudeDegrees = longitudeDegrees
    self.horizontalAccuracyMeters = horizontalAccuracyMeters
    self.altitudeMeters = altitudeMeters
    self.verticalAccuracyMeters = verticalAccuracyMeters
    self.fixedAt = fixedAt
    self.source = source
  }

  /// Whether every supplied component is finite, inside its coordinate range,
  /// and qualified by a non-negative accuracy radius. A malformed assertion is
  /// refused whole, never clamped into a plausible-looking coordinate.
  public var wellFormed: Bool {
    guard
      fixedAt.timeIntervalSinceReferenceDate.isFinite,
      latitudeDegrees.isFinite, longitudeDegrees.isFinite,
      abs(latitudeDegrees) <= 90, abs(longitudeDegrees) <= 180
    else { return false }
    let supplied = [horizontalAccuracyMeters, altitudeMeters, verticalAccuracyMeters]
    guard supplied.allSatisfy({ $0?.isFinite ?? true }) else { return false }
    // A negative radius is how platform location services report that the
    // value it qualifies is invalid, so both radii are checked identically.
    // Accepting a negative vertical accuracy would embed the zero altitude
    // that accompanies it as a sea-level fix.
    let radii = [horizontalAccuracyMeters, verticalAccuracyMeters]
    return radii.allSatisfy { radius in radius.map { $0 >= 0 } ?? true }
  }
}

/// What the capture path did with a supplied location assertion.
public struct CaptureLocationRecord: Codable, Equatable, Sendable {
  public enum Disposition: String, Codable, Equatable, Sendable {
    /// Present in the retained encoded bytes, confirmed by reading them back,
    /// so the original's digest covers it.
    case embeddedInEncodedBytes
    /// Supplied but refused before capture as malformed. The encoded bytes
    /// carry no location.
    case refusedMalformedAssertion
    /// Requested and not refused, yet absent from the encoded bytes when they
    /// were read back. The platform did not write it.
    case requestedButAbsentFromEncodedBytes
  }

  public let assertion: CaptureLocationAssertion
  public let disposition: Disposition

  public init(assertion: CaptureLocationAssertion, disposition: Disposition) {
    self.assertion = assertion
    self.disposition = disposition
  }
}
