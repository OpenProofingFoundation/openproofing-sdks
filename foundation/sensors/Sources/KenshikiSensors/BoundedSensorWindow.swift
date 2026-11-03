import Foundation

public protocol BoundedWindowReducer {
    associatedtype Sample: Sendable
    associatedtype Measurements: Equatable, Sendable

    init()
    func accepts(_ sample: Sample) -> Bool
    mutating func ingest(_ sample: Sample)
    func measurements() -> Measurements?
}

public enum SensorWindowCompletion: String, Equatable, Sendable {
    case closed
    case sourceStopped = "source_stopped"
    case sourceChanged = "source_changed"
    case interrupted
}

public struct CompletedSensorWindow<Measurements: Equatable & Sendable>: Equatable, Sendable {
    public let sourceSessionID: SensorSourceSessionID
    public let monotonicBounds: Range<TimeInterval>
    public let wallClockBounds: DateInterval
    public let timing: SensorWindowTiming
    public let measurements: Measurements?
    public let completion: SensorWindowCompletion
    public let timingContractVersion: String

    /// Copies a result record; acquisition and validation remain with the producing path.
    public init(
        sourceSessionID: SensorSourceSessionID,
        monotonicBounds: Range<TimeInterval>,
        wallClockBounds: DateInterval,
        timing: SensorWindowTiming,
        measurements: Measurements?,
        completion: SensorWindowCompletion,
        timingContractVersion: String
    ) {
        self.sourceSessionID = sourceSessionID
        self.monotonicBounds = monotonicBounds
        self.wallClockBounds = wallClockBounds
        self.timing = timing
        self.measurements = measurements
        self.completion = completion
        self.timingContractVersion = timingContractVersion
    }
}

/// Pure, single-session tumbling-window routing.
///
/// The caller owns framework lifecycle and starts a new instance when source provenance changes.
/// No empty windows are synthesized across gaps; missing history must be represented explicitly by
/// the acquisition layer that knows whether the source was expected to be active.
public struct TumblingSensorWindow<Reducer: BoundedWindowReducer> {
    public let sourceSessionID: SensorSourceSessionID
    public let clockAnchor: SensorClockAnchor
    public let specification: SensorWindowSpecification

    private var currentBounds: Range<TimeInterval>?
    private var timing: SensorWindowTimingAccumulator?
    private var reducer = Reducer()

    public init(
        sourceSessionID: SensorSourceSessionID,
        clockAnchor: SensorClockAnchor,
        specification: SensorWindowSpecification
    ) {
        self.sourceSessionID = sourceSessionID
        self.clockAnchor = clockAnchor
        self.specification = specification
    }

    /// Ingests one source-ordered sample and returns a window only when this sample closes the
    /// preceding canonical bin. The new sample always belongs to the next half-open bin.
    public mutating func ingest(
        _ sample: TimestampedSensorSample<Reducer.Sample>
    ) -> CompletedSensorWindow<Reducer.Measurements>? {
        guard sample.sensorTimestamp.isFinite else {
            timing?.recordInvalid()
            return nil
        }
        let start = specification.canonicalWindowStart(containing: sample.sensorTimestamp)
        let end = start + specification.duration
        guard start.isFinite, end.isFinite, end > start else {
            timing?.recordInvalid()
            return nil
        }
        let wallStart = clockAnchor.wallClockDate(for: start).timeIntervalSinceReferenceDate
        let wallEnd = clockAnchor.wallClockDate(for: end).timeIntervalSinceReferenceDate
        guard wallStart.isFinite, wallEnd.isFinite, wallEnd > wallStart else {
            timing?.recordInvalid()
            return nil
        }
        let targetBounds = start..<end

        if currentBounds == nil {
            begin(targetBounds)
        } else if targetBounds != currentBounds {
            guard let currentBounds else { return nil }
            if targetBounds.lowerBound < currentBounds.lowerBound {
                timing?.recordInvalid()
                return nil
            }
            let completed = finish(completion: .closed)
            begin(targetBounds)
            ingestIntoCurrent(sample)
            return completed
        }

        ingestIntoCurrent(sample)
        return nil
    }

    public mutating func flush(
        completion: SensorWindowCompletion
    ) -> CompletedSensorWindow<Reducer.Measurements>? {
        guard currentBounds != nil else { return nil }
        return finish(completion: completion)
    }

    /// Records a rejected callback against the active window without allowing invalid clock data to
    /// route, open, or close a canonical bin.
    public mutating func recordInvalidSample() {
        timing?.recordInvalid()
    }

    private mutating func begin(_ bounds: Range<TimeInterval>) {
        currentBounds = bounds
        timing = SensorWindowTimingAccumulator(bounds: bounds, specification: specification)
        reducer = Reducer()
    }

    private mutating func ingestIntoCurrent(
        _ sample: TimestampedSensorSample<Reducer.Sample>
    ) {
        guard reducer.accepts(sample.value) else {
            timing?.recordInvalid()
            return
        }
        guard
            timing?.recordValid(
                sensorTimestamp: sample.sensorTimestamp,
                receivedAt: sample.receivedAt,
                systemUptimeAtReceipt: sample.systemUptimeAtReceipt) == true
        else { return }
        reducer.ingest(sample.value)
    }

    private mutating func finish(
        completion: SensorWindowCompletion
    ) -> CompletedSensorWindow<Reducer.Measurements>? {
        guard let bounds = currentBounds, let timing else { return nil }
        let completed = CompletedSensorWindow(
            sourceSessionID: sourceSessionID,
            monotonicBounds: bounds,
            wallClockBounds: DateInterval(
                start: clockAnchor.wallClockDate(for: bounds.lowerBound),
                end: clockAnchor.wallClockDate(for: bounds.upperBound)),
            timing: timing.result(clockAnchor: clockAnchor),
            measurements: reducer.measurements(),
            completion: completion,
            timingContractVersion: specification.contractVersion
        )
        currentBounds = nil
        self.timing = nil
        reducer = Reducer()
        return completed
    }
}
