import Foundation
import CryptoKit
import BiometricInference
import BiometricCapture

struct FaceComparisonInput: Sendable, Codable {
    let operationID: UUID
    let reference: Data
    let referenceSHA256: String
    let selfie: Data
    let selfieSHA256: String
    let captureContext: FaceCaptureContext?
    let passport: SavedPassportCapture?
    let workflowID: UUID?
    let captureEventID: UUID?
    let selection: FaceCaptureSelectionRecord?
    init(operationID: UUID, reference: Data, referenceSHA256: String, selfie: Data,
         selfieSHA256: String, captureContext: FaceCaptureContext? = nil,
         passport: SavedPassportCapture? = nil, workflowID: UUID? = nil, captureEventID: UUID? = nil, selection: FaceCaptureSelectionRecord? = nil) {
        self.operationID = operationID
        self.reference = reference
        self.referenceSHA256 = referenceSHA256
        self.selfie = selfie
        self.selfieSHA256 = selfieSHA256
        self.captureContext = captureContext
        self.passport = passport
        self.workflowID = workflowID
        self.captureEventID = captureEventID
        self.selection = selection
    }
}

struct FaceCaptureContext: Sendable, Equatable, Codable {
    let captureID: UUID
    let selfieSHA256: String
    let receipt: SelfieAdmissionReceipt
    init(capture: CapturedSelfie) {
        captureID = capture.id
        selfieSHA256 = capture.sha256
        receipt = capture.admissionReceipt
    }
}

enum FaceTelemetryValue: Sendable, Equatable, Codable {
    case text(String), code(String), number(Double), range(Double, Double), integer(Int), unsigned(UInt64), flag(Bool), unavailable
}
struct FaceTelemetryField: Sendable, Equatable, Codable {
    let key: String
    let value: FaceTelemetryValue
}
struct FaceInputTelemetry: Sendable {
    let operationID: UUID
    let referenceSHA256: String
    let selfieSHA256: String
    let referenceBytes: Int
    let selfieBytes: Int
    let captureContext: FaceCaptureContext?
    var selection: FaceCaptureSelectionRecord? = nil
}
struct FaceVisualReportSection: Sendable, Equatable, Codable {
    let titleKey: String
    let fields: [FaceTelemetryField]
}
struct FaceVisualReport: Sendable, Equatable, Codable {
    let summary: String
    let sections: [FaceVisualReportSection]
}

struct FaceComparisonCompletion: Sendable, Codable {
    let operationID: UUID
    let referenceSHA256: String
    let selfieSHA256: String
    let score: Double
    let telemetry: [FaceTelemetryField]
    let resultSHA256: String?
    init(operationID: UUID, referenceSHA256: String, selfieSHA256: String, score: Double,
         telemetry: [FaceTelemetryField] = [], resultSHA256: String? = nil) {
        self.operationID = operationID
        self.referenceSHA256 = referenceSHA256
        self.selfieSHA256 = selfieSHA256
        self.score = score
        self.telemetry = telemetry
        self.resultSHA256 = resultSHA256
    }
}

struct FaceVisualAssessmentInput: Sendable {
    let operationID: UUID
    let reference: Data
    let referenceSHA256: String
    let selfie: Data
    let selfieSHA256: String
    let captureContext: FaceCaptureContext?
    let aura: FaceComparisonCompletion?
    let passport: SavedPassportCapture?
    let workflowID: UUID?
    init(source: FaceComparisonInput, aura: FaceComparisonCompletion? = nil) {
        operationID = source.operationID
        reference = source.reference
        referenceSHA256 = source.referenceSHA256
        selfie = source.selfie
        selfieSHA256 = source.selfieSHA256
        captureContext = source.captureContext
        self.aura = aura
        passport = source.passport
        workflowID = source.workflowID
    }
}

enum FaceVisualConsistency: String, Sendable, Codable { case consistent, inconsistent, uncertain }
enum FaceVisualIssue: String, Sendable, CaseIterable, Codable { case blur, poorLighting, occlusion, pose, lowResolution, other }
enum FaceVisualAssessmentFailure: Error { case modelUnavailable, invalidImage, resourceLimit, invalidResponse, sourceMismatch, engine }
enum FaceVisualAggregateStatus: String, Sendable, Codable { case processing, completed, partial, failed, cancelled }
struct FaceVisualAssessmentCompletion: Sendable, Equatable, Codable {
    let operationID: UUID
    let referenceSHA256: String
    let selfieSHA256: String
    let consistency: FaceVisualConsistency?
    let issues: [FaceVisualIssue]
    let durationMilliseconds: Double
    let report: FaceVisualReport?
    let telemetry: [FaceTelemetryField]
    let aggregateStatus: FaceVisualAggregateStatus?
    let completedTaskCount: Int?
    let totalTaskCount: Int?
    init(operationID: UUID, referenceSHA256: String, selfieSHA256: String,
         consistency: FaceVisualConsistency?, issues: [FaceVisualIssue], durationMilliseconds: Double,
         report: FaceVisualReport? = nil, telemetry: [FaceTelemetryField] = [],
         aggregateStatus: FaceVisualAggregateStatus? = nil, completedTaskCount: Int? = nil, totalTaskCount: Int? = nil) {
        self.operationID = operationID
        self.referenceSHA256 = referenceSHA256
        self.selfieSHA256 = selfieSHA256
        self.consistency = consistency
        self.issues = issues
        self.durationMilliseconds = durationMilliseconds
        self.report = report
        self.telemetry = telemetry
        self.aggregateStatus = aggregateStatus
        self.completedTaskCount = completedTaskCount
        self.totalTaskCount = totalTaskCount
    }
}

/// Owns AuraFace operations and validates readback of historical visual results.
@MainActor final class FaceComparisonController {
    enum Phase: Equatable { case idle, processing, completed(Double), failed(String) }
    enum VisualPhase: Equatable { case idle, processing, completed(FaceVisualAssessmentCompletion), unavailable, failed(String) }
    private(set) var phase: Phase = .idle
    private(set) var visualPhase: VisualPhase = .idle
    private(set) var durationMilliseconds: Double?
    private(set) var visualDurationMilliseconds: Double?
    private(set) var visualPartialResult: FaceVisualAssessmentCompletion?
    private(set) var inputTelemetry: FaceInputTelemetry?
    private(set) var auraTelemetry: [FaceTelemetryField] = []
    private(set) var telemetryExpanded = false
    private(set) var visualWaitingForComparison = false
    func toggleTelemetry() {
        guard inputTelemetry != nil else { return }
        telemetryExpanded.toggle()
        onChange?()
    }
    var isProcessing: Bool { phase == .processing || visualPhase == .processing || comparisonTask != nil }
    var hasResult: Bool {
        switch phase {
        case .completed, .failed: return true
        case .idle, .processing:
            switch visualPhase {
            case .completed, .failed: return true
            case .idle, .processing, .unavailable: return false
            }
        }
    }
    var canExportReport: Bool { hasResult && inputTelemetry != nil }
    var onChange: (() -> Void)?
    private let compare: @Sendable (FaceComparisonInput) async throws -> FaceComparisonCompletion
    private let comparePrepared: (@Sendable (FaceComparisonInput, FaceImagePreflightObservation) async throws -> FaceComparisonCompletion)?
    private let persistence: FaceWorkflowPersistence?
    private var pendingCheckpoint: SavedFaceCapture?
    private var comparisonTask: Task<Void, Never>?
    private var operationID: UUID?
    private var generation = UUID()
    private var pendingCapture: (id: UUID, referenceID: UUID, reference: Data, passport: SavedPassportCapture?, workflowID: UUID?)?

    init(compare: @escaping @Sendable (FaceComparisonInput) async throws -> FaceComparisonCompletion,
         persistence: FaceWorkflowPersistence? = nil,
         comparePrepared: (@Sendable (FaceComparisonInput, FaceImagePreflightObservation) async throws -> FaceComparisonCompletion)? = nil) {
        self.persistence = persistence
        self.compare = compare
        self.comparePrepared = comparePrepared
    }

    func beginCapture(referenceID: UUID, reference: Data, passport: SavedPassportCapture? = nil, workflowID: UUID? = nil) -> UUID {
        clear()
        let id = UUID()
        pendingCapture = (id, referenceID, reference, passport, workflowID)
        return id
    }

    func checkpointCapture(_ capture: CapturedSelfie, id: UUID, eventID: UUID? = nil, selection: FaceCaptureSelectionRecord? = nil) async throws {
        guard let pending = pendingCapture, pending.id == id else { throw CancellationError() }
        guard let persistence else { return }
        let input = FaceComparisonInput(operationID: id, reference: pending.reference,
            referenceSHA256: Self.digest(pending.reference), selfie: capture.encodedPNG,
            selfieSHA256: capture.sha256, captureContext: FaceCaptureContext(capture: capture),
            passport: pending.passport, workflowID: pending.workflowID, captureEventID: eventID, selection: selection)
        let record = try pendingCheckpoint ?? SavedFaceCapture(input: input)
        guard record.input.selfieSHA256 == input.selfieSHA256, record.input.selection == selection else { throw FaceWorkflowStorageFailure.conflict }
        pendingCheckpoint = record
        try await persistence.saveCapture(record)
        guard pendingCapture?.id == id else { throw CancellationError() }
        let saved = try await persistence.loadCapture(id)
        guard saved.input.selfieSHA256 == capture.sha256 else { throw FaceWorkflowStorageFailure.conflict }
    }

    func freezeComparisonSnapshot(operationID id: UUID, through boundary: UUID?, recovering: Bool = false) async throws {
        guard let persistence else { return }
        if try await persistence.loadSnapshot(id) != nil { return }
        let capture = try await persistence.loadCapture(id)
        let archive: WorkflowEvidenceArchive?
        var unavailable: SavedComparisonSnapshot.UnavailableReason?
        var unavailableBoundary: SavedComparisonSnapshot.ScanBoundary?
        if recovering, capture.input.workflowID != nil {
            let observation = try await SavedComparisonSnapshot.historicalBoundary(capture: capture, persistence: persistence)
            switch observation.outcome {
            case .found(let value): archive = value
            case .missing: archive = nil; unavailable = .missingBoundary
            case .superseded: archive = nil; unavailable = .supersededCapture
            case .capacity: archive = nil; unavailable = .capacity
            }
            if unavailable != nil { unavailableBoundary = observation.boundary }
        } else if let workflowID = capture.input.workflowID {
            guard let boundary else { throw FaceWorkflowStorageFailure.missingRecord }
            archive = try await WorkflowEvidenceArchive.load(persistence: persistence, workflowID: workflowID, through: boundary)
        } else { archive = nil }
        let snapshot = try SavedComparisonSnapshot(capture: capture, archive: archive, unavailableReason: unavailable, unavailableBoundary: unavailableBoundary)
        try await persistence.saveSnapshot(snapshot)
        guard let saved = try await persistence.loadSnapshot(id), try saved.manifest() == snapshot.manifest() else {
            throw FaceWorkflowStorageFailure.conflict
        }
    }

    func acceptCapture(id: UUID, currentReferenceID: UUID?, selfie: Data, selfieSHA256: String,
                       captureContext: FaceCaptureContext? = nil, selection: FaceCaptureSelectionRecord? = nil,
                       preparedSelfie: FaceImagePreflightObservation? = nil) -> Bool {
        guard let pending = pendingCapture, pending.id == id else { return false }
        pendingCapture = nil
        guard selection == nil || preparedSelfie != nil else {
            failSource()
            return false
        }
        guard pending.referenceID == currentReferenceID else {
            failSource()
            return false
        }
        let eventID = pendingCheckpoint?.input.captureEventID
        start(reference: pending.reference, selfie: selfie, selfieSHA256: selfieSHA256, captureContext: captureContext,
              id: pending.id, passport: pending.passport, workflowID: pending.workflowID, captureEventID: eventID,
              selection: selection, preparedSelfie: preparedSelfie)
        return true
    }

    func cancelCapture(id: UUID) {
        guard pendingCapture?.id == id else { return }
        clear()
    }

    func start(reference: Data, selfie: Data, selfieSHA256: String, captureContext: FaceCaptureContext? = nil,
               id: UUID = UUID(), passport: SavedPassportCapture? = nil, workflowID: UUID? = nil, captureEventID: UUID? = nil,
               selection: FaceCaptureSelectionRecord? = nil, preparedSelfie: FaceImagePreflightObservation? = nil) {
        clear()
        guard !reference.isEmpty, !selfie.isEmpty, Self.digest(selfie) == selfieSHA256,
              captureContext.map({ $0.selfieSHA256 == selfieSHA256 }) ?? true else {
            failSource()
            return
        }
        do {
            if let selection {
                guard let captureContext else { throw FaceWorkflowStorageFailure.invalidRecord }
                try selection.validate(selected: captureContext, imageSHA256: selfieSHA256)
            }
            if let preparedSelfie {
                guard preparedSelfie.sourceSHA256 == selfieSHA256,
                      selection?.selectedAlignedSHA256 == preparedSelfie.alignedSHA256 else { throw FaceWorkflowStorageFailure.invalidRecord }
            }
        } catch { failSource(); return }
        let input = FaceComparisonInput(operationID: id, reference: reference,
            referenceSHA256: Self.digest(reference), selfie: selfie, selfieSHA256: selfieSHA256, captureContext: captureContext,
            passport: passport, workflowID: workflowID, captureEventID: captureEventID, selection: selection)
        let generation = self.generation
        operationID = input.operationID
        inputTelemetry = FaceInputTelemetry(operationID: input.operationID,
            referenceSHA256: input.referenceSHA256, selfieSHA256: input.selfieSHA256,
            referenceBytes: reference.count, selfieBytes: selfie.count, captureContext: captureContext, selection: selection)
        phase = .processing
        visualPhase = .idle
        visualWaitingForComparison = false
        onChange?()
        guard self.generation == generation, operationID == input.operationID, phase == .processing else { return }
        startComparison(input, generation: generation, preparedSelfie: preparedSelfie)
    }

    func restore(_ capture: SavedFaceCapture, aura: SavedFaceStage?, liquid: SavedFaceStage?) throws {
        try capture.validate()
        try aura?.validate(for: capture); try liquid?.validate(for: capture)
        guard aura?.engine != .liquid, liquid?.engine != .aura else { throw FaceWorkflowStorageFailure.invalidRecord }
        clear()
        let input = capture.input
        operationID = input.operationID
        inputTelemetry = FaceInputTelemetry(operationID: input.operationID,
            referenceSHA256: input.referenceSHA256, selfieSHA256: input.selfieSHA256,
            referenceBytes: input.reference.count, selfieBytes: input.selfie.count, captureContext: input.captureContext, selection: input.selection)
        durationMilliseconds = aura?.durationMilliseconds
        if let result = aura?.aura { phase = .completed(result.score); auraTelemetry = result.telemetry }
        else { phase = .failed(aura?.errorCode ?? "comparison.error.interrupted") }
        visualDurationMilliseconds = liquid?.durationMilliseconds
        if let liquid, liquid.precedingAuraID != aura?.id { visualPhase = .failed("comparison.error.source") }
        else if let result = liquid?.liquid { visualPhase = .completed(result) }
        else if let liquid { visualPhase = .failed(liquid.errorCode ?? "comparison.error.interrupted") }
        else { visualPhase = .idle }
        onChange?()
    }

    func runSaved(_ capture: SavedFaceCapture) throws {
        try capture.validate()
        let input = capture.input
        start(reference: input.reference, selfie: input.selfie, selfieSHA256: input.selfieSHA256,
            captureContext: input.captureContext, id: input.operationID, passport: input.passport,
            workflowID: input.workflowID, captureEventID: input.captureEventID, selection: input.selection)
    }

    private func startComparison(_ input: FaceComparisonInput, generation: UUID, preparedSelfie: FaceImagePreflightObservation?) {
        let compare = self.compare
        let comparePrepared = self.comparePrepared
        comparisonTask = Task { [weak self] in
            let start = ContinuousClock.now
            let result: Result<FaceComparisonCompletion, Error>
            do {
                if let preparedSelfie {
                    guard let comparePrepared else { throw FaceWorkflowStorageFailure.invalidRecord }
                    result = .success(try await comparePrepared(input, preparedSelfie))
                } else { result = .success(try await compare(input)) }
            }
            catch { result = .failure(error) }
            guard let self, self.generation == generation, self.operationID == input.operationID, !Task.isCancelled else { return }
            self.comparisonTask = nil
            let elapsed = start.duration(to: .now).components
            self.durationMilliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            switch result {
            case .success(let value):
                if value.operationID == input.operationID,
                   value.referenceSHA256 == input.referenceSHA256, value.selfieSHA256 == input.selfieSHA256,
                   value.score.isFinite, (-1...1).contains(value.score) {
                    self.auraTelemetry = value.telemetry
                    self.phase = .completed(value.score)
                } else { self.phase = .failed("comparison.error.source") }
            case .failure(let error): self.phase = .failed(Self.failureKey(error))
            }
            self.onChange?()

        }
    }



    func reportForExport() -> String? {
        guard canExportReport, let input = inputTelemetry else { return nil }
        return FaceComparisonReportExport.make(input: input, phase: phase, visual: visualPhase,
            auraTelemetry: auraTelemetry, duration: durationMilliseconds,
            visualDuration: visualDurationMilliseconds, partial: visualPartialResult)
    }

    func clear() {
        generation = UUID()
        pendingCheckpoint = nil
        pendingCapture = nil
        operationID = nil
        let retiredComparison = comparisonTask
        comparisonTask = nil
        phase = .idle
        visualPhase = .idle
        durationMilliseconds = nil
        visualDurationMilliseconds = nil
        visualPartialResult = nil
        inputTelemetry = nil
        auraTelemetry = []
        telemetryExpanded = false
        visualWaitingForComparison = false
        retiredComparison?.cancel()
    }

    private func failSource() {
        phase = .failed("comparison.error.source")
        visualPhase = .failed("comparison.error.source")
        onChange?()
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func visualFailure(_ error: Error) -> VisualPhase {
        guard let reason = error as? FaceVisualAssessmentFailure else { return .failed("comparison.visual.error.engine") }
        switch reason {
        case .modelUnavailable: return .unavailable
        case .invalidImage: return .failed("comparison.error.image")
        case .resourceLimit: return .failed("comparison.visual.error.resources")
        case .invalidResponse: return .failed("comparison.visual.error.response")
        case .sourceMismatch: return .failed("comparison.error.source")
        case .engine: return .failed("comparison.visual.error.engine")
        }
    }
    private static func failureKey(_ error: Error) -> String {
        guard let reason = error as? FaceInferenceFailure else { return "comparison.error.engine" }
        switch reason {
        case .faceMissing: return "comparison.error.noFace"
        case .multipleFaces: return "comparison.error.multipleFaces"
        case .landmarksUnavailable, .alignmentFailed: return "comparison.error.alignment"
        case .modelUnavailable: return "comparison.error.model"
        case .invalidImage, .resourceLimit: return "comparison.error.image"
        case .sourceMismatch: return "comparison.error.source"
        case .inferenceFailed: return "comparison.error.engine"
        }
    }
}


/// A complete point-in-time report. Binary portraits and selfie pixels are never included.
enum FaceComparisonReportExport {
    static func make(input: FaceInputTelemetry, phase: FaceComparisonController.Phase,
                     visual: FaceComparisonController.VisualPhase, auraTelemetry: [FaceTelemetryField],
                     duration: Double?, visualDuration: Double?, partial: FaceVisualAssessmentCompletion? = nil) -> String? {
        var aura: [String: Any] = ["telemetry": fields(auraTelemetry), "durationMilliseconds": finite(duration)]
        switch phase {
        case .idle: aura["status"] = "idle"
        case .processing: aura["status"] = "processing"
        case .completed(let score): aura["status"] = "completed"; aura["cosineSimilarity"] = finite(score)
        case .failed(let code): aura["status"] = "failed"; aura["errorCode"] = code
        }
        var liquid: [String: Any] = ["durationMilliseconds": finite(visualDuration)]
        switch visual {
        case .idle: liquid["status"] = "retired"
        case .processing: liquid["status"] = "processing"
        case .unavailable: liquid["status"] = "unavailable"
        case .failed(let code): liquid["status"] = "failed"; liquid["errorCode"] = code
        case .completed(let value):
            liquid["status"] = value.aggregateStatus?.rawValue ?? "completed"
            liquid["historicalProfile"] = LegacyLiquidArchive.isHistorical(value)
            liquid["completedTaskCount"] = value.completedTaskCount
            liquid["totalTaskCount"] = value.totalTaskCount
            liquid["durationMilliseconds"] = finite(value.durationMilliseconds)
            liquid["consistency"] = value.consistency.map { $0.rawValue as Any } ?? NSNull()
            liquid["issues"] = value.issues.map(\.rawValue)
            liquid["telemetry"] = fields(value.telemetry)
            if let report = value.report {
                liquid["summary"] = report.summary
                liquid["sections"] = report.sections.map {
                    ["titleKey": $0.titleKey, "fields": fields($0.fields)] as [String: Any]
                }
            }
        }
        if let report = partial?.report {
            liquid["partialReport"] = ["summary": report.summary, "sections": report.sections.map {
                ["titleKey": $0.titleKey, "fields": fields($0.fields)] as [String: Any]
            }]
        }
        var receipt: Any = NSNull()
        if let value = input.captureContext?.receipt,
           let encoded = try? JSONEncoder().encode(value),
           let object = try? JSONSerialization.jsonObject(with: encoded) { receipt = object }
        var report: [String: Any] = [
            "schemaVersion": 1, "kind": "kenshiki.face-comparison-report",
            "operationID": input.operationID.uuidString,
            "reference": ["sha256": input.referenceSHA256, "encodedBytes": input.referenceBytes] as [String: Any],
            "selfie": ["sha256": input.selfieSHA256, "encodedBytes": input.selfieBytes] as [String: Any],
            "captureReceipt": receipt, "captureTelemetry": fields(FaceComparisonTelemetry.fields(input)),
            "aura": aura, "liquid": liquid
        ]
        if let selection = input.selection, let encoded = try? JSONEncoder().encode(selection),
           let object = try? JSONSerialization.jsonObject(with: encoded) { report["frameSelection"] = object }
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func fields(_ values: [FaceTelemetryField]) -> [[String: Any]] {
        values.map { field in
            let value: Any
            let type: String
            switch field.value {
            case .text(let text): type = "text"; value = text
            case .code(let code): type = "code"; value = code
            case .number(let number): type = number.isFinite ? "number" : "invalidNumber"; value = finite(number)
            case .range(let minimum, let maximum):
                type = minimum.isFinite && maximum.isFinite ? "range" : "invalidNumber"
                value = ["minimum": finite(minimum), "maximum": finite(maximum)]
            case .integer(let number): type = "integer"; value = number
            case .unsigned(let number): type = "unsigned"; value = number
            case .flag(let flag): type = "boolean"; value = flag
            case .unavailable: type = "unavailable"; value = NSNull()
            }
            return ["key": field.key, "type": type, "value": value]
        }
    }
    private static func finite(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return value
    }
}
