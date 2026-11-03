import XCTest

import KenshikiSensors

final class MotionAggregateReducerTests: XCTestCase {
    func testDeviceMotionUsesUnmodifiedAppleProcessedMagnitudes() throws {
        var reducer = DeviceMotionWindowReducer()
        let samples = [
            sample(acceleration: .init(x: 0, y: 0, z: 0), rotation: .init(x: 0, y: 0, z: 0)),
            sample(acceleration: .init(x: 1, y: 0, z: 0), rotation: .init(x: 0, y: 2, z: 0)),
            sample(acceleration: .init(x: 0, y: 2, z: 0), rotation: .init(x: 0, y: 0, z: 3)),
            sample(acceleration: .init(x: 0, y: 0, z: 3), rotation: .init(x: 4, y: 0, z: 0)),
        ]
        for sample in samples {
            XCTAssertTrue(reducer.accepts(sample))
            reducer.ingest(sample)
        }

        let result = try XCTUnwrap(reducer.measurements())
        XCTAssertEqual(result.userAccelerationMagnitudeG.rootMeanSquare, sqrt(3.5), accuracy: 1e-12)
        XCTAssertEqual(result.userAccelerationMagnitudeG.median, 1.5, accuracy: 1e-12)
        XCTAssertEqual(result.userAccelerationMagnitudeG.p95, 2.85, accuracy: 1e-12)
        XCTAssertEqual(result.rotationRateMagnitudeRadiansPerSecond.maximum, 4)
        XCTAssertEqual(result.gravityMean, SensorVector3(x: 0, y: 0, z: -1))
        XCTAssertEqual(result.attitudeReferenceFrame, "x_magnetic_north_z_vertical")
        XCTAssertEqual(result.sensorLocation, "default")
        XCTAssertEqual(result.magneticCalibrationCounts, ["high": 4])
        XCTAssertFalse(result.additionalBiasApplied)
        XCTAssertEqual(result.biasVectorSource, "not_exposed_by_core_motion")
    }

    func testDeviceMotionRejectsMixedReferenceFrames() {
        var reducer = DeviceMotionWindowReducer()
        let first = sample(
            acceleration: .init(x: 0, y: 0, z: 0),
            rotation: .init(x: 0, y: 0, z: 0))
        reducer.ingest(first)
        let changed = DeviceMotionAggregateSample(
            userAcceleration: first.userAcceleration,
            rotationRate: first.rotationRate,
            gravity: first.gravity,
            attitudeReferenceFrame: "x_arbitrary_corrected_z_vertical",
            magneticCalibrationAccuracy: "high",
            sensorLocation: "default")
        XCTAssertFalse(reducer.accepts(changed))
    }

    func testRecordedAccelerationRetainsEverySampleWhileCompactlyProvenancingBatches() throws {
        var reducer = RecordedAccelerationWindowReducer()
        let samples = [
            RecordedAccelerationAggregateSample(
                acceleration: .init(x: 0, y: 0, z: 1), recordingBatchIdentifier: 8),
            RecordedAccelerationAggregateSample(
                acceleration: .init(x: 0, y: 0, z: 9), recordingBatchIdentifier: 8),
            RecordedAccelerationAggregateSample(
                acceleration: .init(x: 0, y: 0, z: 1.1), recordingBatchIdentifier: 9),
        ]
        for sample in samples { reducer.ingest(sample) }

        let result = try XCTUnwrap(reducer.measurements())
        XCTAssertEqual(result.rawAccelerationMagnitudeG.median, 1.1, accuracy: 1e-12)
        XCTAssertEqual(result.rawAccelerationZG.maximum, 9, accuracy: 1e-12)
        XCTAssertEqual(result.recordedSampleCount, 3)
        XCTAssertEqual(result.distinctRecordingBatchCount, 2)
        XCTAssertEqual(result.recordingBatchIdentifierMinimum, 8)
        XCTAssertEqual(result.recordingBatchIdentifierMaximum, 9)
        XCTAssertEqual(result.recordingBatchIdentifierDigest.count, 64)
    }

    private func sample(
        acceleration: SensorVector3,
        rotation: SensorVector3
    ) -> DeviceMotionAggregateSample {
        DeviceMotionAggregateSample(
            userAcceleration: acceleration,
            rotationRate: rotation,
            gravity: .init(x: 0, y: 0, z: -1),
            attitudeReferenceFrame: "x_magnetic_north_z_vertical",
            magneticCalibrationAccuracy: "high",
            sensorLocation: "default")
    }
}
