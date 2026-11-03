import Foundation

/// A framework-independent copy of one item retrieved from the recorded accelerometer.
public struct RecordedAccelerationWindowSample: Equatable, Sendable {
    public let sampleDate: Date
    public let sensorTimestamp: TimeInterval
    public let acceleration: SensorVector3
    public let recordingBatchIdentifier: UInt64

    public init(
        sampleDate: Date,
        sensorTimestamp: TimeInterval,
        acceleration: SensorVector3,
        recordingBatchIdentifier: UInt64
    ) {
        self.sampleDate = sampleDate
        self.sensorTimestamp = sensorTimestamp
        self.acceleration = acceleration
        self.recordingBatchIdentifier = recordingBatchIdentifier
    }
}

public struct RecordedAccelerationWindowTiming: Equatable, Sendable {
    public let wallClockFirstValid: Date?
    public let wallClockLastValid: Date?
    public let sensorTimestampFirst: TimeInterval?
    public let sensorTimestampLast: TimeInterval?
    public let sampleCount: Int
    public let expectedSampleCount: Int
    public let invalidSampleCount: Int
    public let duplicateSampleCount: Int
    public let sensorTimestampRegressionCount: Int
    public let temporalCoverageFraction: Double
    public let maximumSampleGapSeconds: TimeInterval?
    public let leadingGapSeconds: TimeInterval?
    public let trailingGapSeconds: TimeInterval?
    public let observedMedianSampleHz: Double?
    public let acquisitionQuality: SensorWindowAcquisitionQuality
}

public struct CompletedRecordedAccelerationWindow: Equatable, Sendable {
    public let wallClockBounds: DateInterval
    public let timing: RecordedAccelerationWindowTiming
    public let measurements: RecordedAccelerationAggregateMeasurements?
    public let timingContractVersion: String

    /// Copies a result record; acquisition and validation remain with the producing path.
    public init(
        wallClockBounds: DateInterval,
        timing: RecordedAccelerationWindowTiming,
        measurements: RecordedAccelerationAggregateMeasurements?,
        timingContractVersion: String
    ) {
        self.wallClockBounds = wallClockBounds
        self.timing = timing
        self.measurements = measurements
        self.timingContractVersion = timingContractVersion
    }
}

public struct RecordedAccelerationWindowProjectionResult: Equatable, Sendable {
    public let windows: [CompletedRecordedAccelerationWindow]
    public let inputSampleCount: Int
    public let unroutableSampleCount: Int
    public let cutoffExcludedSampleCount: Int
    public let conflictingSampleIdentityCount: Int
    public let conflictingSampleCount: Int

    /// Copies a result record; acquisition and validation remain with the producing path.
    public init(
        windows: [CompletedRecordedAccelerationWindow],
        inputSampleCount: Int,
        unroutableSampleCount: Int,
        cutoffExcludedSampleCount: Int,
        conflictingSampleIdentityCount: Int,
        conflictingSampleCount: Int
    ) {
        self.windows = windows
        self.inputSampleCount = inputSampleCount
        self.unroutableSampleCount = unroutableSampleCount
        self.cutoffExcludedSampleCount = cutoffExcludedSampleCount
        self.conflictingSampleIdentityCount = conflictingSampleIdentityCount
        self.conflictingSampleCount = conflictingSampleCount
    }
}

/// Deterministically projects retrieved recorder samples into closed wall-clock windows.
///
/// Unlike live motion windows, this batch projection has no callback-receipt or latency concept.
/// It never emits a bin whose upper bound is later than `finalizationCutoff`.
public struct RecordedAccelerationWindowProjection: Sendable {
    public static let nominalPeriod: TimeInterval = 0.02
    public static let windowDuration: TimeInterval = 60
    public static let timingContractVersion = "pulse.recorded_acceleration_window_timing.v1"

    private static let specification =
        SensorWindowSpecification(
            duration: windowDuration,
            nominalPeriod: nominalPeriod,
            contractVersion: timingContractVersion)

    public init() {}

    public func project(
        samples: [RecordedAccelerationWindowSample],
        finalizationCutoff: Date
    ) -> RecordedAccelerationWindowProjectionResult {
        let cutoff = finalizationCutoff.timeIntervalSinceReferenceDate
        guard cutoff.isFinite else {
            return RecordedAccelerationWindowProjectionResult(
                windows: [],
                inputSampleCount: samples.count,
                unroutableSampleCount: samples.count,
                cutoffExcludedSampleCount: 0,
                conflictingSampleIdentityCount: 0,
                conflictingSampleCount: 0)
        }

        let routable = samples.filter { Self.hasRepresentableWallBounds($0.sampleDate) }
        let deduplication = Self.deduplicate(routable)
        let ordered = deduplication.samples.sorted { lhs, rhs in
            Self.areInDeterministicOrder(lhs.sample, rhs.sample)
        }
        var bins: [TimeInterval: Bin] = [:]
        var cutoffExcludedSampleCount = 0

        for item in ordered {
            let sample = item.sample
            let wallTime = sample.sampleDate.timeIntervalSinceReferenceDate
            let binStart = floor(wallTime / Self.windowDuration) * Self.windowDuration
            guard binStart + Self.windowDuration <= cutoff else {
                cutoffExcludedSampleCount += 1 + item.duplicateSampleCount
                continue
            }

            bins[binStart, default: Bin()].duplicateSampleCount += item.duplicateSampleCount
            guard sample.sensorTimestamp.isFinite, sample.acceleration.isFinite else {
                bins[binStart, default: Bin()].invalidSampleCount += 1
                continue
            }
            bins[binStart, default: Bin()].samples.append(sample)
        }

        return RecordedAccelerationWindowProjectionResult(
            windows: bins.keys.sorted().map { start in
                finish(bin: bins[start] ?? Bin(), start: start)
            },
            inputSampleCount: samples.count,
            unroutableSampleCount: samples.count - routable.count,
            cutoffExcludedSampleCount: cutoffExcludedSampleCount,
            conflictingSampleIdentityCount: deduplication.conflictingSampleIdentityCount,
            conflictingSampleCount: deduplication.conflictingSampleCount)
    }

    private static func hasRepresentableWallBounds(_ date: Date) -> Bool {
        let time = date.timeIntervalSinceReferenceDate
        guard time.isFinite else { return false }
        let start = floor(time / windowDuration) * windowDuration
        let end = start + windowDuration
        return start.isFinite && end.isFinite && end > start
    }

    private func finish(bin: Bin, start: TimeInterval) -> CompletedRecordedAccelerationWindow {
        let bounds = start..<(start + Self.windowDuration)
        let dates = bin.samples.map(\.sampleDate)
        let summary = SensorTemporalSummary(
            orderedTimestamps: dates.map(\.timeIntervalSinceReferenceDate),
            bounds: bounds,
            specification: Self.specification)

        var reducer = RecordedAccelerationWindowReducer()
        for sample in bin.samples {
            reducer.ingest(
                .init(
                    acceleration: sample.acceleration,
                    recordingBatchIdentifier: sample.recordingBatchIdentifier))
        }
        return CompletedRecordedAccelerationWindow(
            wallClockBounds: DateInterval(
                start: Date(timeIntervalSinceReferenceDate: bounds.lowerBound),
                end: Date(timeIntervalSinceReferenceDate: bounds.upperBound)),
            timing: RecordedAccelerationWindowTiming(
                wallClockFirstValid: dates.first,
                wallClockLastValid: dates.last,
                sensorTimestampFirst: bin.samples.first?.sensorTimestamp,
                sensorTimestampLast: bin.samples.last?.sensorTimestamp,
                sampleCount: dates.count,
                expectedSampleCount: summary.expectedSampleCount,
                invalidSampleCount: bin.invalidSampleCount,
                duplicateSampleCount: bin.duplicateSampleCount,
                sensorTimestampRegressionCount: zip(
                    bin.samples, bin.samples.dropFirst()
                ).reduce(into: 0) { count, pair in
                    if pair.1.sensorTimestamp < pair.0.sensorTimestamp { count += 1 }
                },
                temporalCoverageFraction: summary.temporalCoverageFraction,
                maximumSampleGapSeconds: summary.maximumSampleGapSeconds,
                leadingGapSeconds: summary.leadingGapSeconds,
                trailingGapSeconds: summary.trailingGapSeconds,
                observedMedianSampleHz: summary.observedMedianSampleHz,
                acquisitionQuality: summary.acquisitionQuality),
            measurements: reducer.measurements(),
            timingContractVersion: Self.timingContractVersion)
    }

    private static func areInDeterministicOrder(
        _ lhs: RecordedAccelerationWindowSample, _ rhs: RecordedAccelerationWindowSample
    ) -> Bool {
        if lhs.sampleDate != rhs.sampleDate { return lhs.sampleDate < rhs.sampleDate }
        if lhs.sensorTimestamp.bitPattern != rhs.sensorTimestamp.bitPattern {
            return areDoublesInTotalOrder(lhs.sensorTimestamp, rhs.sensorTimestamp)
        }
        if lhs.recordingBatchIdentifier != rhs.recordingBatchIdentifier {
            return lhs.recordingBatchIdentifier < rhs.recordingBatchIdentifier
        }
        if lhs.acceleration.x.bitPattern != rhs.acceleration.x.bitPattern {
            return areDoublesInTotalOrder(lhs.acceleration.x, rhs.acceleration.x)
        }
        if lhs.acceleration.y.bitPattern != rhs.acceleration.y.bitPattern {
            return areDoublesInTotalOrder(lhs.acceleration.y, rhs.acceleration.y)
        }
        return areDoublesInTotalOrder(lhs.acceleration.z, rhs.acceleration.z)
    }

    private static func areDoublesInTotalOrder(_ lhs: Double, _ rhs: Double) -> Bool {
        if lhs.isFinite != rhs.isFinite { return lhs.isFinite }
        if lhs == rhs { return lhs.bitPattern < rhs.bitPattern }
        return lhs.isFinite ? lhs < rhs : lhs.bitPattern < rhs.bitPattern
    }

    private static func deduplicate(
        _ samples: [RecordedAccelerationWindowSample]
    ) -> DeduplicationResult {
        let groups = Dictionary(grouping: samples, by: RecordedSampleIdentity.init)
        var unique: [DeduplicatedSample] = []
        var conflictingSampleIdentityCount = 0
        var conflictingSampleCount = 0

        for identity in groups.keys.sorted() {
            guard let group = groups[identity]?.sorted(by: areInDeterministicOrder),
                let first = group.first
            else { continue }
            if group.dropFirst().allSatisfy({ isBitwiseIdentical($0, first) }) {
                unique.append(
                    DeduplicatedSample(sample: first, duplicateSampleCount: group.count - 1))
            } else {
                conflictingSampleIdentityCount += 1
                conflictingSampleCount += group.count
            }
        }
        return DeduplicationResult(
            samples: unique,
            conflictingSampleIdentityCount: conflictingSampleIdentityCount,
            conflictingSampleCount: conflictingSampleCount)
    }

    private static func isBitwiseIdentical(
        _ lhs: RecordedAccelerationWindowSample,
        _ rhs: RecordedAccelerationWindowSample
    ) -> Bool {
        lhs.sampleDate.timeIntervalSinceReferenceDate.bitPattern
            == rhs.sampleDate.timeIntervalSinceReferenceDate.bitPattern
            && lhs.sensorTimestamp.bitPattern == rhs.sensorTimestamp.bitPattern
            && lhs.acceleration.x.bitPattern == rhs.acceleration.x.bitPattern
            && lhs.acceleration.y.bitPattern == rhs.acceleration.y.bitPattern
            && lhs.acceleration.z.bitPattern == rhs.acceleration.z.bitPattern
            && lhs.recordingBatchIdentifier == rhs.recordingBatchIdentifier
    }

    private struct Bin {
        var samples: [RecordedAccelerationWindowSample] = []
        var invalidSampleCount = 0
        var duplicateSampleCount = 0
    }

    private struct DeduplicatedSample {
        let sample: RecordedAccelerationWindowSample
        let duplicateSampleCount: Int
    }

    private struct DeduplicationResult {
        let samples: [DeduplicatedSample]
        let conflictingSampleIdentityCount: Int
        let conflictingSampleCount: Int
    }

    private struct RecordedSampleIdentity: Hashable, Comparable {
        let recordingBatchIdentifier: UInt64
        let wallTimeBits: UInt64
        let sensorTimestampBits: UInt64

        init(_ sample: RecordedAccelerationWindowSample) {
            recordingBatchIdentifier = sample.recordingBatchIdentifier
            wallTimeBits = sample.sampleDate.timeIntervalSinceReferenceDate.bitPattern
            sensorTimestampBits = sample.sensorTimestamp.bitPattern
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.recordingBatchIdentifier != rhs.recordingBatchIdentifier {
                return lhs.recordingBatchIdentifier < rhs.recordingBatchIdentifier
            }
            if lhs.wallTimeBits != rhs.wallTimeBits { return lhs.wallTimeBits < rhs.wallTimeBits }
            return lhs.sensorTimestampBits < rhs.sensorTimestampBits
        }
    }
}
