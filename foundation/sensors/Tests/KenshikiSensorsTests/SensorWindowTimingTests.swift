import XCTest

import KenshikiSensors

final class SensorWindowTimingTests: XCTestCase {
    private struct ScalarReducer: BoundedWindowReducer {
        private var values: [Double] = []

        init() {}

        func accepts(_ sample: Double) -> Bool { sample.isFinite }
        mutating func ingest(_ sample: Double) { values.append(sample) }
        func measurements() -> [Double]? { values.isEmpty ? nil : values }
    }

    private let session = SensorSourceSessionID(rawValue: "test-session")
    private let epoch = Date(timeIntervalSince1970: 1_000)

    func testPerfectOneHertzWindowIsObserved() throws {
        var window = makeWindow(nominalPeriod: 1)
        for timestamp in 0..<60 {
            XCTAssertNil(window.ingest(sample(TimeInterval(timestamp))))
        }

        let completed = try XCTUnwrap(window.ingest(sample(60)))
        XCTAssertEqual(completed.monotonicBounds, 0..<60)
        XCTAssertEqual(completed.timing.sampleCount, 60)
        XCTAssertEqual(completed.timing.expectedSampleCount, 60)
        XCTAssertEqual(completed.timing.temporalCoverageFraction, 59.5 / 60, accuracy: 1e-12)
        XCTAssertEqual(completed.timing.maximumSampleGapSeconds, 1)
        XCTAssertEqual(completed.timing.acquisitionQuality, .observed)
        XCTAssertEqual(completed.measurements, (0..<60).map(Double.init))
    }

    func testInternalLossCannotEarnObservedQuality() throws {
        var window = makeWindow(nominalPeriod: 1)
        for timestamp in Array(0..<30) + Array(40..<60) {
            _ = window.ingest(sample(TimeInterval(timestamp)))
        }

        let completed = try XCTUnwrap(window.ingest(sample(60)))
        XCTAssertEqual(completed.timing.sampleCount, 50)
        XCTAssertEqual(completed.timing.temporalCoverageFraction, 49.5 / 60, accuracy: 1e-12)
        XCTAssertEqual(completed.timing.maximumSampleGapSeconds, 11)
        XCTAssertEqual(completed.timing.acquisitionQuality, .partial)
    }

    func testIsolatedCallbackIsPartialRatherThanObserved() throws {
        var window = makeWindow(nominalPeriod: 1)
        XCTAssertNil(window.ingest(sample(30)))

        let completed = try XCTUnwrap(window.flush(completion: .sourceStopped))
        XCTAssertEqual(completed.timing.sampleCount, 1)
        XCTAssertEqual(completed.timing.temporalCoverageFraction, 1 / 60, accuracy: 1e-12)
        XCTAssertEqual(completed.timing.acquisitionQuality, .partial)
        XCTAssertEqual(completed.completion, .sourceStopped)
    }

    func testHalfOpenBoundaryRoutesExactMinuteToNextWindow() throws {
        var window = makeWindow(nominalPeriod: 1)
        XCTAssertNil(window.ingest(sample(59.999)))

        let completed = try XCTUnwrap(window.ingest(sample(60)))
        XCTAssertEqual(completed.monotonicBounds, 0..<60)
        XCTAssertEqual(completed.measurements, [59.999])
        let next = try XCTUnwrap(window.flush(completion: .interrupted))
        XCTAssertEqual(next.monotonicBounds, 60..<120)
        XCTAssertEqual(next.measurements, [60])
    }

    func testWallClockJumpDoesNotChangeWindowRouting() throws {
        var window = makeWindow(nominalPeriod: 1)
        XCTAssertNil(window.ingest(sample(10, receivedAt: epoch)))
        XCTAssertNil(
            window.ingest(
                sample(11, receivedAt: epoch.addingTimeInterval(3_601))))

        let completed = try XCTUnwrap(window.flush(completion: .interrupted))
        XCTAssertEqual(completed.monotonicBounds, 0..<60)
        XCTAssertEqual(completed.wallClockBounds.start, epoch)
        XCTAssertEqual(completed.wallClockBounds.end, epoch.addingTimeInterval(60))
        XCTAssertEqual(completed.timing.wallClockFirstReceived, epoch)
        XCTAssertEqual(
            completed.timing.wallClockLastReceived,
            epoch.addingTimeInterval(3_601))
        XCTAssertEqual(completed.timing.callbackLatencyFirstSeconds, 0)
        XCTAssertEqual(completed.timing.callbackLatencyLastSeconds, 0)
    }

    func testDuplicateAndInvalidSamplesDoNotAffectMeasurementsOrCoverage() throws {
        var window = makeWindow(nominalPeriod: 1)
        XCTAssertNil(window.ingest(sample(10, value: 1)))
        XCTAssertNil(window.ingest(sample(10, value: 2)))
        XCTAssertNil(window.ingest(sample(11, value: .nan)))

        let completed = try XCTUnwrap(window.flush(completion: .interrupted))
        XCTAssertEqual(completed.measurements, [1])
        XCTAssertEqual(completed.timing.sampleCount, 1)
        XCTAssertEqual(completed.timing.duplicateSampleCount, 1)
        XCTAssertEqual(completed.timing.invalidSampleCount, 1)
    }

    func testEmpiricalDistributionPinsR7Quantiles() throws {
        let distribution = try XCTUnwrap(EmpiricalDistribution(values: [0, 1, 2, 3]))
        XCTAssertEqual(distribution.rootMeanSquare, sqrt(3.5), accuracy: 1e-12)
        XCTAssertEqual(distribution.median, 1.5, accuracy: 1e-12)
        XCTAssertEqual(distribution.p95, 2.85, accuracy: 1e-12)
        XCTAssertEqual(distribution.maximum, 3)
    }

    func testExtremeFiniteTimestampIsInvalidWithoutClosingTheActiveWindow() throws {
        var window = makeWindow(nominalPeriod: 1)
        XCTAssertNil(window.ingest(sample(10, value: 1)))
        XCTAssertNil(window.ingest(sample(Double.greatestFiniteMagnitude, value: 2)))
        let completed = try XCTUnwrap(window.flush(completion: .interrupted))
        XCTAssertEqual(completed.monotonicBounds, 0..<60)
        XCTAssertEqual(completed.measurements, [1])
        XCTAssertEqual(completed.timing.invalidSampleCount, 1)
    }

    func testUnrepresentableWallProjectionCannotOpenAWindow() {
        var window = TumblingSensorWindow<ScalarReducer>(
            sourceSessionID: session,
            clockAnchor: SensorClockAnchor(
                sensorTimestamp: 0,
                wallClock: Date(timeIntervalSinceReferenceDate: 1e300)),
            specification: SensorWindowSpecification(nominalPeriod: 1))
        XCTAssertNil(window.ingest(sample(10)))
        XCTAssertNil(window.flush(completion: .interrupted))
    }

    func testSourceSessionDecodingRejectsEmptyIdentityAndPreservesWireShape() throws {
        XCTAssertThrowsError(
            try JSONDecoder().decode(SensorSourceSessionID.self, from: Data([0x22, 0x22])))
        let encoded = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(SensorSourceSessionID.self, from: encoded), session)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #""test-session""#)
    }

    func testMaximumNominalCountRemainsRepresentable() {
        let specification = SensorWindowSpecification(
            duration: 1, nominalPeriod: 1 / Double(SensorWindowSpecification.maximumExpectedSampleCount))
        XCTAssertEqual(specification.expectedSampleCount, 1_000_000)
    }

    private func makeWindow(nominalPeriod: TimeInterval) -> TumblingSensorWindow<ScalarReducer> {
        TumblingSensorWindow(
            sourceSessionID: session,
            clockAnchor: SensorClockAnchor(sensorTimestamp: 0, wallClock: epoch),
            specification: SensorWindowSpecification(nominalPeriod: nominalPeriod)
        )
    }

    private func sample(
        _ timestamp: TimeInterval,
        receivedAt: Date? = nil,
        value: Double? = nil
    ) -> TimestampedSensorSample<Double> {
        .init(
            sensorTimestamp: timestamp,
            receivedAt: receivedAt ?? epoch.addingTimeInterval(timestamp),
            systemUptimeAtReceipt: timestamp,
            value: value ?? timestamp)
    }
}
