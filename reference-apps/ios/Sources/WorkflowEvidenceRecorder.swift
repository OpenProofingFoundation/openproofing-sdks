import Foundation

struct SavedWorkflowLocation: Codable, Sendable {
    enum Permission: String, Codable, Sendable { case notRequested, authorized, denied, restricted, unavailable }
    enum Accuracy: String, Codable, Sendable { case full, reduced, unavailable }
    struct Fix: Codable, Sendable {
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        let horizontalAccuracyMeters: Double
        let altitudeMeters: Double?
        let verticalAccuracyMeters: Double?
        let simulatedBySoftware: Bool?
        let producedByAccessory: Bool?
    }
    let permission: Permission
    let accuracy: Accuracy
    let observedAt: Date
    let fix: Fix?
    let providerErrorCode: Int?
    var usable: Bool {
        permission == .authorized && fix.map { observedAt.timeIntervalSince($0.timestamp) >= -1 && observedAt.timeIntervalSince($0.timestamp) <= 15 } == true
    }
    func validate() throws {
        guard SavedFaceCapture.validDate(observedAt), fix == nil || permission == .authorized else {
            throw FaceWorkflowStorageFailure.invalidRecord
        }
        if let fix {
            guard SavedFaceCapture.validDate(fix.timestamp), fix.latitude.isFinite, (-90...90).contains(fix.latitude),
                  fix.longitude.isFinite, (-180...180).contains(fix.longitude),
                  fix.horizontalAccuracyMeters.isFinite, fix.horizontalAccuracyMeters >= 0,
                  fix.altitudeMeters.map(\.isFinite) ?? true,
                  fix.verticalAccuracyMeters.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  (fix.altitudeMeters == nil) == (fix.verticalAccuracyMeters == nil) else {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
        }
    }
}

/// Bounded FIFO; a failed write stays at the head and is retried with the same ID and bytes.
actor WorkflowEvidenceJournal {
    private struct Pending { let source: SavedWorkflowEvent; var prepared: SavedWorkflowEvent? }
    private let append: @Sendable (SavedWorkflowEvent) async throws -> Void
    private var queue: [Pending] = []
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var draining = false
    private var watermark: (segment: UUID, uptime: Double)?
    private(set) var isRetired = false
    private var retirementWaiters: [CheckedContinuation<Void, Never>] = []
    init(append: @escaping @Sendable (SavedWorkflowEvent) async throws -> Void) { self.append = append }

    func record(_ event: SavedWorkflowEvent) async throws {
        guard !isRetired else { throw CancellationError() }
        try event.validate()
        guard queue.count < 32 else { throw FaceWorkflowStorageFailure.capacity }
        queue.append(Pending(source: event))
        try await flush()
    }

    func flush() async throws {
        guard !isRetired else { throw CancellationError() }
        guard !queue.isEmpty else { return }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            if !draining { draining = true; Task { await drain() } }
        }
    }

    /// Fence late producers, discard retries, and await the one active storage call before erasure.
    func retire() async {
        isRetired = true
        guard draining else { finishRetirement(); return }
        await withCheckedContinuation { retirementWaiters.append($0) }
    }

    private func finishRetirement() {
        queue.removeAll(); watermark = nil; draining = false
        let waiting = waiters; waiters = []
        for waiter in waiting { waiter.resume(throwing: CancellationError()) }
        let retiring = retirementWaiters; retirementWaiters = []
        for waiter in retiring { waiter.resume() }
    }

    private func drain() async {
        while !queue.isEmpty {
            guard !isRetired else { finishRetirement(); return }
            if queue[0].prepared == nil {
                let source = queue[0].source
                let previous = watermark.flatMap { $0.segment == source.segmentID ? $0.uptime : nil }
                let motion = source.motion?.after(previous)
                let gap = previous.flatMap { prior in motion.map { max(0, $0.startUptime - prior - 0.02) } }
                queue[0].prepared = source.replacingMotion(motion, gap: gap)
            }
            guard let event = queue[0].prepared else { return }
            do {
                try await append(event)
                guard !isRetired else { finishRetirement(); return }
                if let motion = event.motion { watermark = (event.segmentID, motion.endUptime) }
                queue.removeFirst()
            } catch {
                guard !isRetired else { finishRetirement(); return }
                draining = false
                let waiting = waiters; waiters = []
                for waiter in waiting { waiter.resume(throwing: error) }
                return
            }
        }
        draining = false
        let waiting = waiters; waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

@MainActor struct WorkflowSensorPort {
    let start: (@escaping @MainActor () -> Void) -> Void
    let stop: () -> Void
    let motion: () -> SavedWorkflowMotion?
    let motionPermission: () -> String
    let location: () -> SavedWorkflowLocation
}

/// Session-wide acquisition. The bounded witness is drained continuously, not only at selfie time.
@MainActor final class WorkflowEvidenceRecorder {
    enum Status { case idle, recording, failed }
    private(set) var status: Status = .idle
    private(set) var latestEvent: SavedWorkflowEvent?
    var onChange: (() -> Void)?
    private let sensors: WorkflowSensorPort
    private var journal: WorkflowEvidenceJournal
    private let persistence: FaceWorkflowPersistence
    private var workflowID: UUID?
    private var segmentID = UUID()
    private var ticker: Task<Void, Never>?
    private var erasing = false

    init(sensors: WorkflowSensorPort, persistence: FaceWorkflowPersistence) {
        self.sensors = sensors
        self.persistence = persistence
        journal = WorkflowEvidenceJournal(append: persistence.appendEvent)
    }

    func start(workflowID: UUID, resume: Bool = false) async throws {
        guard !erasing else { throw CancellationError() }
        ticker?.cancel()
        sensors.stop()
        self.workflowID = workflowID
        segmentID = UUID()
        try await record(resume ? "workflow.resumed" : "workflow.started")
        guard self.workflowID == workflowID else { throw CancellationError() }
        sensors.start { [weak self] in
            guard let self, self.workflowID == workflowID else { return }
            Task { try? await self.record("sensor.permission_changed") }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.workflowID == workflowID else { return }
                do { try await self.record("sensor.window") } catch { continue }
            }
        }
    }

    @discardableResult
    func record(_ action: String, captureID: UUID? = nil, imageSHA256: String? = nil, mrz: SavedMRZCapture? = nil) async throws -> SavedWorkflowEvent {
        guard !erasing else { throw CancellationError() }
        guard let workflowID else { throw FaceWorkflowStorageFailure.missingRecord }
        if case .failed = status {
            do { try await journal.flush() }
            catch { throw error }
        }
        let event = SavedWorkflowEvent(workflowID: workflowID, action: action,
            permissionStatus: sensors.motionPermission(), motion: sensors.motion(), segmentID: segmentID,
            captureID: captureID ?? mrz?.id, imageSHA256: imageSHA256, location: sensors.location(), mrz: mrz)
        do {
            try await journal.record(event)
            guard self.workflowID == workflowID else { return event }
            latestEvent = event; status = .recording; onChange?()
            return event
        } catch {
            if self.workflowID == workflowID { status = .failed; onChange?() }
            throw error
        }
    }

    /// Called before deleting the store. A fresh journal cannot inherit old retry buffers or watermarks.
    func discardForErasure() async {
        let retiring = journal
        if erasing { await retiring.retire(); return }
        erasing = true
        workflowID = nil
        ticker?.cancel(); ticker = nil
        sensors.stop()
        await retiring.retire()
        journal = WorkflowEvidenceJournal(append: persistence.appendEvent)
        latestEvent = nil; status = .idle; erasing = false
        onChange?()
    }

    func export(through event: SavedWorkflowEvent) async throws -> WorkflowEvidenceArchive {
        do {
            try await journal.flush()
            return try await WorkflowEvidenceArchive.load(persistence: persistence,
                workflowID: event.workflowID, through: event.id)
        } catch {
            status = .failed; onChange?()
            throw error
        }
    }

    func motionProjection(through event: SavedWorkflowEvent) async throws -> WorkflowMotionProjection {
        try await journal.flush()
        return try await WorkflowMotionProjection.load(persistence: persistence,
            workflowID: event.workflowID, through: event.id)
    }

    @discardableResult
    func stop(_ action: String) -> Task<Void, Never>? {
        guard let workflowID else { return nil }
        let event = SavedWorkflowEvent(workflowID: workflowID, action: action,
            permissionStatus: sensors.motionPermission(), motion: sensors.motion(), segmentID: segmentID,
            location: sensors.location())
        self.workflowID = nil
        ticker?.cancel(); ticker = nil
        sensors.stop()
        status = .idle; onChange?()
        return Task { [weak self, journal] in
            do { try await journal.record(event) }
            catch {
                guard let self, self.workflowID == nil, self.journal === journal else { return }
                self.status = .failed; self.onChange?()
            }
        }
    }
}

/// Bounded snapshot ending at an acknowledged event; the caller can page remaining records later.
struct WorkflowEvidenceArchive: Codable, Sendable {
    let schemaVersion: Int
    let workflowID: UUID
    let throughEventID: UUID
    let events: [SavedWorkflowEvent]
    let truncated: Bool
    let nextSequence: Int

    static func load(persistence: FaceWorkflowPersistence, workflowID: UUID,
                     through eventID: UUID) async throws -> Self {
        var events: [SavedWorkflowEvent] = []
        var bytes = 0
        var cursor = 0
        let encoder = JSONEncoder()
        while events.count < 4096 {
            let page = try await persistence.loadEvents(workflowID, cursor)
            guard !page.isEmpty else { throw FaceWorkflowStorageFailure.missingRecord }
            for event in page {
                try event.validate()
                guard event.workflowID == workflowID else { throw FaceWorkflowStorageFailure.invalidRecord }
                let count = try encoder.encode(event).count
                if bytes + count > 8 * 1024 * 1024 || events.count == 4096 {
                    return Self(schemaVersion: 1, workflowID: workflowID, throughEventID: eventID,
                        events: events, truncated: true, nextSequence: cursor + 1)
                }
                events.append(event); cursor += 1; bytes += count
                if event.id == eventID {
                    return Self(schemaVersion: 1, workflowID: workflowID, throughEventID: eventID,
                        events: events, truncated: false, nextSequence: cursor + 1)
                }
            }
        }
        return Self(schemaVersion: 1, workflowID: workflowID, throughEventID: eventID,
            events: events, truncated: true, nextSequence: cursor + 1)
    }
}
