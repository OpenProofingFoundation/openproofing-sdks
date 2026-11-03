import Foundation

public enum SensorMeasurementOrigin: String, Sendable {
  case nativeSensor, platformFused, derived
}

public enum SensorMeasurementQuantity: String, Sendable {
  case acceleration, angularVelocity, magneticField, pressure, angle, dimensionless
}

public enum SensorMeasurementUnit: String, Sendable {
  case standardGravity, metersPerSecondSquared, radiansPerSecond, microtesla
  case kilopascals, radians, dimensionless
}

public enum SensorGravityInclusion: String, Sendable {
  case included, excluded, gravityOnly, notApplicable
}

public enum SensorMeasurementShape: String, Sendable { case scalar, vector3 }

public enum SensorClockKind: String, Sendable { case monotonic, wallClock, providerDefined }

public struct SensorClockDomain: Equatable, Sendable {
  public let identifier: String
  public let session: SensorSourceSessionID
  public let kind: SensorClockKind

  public init(identifier: String, session: SensorSourceSessionID, kind: SensorClockKind) throws {
    try SensorContractChecks.identifier(identifier, "clock.identifier")
    try SensorContractChecks.identifier(session.rawValue, "clock.session")
    self.identifier = identifier
    self.session = session
    self.kind = kind
  }
}

public struct SensorMeasurementTime: Equatable, Sendable {
  public let clock: SensorClockDomain
  public let seconds: Double

  public init(clock: SensorClockDomain, seconds: Double) throws {
    try SensorContractChecks.require(seconds.isFinite, "time")
    self.clock = clock
    self.seconds = seconds
  }
}

/// One measured clock pair. Uncertainty is supplied by the measuring adapter, never inferred here.
public struct SensorClockCorrelation: Equatable, Sendable {
  public let source: SensorMeasurementTime
  public let target: SensorMeasurementTime
  public let uncertaintySeconds: Double

  public init(
    source: SensorMeasurementTime, target: SensorMeasurementTime, uncertaintySeconds: Double
  ) throws {
    try SensorContractChecks.require(source.clock != target.clock, "correlation.domains")
    try SensorContractChecks.require(
      uncertaintySeconds.isFinite && uncertaintySeconds >= 0, "correlation.uncertainty")
    self.source = source
    self.target = target
    self.uncertaintySeconds = uncertaintySeconds
  }
}

public enum SensorFrameLineage: Equatable, Sendable {
  case reported
  case notExposed
  case transformed(sourceFrameID: String, binding: SensorDerivationBinding)
}

public struct SensorMeasurementDescriptor: Equatable, Sendable {
  public let streamID: String
  public let sourceID: String
  public let origin: SensorMeasurementOrigin
  public let quantity: SensorMeasurementQuantity
  public let unit: SensorMeasurementUnit
  public let gravity: SensorGravityInclusion
  public let shape: SensorMeasurementShape
  /// Names a versioned axes/orientation convention; it is not a device display orientation.
  public let frameID: String
  public let frameLineage: SensorFrameLineage
  public let calibration: SensorArtifactReference?
  /// Nil means unknown. Floating-point precision is not instrument resolution.
  public let resolution: Double?

  var artifactReferences: [SensorArtifactReference] {
    let calibrationReferences = calibration.map { [$0] } ?? []
    if case .transformed(_, let binding) = frameLineage {
      return calibrationReferences + binding.artifactReferences
    }
    return calibrationReferences
  }

  public init(
    streamID: String, sourceID: String, origin: SensorMeasurementOrigin,
    quantity: SensorMeasurementQuantity, unit: SensorMeasurementUnit,
    gravity: SensorGravityInclusion, frameID: String, shape: SensorMeasurementShape = .scalar,
    frameLineage: SensorFrameLineage = .reported,
    calibration: SensorArtifactReference? = nil, resolution: Double? = nil
  ) throws {
    for (name, value) in [("streamID", streamID), ("sourceID", sourceID), ("frameID", frameID)] {
      try SensorContractChecks.identifier(value, name)
    }
    let compatible: Bool
    switch quantity {
    case .acceleration: compatible = unit == .standardGravity || unit == .metersPerSecondSquared
    case .angularVelocity: compatible = unit == .radiansPerSecond
    case .magneticField: compatible = unit == .microtesla
    case .pressure: compatible = unit == .kilopascals
    case .angle: compatible = unit == .radians
    case .dimensionless: compatible = unit == .dimensionless
    }
    try SensorContractChecks.require(compatible, "quantity.unit")
    try SensorContractChecks.require(
      (quantity == .acceleration) == (gravity != .notApplicable), "gravity")
    if let resolution {
      try SensorContractChecks.require(resolution.isFinite && resolution > 0, "resolution")
    }
    if case .transformed(let sourceFrameID, _) = frameLineage {
      try SensorContractChecks.identifier(sourceFrameID, "sourceFrameID")
      try SensorContractChecks.require(
        sourceFrameID != frameID && origin == .derived, "frameTransform")
    }
    self.streamID = streamID
    self.sourceID = sourceID
    self.origin = origin
    self.quantity = quantity
    self.unit = unit
    self.gravity = gravity
    self.shape = shape
    self.frameID = frameID
    self.frameLineage = frameLineage
    self.calibration = calibration
    self.resolution = resolution
    var commitments = SensorArtifactCommitments()
    try commitments.include(artifactReferences)
  }
}

public enum SensorMeasurementValue: Equatable, Sendable {
  case scalar(Double)
  case vector(SensorVector3)

  var isFinite: Bool {
    switch self {
    case .scalar(let value): value.isFinite
    case .vector(let value): value.isFinite
    }
  }
}

public struct SensorMeasurement: Equatable, Sendable {
  public let sampleID: String
  public let sequence: UInt64
  public let descriptor: SensorMeasurementDescriptor
  public let time: SensorMeasurementTime
  public let receivedAt: SensorMeasurementTime?
  public let value: SensorMeasurementValue
  public let derivation: SensorDerivationBinding?

  public init(
    sampleID: String, sequence: UInt64, descriptor: SensorMeasurementDescriptor,
    time: SensorMeasurementTime, receivedAt: SensorMeasurementTime? = nil,
    value: SensorMeasurementValue, derivation: SensorDerivationBinding? = nil
  ) throws {
    try SensorContractChecks.identifier(sampleID, "sampleID")
    try SensorContractChecks.require(value.isFinite, "measurement.value")
    switch (descriptor.shape, value) {
    case (.scalar, .scalar), (.vector3, .vector): break
    default: throw SensorEvidenceContractError.invalid("measurement.shape")
    }
    try SensorContractChecks.require(
      (descriptor.origin == .derived) == (derivation != nil), "measurement.derivation")
    var commitments = SensorArtifactCommitments()
    try commitments.include(descriptor.artifactReferences)
    try commitments.include(derivation?.artifactReferences ?? [])
    self.sampleID = sampleID
    self.sequence = sequence
    self.descriptor = descriptor
    self.time = time
    self.receivedAt = receivedAt
    self.value = value
    self.derivation = derivation
  }
}
