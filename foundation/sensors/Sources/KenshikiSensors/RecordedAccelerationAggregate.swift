import CryptoKit
import Foundation

/// One copied raw accelerometer item retrieved from `CMSensorRecorder`.
///
/// Raw acceleration includes gravity. It is intentionally not interchangeable with Core Motion's
/// processed user acceleration and carries no rotation, gravity-separated, attitude, or rest fields.
public struct RecordedAccelerationAggregateSample: Equatable, Sendable {
    public let acceleration: SensorVector3
    public let recordingBatchIdentifier: UInt64

    public init(acceleration: SensorVector3, recordingBatchIdentifier: UInt64) {
        self.acceleration = acceleration
        self.recordingBatchIdentifier = recordingBatchIdentifier
    }
}

public struct RecordedAccelerationAggregateMeasurements: Equatable, Sendable {
    public let rawAccelerationMagnitudeG: EmpiricalDistribution
    public let rawAccelerationXG: EmpiricalDistribution
    public let rawAccelerationYG: EmpiricalDistribution
    public let rawAccelerationZG: EmpiricalDistribution
    public let recordedSampleCount: Int
    public let distinctRecordingBatchCount: Int
    public let recordingBatchIdentifierMinimum: UInt64
    public let recordingBatchIdentifierMaximum: UInt64
    public let recordingBatchIdentifierDigest: String
}

public struct RecordedAccelerationWindowReducer: BoundedWindowReducer {
    private var magnitudes: [Double] = []
    private var xValues: [Double] = []
    private var yValues: [Double] = []
    private var zValues: [Double] = []
    private var recordingBatchIdentifiers: Set<UInt64> = []

    public init() {}

    public func accepts(_ sample: RecordedAccelerationAggregateSample) -> Bool {
        sample.acceleration.isFinite
    }

    public mutating func ingest(_ sample: RecordedAccelerationAggregateSample) {
        recordingBatchIdentifiers.insert(sample.recordingBatchIdentifier)
        magnitudes.append(sample.acceleration.magnitude)
        xValues.append(sample.acceleration.x)
        yValues.append(sample.acceleration.y)
        zValues.append(sample.acceleration.z)
    }

    public func measurements() -> RecordedAccelerationAggregateMeasurements? {
        guard let magnitude = EmpiricalDistribution(values: magnitudes),
            let x = EmpiricalDistribution(values: xValues),
            let y = EmpiricalDistribution(values: yValues),
            let z = EmpiricalDistribution(values: zValues)
        else { return nil }
        let identifiers = recordingBatchIdentifiers.sorted()
        guard let minimum = identifiers.first, let maximum = identifiers.last else { return nil }
        var identifierBytes = Data(capacity: identifiers.count * MemoryLayout<UInt64>.size)
        for identifier in identifiers {
            var bigEndian = identifier.bigEndian
            withUnsafeBytes(of: &bigEndian) { identifierBytes.append(contentsOf: $0) }
        }
        let digest = SHA256.hash(data: identifierBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return RecordedAccelerationAggregateMeasurements(
            rawAccelerationMagnitudeG: magnitude,
            rawAccelerationXG: x,
            rawAccelerationYG: y,
            rawAccelerationZG: z,
            recordedSampleCount: magnitudes.count,
            distinctRecordingBatchCount: identifiers.count,
            recordingBatchIdentifierMinimum: minimum,
            recordingBatchIdentifierMaximum: maximum,
            recordingBatchIdentifierDigest: digest)
    }
}
