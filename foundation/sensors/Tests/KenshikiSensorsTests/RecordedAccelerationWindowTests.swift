import XCTest

import KenshikiSensors

final class RecordedAccelerationWindowTests: XCTestCase {
    private let minute = Date(timeIntervalSinceReferenceDate: 120)

    func testSortsDeduplicatesAndReportsActualBounds() throws {
        let samples = [
            sample(offset: 0.04, timestamp: 50.04, id: 3),
            sample(offset: 0, timestamp: 50, id: 1),
            sample(offset: 0.02, timestamp: 50.02, id: 2),
            sample(offset: 0.02, timestamp: 50.02, id: 2),
            sample(offset: 0.06, timestamp: .nan, id: 4),
        ]

        let window = try XCTUnwrap(project(samples).first)
        XCTAssertEqual(window.timing.sampleCount, 3)
        XCTAssertEqual(window.timing.duplicateSampleCount, 1)
        XCTAssertEqual(window.timing.invalidSampleCount, 1)
        XCTAssertEqual(window.timing.wallClockFirstValid, minute)
        XCTAssertEqual(window.timing.wallClockLastValid, minute.addingTimeInterval(0.04))
        XCTAssertEqual(window.timing.sensorTimestampFirst, 50)
        XCTAssertEqual(window.timing.sensorTimestampLast, 50.04)
        XCTAssertEqual(window.measurements?.rawAccelerationZG.maximum, 1)
        XCTAssertEqual(project(samples), project(Array(samples.reversed())))
    }

    func testConflictingSampleIdentityIsRejectedWithoutInputOrderChoosingEvidence() throws {
        let samples = [
            sample(offset: 0, timestamp: 50, id: 1, z: 1),
            sample(offset: 0, timestamp: 50, id: 1, z: 2),
            sample(offset: 0.02, timestamp: 50.02, id: 2),
        ]

        let forward = projectResult(samples)
        let reversed = projectResult(Array(samples.reversed()))
        let window = try XCTUnwrap(forward.windows.first)

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.conflictingSampleIdentityCount, 1)
        XCTAssertEqual(forward.conflictingSampleCount, 2)
        XCTAssertEqual(window.timing.sampleCount, 1)
        XCTAssertEqual(window.measurements?.recordingBatchIdentifierMinimum, 2)
    }

    func testInvalidWallDatesAreReportedAsUnroutable() {
        let result = projectResult([
            sample(offset: 0, timestamp: 50, id: 1),
            RecordedAccelerationWindowSample(
                sampleDate: Date(timeIntervalSinceReferenceDate: .nan),
                sensorTimestamp: 50.02,
                acceleration: .init(x: 0, y: 0, z: 1),
                recordingBatchIdentifier: 2),
        ])

        XCTAssertEqual(result.inputSampleCount, 2)
        XCTAssertEqual(result.unroutableSampleCount, 1)
        XCTAssertEqual(result.windows.first?.timing.sampleCount, 1)
    }

    func testSignedZeroOrderingIsBitDeterministic() throws {
        let samples = [
            sample(offset: 0, timestamp: -0.0, id: 2),
            sample(offset: 0, timestamp: 0.0, id: 1),
        ]

        let forward = projectResult(samples)
        let reversed = projectResult(Array(samples.reversed()))
        let firstTimestamp = try XCTUnwrap(forward.windows.first?.timing.sensorTimestampFirst)

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(firstTimestamp.bitPattern, 0.0.bitPattern)
    }

    func testSensorTimestampRegressionIsReportedWithoutReplacingWallClockTiming() throws {
        let window = try XCTUnwrap(project([
            sample(offset: 0, timestamp: 100, id: 1),
            sample(offset: 0.02, timestamp: 99, id: 2),
        ]).first)

        XCTAssertEqual(window.timing.sensorTimestampRegressionCount, 1)
        XCTAssertEqual(window.timing.wallClockFirstValid, minute)
        XCTAssertEqual(window.timing.wallClockLastValid, minute.addingTimeInterval(0.02))
        XCTAssertEqual(window.timing.sensorTimestampFirst, 100)
        XCTAssertEqual(window.timing.sensorTimestampLast, 99)
    }

    func testHalfOpenBoundaryAndCutoffOnlyFinalizeClosedBins() throws {
        let samples = [
            sample(offset: 59.98, timestamp: 109.98, id: 42),
            sample(offset: 60, timestamp: 110, id: 42),
        ]
        let atBoundary = project(samples, cutoffOffset: 60)
        XCTAssertEqual(atBoundary.count, 1)
        XCTAssertEqual(atBoundary[0].timing.sampleCount, 1)
        XCTAssertEqual(atBoundary[0].measurements?.recordingBatchIdentifierMinimum, 42)
        XCTAssertEqual(projectResult(samples, cutoffOffset: 60).cutoffExcludedSampleCount, 1)

        let both = project(samples, cutoffOffset: 120)
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both[1].wallClockBounds.start, minute.addingTimeInterval(60))
        XCTAssertEqual(both[1].measurements?.recordingBatchIdentifierMinimum, 42)
    }

    func testCompleteFiftyHertzMinuteIsObserved() throws {
        let samples = (0..<3_000).map { index in
            sample(offset: Double(index) * 0.02, timestamp: 1_000 + Double(index) * 0.02, id: 42)
        }

        let window = try XCTUnwrap(project(samples).first)
        XCTAssertEqual(window.timing.sampleCount, 3_000)
        XCTAssertEqual(window.timing.expectedSampleCount, 3_000)
        XCTAssertEqual(window.timing.temporalCoverageFraction, 59.99 / 60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(window.timing.maximumSampleGapSeconds), 0.02, accuracy: 1e-9)
        XCTAssertEqual(window.timing.observedMedianSampleHz ?? 0, 50, accuracy: 1e-8)
        XCTAssertEqual(window.timing.acquisitionQuality, .observed)
    }

    func testInternalGapAndMissingSupportArePartial() throws {
        let samples = (0..<3_000).compactMap { index -> RecordedAccelerationWindowSample? in
            let offset = Double(index) * 0.02
            guard !(20..<30).contains(offset) else { return nil }
            return sample(offset: offset, timestamp: 2_000 + offset, id: 42)
        }

        let window = try XCTUnwrap(project(samples).first)
        XCTAssertLessThan(window.timing.temporalCoverageFraction, 0.84)
        XCTAssertGreaterThan(window.timing.maximumSampleGapSeconds ?? 0, 10)
        XCTAssertEqual(window.timing.acquisitionQuality, .partial)
    }

    func testStationaryRecordedAccelerationPreservesRawGravityNearOneG() throws {
        let samples = (0..<3_000).map { index in
            sample(
                offset: Double(index) * 0.02,
                timestamp: 3_000 + Double(index) * 0.02,
                id: 42,
                z: index.isMultiple(of: 2) ? 0.99 : 1.01)
        }

        let measurements = try XCTUnwrap(project(samples).first?.measurements)
        XCTAssertEqual(measurements.rawAccelerationMagnitudeG.median, 1, accuracy: 1e-12)
        XCTAssertEqual(measurements.rawAccelerationMagnitudeG.rootMeanSquare, sqrt(1.0001), accuracy: 1e-12)
        XCTAssertEqual(measurements.rawAccelerationZG.maximum, 1.01, accuracy: 1e-12)
    }

    func testFiniteWallDateBeyondBinPrecisionIsUnroutable() {
        let result = RecordedAccelerationWindowProjection().project(
            samples: [
                RecordedAccelerationWindowSample(
                    sampleDate: Date(timeIntervalSinceReferenceDate: 1e300),
                    sensorTimestamp: 1,
                    acceleration: .init(x: 0, y: 0, z: 1),
                    recordingBatchIdentifier: 42)
            ],
            finalizationCutoff: Date(timeIntervalSinceReferenceDate: 1.1e300))
        XCTAssertEqual(result.unroutableSampleCount, 1)
        XCTAssertTrue(result.windows.isEmpty)
    }

    private func project(
        _ samples: [RecordedAccelerationWindowSample], cutoffOffset: TimeInterval = 60
    ) -> [CompletedRecordedAccelerationWindow] {
        projectResult(samples, cutoffOffset: cutoffOffset).windows
    }

    private func projectResult(
        _ samples: [RecordedAccelerationWindowSample], cutoffOffset: TimeInterval = 60
    ) -> RecordedAccelerationWindowProjectionResult {
        RecordedAccelerationWindowProjection().project(
            samples: samples,
            finalizationCutoff: minute.addingTimeInterval(cutoffOffset))
    }

    private func sample(
        offset: TimeInterval, timestamp: TimeInterval, id: UInt64, z: Double = 1
    ) -> RecordedAccelerationWindowSample {
        .init(
            sampleDate: minute.addingTimeInterval(offset),
            sensorTimestamp: timestamp,
            acceleration: .init(x: 0, y: 0, z: z),
            recordingBatchIdentifier: id)
    }
}
