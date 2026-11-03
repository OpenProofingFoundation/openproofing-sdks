import Foundation
import KenshikiSensors
import XCTest

final class SensorEvidenceContractTests: XCTestCase {
  func testSharedConformanceVectors() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "sensor-measurement-window-v1.vectors", withExtension: "json"))
    let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    XCTAssertEqual(vectors.contract, SensorEvidenceWindow.contractVersion)
    XCTAssertEqual(vectors.cases.count, 13)
    XCTAssertEqual(Set(vectors.cases.map(\.id)).count, vectors.cases.count)
    for vector in vectors.cases {
      let accepted: Bool
      do {
        switch vector.kind {
        case "sample":
          let sample = try measurement(
            seconds: XCTUnwrap(vector.time),
            value: .scalar(XCTUnwrap(vector.value)))
          _ = try SensorEvidenceWindow(
            windowID: vector.id, descriptor: sample.descriptor,
            bounds: SensorEvidenceInterval(
              clock: clock(), start: XCTUnwrap(vector.start),
              end: XCTUnwrap(vector.end)),
            retention: .inline([sample]), availability: .observed)
        case "state":
          let state = try XCTUnwrap(
            vector.state.flatMap(SensorEvidenceAvailability.init(rawValue:)))
          let retained: SensorSampleRetention =
            vector.hasSample == true
            ? .inline([try measurement()]) : .none
          _ = try window(
            retention: retained, state: state,
            omissions: vector.hasOmission == true
              ? [SensorEvidenceOmission(reason: .gap)] : [])
        case "correlation":
          _ = try SensorClockCorrelation(
            source: SensorMeasurementTime(clock: clock(), seconds: 0),
            target: SensorMeasurementTime(clock: clock(id: "unix", kind: .wallClock), seconds: 100),
            uncertaintySeconds: XCTUnwrap(vector.uncertainty))
        case "descriptor":
          _ = try SensorMeasurementDescriptor(
            streamID: "accel", sourceID: "capture.v1", origin: .platformFused,
            quantity: XCTUnwrap(vector.quantity.flatMap(SensorMeasurementQuantity.init(rawValue:))),
            unit: XCTUnwrap(vector.unit.flatMap(SensorMeasurementUnit.init(rawValue:))),
            gravity: XCTUnwrap(vector.gravity.flatMap(SensorGravityInclusion.init(rawValue:))),
            frameID: "device.xyz.v1")
        default:
          XCTFail("Unknown vector kind: \(vector.kind)")
          continue
        }
        accepted = true
      } catch is SensorEvidenceContractError {
        accepted = false
      }
      XCTAssertEqual(accepted, vector.accepted, vector.id)
    }
  }

  func testRejectsNonFiniteMeasurementsAndIntervals() throws {
    for value in [Double.nan, .infinity, -.infinity] {
      XCTAssertThrowsError(try measurement(value: .scalar(value)))
      XCTAssertThrowsError(
        try measurement(
          value: .vector(.init(x: 0, y: value, z: 0)),
          descriptor: descriptor(shape: .vector3)))
      XCTAssertThrowsError(try SensorMeasurementTime(clock: clock(), seconds: value))
    }
    XCTAssertThrowsError(try SensorEvidenceInterval(clock: clock(), start: 1, end: 1))
    XCTAssertThrowsError(
      try SensorEvidenceInterval(
        clock: clock(), start: -Double.greatestFiniteMagnitude, end: Double.greatestFiniteMagnitude)
    )
    let zero = try measurement(value: .scalar(0))
    XCTAssertEqual(zero.value, .scalar(0))
  }

  func testWindowRejectsMixedDomainsFramesUnitsAndOrder() throws {
    let first = try measurement()
    let otherClock = try clock(session: "other-boot")
    XCTAssertThrowsError(
      try window(
        retention: .inline([
          measurement(id: "other", sequence: 1, seconds: 0.5, domain: otherClock)
        ])))
    for descriptor in [
      try descriptor(frame: "world.xyz.v1"),
      try descriptor(unit: .metersPerSecondSquared),
      try descriptor(gravity: .included),
    ] {
      XCTAssertThrowsError(
        try window(
          retention: .inline([
            first, measurement(id: "other", sequence: 1, seconds: 0.5, descriptor: descriptor),
          ])))
    }
    XCTAssertThrowsError(
      try window(
        retention: .inline([
          measurement(id: "later", sequence: 1, seconds: 0.5), first,
        ])))
    XCTAssertThrowsError(
      try window(
        retention: .inline([
          first,
          measurement(
            id: "shape", sequence: 1, seconds: 0.5,
            value: .vector(.init(x: 0, y: 0, z: 0))),
        ])))
  }

  func testDuplicateSampleIdentitiesAreRefused() throws {
    XCTAssertThrowsError(
      try window(
        retention: .inline([
          measurement(), measurement(sequence: 1, seconds: 0.5),
        ])))
    XCTAssertThrowsError(
      try window(retention: .external(reference: reference("raw"), sampleIDs: ["a", "a"])))
  }

  func testSequenceGapsRequireExplicitPartialEvidence() throws {
    let samples = try [measurement(), measurement(id: "after-gap", sequence: 2, seconds: 0.5)]
    XCTAssertThrowsError(try window(retention: .inline(samples)))
    _ = try window(
      retention: .inline(samples), state: .partial,
      omissions: [SensorEvidenceOmission(reason: .gap)])
    XCTAssertThrowsError(
      try SensorMeasurementTime(clock: clock(), seconds: .nan))
    let delayedSample = try SensorMeasurement(
      sampleID: "bad-receipt", sequence: 0, descriptor: descriptor(),
      time: SensorMeasurementTime(clock: clock(), seconds: 0.5),
      receivedAt: SensorMeasurementTime(clock: clock(), seconds: 0), value: .scalar(1))
    XCTAssertThrowsError(try window(retention: .inline([delayedSample])))
  }

  func testRawAndAggregateRetentionRemainExplicit() throws {
    let raw = try window(retention: .inline([measurement()]))
    XCTAssertEqual(raw.availability, .observed)
    let aggregates = SensorSampleRetention.aggregateOnly(
      aggregates: [try reference("rms")], sourceSampleIDs: ["sample"])
    XCTAssertThrowsError(try window(retention: aggregates))
    let partial = try window(
      retention: aggregates, state: .partial,
      omissions: [SensorEvidenceOmission(reason: .rawNotRetained)])
    XCTAssertEqual(partial.retention, aggregates)
    XCTAssertThrowsError(
      try window(
        retention: .inline([measurement()]), state: .unavailable,
        omissions: [SensorEvidenceOmission(reason: .unsupported)]))
    _ = try window(
      retention: .none, state: .empty,
      omissions: [SensorEvidenceOmission(reason: .noSamples)])
  }

  func testCompleteDecisionManifestPreservesNegativeInputsAndOrder() throws {
    let roles: [SensorDerivationInputRole] = [.supporting, .contradicting, .rejected, .omission]
    let inputs = try roles.enumerated().map { index, role in
      try SensorDerivationInput(
        reference: reference("input-\(index)"), selector: "whole-record",
        role: role, extent: extent(), reasonCode: "declared-by-method")
    }
    let binding = try SensorDerivationBinding(
      methodID: "fusion", methodVersion: "1",
      configuration: reference("config"), inputs: inputs,
      limitations: [.sourceAuthenticityUnverified])
    XCTAssertEqual(binding.inputs.map(\.role), roles)
    XCTAssertEqual(
      binding.inputs.map(\.reference.recordID), ["input-0", "input-1", "input-2", "input-3"])
    XCTAssertEqual(binding.configuration.sha256, String(repeating: "a", count: 64))
    XCTAssertEqual(binding.inputs.first?.extent, try extent())
    XCTAssertEqual(binding.limitations, [.sourceAuthenticityUnverified])
    XCTAssertThrowsError(
      try SensorDerivationInput(
        reference: reference("rejected"), selector: "*", role: .rejected, extent: extent()))
  }

  func testConflictingCommitmentsAndDuplicateInputsAreRefused() throws {
    let input = try SensorDerivationInput(
      reference: reference("raw"), selector: "x", role: .supporting, extent: extent())
    let conflicting = try SensorDerivationInput(
      reference: SensorArtifactReference(
        recordID: "raw", sha256: String(repeating: "b", count: 64)),
      selector: "y", role: .contradicting, extent: extent())
    for inputs in [[input, input], [input, conflicting], []] {
      XCTAssertThrowsError(
        try SensorDerivationBinding(
          methodID: "rms", methodVersion: "v1",
          configuration: reference("config"), inputs: inputs,
          limitations: [.sourceAuthenticityUnverified]))
    }
  }

  func testDerivedMeasurementsRequireImmutableMethodBinding() throws {
    let derived = try descriptor(origin: .derived)
    XCTAssertThrowsError(try measurement(descriptor: derived))
    let binding = try binding()
    let result = try SensorMeasurement(
      sampleID: "result", sequence: 0, descriptor: derived,
      time: SensorMeasurementTime(clock: clock(), seconds: 0),
      value: .scalar(0), derivation: binding)
    XCTAssertEqual(result.derivation, binding)
    XCTAssertThrowsError(
      try SensorMeasurement(
        sampleID: "raw", sequence: 0, descriptor: descriptor(),
        time: SensorMeasurementTime(clock: clock(), seconds: 0),
        value: .scalar(0), derivation: binding))
  }

  func testFrameTransformRequiresDerivedOriginAndSourceFrame() throws {
    let lineage = SensorFrameLineage.transformed(
      sourceFrameID: "device.xyz.v1", binding: try binding())
    XCTAssertThrowsError(try descriptor(frame: "world.xyz.v1", lineage: lineage))
    let transformed = try descriptor(frame: "world.xyz.v1", origin: .derived, lineage: lineage)
    XCTAssertEqual(transformed.frameLineage, lineage)
    XCTAssertThrowsError(try descriptor(frame: "device.xyz.v1", origin: .derived, lineage: lineage))
  }

  func testForeignReceiptClockRequiresCorrelationOrExplicitOmission() throws {
    let sensorClock = try clock()
    let wallClock = try clock(id: "unix", kind: .wallClock)
    let receipt = try SensorMeasurementTime(clock: wallClock, seconds: 100)
    let sample = try SensorMeasurement(
      sampleID: "sample", sequence: 0, descriptor: descriptor(),
      time: SensorMeasurementTime(clock: sensorClock, seconds: 0),
      receivedAt: receipt, value: .scalar(0))
    XCTAssertThrowsError(try window(retention: .inline([sample])))
    let correlation = try SensorClockCorrelation(
      source: sample.time, target: receipt, uncertaintySeconds: 0.002)
    _ = try window(retention: .inline([sample]), correlations: [correlation])
    _ = try window(
      retention: .inline([sample]), state: .partial,
      omissions: [SensorEvidenceOmission(reason: .clockUncorrelated)])
  }

  func testCollectionAndNominalPeriodBoundsAreEnforced() throws {
    let ids = (0...SensorEvidenceWindow.maximumSampleCount).map(String.init)
    XCTAssertThrowsError(
      try window(retention: .external(reference: reference("raw"), sampleIDs: ids)))
    XCTAssertThrowsError(
      try SensorEvidenceWindow(
        windowID: "oversample", descriptor: descriptor(),
        bounds: SensorEvidenceInterval(clock: clock(), start: 0, end: 1),
        nominalPeriodSeconds: .leastNonzeroMagnitude, retention: .inline([measurement()]),
        availability: .observed))
  }

  func testArtifactCommitmentShapeIsStrict() throws {
    for hash in ["", String(repeating: "A", count: 64), String(repeating: "0", count: 63)] {
      XCTAssertThrowsError(try SensorArtifactReference(recordID: "record", sha256: hash))
    }
    XCTAssertThrowsError(
      try SensorArtifactReference(
        recordID: "bad\nrecord", sha256: String(repeating: "a", count: 64)))
  }

  func testVectorShapeAndPointDerivationAreExplicit() throws {
    let vectorDescriptor = try SensorMeasurementDescriptor(
      streamID: "raw-accel", sourceID: "adapter.v1", origin: .nativeSensor,
      quantity: .acceleration, unit: .standardGravity, gravity: .included,
      frameID: "device.xyz.v1", shape: .vector3)
    let vector = try measurement(
      value: .vector(.init(x: 0, y: 0, z: 1)), descriptor: vectorDescriptor)
    XCTAssertEqual(vector.value, .vector(.init(x: 0, y: 0, z: 1)))
    XCTAssertThrowsError(try measurement(value: .scalar(1), descriptor: vectorDescriptor))
    let point = SensorDerivationExtent.point(vector.time)
    let input = try SensorDerivationInput(
      reference: reference("sample"), selector: "z",
      role: .supporting, extent: point)
    XCTAssertEqual(input.extent, point)
    XCTAssertThrowsError(
      try SensorDerivationBinding(
        methodID: "method", methodVersion: "1", configuration: reference("config"),
        inputs: [input], limitations: [.resolutionUnknown, .resolutionUnknown]))
  }

  func testFineSignedValuesPreserveBitsWithoutClaimingResolution() throws {
    let descriptor = try SensorMeasurementDescriptor(
      streamID: "fine-motion", sourceID: "adapter.v1", origin: .platformFused,
      quantity: .acceleration, unit: .standardGravity, gravity: .excluded,
      frameID: "device.xyz.v1", shape: .vector3)
    let input = SensorVector3(x: 1e-15, y: -1e-15, z: -0.0)
    let sample = try measurement(value: .vector(input), descriptor: descriptor)
    let retained = try SensorEvidenceWindow(
      windowID: "fine-window", descriptor: descriptor,
      bounds: SensorEvidenceInterval(clock: clock(), start: 0, end: 1),
      retention: .inline([sample]), availability: .observed)
    guard case .inline(let samples) = retained.retention,
      case .vector(let output) = samples.first?.value
    else { return XCTFail("Expected original vector samples") }
    XCTAssertEqual(output.x.bitPattern, input.x.bitPattern)
    XCTAssertEqual(output.y.bitPattern, input.y.bitPattern)
    XCTAssertEqual(output.z.bitPattern, input.z.bitPattern)
    XCTAssertNil(retained.descriptor.resolution)
  }

  func testComposedMeasurementsRejectConflictingRecordCommitments() throws {
    let original = try binding()
    let conflicting = try SensorDerivationBinding(
      methodID: "other-method", methodVersion: "1",
      configuration: SensorArtifactReference(
        recordID: "config", sha256: String(repeating: "b", count: 64)),
      inputs: original.inputs, limitations: [])
    let transformed = try SensorMeasurementDescriptor(
      streamID: "derived", sourceID: "adapter.v1", origin: .derived,
      quantity: .acceleration, unit: .standardGravity, gravity: .excluded,
      frameID: "world.xyz.v1",
      frameLineage: .transformed(sourceFrameID: "device.xyz.v1", binding: original))
    let calibrated = try SensorMeasurementDescriptor(
      streamID: "derived", sourceID: "adapter.v1", origin: .derived,
      quantity: .acceleration, unit: .standardGravity, gravity: .excluded,
      frameID: "device.xyz.v1", calibration: reference("config"))
    for descriptor in [transformed, calibrated] {
      XCTAssertThrowsError(
        try SensorMeasurement(
          sampleID: "derived", sequence: 0, descriptor: descriptor,
          time: SensorMeasurementTime(clock: clock(), seconds: 0), value: .scalar(0),
          derivation: conflicting))
    }
    XCTAssertThrowsError(
      try SensorMeasurementDescriptor(
        streamID: "derived", sourceID: "adapter.v1", origin: .derived,
        quantity: .acceleration, unit: .standardGravity, gravity: .excluded,
        frameID: "world.xyz.v1",
        frameLineage: .transformed(sourceFrameID: "device.xyz.v1", binding: original),
        calibration: SensorArtifactReference(
          recordID: "config", sha256: String(repeating: "b", count: 64))))
  }

  func testComposedMeasurementsAllowConsistentRecordReuse() throws {
    let binding = try binding()
    let descriptor = try SensorMeasurementDescriptor(
      streamID: "derived", sourceID: "adapter.v1", origin: .derived,
      quantity: .acceleration, unit: .standardGravity, gravity: .excluded,
      frameID: "world.xyz.v1",
      frameLineage: .transformed(sourceFrameID: "device.xyz.v1", binding: binding),
      calibration: reference("config"))
    let sample = try SensorMeasurement(
      sampleID: "derived", sequence: 0, descriptor: descriptor,
      time: SensorMeasurementTime(clock: clock(), seconds: 0), value: .scalar(0),
      derivation: binding)
    _ = try SensorEvidenceWindow(
      windowID: "consistent", descriptor: descriptor,
      bounds: SensorEvidenceInterval(clock: clock(), start: 0, end: 1),
      retention: .inline([sample]), availability: .observed)
    XCTAssertEqual(sample.derivation?.configuration, descriptor.calibration)
    XCTAssertThrowsError(
      try SensorEvidenceWindow(
        windowID: "conflicting-external", descriptor: descriptor,
        bounds: SensorEvidenceInterval(clock: clock(), start: 0, end: 1),
        retention: .external(
          reference: SensorArtifactReference(
            recordID: "config", sha256: String(repeating: "b", count: 64)),
          sampleIDs: ["derived"]), availability: .observed))
  }

  func testWindowsRejectCrossSampleCommitmentConflicts() throws {
    let descriptor = try descriptor(origin: .derived)
    let firstBinding = try binding()
    let otherBinding = try SensorDerivationBinding(
      methodID: "method", methodVersion: "1",
      configuration: SensorArtifactReference(
        recordID: "config", sha256: String(repeating: "b", count: 64)),
      inputs: firstBinding.inputs, limitations: [])
    let first = try SensorMeasurement(
      sampleID: "first", sequence: 0, descriptor: descriptor,
      time: SensorMeasurementTime(clock: clock(), seconds: 0), value: .scalar(1),
      derivation: firstBinding)
    let second = try SensorMeasurement(
      sampleID: "second", sequence: 1, descriptor: descriptor,
      time: SensorMeasurementTime(clock: clock(), seconds: 0.5), value: .scalar(2),
      derivation: otherBinding)
    XCTAssertThrowsError(
      try SensorEvidenceWindow(
        windowID: "conflicting-samples", descriptor: descriptor,
        bounds: SensorEvidenceInterval(clock: clock(), start: 0, end: 1),
        retention: .inline([first, second]), availability: .observed))
    let consistent = try SensorMeasurement(
      sampleID: "second", sequence: 1, descriptor: descriptor,
      time: SensorMeasurementTime(clock: clock(), seconds: 0.5), value: .scalar(2),
      derivation: firstBinding)
    _ = try SensorEvidenceWindow(
      windowID: "consistent-samples", descriptor: descriptor,
      bounds: SensorEvidenceInterval(clock: clock(), start: 0, end: 1),
      retention: .inline([first, consistent]), availability: .observed)
    let calibrated = try SensorMeasurementDescriptor(
      streamID: "derived", sourceID: "adapter.v1", origin: .derived,
      quantity: .acceleration, unit: .standardGravity, gravity: .excluded,
      frameID: "device.xyz.v1", calibration: reference("config"))
    XCTAssertThrowsError(
      try SensorEvidenceWindow(
        windowID: "conflicting-aggregate", descriptor: calibrated,
        bounds: SensorEvidenceInterval(clock: clock(), start: 0, end: 1),
        retention: .aggregateOnly(
          aggregates: [otherBinding.configuration], sourceSampleIDs: ["first"]),
        availability: .partial, omissions: [SensorEvidenceOmission(reason: .rawNotRetained)]))
  }

  func testCanonicalUnicodeInputIdentitiesAndSelectorsAreDeduplicated() throws {
    let composed = "\u{00e9}"
    let decomposed = "e\u{0301}"
    XCTAssertEqual(composed, decomposed)
    XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
    for (firstID, secondID, firstSelector, secondSelector) in [
      (composed, decomposed, "x", "x"),
      ("record", "record", composed, decomposed),
      (composed, decomposed, composed, decomposed),
    ] {
      let inputs = try [
        SensorDerivationInput(
          reference: reference(firstID), selector: firstSelector, role: .supporting,
          extent: extent()),
        SensorDerivationInput(
          reference: reference(secondID), selector: secondSelector, role: .contradicting,
          extent: extent()),
      ]
      XCTAssertThrowsError(
        try SensorDerivationBinding(
          methodID: "unicode", methodVersion: "1", configuration: reference("config"),
          inputs: inputs, limitations: [])
      ) { error in
        XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("duplicateInput"))
      }
    }
  }

  func testCanonicalUnicodeRecordsAllowDistinctSelectorsAndSeparateRecords() throws {
    let inputs = try [
      SensorDerivationInput(
        reference: reference("\u{00e9}"), selector: "x", role: .supporting, extent: extent()),
      SensorDerivationInput(
        reference: reference("e\u{0301}"), selector: "y", role: .contradicting, extent: extent()),
      SensorDerivationInput(
        reference: reference("other-record"), selector: "x", role: .context, extent: extent()),
    ]
    let binding = try SensorDerivationBinding(
      methodID: "unicode", methodVersion: "1", configuration: reference("config"),
      inputs: inputs, limitations: [])
    XCTAssertEqual(binding.inputs, inputs)
    XCTAssertEqual(binding.inputs.map(\.selector), ["x", "y", "x"])
  }

  func testMaximumWindowResolvesLateGapAndClockOmissions() throws {
    let count = SensorEvidenceWindow.maximumSampleCount
    let descriptor = try descriptor()
    let sourceClock = try clock()
    let receiptClock = try clock(id: "receipt", kind: .wallClock)
    let bounds = try SensorEvidenceInterval(clock: sourceClock, start: 0, end: Double(count))
    let samples = try (0..<count).map { index in
      try SensorMeasurement(
        sampleID: "sample-\(index)", sequence: UInt64(index) * 2, descriptor: descriptor,
        time: SensorMeasurementTime(clock: sourceClock, seconds: Double(index)),
        receivedAt: SensorMeasurementTime(clock: receiptClock, seconds: Double(index) + 100),
        value: .scalar(Double(index)))
    }
    // Relevant reasons deliberately follow the maximum number of unrelated omissions.
    // This exercises declared capacity without relying on a machine-dependent time limit.
    let unrelated = try SensorEvidenceOmission(reason: .invalidSample)
    var omissions = Array(repeating: unrelated, count: count - 2)
    omissions.append(try SensorEvidenceOmission(reason: .gap))
    omissions.append(try SensorEvidenceOmission(reason: .clockUncorrelated))
    let admitted = try SensorEvidenceWindow(
      windowID: "maximum-gapped", descriptor: descriptor, bounds: bounds,
      retention: .inline(samples), availability: .partial, omissions: omissions)
    XCTAssertEqual(admitted.omissions.count, count)
    guard case .inline(let retained) = admitted.retention else {
      return XCTFail("Expected all retained samples")
    }
    XCTAssertEqual(retained.count, count)
    XCTAssertEqual(retained.last?.sampleID, "sample-\(count - 1)")
    XCTAssertEqual(retained.last?.sequence, UInt64(count - 1) * 2)
    XCTAssertThrowsError(
      try SensorEvidenceWindow(
        windowID: "missing-clock-omission", descriptor: descriptor, bounds: bounds,
        retention: .inline(samples), availability: .partial, omissions: Array(omissions.dropLast()))
    ) { error in
      XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("receipt.clock"))
    }
    omissions.remove(at: count - 2)
    XCTAssertThrowsError(
      try SensorEvidenceWindow(
        windowID: "missing-gap-omission", descriptor: descriptor, bounds: bounds,
        retention: .inline(samples), availability: .partial, omissions: omissions)
    ) { error in
      XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("sample.sequenceGap"))
    }
  }

  func testClockCorrelationsCannotSubstituteSessionOrClockKind() throws {
    let sourceClock = try clock()
    let receiptClock = try clock(id: "wall", session: "wall-session", kind: .wallClock)
    let sourceTime = try SensorMeasurementTime(clock: sourceClock, seconds: 0)
    let receiptTime = try SensorMeasurementTime(clock: receiptClock, seconds: 100)
    let sample = try SensorMeasurement(
      sampleID: "sample", sequence: 0, descriptor: descriptor(),
      time: sourceTime, receivedAt: receiptTime, value: .scalar(1))
    for substituted in [
      try clock(session: "other-boot"),
      try clock(kind: .providerDefined),
    ] {
      let correlation = try SensorClockCorrelation(
        source: SensorMeasurementTime(clock: substituted, seconds: 0), target: receiptTime,
        uncertaintySeconds: 0.002)
      XCTAssertThrowsError(try window(retention: .inline([sample]), correlations: [correlation])) {
        error in
        XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("unrelatedCorrelation"))
      }
    }
    let wrongReceiptSession = try SensorClockCorrelation(
      source: sourceTime,
      target: SensorMeasurementTime(
        clock: clock(id: "wall", session: "other-wall-session", kind: .wallClock), seconds: 100),
      uncertaintySeconds: 0.002)
    XCTAssertThrowsError(
      try window(retention: .inline([sample]), correlations: [wrongReceiptSession])
    ) { error in
      XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("receipt.clock"))
    }
    for correlation in [
      try SensorClockCorrelation(
        source: sourceTime, target: receiptTime, uncertaintySeconds: 0.002),
      try SensorClockCorrelation(
        source: receiptTime, target: sourceTime, uncertaintySeconds: 0.002),
    ] {
      let admitted = try window(retention: .inline([sample]), correlations: [correlation])
      XCTAssertEqual(admitted.clockCorrelations, [correlation])
    }
  }

  func testOmissionIntervalsCannotCrossSessionOrWindowBounds() throws {
    let samples = try [measurement()]
    for interval in [
      try SensorEvidenceInterval(clock: clock(session: "other-boot"), start: 0.25, end: 0.5),
      try SensorEvidenceInterval(clock: clock(), start: -0.1, end: 0.5),
      try SensorEvidenceInterval(clock: clock(), start: 0.5, end: 1.1),
    ] {
      XCTAssertThrowsError(
        try window(
          retention: .inline(samples), state: .partial,
          omissions: [SensorEvidenceOmission(reason: .gap, interval: interval)])
      ) { error in
        XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("omission.interval"))
      }
    }
    let omissions = try [
      SensorEvidenceOmission(
        reason: .gap, interval: SensorEvidenceInterval(clock: clock(), start: 0.25, end: 0.5)),
      SensorEvidenceOmission(reason: .clockUncorrelated),
    ]
    let admitted = try window(retention: .inline(samples), state: .partial, omissions: omissions)
    XCTAssertEqual(admitted.omissions, omissions)
    XCTAssertNil(admitted.omissions.last?.interval)
  }

  func testInputExtentsRetainDomainsWithoutReidentifyingDuplicateEvidence() throws {
    let point = SensorDerivationExtent.point(
      try SensorMeasurementTime(clock: clock(session: "point-source"), seconds: 0.5))
    let interval = SensorDerivationExtent.interval(
      try SensorEvidenceInterval(clock: clock(session: "interval-source"), start: 0.25, end: 0.75))
    let inputs = try [
      SensorDerivationInput(
        reference: reference("point-input"), selector: "value", role: .supporting, extent: point),
      SensorDerivationInput(
        reference: reference("interval-input"), selector: "value", role: .contradicting,
        extent: interval),
    ]
    let binding = try SensorDerivationBinding(
      methodID: "multi-source", methodVersion: "1", configuration: reference("alignment-profile"),
      inputs: inputs, limitations: [.clockAlignmentUncertain, .sourceAuthenticityUnverified])
    let descriptor = try descriptor(origin: .derived)
    let result = try SensorMeasurement(
      sampleID: "derived", sequence: 0, descriptor: descriptor,
      time: SensorMeasurementTime(clock: clock(), seconds: 0), value: .scalar(1),
      derivation: binding)
    let admitted = try SensorEvidenceWindow(
      windowID: "multi-source-result", descriptor: descriptor,
      bounds: SensorEvidenceInterval(clock: clock(), start: 0, end: 1),
      retention: .inline([result]), availability: .observed)
    guard case .inline(let retained) = admitted.retention else {
      return XCTFail("Expected retained result")
    }
    XCTAssertEqual(retained.first?.derivation?.inputs.map(\.extent), [point, interval])
    XCTAssertEqual(retained.first?.derivation?.limitations, binding.limitations)
    let replayed = try SensorDerivationInput(
      reference: inputs[0].reference, selector: inputs[0].selector,
      role: .contradicting, extent: interval)
    XCTAssertThrowsError(
      try SensorDerivationBinding(
        methodID: "multi-source", methodVersion: "1", configuration: reference("alignment-profile"),
        inputs: [inputs[0], replayed], limitations: [.clockAlignmentUncertain])
    ) { error in
      XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("duplicateInput"))
    }
  }

  func testWindowRequiresExactCalibrationAndTransformationDescriptors() throws {
    let originalBinding = try binding()
    let otherVersionBinding = try SensorDerivationBinding(
      methodID: originalBinding.methodID, methodVersion: "2",
      configuration: originalBinding.configuration,
      inputs: originalBinding.inputs, limitations: originalBinding.limitations)
    let otherConfigurationBinding = try SensorDerivationBinding(
      methodID: originalBinding.methodID, methodVersion: originalBinding.methodVersion,
      configuration: reference("other-config"),
      inputs: originalBinding.inputs, limitations: originalBinding.limitations)
    for (original, substituted) in [
      (
        try SensorMeasurementDescriptor(
          streamID: "accel", sourceID: "adapter.v1", origin: .platformFused,
          quantity: .acceleration, unit: .standardGravity, gravity: .excluded,
          frameID: "device.xyz.v1", calibration: reference("calibration-a")),
        try SensorMeasurementDescriptor(
          streamID: "accel", sourceID: "adapter.v1", origin: .platformFused,
          quantity: .acceleration, unit: .standardGravity, gravity: .excluded,
          frameID: "device.xyz.v1", calibration: reference("calibration-b"))
      ),
      (
        try descriptor(
          frame: "world.xyz.v1", origin: .derived,
          lineage: .transformed(sourceFrameID: "device.xyz.v1", binding: originalBinding)),
        try descriptor(
          frame: "world.xyz.v1", origin: .derived,
          lineage: .transformed(sourceFrameID: "device.xyz.v1", binding: otherVersionBinding))
      ),
      (
        try descriptor(
          frame: "world.xyz.v1", origin: .derived,
          lineage: .transformed(sourceFrameID: "device.xyz.v1", binding: originalBinding)),
        try descriptor(
          frame: "world.xyz.v1", origin: .derived,
          lineage: .transformed(sourceFrameID: "device.xyz.v1", binding: otherConfigurationBinding))
      ),
    ] {
      let sample = try SensorMeasurement(
        sampleID: "sample", sequence: 0, descriptor: original,
        time: SensorMeasurementTime(clock: clock(), seconds: 0), value: .scalar(0.25),
        derivation: original.origin == .derived ? originalBinding : nil)
      let bounds = try SensorEvidenceInterval(clock: clock(), start: 0, end: 1)
      _ = try SensorEvidenceWindow(
        windowID: "exact-descriptor", descriptor: original, bounds: bounds,
        retention: .inline([sample]), availability: .observed)
      XCTAssertThrowsError(
        try SensorEvidenceWindow(
          windowID: "substituted-descriptor", descriptor: substituted, bounds: bounds,
          retention: .inline([sample]), availability: .observed)
      ) { error in
        XCTAssertEqual(error as? SensorEvidenceContractError, .invalid("sample.descriptor"))
      }
    }
  }

  private func clock(
    id: String = "uptime", session: String = "boot-1",
    kind: SensorClockKind = .monotonic
  ) throws -> SensorClockDomain {
    try SensorClockDomain(identifier: id, session: .init(rawValue: session), kind: kind)
  }

  private func descriptor(
    frame: String = "device.xyz.v1", unit: SensorMeasurementUnit = .standardGravity,
    gravity: SensorGravityInclusion = .excluded,
    origin: SensorMeasurementOrigin = .platformFused,
    lineage: SensorFrameLineage = .reported, shape: SensorMeasurementShape = .scalar
  ) throws -> SensorMeasurementDescriptor {
    try SensorMeasurementDescriptor(
      streamID: "accel", sourceID: "adapter.v1", origin: origin,
      quantity: .acceleration, unit: unit, gravity: gravity,
      frameID: frame, shape: shape, frameLineage: lineage)
  }

  private func measurement(
    id: String = "sample", sequence: UInt64 = 0, seconds: Double = 0,
    domain: SensorClockDomain? = nil, value: SensorMeasurementValue = .scalar(1),
    descriptor supplied: SensorMeasurementDescriptor? = nil
  ) throws -> SensorMeasurement {
    try SensorMeasurement(
      sampleID: id, sequence: sequence, descriptor: supplied ?? descriptor(),
      time: SensorMeasurementTime(clock: domain ?? clock(), seconds: seconds), value: value)
  }

  private func window(
    retention: SensorSampleRetention, state: SensorEvidenceAvailability = .observed,
    omissions: [SensorEvidenceOmission] = [],
    correlations: [SensorClockCorrelation] = []
  ) throws -> SensorEvidenceWindow {
    try SensorEvidenceWindow(
      windowID: "window", descriptor: descriptor(),
      bounds: SensorEvidenceInterval(clock: clock(), start: 0, end: 1),
      retention: retention, availability: state, omissions: omissions,
      clockCorrelations: correlations)
  }

  private func reference(_ id: String) throws -> SensorArtifactReference {
    try SensorArtifactReference(recordID: id, sha256: String(repeating: "a", count: 64))
  }

  private func extent() throws -> SensorDerivationExtent {
    .interval(try SensorEvidenceInterval(clock: clock(), start: 0, end: 1))
  }

  private func binding() throws -> SensorDerivationBinding {
    try SensorDerivationBinding(
      methodID: "method", methodVersion: "1", configuration: reference("config"),
      inputs: [
        SensorDerivationInput(
          reference: reference("raw"), selector: "*", role: .supporting, extent: extent())
      ], limitations: [.resolutionUnknown])
  }

  private struct Vectors: Decodable {
    let contract: String
    let cases: [Vector]
  }
  private struct Vector: Decodable {
    let id: String
    let kind: String
    let accepted: Bool
    let value: Double?
    let time: Double?
    let start: Double?
    let end: Double?
    let state: String?
    let hasSample: Bool?
    let hasOmission: Bool?
    let uncertainty: Double?
    let quantity: String?
    let unit: String?
    let gravity: String?
  }
}
