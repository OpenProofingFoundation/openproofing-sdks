import CryptoKit
import Foundation
import KenshikiSensors
import XCTest

/// Exercises public mathematical and evidence APIs together. Fixture-byte commitments below are
/// test-owned records, not a production wire codec, custody receipt or sensor-authenticity proof.
final class SensorCoreIntegrationTests: XCTestCase {
  private let epoch = Date(timeIntervalSinceReferenceDate: 120)

  func testRetainedAtomsDriveAggregateAndRejectConflictingRebinding() throws {
    let values = [-0.0, 1e-9, -2e-9, 3e-9].map { SensorVector3(x: $0, y: -0.0, z: 0) }
    let samples = try atoms(values: values, offsets: [0.125, 0.375, 0.625, 0.875])
    let source = try evidence(samples)
    let aggregate = try processed(source)
    let result = try derived(aggregate, source: source)
    let retained = try inline(source)
    let observation = try XCTUnwrap(inline(result).first)
    XCTAssertEqual(aggregate.sourceSessionID, source.bounds.clock.session)
    XCTAssertEqual(aggregate.timing.acquisitionQuality, .observed)
    XCTAssertEqual(aggregate.timing.sampleCount, retained.count)
    XCTAssertEqual(aggregate.wallClockBounds.start, epoch)
    XCTAssertEqual(aggregate.wallClockBounds.end, epoch.addingTimeInterval(1))
    XCTAssertEqual(try scalar(observation), sqrt(3.5) * 1e-9, accuracy: 1e-23)
    XCTAssertEqual(observation.descriptor.unit, .standardGravity)
    XCTAssertEqual(observation.descriptor.gravity, .excluded)
    for (sample, original) in zip(retained, values) {
      let actual = try vector(sample)
      XCTAssertEqual(actual.x.bitPattern, original.x.bitPattern)
      XCTAssertEqual(actual.y.bitPattern, original.y.bitPattern)
      XCTAssertEqual(actual.z.bitPattern, original.z.bitPattern)
    }
    let binding = try XCTUnwrap(observation.derivation)
    XCTAssertEqual(binding.inputs.map(\.reference.recordID), retained.map(\.sampleID))
    XCTAssertEqual(binding.inputs.map(\.extent), retained.map { .point($0.time) })
    XCTAssertEqual(binding.inputs.map(\.reference), try retained.map(reference))

    var changedValues = values
    changedValues[0] = SensorVector3(x: 4e-9, y: -0.0, z: 0)
    let changedSource = try evidence(
      atoms(values: changedValues, offsets: [0.125, 0.375, 0.625, 0.875]))
    let changedResult = try derived(processed(changedSource), source: changedSource)
    let changed = try XCTUnwrap(inline(changedResult).first)
    XCTAssertNotEqual(try scalar(changed), try scalar(observation))
    XCTAssertNotEqual(try reference(samples[0]), try reference(inline(changedSource)[0]))
    let second = try SensorMeasurement(
      sampleID: "recomputed-rms", sequence: 1, descriptor: changed.descriptor,
      time: SensorMeasurementTime(clock: changed.time.clock, seconds: 0.75),
      value: changed.value, derivation: changed.derivation)
    // Both calculations used real reducers. Reusing a source record ID for changed bytes must not
    // combine into one admitted result window, even though both results are finite valid scalars.
    XCTAssertThrowsError(
      try SensorEvidenceWindow(
        windowID: "mixed-results", descriptor: result.descriptor, bounds: result.bounds,
        retention: .inline([observation, second]), availability: .observed)
    ) { error in
      XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("conflictingRecordDigest"))
    }
  }

  func testMissingSequencePropagatesPartialTimingAndOmissionLineage() throws {
    let samples = try atoms(
      values: [0.0, 2e-9, 3e-9].map { SensorVector3(x: $0, y: 0, z: 0) },
      offsets: [0.125, 0.625, 0.875], sequences: [0, 2, 3])
    XCTAssertThrowsError(try evidence(samples)) { error in
      XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("sample.sequenceGap"))
    }
    let gap = try SensorEvidenceOmission(
      reason: .gap,
      interval: SensorEvidenceInterval(clock: clock(), start: 0.25, end: 0.5),
      sampleIDs: ["atom-1"])
    let source = try evidence(samples, omissions: [gap])
    let aggregate = try processed(source)
    XCTAssertEqual(aggregate.timing.acquisitionQuality, .partial)
    XCTAssertEqual(aggregate.timing.temporalCoverageFraction, 0.75, accuracy: 1e-12)
    XCTAssertEqual(aggregate.timing.sampleCount, 3)
    let result = try derived(aggregate, source: source)
    XCTAssertEqual(result.availability, .partial)
    XCTAssertEqual(result.omissions, [gap])
    let observation = try XCTUnwrap(inline(result).first)
    XCTAssertEqual(try scalar(observation), sqrt(13.0 / 3) * 1e-9, accuracy: 1e-23)
    let binding = try XCTUnwrap(observation.derivation)
    XCTAssertEqual(binding.inputs.map(\.role), [.supporting, .supporting, .supporting, .omission])
    XCTAssertEqual(binding.inputs.last?.extent, gap.interval.map(SensorDerivationExtent.interval))
    XCTAssertTrue(binding.limitations.contains(.partialInput))
    XCTAssertEqual(try inline(source).map(\.sequence), [0, 2, 3])
  }

  func testReplaySessionMutationAndBoundaryCannotPolluteAcceptedSamples() throws {
    let samples = try atoms(
      values: [1.0, 2.0].map { SensorVector3(x: $0, y: 0, z: 0) },
      offsets: [0.125, 0.375])
    var window = try processedWindow()
    for sample in samples { XCTAssertNil(try ingest(sample, into: &window)) }
    let replay = try atoms(values: [.init(x: 999, y: 0, z: 0)], offsets: [0.375])[0]
    XCTAssertNil(try ingest(replay, into: &window))
    XCTAssertNil(try ingest(samples[0], into: &window))
    XCTAssertThrowsError(try evidence(samples + [samples[0]])) { error in
      XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("sampleIDs.duplicate"))
    }
    let otherSession = try atoms(
      values: [.init(x: 999, y: 0, z: 0)], offsets: [0.625], sequences: [2],
      domain: clock(session: "other-boot"))[0]
    XCTAssertThrowsError(try evidence(samples + [otherSession])) { error in
      XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("sample.time"))
    }
    let boundary = try atoms(
      values: [.init(x: 100, y: 0, z: 0)], offsets: [1], sequences: [2])[0]
    XCTAssertThrowsError(try evidence(samples + [boundary])) { error in
      XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("sample.time"))
    }
    let completed = try XCTUnwrap(ingest(boundary, into: &window))
    XCTAssertEqual(completed.monotonicBounds, 0..<1)
    XCTAssertEqual(completed.timing.sampleCount, 2)
    XCTAssertEqual(completed.timing.duplicateSampleCount, 1)
    XCTAssertEqual(completed.timing.outOfOrderSampleCount, 1)
    XCTAssertEqual(
      try XCTUnwrap(completed.measurements).userAccelerationMagnitudeG.rootMeanSquare,
      sqrt(2.5), accuracy: 1e-12)
    let next = try XCTUnwrap(window.flush(completion: .sourceStopped))
    XCTAssertEqual(next.monotonicBounds, 1..<2)
    XCTAssertEqual(next.timing.sampleCount, 1)
    XCTAssertEqual(next.measurements?.userAccelerationMagnitudeG.maximum, 100)
    let nextEvidence = try evidence(
      [boundary], bounds: SensorEvidenceInterval(clock: clock(), start: 1, end: 2))
    XCTAssertEqual(try inline(nextEvidence).first?.sequence, 2)
    let omissions = try [
      SensorEvidenceOmission(reason: .duplicateSample), SensorEvidenceOmission(reason: .outOfOrder),
    ]
    XCTAssertEqual(try evidence(samples, omissions: omissions).availability, .partial)
  }

  func testLiveAndHistoricalRawPipelinesReconcileTimingAndKeepGravityUnits() throws {
    let descriptor = try SensorMeasurementDescriptor(
      streamID: "raw-acceleration", sourceID: "fixture.raw.v1", origin: .nativeSensor,
      quantity: .acceleration, unit: .standardGravity, gravity: .included,
      frameID: "device.xyz.v1", shape: .vector3)
    let offsets = [0.01, 0.03, 0.05, 0.07]
    let samples = try atoms(
      values: [0.99, 1.01, 1, 1].map { SensorVector3(x: 0, y: 0, z: $0) },
      offsets: offsets, descriptor: descriptor)
    let bounds = try SensorEvidenceInterval(clock: clock(), start: 0, end: 60)
    let source = try evidence(samples, bounds: bounds, period: 0.02)
    let anchor = SensorClockAnchor(sensorTimestamp: 0, wallClock: epoch)
    var live = TumblingSensorWindow<RecordedAccelerationWindowReducer>(
      sourceSessionID: bounds.clock.session, clockAnchor: anchor,
      specification: .init(duration: 60, nominalPeriod: 0.02))
    var history: [RecordedAccelerationWindowSample] = []
    for sample in try inline(source) {
      let value = try vector(sample)
      let date = anchor.wallClockDate(for: sample.time.seconds)
      XCTAssertNil(
        live.ingest(
          .init(
            sensorTimestamp: sample.time.seconds, receivedAt: date,
            systemUptimeAtReceipt: sample.time.seconds,
            value: .init(acceleration: value, recordingBatchIdentifier: 42))))
      history.append(
        .init(
          sampleDate: date, sensorTimestamp: sample.time.seconds,
          acceleration: value, recordingBatchIdentifier: 42))
    }
    let forward = try XCTUnwrap(live.flush(completion: .sourceStopped))
    let projection = RecordedAccelerationWindowProjection().project(
      samples: Array(history.reversed()) + [history[0]],
      finalizationCutoff: epoch.addingTimeInterval(60))
    let recorded = try XCTUnwrap(projection.windows.first)
    XCTAssertEqual(projection.windows.count, 1)
    XCTAssertEqual(recorded.timing.duplicateSampleCount, 1)
    XCTAssertEqual(recorded.measurements, forward.measurements)
    XCTAssertEqual(recorded.wallClockBounds, forward.wallClockBounds)
    XCTAssertEqual(recorded.timing.sampleCount, forward.timing.sampleCount)
    XCTAssertEqual(recorded.timing.expectedSampleCount, forward.timing.expectedSampleCount)
    XCTAssertEqual(recorded.timing.acquisitionQuality, .partial)
    XCTAssertEqual(recorded.timing.acquisitionQuality, forward.timing.acquisitionQuality)
    XCTAssertEqual(
      recorded.timing.temporalCoverageFraction, forward.timing.temporalCoverageFraction,
      accuracy: 1e-12)
    let raw = try XCTUnwrap(recorded.measurements)
    XCTAssertEqual(raw.rawAccelerationMagnitudeG.rootMeanSquare, sqrt(1.00005), accuracy: 1e-12)
    XCTAssertEqual(source.descriptor.unit, .standardGravity)
    XCTAssertEqual(source.descriptor.gravity, .included)
    let correlation = try SensorClockCorrelation(
      source: SensorMeasurementTime(clock: bounds.clock, seconds: 0),
      target: SensorMeasurementTime(
        clock: clock(kind: .wallClock), seconds: epoch.timeIntervalSinceReferenceDate),
      uncertaintySeconds: 0)
    XCTAssertEqual(
      correlation.target.seconds, recorded.wallClockBounds.start.timeIntervalSinceReferenceDate)
    // Raw gravity-including atoms cannot be admitted as the processed gravity-excluded stream.
    XCTAssertThrowsError(
      try SensorEvidenceWindow(
        windowID: "relabelled", descriptor: processedDescriptor(), bounds: bounds,
        retention: source.retention, availability: .observed)
    ) { error in
      XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("sample.descriptor"))
    }
  }

  private func clock(
    session: String = "boot-1", kind: SensorClockKind = .monotonic
  ) throws -> SensorClockDomain {
    try SensorClockDomain(
      identifier: kind == .wallClock ? "fixture.wall" : "fixture.uptime",
      session: .init(rawValue: session), kind: kind)
  }

  private func processedDescriptor() throws -> SensorMeasurementDescriptor {
    try SensorMeasurementDescriptor(
      streamID: "user-acceleration", sourceID: "fixture.processed.v1", origin: .platformFused,
      quantity: .acceleration, unit: .standardGravity, gravity: .excluded,
      frameID: "device.xyz.v1", shape: .vector3)
  }

  private func atoms(
    values: [SensorVector3], offsets: [Double], sequences: [UInt64]? = nil,
    domain: SensorClockDomain? = nil, descriptor: SensorMeasurementDescriptor? = nil
  ) throws -> [SensorMeasurement] {
    XCTAssertEqual(values.count, offsets.count)
    return try values.indices.map { index in
      let sequence = sequences?[index] ?? UInt64(index)
      return try SensorMeasurement(
        sampleID: "atom-\(sequence)", sequence: sequence,
        descriptor: descriptor ?? processedDescriptor(),
        time: SensorMeasurementTime(clock: domain ?? clock(), seconds: offsets[index]),
        value: .vector(values[index]))
    }
  }

  private func evidence(
    _ samples: [SensorMeasurement], omissions: [SensorEvidenceOmission] = [],
    bounds: SensorEvidenceInterval? = nil, period: Double = 0.25
  ) throws -> SensorEvidenceWindow {
    try SensorEvidenceWindow(
      windowID: "source", descriptor: XCTUnwrap(samples.first).descriptor,
      bounds: bounds ?? SensorEvidenceInterval(clock: clock(), start: 0, end: 1),
      nominalPeriodSeconds: period, retention: .inline(samples),
      availability: omissions.isEmpty ? .observed : .partial, omissions: omissions)
  }

  private func processedWindow() throws -> TumblingSensorWindow<DeviceMotionWindowReducer> {
    TumblingSensorWindow(
      sourceSessionID: try clock().session,
      clockAnchor: SensorClockAnchor(sensorTimestamp: 0, wallClock: epoch),
      specification: .init(duration: 1, nominalPeriod: 0.25))
  }

  private func ingest(
    _ sample: SensorMeasurement, into window: inout TumblingSensorWindow<DeviceMotionWindowReducer>
  ) throws -> CompletedSensorWindow<DeviceMotionAggregateMeasurements>? {
    window.ingest(
      .init(
        sensorTimestamp: sample.time.seconds,
        receivedAt: epoch.addingTimeInterval(sample.time.seconds),
        systemUptimeAtReceipt: sample.time.seconds,
        value: .init(
          userAcceleration: try vector(sample), rotationRate: .init(x: 0, y: 0, z: 0),
          gravity: .init(x: 0, y: 0, z: -1), attitudeReferenceFrame: sample.descriptor.frameID,
          magneticCalibrationAccuracy: "unknown", sensorLocation: "fixture")))
  }

  private func processed(
    _ source: SensorEvidenceWindow
  ) throws -> CompletedSensorWindow<DeviceMotionAggregateMeasurements> {
    var window = try processedWindow()
    for sample in try inline(source) { XCTAssertNil(try ingest(sample, into: &window)) }
    return try XCTUnwrap(window.flush(completion: .closed))
  }

  /// The test caller composes public APIs here; this is not a shipped core-to-custody adapter.
  private func derived(
    _ aggregate: CompletedSensorWindow<DeviceMotionAggregateMeasurements>,
    source: SensorEvidenceWindow
  ) throws -> SensorEvidenceWindow {
    let samples = try inline(source)
    var inputs = try samples.map { sample in
      try SensorDerivationInput(
        reference: reference(sample), selector: "value", role: .supporting,
        extent: .point(sample.time))
    }
    for omission in source.omissions {
      let interval = try XCTUnwrap(omission.interval)
      inputs.append(
        try SensorDerivationInput(
          reference: fixtureReference("gap", bytes: Data("missing atom-1 at 0.375".utf8)),
          selector: "omission", role: .omission, extent: .interval(interval),
          reasonCode: "callback-gap"))
    }
    var limitations: [SensorDerivationLimitation] = [
      .resolutionUnknown, .sourceAuthenticityUnverified,
    ]
    if aggregate.timing.acquisitionQuality == .partial { limitations.append(.partialInput) }
    let binding = try SensorDerivationBinding(
      methodID: "pulse.device-motion.sample-rms", methodVersion: "v1",
      configuration: fixtureReference(
        "configuration", bytes: Data("duration=1;period=0.25;RMS=sample".utf8)),
      inputs: inputs, limitations: limitations)
    let descriptor = try SensorMeasurementDescriptor(
      streamID: "acceleration-rms", sourceID: "fixture.derived.v1", origin: .derived,
      quantity: source.descriptor.quantity, unit: source.descriptor.unit,
      gravity: source.descriptor.gravity, frameID: source.descriptor.frameID)
    let observation = try SensorMeasurement(
      sampleID: "rms", sequence: 0, descriptor: descriptor,
      time: SensorMeasurementTime(clock: source.bounds.clock, seconds: source.bounds.start),
      value: .scalar(XCTUnwrap(aggregate.measurements).userAccelerationMagnitudeG.rootMeanSquare),
      derivation: binding)
    return try SensorEvidenceWindow(
      windowID: "result", descriptor: descriptor, bounds: source.bounds,
      retention: .inline([observation]), availability: source.availability,
      omissions: source.omissions)
  }

  private func inline(_ window: SensorEvidenceWindow) throws -> [SensorMeasurement] {
    guard case .inline(let samples) = window.retention else {
      throw SensorEvidenceContractError.invalid("fixture.expectedInline")
    }
    return samples
  }

  private func vector(_ sample: SensorMeasurement) throws -> SensorVector3 {
    guard case .vector(let value) = sample.value else {
      throw SensorEvidenceContractError.invalid("fixture.expectedVector")
    }
    return value
  }

  private func scalar(_ sample: SensorMeasurement) throws -> Double {
    guard case .scalar(let value) = sample.value else {
      throw SensorEvidenceContractError.invalid("fixture.expectedScalar")
    }
    return value
  }

  /// The reference constructor validates shape; this helper supplies the exact fixture-byte digest.
  private func fixtureReference(_ id: String, bytes: Data) throws -> SensorArtifactReference {
    try SensorArtifactReference(
      recordID: id, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
  }

  /// Exact deterministic fixture bytes include identity, clock/session, profile and IEEE-754 axes.
  /// This local encoding is deliberately not exposed or asserted to be a production persistence API.
  private func reference(_ sample: SensorMeasurement) throws -> SensorArtifactReference {
    var bytes = Data()
    func append(_ value: UInt64) {
      var bigEndian = value.bigEndian
      withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
    }
    for text in [
      sample.sampleID, sample.descriptor.streamID, sample.descriptor.sourceID,
      sample.descriptor.origin.rawValue, sample.descriptor.quantity.rawValue,
      sample.descriptor.unit.rawValue, sample.descriptor.gravity.rawValue,
      sample.descriptor.frameID, sample.time.clock.identifier,
      sample.time.clock.session.rawValue, sample.time.clock.kind.rawValue,
    ] {
      let utf8 = Data(text.utf8)
      append(UInt64(utf8.count))
      bytes.append(utf8)
    }
    append(sample.sequence)
    append(sample.time.seconds.bitPattern)
    let value = try vector(sample)
    for axis in [value.x, value.y, value.z] { append(axis.bitPattern) }
    return try fixtureReference(sample.sampleID, bytes: bytes)
  }
}
