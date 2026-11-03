import Foundation

public struct SensorSourceSessionID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "A sensor source session ID must not be empty")
        self.rawValue = rawValue
    }

    public static func random() -> Self {
        .init(rawValue: UUID().uuidString.lowercased())
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A sensor source session ID must not be empty")
        }
        rawValue = value
    }
}

/// One fixed relationship between a source's monotonic clock and wall clock.
///
/// Window routing uses the monotonic clock. Wall-clock dates are a projection for lake queries and
/// presentation, so a wall-clock adjustment cannot move a sample into a different sensor window.
public struct SensorClockAnchor: Equatable, Sendable {
    public let sensorTimestamp: TimeInterval
    public let wallClock: Date

    public init(sensorTimestamp: TimeInterval, wallClock: Date) {
        precondition(sensorTimestamp.isFinite, "The sensor clock anchor must be finite")
        precondition(wallClock.timeIntervalSinceReferenceDate.isFinite, "The wall clock anchor must be finite")
        self.sensorTimestamp = sensorTimestamp
        self.wallClock = wallClock
    }

    public func wallClockDate(for sensorTimestamp: TimeInterval) -> Date {
        wallClock.addingTimeInterval(sensorTimestamp - self.sensorTimestamp)
    }
}

public struct TimestampedSensorSample<Value: Sendable>: Sendable {
    public let sensorTimestamp: TimeInterval
    public let receivedAt: Date
    public let systemUptimeAtReceipt: TimeInterval
    public let value: Value

    public init(
        sensorTimestamp: TimeInterval,
        receivedAt: Date,
        systemUptimeAtReceipt: TimeInterval,
        value: Value
    ) {
        self.sensorTimestamp = sensorTimestamp
        self.receivedAt = receivedAt
        self.systemUptimeAtReceipt = systemUptimeAtReceipt
        self.value = value
    }
}
