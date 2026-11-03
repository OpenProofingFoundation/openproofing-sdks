import XCTest

@testable import KenshikiSensors

final class SensorTemporalSummaryTests: XCTestCase {
    private struct ScalarReducer: BoundedWindowReducer {
        init() {}
        func accepts(_ sample: Double) -> Bool { sample.isFinite }
        mutating func ingest(_: Double) {
            // This timing-only fixture intentionally ignores values; the window owns timing.
        }
        func measurements() -> Bool? { true }
    }

    func testCountThresholdIsInclusiveAtNinetyFivePercent() {
        let specification = SensorWindowSpecification(
            duration: 20,
            nominalPeriod: 1,
            qualityPolicy: .init(
                minimumExpectedCountFraction: 0.95,
                minimumTemporalCoverageFraction: 0,
                maximumGapPeriods: 20))

        let atThreshold = summary(
            timestamps: (0..<19).map(Double.init),
            bounds: 0..<20,
            specification: specification)
        let belowThreshold = summary(
            timestamps: (0..<18).map(Double.init),
            bounds: 0..<20,
            specification: specification)

        XCTAssertEqual(atThreshold.expectedSampleCount, 20)
        XCTAssertEqual(atThreshold.acquisitionQuality, .observed)
        XCTAssertEqual(belowThreshold.acquisitionQuality, .partial)
    }

    func testCoverageThresholdIsInclusiveAndRejectsBelowByEpsilon() {
        let specification = SensorWindowSpecification(
            duration: 20,
            nominalPeriod: 1,
            qualityPolicy: .init(
                minimumExpectedCountFraction: 0,
                minimumTemporalCoverageFraction: 0.95,
                maximumGapPeriods: 20))
        let exact = (0..<19).map { Double($0) + 0.5 }
        var below = exact
        below[0] += 1e-9

        let atThreshold = summary(
            timestamps: exact, bounds: 0..<20, specification: specification)
        let belowThreshold = summary(
            timestamps: below, bounds: 0..<20, specification: specification)

        XCTAssertEqual(atThreshold.temporalCoverageFraction, 0.95, accuracy: 1e-12)
        XCTAssertEqual(atThreshold.acquisitionQuality, .observed)
        XCTAssertLessThan(belowThreshold.temporalCoverageFraction, 0.95)
        XCTAssertEqual(belowThreshold.acquisitionQuality, .partial)
    }

    func testMaximumGapThresholdIsInclusiveAndRejectsAboveByEpsilon() {
        let specification = SensorWindowSpecification(
            duration: 4,
            nominalPeriod: 1,
            qualityPolicy: .init(
                minimumExpectedCountFraction: 0,
                minimumTemporalCoverageFraction: 0,
                maximumGapPeriods: 3))

        let atThreshold = summary(
            timestamps: [0, 3], bounds: 0..<4, specification: specification)
        let aboveThreshold = summary(
            timestamps: [0, 3 + 1e-9], bounds: 0..<4, specification: specification)

        XCTAssertEqual(atThreshold.maximumSampleGapSeconds, 3)
        XCTAssertEqual(atThreshold.acquisitionQuality, .observed)
        XCTAssertGreaterThan(aboveThreshold.maximumSampleGapSeconds ?? 0, 3)
        XCTAssertEqual(aboveThreshold.acquisitionQuality, .partial)
    }

    func testTranslationAcrossNegativeAndPositiveClockDomainsPreservesSummary() {
        let specification = SensorWindowSpecification(duration: 60, nominalPeriod: 0.02)
        let offsets = (0..<3_000).map { Double($0) * 0.02 }
        let negative = summary(
            timestamps: offsets.map { $0 - 120 },
            bounds: -120 ..< -60,
            specification: specification)
        let positive = summary(
            timestamps: offsets.map { $0 + 240 },
            bounds: 240..<300,
            specification: specification)

        XCTAssertEqual(negative.expectedSampleCount, positive.expectedSampleCount)
        XCTAssertEqual(
            negative.temporalCoverageFraction,
            positive.temporalCoverageFraction,
            accuracy: 1e-10)
        XCTAssertEqual(
            negative.maximumSampleGapSeconds ?? 0,
            positive.maximumSampleGapSeconds ?? 0,
            accuracy: 1e-10)
        XCTAssertEqual(
            negative.observedMedianSampleHz ?? 0,
            positive.observedMedianSampleHz ?? 0,
            accuracy: 1e-8)
        XCTAssertEqual(negative.acquisitionQuality, positive.acquisitionQuality)
    }

    func testLiveAndRecordedRoutesProduceEquivalentTemporalEvidence() throws {
        let minute = Date(timeIntervalSinceReferenceDate: 120)
        let offsets = (0..<3_000).map { Double($0) * 0.02 }
        var live = TumblingSensorWindow<ScalarReducer>(
            sourceSessionID: .init(rawValue: "temporal-parity"),
            clockAnchor: .init(sensorTimestamp: 0, wallClock: minute),
            specification: .init(duration: 60, nominalPeriod: 0.02))
        for offset in offsets {
            XCTAssertNil(
                live.ingest(
                    .init(
                        sensorTimestamp: offset,
                        receivedAt: minute.addingTimeInterval(offset),
                        systemUptimeAtReceipt: offset,
                        value: offset)))
        }
        let liveTiming = try XCTUnwrap(live.flush(completion: .interrupted)?.timing)

        let recordedSamples = offsets.enumerated().map { index, offset in
            RecordedAccelerationWindowSample(
                sampleDate: minute.addingTimeInterval(offset),
                sensorTimestamp: 1_000 + offset,
                acceleration: .init(x: 0, y: 0, z: 1),
                recordingBatchIdentifier: 42)
        }
        let recordedTiming = try XCTUnwrap(
            RecordedAccelerationWindowProjection().project(
                samples: recordedSamples,
                finalizationCutoff: minute.addingTimeInterval(60)
            ).windows.first?.timing)

        XCTAssertEqual(liveTiming.sampleCount, recordedTiming.sampleCount)
        XCTAssertEqual(liveTiming.expectedSampleCount, recordedTiming.expectedSampleCount)
        XCTAssertEqual(
            liveTiming.temporalCoverageFraction,
            recordedTiming.temporalCoverageFraction,
            accuracy: 1e-10)
        XCTAssertEqual(
            liveTiming.maximumSampleGapSeconds ?? 0,
            recordedTiming.maximumSampleGapSeconds ?? 0,
            accuracy: 1e-10)
        XCTAssertEqual(
            liveTiming.leadingGapSeconds ?? 0,
            recordedTiming.leadingGapSeconds ?? 0,
            accuracy: 1e-10)
        XCTAssertEqual(
            liveTiming.trailingGapSeconds ?? 0,
            recordedTiming.trailingGapSeconds ?? 0,
            accuracy: 1e-10)
        XCTAssertEqual(
            liveTiming.observedMedianSampleHz ?? 0,
            recordedTiming.observedMedianSampleHz ?? 0,
            accuracy: 1e-8)
        XCTAssertEqual(liveTiming.acquisitionQuality, recordedTiming.acquisitionQuality)
    }

    private func summary(
        timestamps: [TimeInterval],
        bounds: Range<TimeInterval>,
        specification: SensorWindowSpecification
    ) -> SensorTemporalSummary {
        SensorTemporalSummary(
            orderedTimestamps: timestamps,
            bounds: bounds,
            specification: specification)
    }
}
