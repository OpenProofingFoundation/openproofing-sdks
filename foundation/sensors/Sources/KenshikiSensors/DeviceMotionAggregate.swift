import Foundation

/// Copied scalar values from one Apple-processed `CMDeviceMotion` item.
///
/// This type deliberately has no Pulse bias field: Core Motion already supplies user acceleration
/// and bias-corrected rotation rate, and it does not expose the bias vector it used.
public struct DeviceMotionAggregateSample: Equatable, Sendable {
    public let userAcceleration: SensorVector3
    public let rotationRate: SensorVector3
    public let gravity: SensorVector3
    public let attitudeReferenceFrame: String
    public let magneticCalibrationAccuracy: String
    public let sensorLocation: String

    public init(
        userAcceleration: SensorVector3,
        rotationRate: SensorVector3,
        gravity: SensorVector3,
        attitudeReferenceFrame: String,
        magneticCalibrationAccuracy: String,
        sensorLocation: String
    ) {
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
        self.gravity = gravity
        self.attitudeReferenceFrame = attitudeReferenceFrame
        self.magneticCalibrationAccuracy = magneticCalibrationAccuracy
        self.sensorLocation = sensorLocation
    }
}

public struct DeviceMotionAggregateMeasurements: Equatable, Sendable {
    public let userAccelerationMagnitudeG: EmpiricalDistribution
    public let rotationRateMagnitudeRadiansPerSecond: EmpiricalDistribution
    public let gravityMean: SensorVector3
    public let attitudeReferenceFrame: String
    public let magneticCalibrationCounts: [String: Int]
    public let sensorLocation: String
    public let additionalBiasApplied: Bool
    public let biasVectorSource: String
}

public struct DeviceMotionWindowReducer: BoundedWindowReducer {
    private var accelerationMagnitudes: [Double] = []
    private var rotationMagnitudes: [Double] = []
    private var gravitySum = SensorVector3(x: 0, y: 0, z: 0)
    private var referenceFrame: String?
    private var sensorLocation: String?
    private var magneticCalibrationCounts: [String: Int] = [:]

    public init() {}

    public func accepts(_ sample: DeviceMotionAggregateSample) -> Bool {
        sample.userAcceleration.isFinite
            && sample.rotationRate.isFinite
            && sample.gravity.isFinite
            && !sample.attitudeReferenceFrame.isEmpty
            && !sample.magneticCalibrationAccuracy.isEmpty
            && !sample.sensorLocation.isEmpty
            && (referenceFrame == nil || referenceFrame == sample.attitudeReferenceFrame)
            && (sensorLocation == nil || sensorLocation == sample.sensorLocation)
    }

    public mutating func ingest(_ sample: DeviceMotionAggregateSample) {
        referenceFrame = referenceFrame ?? sample.attitudeReferenceFrame
        sensorLocation = sensorLocation ?? sample.sensorLocation
        accelerationMagnitudes.append(sample.userAcceleration.magnitude)
        rotationMagnitudes.append(sample.rotationRate.magnitude)
        gravitySum = SensorVector3(
            x: gravitySum.x + sample.gravity.x,
            y: gravitySum.y + sample.gravity.y,
            z: gravitySum.z + sample.gravity.z)
        magneticCalibrationCounts[sample.magneticCalibrationAccuracy, default: 0] += 1
    }

    public func measurements() -> DeviceMotionAggregateMeasurements? {
        guard let acceleration = EmpiricalDistribution(values: accelerationMagnitudes),
            let rotation = EmpiricalDistribution(values: rotationMagnitudes),
            let referenceFrame,
            let sensorLocation
        else { return nil }
        let count = Double(accelerationMagnitudes.count)
        return DeviceMotionAggregateMeasurements(
            userAccelerationMagnitudeG: acceleration,
            rotationRateMagnitudeRadiansPerSecond: rotation,
            gravityMean: SensorVector3(
                x: gravitySum.x / count,
                y: gravitySum.y / count,
                z: gravitySum.z / count),
            attitudeReferenceFrame: referenceFrame,
            magneticCalibrationCounts: magneticCalibrationCounts,
            sensorLocation: sensorLocation,
            additionalBiasApplied: false,
            biasVectorSource: "not_exposed_by_core_motion"
        )
    }
}
