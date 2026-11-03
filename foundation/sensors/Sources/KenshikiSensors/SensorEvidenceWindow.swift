import Foundation

public struct SensorEvidenceInterval: Equatable, Sendable {
  public let clock: SensorClockDomain
  public let start: Double
  public let end: Double

  public init(clock: SensorClockDomain, start: Double, end: Double) throws {
    try SensorContractChecks.require(
      start.isFinite && end.isFinite && end > start && (end - start).isFinite, "interval")
    self.clock = clock
    self.start = start
    self.end = end
  }
}

public enum SensorEvidenceAvailability: String, Sendable {
  case observed, partial, empty, unavailable
}

public enum SensorEvidenceOmissionReason: String, Sendable {
  case gap, invalidSample, duplicateSample, outOfOrder, permissionDenied, unsupported
  case capacity, interrupted, rawNotRetained, noSamples, clockUncorrelated
}

public struct SensorEvidenceOmission: Equatable, Sendable {
  public let reason: SensorEvidenceOmissionReason
  public let interval: SensorEvidenceInterval?
  public let sampleIDs: [String]

  public init(
    reason: SensorEvidenceOmissionReason, interval: SensorEvidenceInterval? = nil,
    sampleIDs: [String] = []
  ) throws {
    try SensorEvidenceWindow.validateIDs(sampleIDs)
    self.reason = reason
    self.interval = interval
    self.sampleIDs = sampleIDs
  }
}

public enum SensorSampleRetention: Equatable, Sendable {
  case inline([SensorMeasurement])
  /// Reference identifies the exact retained raw batch; IDs retain its declared sample order.
  case external(reference: SensorArtifactReference, sampleIDs: [String])
  case aggregateOnly(aggregates: [SensorArtifactReference], sourceSampleIDs: [String])
  case none
}

/// Immutable single-stream evidence. Observed means retained measurements exist without declared
/// omissions; it is not continuous coverage, hardware authenticity or an identity verdict.
public struct SensorEvidenceWindow: Equatable, Sendable {
  public static let contractVersion = "kenshiki.sensor_measurement_window.v1"
  public static let maximumSampleCount = 65_536
  public let windowID: String
  public let descriptor: SensorMeasurementDescriptor
  public let bounds: SensorEvidenceInterval
  public let nominalPeriodSeconds: Double?
  public let retention: SensorSampleRetention
  public let availability: SensorEvidenceAvailability
  public let omissions: [SensorEvidenceOmission]
  public let clockCorrelations: [SensorClockCorrelation]

  public init(
    windowID: String, descriptor: SensorMeasurementDescriptor, bounds: SensorEvidenceInterval,
    nominalPeriodSeconds: Double? = nil, retention: SensorSampleRetention,
    availability: SensorEvidenceAvailability, omissions: [SensorEvidenceOmission] = [],
    clockCorrelations: [SensorClockCorrelation] = []
  ) throws {
    try SensorContractChecks.identifier(windowID, "windowID")
    if let period = nominalPeriodSeconds {
      let expected = ((bounds.end - bounds.start) / period).rounded()
      try SensorContractChecks.require(
        period.isFinite && period > 0 && period <= bounds.end - bounds.start
          && expected.isFinite && expected >= 1 && expected <= 1_000_000, "nominalPeriod")
    }
    try SensorContractChecks.require(omissions.count <= Self.maximumSampleCount, "omissions")
    try SensorContractChecks.require(clockCorrelations.count <= 256, "correlations")
    for correlation in clockCorrelations {
      try SensorContractChecks.require(
        correlation.source.clock == bounds.clock || correlation.target.clock == bounds.clock,
        "unrelatedCorrelation")
    }
    for omission in omissions {
      if let interval = omission.interval {
        try SensorContractChecks.require(
          interval.clock == bounds.clock && interval.start >= bounds.start
            && interval.end <= bounds.end,
          "omission.interval")
      }
    }
    let hasSequenceGapOmission = omissions.contains { $0.reason == .gap }
    let hasUncorrelatedClockOmission = omissions.contains { $0.reason == .clockUncorrelated }
    let sampleCount: Int
    var commitments = SensorArtifactCommitments()
    try commitments.include(descriptor.artifactReferences)
    switch retention {
    case .inline(let samples):
      try Self.validateIDs(samples.map(\.sampleID))
      var previous: SensorMeasurement?
      for sample in samples {
        try commitments.include(sample.derivation?.artifactReferences ?? [])
        try SensorContractChecks.require(sample.descriptor == descriptor, "sample.descriptor")
        try SensorContractChecks.require(
          sample.time.clock == bounds.clock && sample.time.seconds >= bounds.start
            && sample.time.seconds < bounds.end, "sample.time")
        if let previous {
          try SensorContractChecks.require(
            previous.sequence < sample.sequence && previous.time.seconds <= sample.time.seconds,
            "sample.order")
          try SensorContractChecks.require(
            sample.sequence - previous.sequence == 1 || hasSequenceGapOmission,
            "sample.sequenceGap")
          switch (previous.value, sample.value) {
          case (.scalar, .scalar), (.vector, .vector):
            // Consecutive values retain the stream's already validated component shape.
            break
          default: throw SensorEvidenceContractError.invalid("sample.shape")
          }
        }
        if let receipt = sample.receivedAt, receipt.clock != bounds.clock {
          let correlated = clockCorrelations.contains {
            ($0.source.clock == bounds.clock && $0.target.clock == receipt.clock)
              || ($0.target.clock == bounds.clock && $0.source.clock == receipt.clock)
          }
          try SensorContractChecks.require(
            correlated || hasUncorrelatedClockOmission, "receipt.clock")
        } else if let receipt = sample.receivedAt {
          try SensorContractChecks.require(receipt.seconds >= sample.time.seconds, "receipt.order")
        }
        previous = sample
      }
      sampleCount = samples.count
    case .external(let reference, let sampleIDs):
      try commitments.include([reference])
      try Self.validateIDs(sampleIDs)
      sampleCount = sampleIDs.count
    case .aggregateOnly(let aggregates, let sourceSampleIDs):
      try commitments.include(aggregates)
      try Self.validateIDs(sourceSampleIDs)
      try SensorContractChecks.require(
        !aggregates.isEmpty && aggregates.count <= SensorDerivationBinding.maximumInputs
          && Set(aggregates.map(\.recordID)).count == aggregates.count, "aggregates")
      try SensorContractChecks.require(
        omissions.contains { $0.reason == .rawNotRetained }, "rawRetention")
      sampleCount = sourceSampleIDs.count
    case .none: sampleCount = 0
    }
    switch availability {
    case .observed:
      try SensorContractChecks.require(sampleCount > 0 && omissions.isEmpty, "observed")
    case .partial:
      try SensorContractChecks.require(sampleCount > 0 && !omissions.isEmpty, "partial")
    case .empty, .unavailable:
      try SensorContractChecks.require(sampleCount == 0 && !omissions.isEmpty, "absence")
      if case .none = retention {
        // Absence has no retained data; its explicit omission was validated above.
      } else {
        throw SensorEvidenceContractError.invalid("absence.retention")
      }
    }
    self.windowID = windowID
    self.descriptor = descriptor
    self.bounds = bounds
    self.nominalPeriodSeconds = nominalPeriodSeconds
    self.retention = retention
    self.availability = availability
    self.omissions = omissions
    self.clockCorrelations = clockCorrelations
  }

  static func validateIDs(_ sampleIDs: [String]) throws {
    try SensorContractChecks.require(sampleIDs.count <= maximumSampleCount, "sampleIDs.count")
    try SensorContractChecks.require(Set(sampleIDs).count == sampleIDs.count, "sampleIDs.duplicate")
    for identifier in sampleIDs { try SensorContractChecks.identifier(identifier, "sampleID") }
  }
}
