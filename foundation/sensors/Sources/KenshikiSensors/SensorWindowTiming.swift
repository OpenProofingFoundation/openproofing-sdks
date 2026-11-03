import Foundation

public struct SensorWindowQualityPolicy: Equatable, Sendable {
    public let minimumExpectedCountFraction: Double
    public let minimumTemporalCoverageFraction: Double
    public let maximumGapPeriods: Double

    public init(
        minimumExpectedCountFraction: Double = 0.95,
        minimumTemporalCoverageFraction: Double = 0.95,
        maximumGapPeriods: Double = 3
    ) {
        precondition((0...1).contains(minimumExpectedCountFraction))
        precondition((0...1).contains(minimumTemporalCoverageFraction))
        precondition(maximumGapPeriods > 0 && maximumGapPeriods.isFinite)
        self.minimumExpectedCountFraction = minimumExpectedCountFraction
        self.minimumTemporalCoverageFraction = minimumTemporalCoverageFraction
        self.maximumGapPeriods = maximumGapPeriods
    }
}

public struct SensorWindowSpecification: Equatable, Sendable {
    /// Engineering limit on configured nominal count, not sensor resolution or an acquisition
    /// guarantee. It does not bound supernominal callbacks retained by a caller or reducer.
    public static let maximumExpectedSampleCount = 1_000_000

    public let duration: TimeInterval
    public let nominalPeriod: TimeInterval
    public let qualityPolicy: SensorWindowQualityPolicy
    public let contractVersion: String

    public init(
        duration: TimeInterval = 60,
        nominalPeriod: TimeInterval,
        qualityPolicy: SensorWindowQualityPolicy = .init(),
        contractVersion: String = "pulse.sensor_window_timing.v1"
    ) {
        precondition(duration > 0 && duration.isFinite)
        precondition(nominalPeriod > 0 && nominalPeriod.isFinite)
        precondition(nominalPeriod <= duration)
        precondition(!contractVersion.isEmpty)
        let expectedCount = (duration / nominalPeriod).rounded()
        precondition(
            expectedCount.isFinite && expectedCount >= 1
                && expectedCount <= Double(Self.maximumExpectedSampleCount),
            "The configured expected sample count must fit the supported engineering bound")
        precondition((nominalPeriod * qualityPolicy.maximumGapPeriods).isFinite)
        self.duration = duration
        self.nominalPeriod = nominalPeriod
        self.qualityPolicy = qualityPolicy
        self.contractVersion = contractVersion
    }

    public func canonicalWindowStart(containing sensorTimestamp: TimeInterval) -> TimeInterval {
        floor(sensorTimestamp / duration) * duration
    }

    public var expectedSampleCount: Int {
        max(1, Int((duration / nominalPeriod).rounded()))
    }
}

public enum SensorWindowAcquisitionQuality: String, Equatable, Sendable {
    case observed
    case partial
    case empty
}

public struct SensorWindowTiming: Equatable, Sendable {
    public let sensorTimestampFirst: TimeInterval?
    public let sensorTimestampLast: TimeInterval?
    public let wallClockFirstReceived: Date?
    public let wallClockLastReceived: Date?
    public let wallClockFirstValid: Date?
    public let wallClockLastValid: Date?
    public let callbackLatencyFirstSeconds: TimeInterval?
    public let callbackLatencyLastSeconds: TimeInterval?
    public let sampleCount: Int
    public let invalidSampleCount: Int
    public let duplicateSampleCount: Int
    public let outOfOrderSampleCount: Int
    public let expectedSampleCount: Int
    public let temporalCoverageFraction: Double
    public let maximumSampleGapSeconds: TimeInterval?
    public let leadingGapSeconds: TimeInterval?
    public let trailingGapSeconds: TimeInterval?
    public let requestedSampleHz: Double
    public let observedMedianSampleHz: Double?
    public let acquisitionQuality: SensorWindowAcquisitionQuality
}

struct SensorWindowTimingAccumulator {
    let bounds: Range<TimeInterval>
    let specification: SensorWindowSpecification
    private(set) var sensorTimestamps: [TimeInterval] = []
    private(set) var wallClocks: [Date] = []
    private(set) var receiptUptimes: [TimeInterval] = []
    private(set) var invalidSampleCount = 0
    private(set) var duplicateSampleCount = 0
    private(set) var outOfOrderSampleCount = 0

    mutating func recordValid(
        sensorTimestamp: TimeInterval,
        receivedAt: Date,
        systemUptimeAtReceipt: TimeInterval
    ) -> Bool {
        guard sensorTimestamp.isFinite,
            receivedAt.timeIntervalSinceReferenceDate.isFinite,
            systemUptimeAtReceipt.isFinite,
            sensorTimestamp >= bounds.lowerBound,
            sensorTimestamp < bounds.upperBound
        else {
            invalidSampleCount += 1
            return false
        }
        if let last = sensorTimestamps.last {
            if sensorTimestamp == last {
                duplicateSampleCount += 1
                return false
            }
            if sensorTimestamp < last {
                outOfOrderSampleCount += 1
                return false
            }
        }
        sensorTimestamps.append(sensorTimestamp)
        wallClocks.append(receivedAt)
        receiptUptimes.append(systemUptimeAtReceipt)
        return true
    }

    mutating func recordInvalid() {
        invalidSampleCount += 1
    }

    func result(clockAnchor: SensorClockAnchor) -> SensorWindowTiming {
        let summary = SensorTemporalSummary(
            orderedTimestamps: sensorTimestamps,
            bounds: bounds,
            specification: specification)

        let firstValid = sensorTimestamps.first.map(clockAnchor.wallClockDate(for:))
        let lastValid = sensorTimestamps.last.map(clockAnchor.wallClockDate(for:))
        let firstLatency = receiptUptimes.first.flatMap { receipt in
            sensorTimestamps.first.map { receipt - $0 }
        }
        let lastLatency = receiptUptimes.last.flatMap { receipt in
            sensorTimestamps.last.map { receipt - $0 }
        }
        return SensorWindowTiming(
            sensorTimestampFirst: sensorTimestamps.first,
            sensorTimestampLast: sensorTimestamps.last,
            wallClockFirstReceived: wallClocks.first,
            wallClockLastReceived: wallClocks.last,
            wallClockFirstValid: firstValid,
            wallClockLastValid: lastValid,
            callbackLatencyFirstSeconds: firstLatency,
            callbackLatencyLastSeconds: lastLatency,
            sampleCount: sensorTimestamps.count,
            invalidSampleCount: invalidSampleCount,
            duplicateSampleCount: duplicateSampleCount,
            outOfOrderSampleCount: outOfOrderSampleCount,
            expectedSampleCount: summary.expectedSampleCount,
            temporalCoverageFraction: summary.temporalCoverageFraction,
            maximumSampleGapSeconds: summary.maximumSampleGapSeconds,
            leadingGapSeconds: summary.leadingGapSeconds,
            trailingGapSeconds: summary.trailingGapSeconds,
            requestedSampleHz: 1 / specification.nominalPeriod,
            observedMedianSampleHz: summary.observedMedianSampleHz,
            acquisitionQuality: summary.acquisitionQuality
        )
    }
}
