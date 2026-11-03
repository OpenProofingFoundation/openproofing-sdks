import Foundation
import KenshikiMotion

enum FaceWorkflowStorageFailure: Error { case invalidRecord, missingRecord, conflict, capacity, unavailable }

struct FaceWorkflowPersistence: Sendable {
    let saveCapture: @Sendable (SavedFaceCapture) async throws -> Void
    let loadCapture: @Sendable (UUID) async throws -> SavedFaceCapture
    let saveStage: @Sendable (SavedFaceStage) async throws -> Void
    let loadStage: @Sendable (UUID, SavedFaceStage.Engine) async throws -> SavedFaceStage?
    let latestCaptureID: @Sendable () async throws -> UUID?
    let appendEvent: @Sendable (SavedWorkflowEvent) async throws -> Void
    var savePass: @Sendable (SavedLiquidPass) async throws -> Void = { _ in throw FaceWorkflowStorageFailure.unavailable }
    var loadPasses: @Sendable (UUID) async throws -> [SavedLiquidPass] = { _ in throw FaceWorkflowStorageFailure.unavailable }
    var loadEvents: @Sendable (UUID, Int) async throws -> [SavedWorkflowEvent] = { _, _ in throw FaceWorkflowStorageFailure.unavailable }
    var saveSnapshot: @Sendable (SavedComparisonSnapshot) async throws -> Void = { _ in throw FaceWorkflowStorageFailure.unavailable }
    var loadSnapshot: @Sendable (UUID) async throws -> SavedComparisonSnapshot? = { _ in throw FaceWorkflowStorageFailure.unavailable }
    static let unavailable = Self(
        saveCapture: { _ in throw FaceWorkflowStorageFailure.unavailable },
        loadCapture: { _ in throw FaceWorkflowStorageFailure.unavailable },
        saveStage: { _ in throw FaceWorkflowStorageFailure.unavailable },
        loadStage: { _, _ in throw FaceWorkflowStorageFailure.unavailable },
        latestCaptureID: { throw FaceWorkflowStorageFailure.unavailable },
        appendEvent: { _ in throw FaceWorkflowStorageFailure.unavailable })
}

struct SavedFaceCapture: Codable, Sendable {
    let version: Int
    let recordedAt: Date
    let input: FaceComparisonInput
    init(input: FaceComparisonInput, recordedAt: Date = Date()) throws {
        version = 1
        self.recordedAt = recordedAt
        self.input = input
        try validate()
    }
    func validate() throws {
        guard version == 1, Self.validDate(recordedAt), !input.reference.isEmpty, !input.selfie.isEmpty,
              input.reference.count + input.selfie.count <= 32 * 1024 * 1024,
              SavedPassportCapture.digest(input.reference) == input.referenceSHA256,
              SavedPassportCapture.digest(input.selfie) == input.selfieSHA256 else { throw FaceWorkflowStorageFailure.invalidRecord }
        guard input.captureEventID == nil || (input.captureContext != nil && input.workflowID != nil) else {
            throw FaceWorkflowStorageFailure.invalidRecord
        }
        if let passport = input.passport {
            try passport.validate()
            guard passport.nfc.portrait == input.reference else { throw FaceWorkflowStorageFailure.invalidRecord }
        }
        guard input.selection == nil || input.captureContext != nil else { throw FaceWorkflowStorageFailure.invalidRecord }
        if let capture = input.captureContext {
            guard capture.selfieSHA256 == input.selfieSHA256, capture.receipt.admissionValid else {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
            _ = try FaceComparisonHost.captureMeasurements(capture, selfieSHA256: input.selfieSHA256)
            try input.selection?.validate(selected: capture, imageSHA256: input.selfieSHA256)
        }
    }
    static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (0..<253402300800).contains(date.timeIntervalSince1970)
    }
}

/// One immutable attempt per engine. Failed attempts are durable too; retry appends a new attempt.
struct SavedFaceStage: Codable, Sendable {
    enum Engine: String, Codable, Sendable { case aura, liquid }
    let version: Int
    let id: UUID
    let operationID: UUID
    let engine: Engine
    let recordedAt: Date
    let durationMilliseconds: Double
    let aura: FaceComparisonCompletion?
    let liquid: FaceVisualAssessmentCompletion?
    let errorCode: String?
    let precedingAuraID: UUID?

    init(operationID: UUID, engine: Engine, durationMilliseconds: Double,
         aura: FaceComparisonCompletion? = nil, liquid: FaceVisualAssessmentCompletion? = nil,
         errorCode: String? = nil, precedingAuraID: UUID? = nil) {
        version = 1; id = UUID(); self.operationID = operationID; self.engine = engine
        recordedAt = Date(); self.durationMilliseconds = durationMilliseconds
        self.aura = aura; self.liquid = liquid; self.errorCode = errorCode; self.precedingAuraID = precedingAuraID
    }

    func validate(for capture: SavedFaceCapture) throws {
        guard version == 1, operationID == capture.input.operationID, SavedFaceCapture.validDate(recordedAt),
              durationMilliseconds.isFinite, durationMilliseconds >= 0,
              errorCode.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { throw FaceWorkflowStorageFailure.invalidRecord }
        if let aura {
            guard engine == .aura, liquid == nil, errorCode == nil, precedingAuraID == nil,
                  aura.operationID == operationID, aura.referenceSHA256 == capture.input.referenceSHA256,
                  aura.selfieSHA256 == capture.input.selfieSHA256, aura.score.isFinite, (-1...1).contains(aura.score),
                  aura.resultSHA256.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? false else {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
        } else if let liquid {
            guard engine == .liquid, errorCode == nil, precedingAuraID != nil,
                  liquid.operationID == operationID, liquid.referenceSHA256 == capture.input.referenceSHA256,
                  liquid.selfieSHA256 == capture.input.selfieSHA256,
                  liquid.durationMilliseconds.isFinite, liquid.durationMilliseconds >= 0,
                  liquid.report != nil || liquid.consistency != nil else { throw FaceWorkflowStorageFailure.invalidRecord }
            if let status = liquid.aggregateStatus {
                guard let completed = liquid.completedTaskCount, let total = liquid.totalTaskCount,
                      (1...8).contains(total), (0...total).contains(completed) else { throw FaceWorkflowStorageFailure.invalidRecord }
                switch status {
                case .completed: guard completed == total else { throw FaceWorkflowStorageFailure.invalidRecord }
                case .partial: guard completed > 0, completed < total else { throw FaceWorkflowStorageFailure.invalidRecord }
                case .failed: guard completed == 0 else { throw FaceWorkflowStorageFailure.invalidRecord }
                case .processing, .cancelled: break
                }
            } else if liquid.completedTaskCount != nil || liquid.totalTaskCount != nil {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
        } else {
            guard errorCode != nil, (engine == .aura ? precedingAuraID == nil : precedingAuraID != nil) else {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
        }
    }
}

/// A workflow event contains typed action codes or the full bounded Pulse motion window.
/// Text entered by the holder is never copied into interaction events.
struct SavedWorkflowEvent: Codable, Sendable {
    let version: Int
    let id: UUID
    let workflowID: UUID
    let segmentID: UUID
    let captureID: UUID?
    let imageSHA256: String?
    let location: SavedWorkflowLocation?
    let mrz: SavedMRZCapture?
    let gapBeforeSeconds: Double?
    let occurredAt: Date
    let uptimeSeconds: Double
    let action: String
    let permissionStatus: String?
    let motion: SavedWorkflowMotion?
    init(workflowID: UUID, action: String, permissionStatus: String? = nil, motion: SavedWorkflowMotion? = nil,
         segmentID: UUID = UUID(), captureID: UUID? = nil, imageSHA256: String? = nil,
         location: SavedWorkflowLocation? = nil, mrz: SavedMRZCapture? = nil, gapBeforeSeconds: Double? = nil,
         id: UUID = UUID(), occurredAt: Date = Date(), uptimeSeconds: Double = ProcessInfo.processInfo.systemUptime) {
        version = 1; self.id = id; self.workflowID = workflowID; self.occurredAt = occurredAt
        self.uptimeSeconds = uptimeSeconds; self.action = action
        self.permissionStatus = permissionStatus; self.motion = motion; self.segmentID = segmentID
        self.captureID = captureID; self.imageSHA256 = imageSHA256; self.location = location
        self.gapBeforeSeconds = gapBeforeSeconds; self.mrz = mrz
    }
    func replacingMotion(_ value: SavedWorkflowMotion?, gap: Double?) -> Self {
        Self(workflowID: workflowID, action: action, permissionStatus: permissionStatus, motion: value,
            segmentID: segmentID, captureID: captureID, imageSHA256: imageSHA256, location: location, mrz: mrz,
            gapBeforeSeconds: gap, id: id, occurredAt: occurredAt, uptimeSeconds: uptimeSeconds)
    }
    func validate() throws {
        guard version == 1, SavedFaceCapture.validDate(occurredAt), uptimeSeconds.isFinite, uptimeSeconds >= 0,
              !action.isEmpty, action.utf8.count <= 128,
              action.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              permissionStatus.map({ ["notRequested", "requesting", "authorized", "denied", "unavailable"].contains($0) }) ?? true else {
            throw FaceWorkflowStorageFailure.invalidRecord
        }
        guard imageSHA256.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true,
              imageSHA256 == nil || captureID != nil,
              gapBeforeSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw FaceWorkflowStorageFailure.invalidRecord }
        try motion?.validate()
        try location?.validate()
        if let mrz {
            try mrz.validate()
            guard action == "passport.mrz.captured", captureID == mrz.id, imageSHA256 == nil else {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
        }
    }
}

struct SavedWorkflowMotion: Codable, Sendable {
    struct Sample: Codable, Sendable {
        let offsetSeconds: Double
        let acceleration: [Double]
        let rotation: [Double]
        let gravity: [Double]
        let magneticMicrotesla: Double?
    }
    let startedAt: Date
    let endedAt: Date
    let startUptime: Double
    let endUptime: Double
    let requestedSampleRateHz: Double
    let samples: [Sample]
    let summary: PulseCeremonyMotionSummary

    init(_ capture: PulseCeremonyMotionCapture) {
        self.init(window: capture.window, startUptime: capture.startUptime, endUptime: capture.endUptime)
    }
    init(window: PulseCeremonyMotionWindow, startUptime: Double, endUptime: Double) {
        startedAt = window.startedAt; endedAt = window.endedAt
        self.startUptime = startUptime; self.endUptime = endUptime
        requestedSampleRateHz = window.requestedSampleRateHz
        samples = window.samples.map { .init(offsetSeconds: $0.offsetSeconds,
            acceleration: [$0.userAcceleration.x, $0.userAcceleration.y, $0.userAcceleration.z],
            rotation: [$0.rotationRate.x, $0.rotationRate.y, $0.rotationRate.z],
            gravity: [$0.gravity.x, $0.gravity.y, $0.gravity.z], magneticMicrotesla: $0.magneticFieldMicrotesla) }
        summary = PulseCeremonyMotionSummarizer.summarize(window)
    }
    func validate() throws {
        guard SavedFaceCapture.validDate(startedAt), SavedFaceCapture.validDate(endedAt), endedAt >= startedAt,
              startUptime.isFinite, startUptime >= 0, endUptime.isFinite, endUptime >= startUptime,
              endUptime - startUptime <= 5.000001, requestedSampleRateHz == 50,
              abs(endedAt.timeIntervalSince(startedAt) - (endUptime - startUptime)) < 0.00001,
              samples.first?.offsetSeconds == 0,
              abs((samples.last?.offsetSeconds ?? -1) - (endUptime - startUptime)) < 0.00001,
              (1...300).contains(samples.count) else { throw FaceWorkflowStorageFailure.invalidRecord }
        var previous = -1.0
        for sample in samples {
            guard sample.offsetSeconds.isFinite, sample.offsetSeconds >= 0, sample.offsetSeconds > previous,
                  [sample.acceleration, sample.rotation, sample.gravity].allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
                  sample.magneticMicrotesla.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw FaceWorkflowStorageFailure.invalidRecord }
            previous = sample.offsetSeconds
        }
        let window = PulseCeremonyMotionWindow(ceremony: summary.ceremony, startedAt: startedAt, endedAt: endedAt,
            requestedSampleRateHz: requestedSampleRateHz, samples: samples.map {
                .init(offsetSeconds: $0.offsetSeconds, userAcceleration: SIMD3($0.acceleration[0], $0.acceleration[1], $0.acceleration[2]),
                    rotationRate: SIMD3($0.rotation[0], $0.rotation[1], $0.rotation[2]),
                    gravity: SIMD3($0.gravity[0], $0.gravity[1], $0.gravity[2]), magneticFieldMicrotesla: $0.magneticMicrotesla)
            }, magnetometerCalibrated: summary.magnetometerCalibrated)
        guard PulseCeremonyMotionSummarizer.summarize(window) == summary else { throw FaceWorkflowStorageFailure.invalidRecord }
    }
    func after(_ watermark: Double?) -> Self? {
        guard let watermark else { return self }
        let remaining = samples.filter { startUptime + $0.offsetSeconds > watermark + 0.000000001 }
        guard let first = remaining.first, let last = remaining.last else { return nil }
        let offset = first.offsetSeconds
        let window = PulseCeremonyMotionWindow(ceremony: summary.ceremony,
            startedAt: startedAt.addingTimeInterval(offset), endedAt: startedAt.addingTimeInterval(last.offsetSeconds),
            requestedSampleRateHz: requestedSampleRateHz, samples: remaining.map {
                .init(offsetSeconds: $0.offsetSeconds - offset,
                    userAcceleration: SIMD3($0.acceleration[0], $0.acceleration[1], $0.acceleration[2]),
                    rotationRate: SIMD3($0.rotation[0], $0.rotation[1], $0.rotation[2]),
                    gravity: SIMD3($0.gravity[0], $0.gravity[1], $0.gravity[2]), magneticFieldMicrotesla: $0.magneticMicrotesla)
            }, magnetometerCalibrated: summary.magnetometerCalibrated)
        return Self(window: window, startUptime: startUptime + offset, endUptime: startUptime + last.offsetSeconds)
    }

}

/// Immutable evidence boundary for one comparison. Capture binding and workflow timing remain separate.
struct SavedComparisonSnapshot: Codable, Sendable {
    let operationID: UUID
    let recordedAt: Date
    let referenceSHA256: String
    let selfieSHA256: String
    enum UnavailableReason: String, Codable, Sendable { case missingBoundary, supersededCapture, capacity }
    let archive: WorkflowEvidenceArchive?
    struct ScanBoundary: Codable, Sendable, Equatable {
        let sequence: Int
        let throughEventID: UUID?
        let prefixSHA256: String
    }
    let unavailableReason: UnavailableReason?
    let unavailableBoundary: ScanBoundary?

    init(capture: SavedFaceCapture, archive: WorkflowEvidenceArchive?, recordedAt: Date = Date(),
         unavailableReason: UnavailableReason? = nil, unavailableBoundary: ScanBoundary? = nil) throws {
        operationID = capture.input.operationID; self.recordedAt = recordedAt
        referenceSHA256 = capture.input.referenceSHA256; selfieSHA256 = capture.input.selfieSHA256
        self.archive = archive; self.unavailableReason = unavailableReason; self.unavailableBoundary = unavailableBoundary
        try validate(capture: capture)
    }
    func validate(capture: SavedFaceCapture) throws {
        guard operationID == capture.input.operationID, referenceSHA256 == capture.input.referenceSHA256,
              selfieSHA256 == capture.input.selfieSHA256, SavedFaceCapture.validDate(recordedAt) else {
            throw FaceWorkflowStorageFailure.invalidRecord
        }
        if let workflowID = capture.input.workflowID {
            if unavailableReason != nil {
                guard archive == nil, let boundary = unavailableBoundary, (0...4096).contains(boundary.sequence),
                      (boundary.sequence == 0) == (boundary.throughEventID == nil),
                      boundary.prefixSHA256.count == 64, boundary.prefixSHA256.allSatisfy(\.isHexDigit) else {
                    throw FaceWorkflowStorageFailure.invalidRecord
                }
                return
            }
            guard unavailableBoundary == nil, let archive, archive.schemaVersion == 1, archive.workflowID == workflowID,
                  !archive.truncated, !archive.events.isEmpty, archive.events.count <= 4096,
                  archive.nextSequence == archive.events.count + 1,
                  archive.events.last?.id == archive.throughEventID,
                  ["selfie.compare", "comparison.retry"].contains(archive.events.last?.action ?? ""),
                  Set(archive.events.map(\.id)).count == archive.events.count else { throw FaceWorkflowStorageFailure.invalidRecord }
            for event in archive.events {
                try event.validate()
                guard event.workflowID == workflowID else { throw FaceWorkflowStorageFailure.invalidRecord }
            }
            if let captureEventID = capture.input.captureEventID {
                guard let index = archive.events.firstIndex(where: { $0.id == captureEventID }),
                      index < archive.events.count - 1 else { throw FaceWorkflowStorageFailure.invalidRecord }
            }
        } else if archive != nil || unavailableReason != nil || unavailableBoundary != nil { throw FaceWorkflowStorageFailure.invalidRecord }
    }
    enum HistoricalBoundary: Sendable {
        case found(WorkflowEvidenceArchive)
        case missing, superseded, capacity
    }

    /// One scanner is shared by async workflow recovery and synchronous repository verification.
    struct HistoricalScanner {
        let capture: SavedFaceCapture
        private var events: [SavedWorkflowEvent] = []
        private var byteCount = 0
        private var foundCapture = false
        private var prefixDigests: [String] = []
        private var lastEventID: UUID?
        init(capture: SavedFaceCapture) { self.capture = capture }
        var count: Int { prefixDigests.count }
        var boundary: ScanBoundary {
            .init(sequence: count, throughEventID: lastEventID,
                prefixSHA256: SavedPassportCapture.digest(Data(prefixDigests.joined(separator: "\n").utf8)))
        }
        mutating func consume(_ event: SavedWorkflowEvent) throws -> HistoricalBoundary? {
            guard let workflowID = capture.input.workflowID else { throw FaceWorkflowStorageFailure.invalidRecord }
            try event.validate()
            guard event.workflowID == workflowID else { throw FaceWorkflowStorageFailure.invalidRecord }
            prefixDigests.append(try FaceComparisonHost.sourceDigest(event)); lastEventID = event.id
            byteCount += try JSONEncoder().encode(event).count
            guard byteCount <= 8 * 1024 * 1024, count <= 4096 else { return .capacity }
            events.append(event)
            if let captureEventID = capture.input.captureEventID, event.id == captureEventID {
                guard !foundCapture, event.action == "selfie.captured",
                      event.captureID == capture.input.captureContext?.captureID,
                      event.imageSHA256 == capture.input.selfieSHA256 else { throw FaceWorkflowStorageFailure.invalidRecord }
                foundCapture = true
            } else if foundCapture {
                if ["selfie.captured", "selfie.retake"].contains(event.action) { return .superseded }
                if event.action == "selfie.compare" {
                    return .found(WorkflowEvidenceArchive(schemaVersion: 1, workflowID: workflowID,
                        throughEventID: event.id, events: events, truncated: false, nextSequence: events.count + 1))
                }
            }
            return nil
        }
    }

    /// Stop at this capture's first Compare event. A later retake cannot become its boundary.
    static func historicalBoundary(capture: SavedFaceCapture, persistence: FaceWorkflowPersistence) async throws -> (outcome: HistoricalBoundary, boundary: ScanBoundary) {
        var scanner = HistoricalScanner(capture: capture)
        guard let workflowID = capture.input.workflowID else { return (.missing, scanner.boundary) }
        while scanner.count < 4096 {
            let page = try await persistence.loadEvents(workflowID, scanner.count)
            if page.isEmpty { return (.missing, scanner.boundary) }
            for event in page {
                if let outcome = try scanner.consume(event) { return (outcome, scanner.boundary) }
                if scanner.count == 4096 { return (.capacity, scanner.boundary) }
            }
        }
        return (.capacity, scanner.boundary)
    }

    func manifest() throws -> Data {
        var object: [String: Any] = ["schemaVersion": 1, "operationID": operationID.uuidString,
            "referenceSHA256": referenceSHA256, "selfieSHA256": selfieSHA256,
            "recordedAt": ISO8601DateFormatter().string(from: recordedAt), "lastSequence": archive?.events.count ?? 0]
        if let archive {
            object["workflowID"] = archive.workflowID.uuidString
            object["throughEventID"] = archive.throughEventID.uuidString
            object["archiveSHA256"] = try FaceComparisonHost.sourceDigest(archive)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
