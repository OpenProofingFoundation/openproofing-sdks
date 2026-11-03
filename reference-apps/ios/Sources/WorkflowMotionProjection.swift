import Foundation

/// A read-only projection of acknowledged, persisted workflow evidence. Raw records remain intact.
/// Durations join samples only within a recording segment and within 1.5 requested sample periods.
/// A resume creates a new segment; its unobserved interval is never counted as recorded coverage.
/// Unique samples must advance within each segment, as the persisted journal does. Repeated
/// samples are checked against a bounded recent tail; older or conflicting evidence fails.
struct WorkflowMotionProjection: Codable, Sendable {
    static let maximumEventCount = 100_000
    static let maximumRetainedSamplesPerSegment = 300
    static let maximumRetainedSegments = 32
    struct Range: Codable, Sendable, Equatable {
        private(set) var minimum: Double
        private(set) var maximum: Double
        private(set) var count: Int
        init(_ value: Double) { minimum = value; maximum = value; count = 1 }
        mutating func include(_ value: Double) {
            minimum = min(minimum, value); maximum = max(maximum, value); count += 1
        }
    }
    let workflowID: UUID
    let throughEventID: UUID
    let eventCount: Int
    let windowCount: Int
    let sampleCount: Int
    let duplicateSampleCount: Int
    /// Diagnostic only: proves projection does not retain the complete workflow's raw samples.
    let retainedSampleHighWatermark: Int
    let segmentCount: Int
    let eventsWithoutMotion: Int
    let magneticSampleCount: Int
    let uncalibratedWindowCount: Int
    let gapCount: Int
    let gapSeconds: Double
    let observedSeconds: Double
    let firstSampleAt: Date?
    let lastSampleAt: Date?
    let permissions: [String]
    let ceremonies: [String]
    let gravityAxes: [String]
    /// Sample ranges use device-frame axes. Summary ranges are extrema of stored window summaries.
    let ranges: [String: Range]

    static func load(persistence: FaceWorkflowPersistence, workflowID: UUID,
                     through eventID: UUID) async throws -> Self {
        var builder = Builder(workflowID: workflowID, throughEventID: eventID)
        var cursor = 0
        while true {
            try Task.checkCancellation()
            let page = try await persistence.loadEvents(workflowID, cursor)
            guard !page.isEmpty else { throw FaceWorkflowStorageFailure.missingRecord }
            for event in page {
                try Task.checkCancellation()
                guard cursor < maximumEventCount else { throw FaceWorkflowStorageFailure.capacity }
                try builder.include(event)
                cursor += 1
                if event.id == eventID { return builder.finish() }
            }
        }
    }

    /// Also exercises projection of imported/historical archives without modifying their samples.
    static func project(_ archive: WorkflowEvidenceArchive) throws -> Self {
        guard archive.schemaVersion == 1, !archive.truncated, archive.events.last?.id == archive.throughEventID else {
            throw FaceWorkflowStorageFailure.missingRecord
        }
        guard archive.events.count <= maximumEventCount else { throw FaceWorkflowStorageFailure.capacity }
        var builder = Builder(workflowID: archive.workflowID, throughEventID: archive.throughEventID)
        for event in archive.events { try builder.include(event) }
        return builder.finish()
    }

    private struct Builder {
        struct Segment {
            var tail: [Int64: SavedWorkflowMotion.Sample] = [:]
            var tailKeys: [Int64] = []
            var latest: (key: Int64, uptime: Double, period: Double)?
            var firstDate: Date?
            var lastDate: Date?
            var observed = 0.0, missing = 0.0
            var gaps = 0
        }
        let workflowID: UUID
        let throughEventID: UUID
        var eventIDs = Set<UUID>()
        var segments: [UUID: Segment] = [:]
        var retainedSegments: [UUID] = []
        var retainedSampleHighWatermark = 0
        var permissions = Set<String>()
        var ceremonies = Set<String>()
        var gravityAxes = Set<String>()
        var ranges: [String: Range] = [:]
        var windowKeys = Set<String>()
        var eventCount = 0, windowCount = 0, sampleCount = 0, duplicateSampleCount = 0
        var eventsWithoutMotion = 0, magneticSampleCount = 0, uncalibratedWindowCount = 0

        mutating func add(_ key: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            if ranges[key] == nil { ranges[key] = Range(value) }
            else { ranges[key]?.include(value) }
        }
        mutating func include(_ event: SavedWorkflowEvent) throws {
            try event.validate()
            guard event.workflowID == workflowID else { throw FaceWorkflowStorageFailure.invalidRecord }
            guard eventIDs.insert(event.id).inserted else { return }
            guard eventCount < WorkflowMotionProjection.maximumEventCount else { throw FaceWorkflowStorageFailure.capacity }
            eventCount += 1
            if segments[event.segmentID] == nil { segments[event.segmentID] = Segment() }
            if let permission = event.permissionStatus { permissions.insert(permission) }
            guard let motion = event.motion else { eventsWithoutMotion += 1; return }
            let windowKey = "\(event.segmentID):\(motion.startUptime):\(motion.endUptime):\(motion.summary.rawWindowSHA256)"
            if windowKeys.insert(windowKey).inserted {
                windowCount += 1
                if !motion.summary.magnetometerCalibrated { uncalibratedWindowCount += 1 }
                let summary = motion.summary
                ceremonies.insert(summary.ceremony.rawValue)
                if let axis = summary.gravityDominantAxis { gravityAxes.insert(axis) }
                add("requestedSampleRate", motion.requestedSampleRateHz)
                add("windowSampleCount", Double(summary.sampleCount))
                add("windowDuration", summary.durationSeconds)
                add("accelerationRMS", summary.accelerationRMSg)
                add("rotationRMS", summary.rotationRMSRadPerSecond)
                add("tremorRatio", summary.tremorBandRatio)
                add("gravityDominance", summary.gravityDominance)
                add("gravityDrift", summary.gravityDriftRadians)
                add("approachRMS", summary.approachRMSg)
                add("settleRatio", summary.settleRatio)
                add("magneticDelta", summary.magneticDeltaMicrotesla)
            }
            // Keep a small number of recently used segment tails, since a late retirement
            // event can interleave with a resumed segment. Eviction preserves aggregates and
            // the last timestamp. A later old duplicate then fails instead of being guessed.
            retainedSegments.removeAll { $0 == event.segmentID }
            retainedSegments.append(event.segmentID)
            if retainedSegments.count > WorkflowMotionProjection.maximumRetainedSegments {
                let evicted = retainedSegments.removeFirst()
                segments[evicted]?.tail.removeAll(keepingCapacity: false)
                segments[evicted]?.tailKeys.removeAll(keepingCapacity: false)
            }
            var segment = segments.removeValue(forKey: event.segmentID) ?? Segment()
            for sample in motion.samples {
                let uptime = motion.startUptime + sample.offsetSeconds
                // The journal's overlap tolerance is one nanosecond. Quantization also
                // avoids binary-addition drift when overlapping windows have different starts.
                guard let key = Int64(exactly: (uptime * 1_000_000_000).rounded()) else {
                    throw FaceWorkflowStorageFailure.invalidRecord
                }
                if let prior = segment.tail[key] {
                    guard prior.acceleration == sample.acceleration,
                          prior.rotation == sample.rotation, prior.gravity == sample.gravity,
                          prior.magneticMicrotesla == sample.magneticMicrotesla else {
                        throw FaceWorkflowStorageFailure.invalidRecord
                    }
                    duplicateSampleCount += 1; continue
                }
                let period = 1 / motion.requestedSampleRateHz
                if let previous = segment.latest {
                    guard key > previous.key else { throw FaceWorkflowStorageFailure.invalidRecord }
                    let delta = uptime - previous.uptime
                    let requestedPeriod = max(previous.period, period)
                    if delta <= requestedPeriod * 1.5 + 0.000000001 { segment.observed += delta }
                    else { segment.gaps += 1; segment.missing += max(0, delta - requestedPeriod) }
                }
                segment.latest = (key, uptime, period)
                let date = motion.startedAt.addingTimeInterval(sample.offsetSeconds)
                segment.firstDate = min(segment.firstDate ?? date, date)
                segment.lastDate = max(segment.lastDate ?? date, date)
                let cutoff = key - 5_000_000_000
                while let oldest = segment.tailKeys.first, oldest < cutoff {
                    segment.tail.removeValue(forKey: oldest)
                    segment.tailKeys.removeFirst()
                }
                while segment.tail.count >= WorkflowMotionProjection.maximumRetainedSamplesPerSegment,
                      let oldest = segment.tailKeys.first {
                    segment.tail.removeValue(forKey: oldest)
                    segment.tailKeys.removeFirst()
                }
                segment.tail[key] = sample
                segment.tailKeys.append(key)
                let retained = retainedSegments.reduce(segment.tail.count) {
                    $0 + (segments[$1]?.tail.count ?? 0)
                }
                retainedSampleHighWatermark = max(retainedSampleHighWatermark, retained)
                sampleCount += 1
                for (name, vector) in [("acceleration", sample.acceleration), ("rotation", sample.rotation), ("gravity", sample.gravity)] {
                    for (index, axis) in ["X", "Y", "Z"].enumerated() { add(name + axis, vector[index]) }
                    add(name + "Magnitude", vector.reduce(0) { hypot($0, $1) })
                }
                if sample.magneticMicrotesla != nil { magneticSampleCount += 1 }
                add("magneticMagnitude", sample.magneticMicrotesla)
            }
            segments[event.segmentID] = segment
        }
        func finish() -> WorkflowMotionProjection {
            var observed = 0.0, missing = 0.0
            var gaps = 0
            var first: Date?, last: Date?
            // Stable accumulation order keeps a reloaded projection bit-for-bit reproducible.
            for id in segments.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let segment = segments[id] else { continue }
                if let date = segment.firstDate { first = min(first ?? date, date) }
                if let date = segment.lastDate { last = max(last ?? date, date) }
                observed += segment.observed; missing += segment.missing; gaps += segment.gaps
            }
            return WorkflowMotionProjection(workflowID: workflowID, throughEventID: throughEventID,
                eventCount: eventCount, windowCount: windowCount, sampleCount: sampleCount,
                duplicateSampleCount: duplicateSampleCount, retainedSampleHighWatermark: retainedSampleHighWatermark,
                segmentCount: segments.count,
                eventsWithoutMotion: eventsWithoutMotion, magneticSampleCount: magneticSampleCount,
                uncalibratedWindowCount: uncalibratedWindowCount, gapCount: gaps, gapSeconds: missing,
                observedSeconds: observed, firstSampleAt: first, lastSampleAt: last,
                permissions: permissions.sorted(), ceremonies: ceremonies.sorted(), gravityAxes: gravityAxes.sorted(), ranges: ranges)
        }
    }
}
