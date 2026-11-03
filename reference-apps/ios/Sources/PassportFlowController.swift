import Foundation
import PassportSDK

struct PassportManualAccessFields: Equatable, Codable, Sendable {
    let documentNumber: String
    let birthDateYYMMDD: String
    let expiryDateYYMMDD: String
}

struct AcceptedPassportPortrait: Sendable {
    let attemptID: UUID
    let read: PassportReadObservation
    let printedMRZ: PassportMRZObservation?
    let capturedAt: Date
    let serverVerification: PassportServerVerification?

    init(attemptID: UUID, read: PassportReadObservation, printedMRZ: PassportMRZObservation?, capturedAt: Date = Date(), serverVerification: PassportServerVerification? = nil) {
        self.attemptID = attemptID
        self.read = read
        self.printedMRZ = printedMRZ
        self.capturedAt = capturedAt
        self.serverVerification = serverVerification
    }
}

@MainActor struct PassportFlowEffects {
    var serverRead: ((PassportAccessKey, URL,
        @escaping @MainActor @Sendable (PassportReadEvent) -> Void,
        @escaping @MainActor @Sendable (PassportServerStage) -> Void,
        @escaping @MainActor @Sendable (PassportReadObservation) throws -> Void) async throws -> PassportServerRead)? = nil
    var available: Bool = true
    let startCamera: (
        @escaping @MainActor @Sendable ([[String]]) -> Void,
        @escaping @MainActor @Sendable () -> Void
    ) async throws -> Void
    let stopCamera: () async -> Void
    let read: (
        PassportAccessKey, URL, @escaping @MainActor @Sendable (PassportReadEvent) -> Void
    ) async throws -> PassportReadObservation
}

enum PassportLocalAdmissionFailure: Error { case unverifiedEvidence, correspondence }

enum PassportFlowIntent {
    case visible, hidden, beginJourney, startMRZ, confirmKey, scan, cancelScan, retryRead, retrySave, retryMRZSave, usePortrait, restart, discard, cancel
    case manualKey(PassportManualAccessFields)
}

/// Coordinates explicit access-key confirmation, camera handoff and one verified NFC operation.
/// OS sheet resign-active is not backgrounding. Only the host's actual background/tab-hide
/// notification withdraws this operation; no view or application-global state is consulted here.
@MainActor final class PassportFlowController {
    enum Phase: Equatable { case start, mrz, savingMRZ, mrzSaveFailure, confirm, ready, scanning, saving, saveFailure, result, failure }
    enum Failure: Equatable {
        case invalidAccessKey, camera, trustAnchorsRequired, unavailable, interrupted
        case server(PassportServerFailure)
        case read(PassportReadFailure), unverifiedEvidence, portraitUnavailable, correspondence
    }

    private(set) var phase: Phase = .start
    private(set) var failure: Failure?
    private(set) var correspondenceMismatchedFields: [PassportCorrespondenceObservation.Field] = []
    private(set) var event: PassportReadEvent?
    private(set) var printedMRZ: PassportMRZObservation?
    private(set) var accessFields: PassportManualAccessFields?
    private(set) var result: PassportReadObservation?
    private(set) var resultServerVerification: PassportServerVerification?
    private(set) var serverRejection: PassportServerRejection?
    private(set) var serverStage: PassportServerStage?
    var canEnterManualAccessKey: Bool {
        guard usable else { return false }
        switch phase {
        case .start, .mrz, .confirm: return true
        case .failure: return failure == .camera || failure == .invalidAccessKey
        default: return false
        }
    }
    private var resultCapturedAt: Date?
    private var pendingMRZ: SavedMRZCapture?
    private var mrzCommitted = false
    private var afterMRZCommit: Phase = .confirm
    var persistMRZ: ((SavedMRZCapture) async throws -> Void)?
    var scanAfterMRZCommit = false
    private var pendingCheckpoint: AcceptedPassportPortrait?
    /// The guided host installs this before acquisition. Completion is published only after commit.
    var beforeAction: ((String) async throws -> Void)?
    private var actionTask: Task<Void, Never>?
    var persistCompletedRead: ((AcceptedPassportPortrait) async throws -> Void)?
    private(set) var attemptID = UUID()
    private(set) var trustAnchorsURL: URL?
    var hasPortrait: Bool {
        guard let result, result.portrait?.isEmpty == false, result.dg2?.isEmpty == false,
              let digest = result.dg2Digest, !digest.isEmpty,
              let algorithm = result.dg2DigestAlgorithm else { return false }
        return ["SHA-1", "SHA-256", "SHA-384", "SHA-512"].contains(algorithm)
    }
    var onChange: (() -> Void)?
    var onAccepted: ((AcceptedPassportPortrait) -> Void)?
    var onClose: (() -> Void)?
    var diagnosticObserver: @Sendable (PassportServerDiagnostic) -> Void = { _ in
        // An observer is optional; the diagnostic always writes persistent OSLog first.
    }

    private let effects: PassportFlowEffects
    private var key: PassportAccessKey?
    private var visible = false
    private var backgrounded = false
    private var closed = false
    private var beginWhenVisible = false
    private var operation: Task<Void, Never>?
    private var retirement: Task<Void, Never>?

    init(effects: PassportFlowEffects) { self.effects = effects }

    /// Hosts explicitly provision a local trust file; there is no ambient bundle/store lookup.
    func supplyTrustAnchors(_ url: URL?) {
        guard !closed else { return }
        if phase == .scanning { reset(failure: .interrupted) }
        trustAnchorsURL = url?.isFileURL == true ? url : nil
        render()
    }

    func send(_ intent: PassportFlowIntent) {
        let code: String?
        switch intent {
        case .scan: code = "passport.scan"
        case .usePortrait: code = "passport.continue"
        default: code = nil
        }
        if let code, let beforeAction {
            guard actionTask == nil, usable else { return }
            let token = attemptID
            actionTask = Task { [weak self] in
                do {
                    try await beforeAction(code)
                    guard let self, self.attemptID == token, !Task.isCancelled else { return }
                    self.actionTask = nil; self.perform(intent)
                } catch {
                    guard let self, self.attemptID == token else { return }
                    self.actionTask = nil; self.failure = .unavailable; self.render()
                }
            }
            return
        }
        perform(intent)
    }

    private func perform(_ intent: PassportFlowIntent) {
        if case .hidden = intent { visible = false }
        guard !closed else { return }
        switch intent {
        case .visible:
            visible = true
            if beginWhenVisible, usable, phase == .start {
                beginWhenVisible = false
                beginMRZ()
            }
        case .beginJourney:
            guard phase == .start, !backgrounded else { return }
            beginWhenVisible = true
            if usable {
                beginWhenVisible = false
                beginMRZ()
            }
        case .hidden: reset(failure: nil)
        case .restart, .discard: reset(failure: nil)
        case .cancel:
            closed = true
            let close = onClose
            onClose = nil
            onAccepted = nil
            reset(failure: nil)
            close?()
        case .startMRZ:
            guard usable, phase == .start || phase == .failure else { return }
            beginMRZ()
        case .manualKey(let fields):
            guard canEnterManualAccessKey else { return }
            retire()
            clearEvidence()
            do {
                key = try PassportAccessKey(documentNumber: fields.documentNumber,
                    birthDateYYMMDD: fields.birthDateYYMMDD, expiryDateYYMMDD: fields.expiryDateYYMMDD)
                accessFields = fields
                phase = .confirm
                failure = nil
            } catch { phase = .failure; failure = .invalidAccessKey }
            render()
        case .confirmKey:
            guard usable, phase == .confirm, key != nil else { return }
            if persistMRZ != nil, !mrzCommitted, let fields = accessFields {
                do {
                    pendingMRZ = try pendingMRZ ?? SavedMRZCapture(fields: fields, lines: printedMRZ?.normalizedLines)
                    beginMRZCommit(then: .ready)
                } catch { phase = .mrzSaveFailure; render() }
            } else { phase = .ready; render() }
        case .scan:
            guard usable, phase == .ready, let key else { return }
            guard effects.available else {
                phase = .failure
                failure = .unavailable
                render()
                return
            }
            guard let url = trustAnchorsURL, url.isFileURL else {
                phase = .failure
                failure = .trustAnchorsRequired
                render()
                return
            }
            beginRead(key: key, trust: url)
        case .retryRead:
            guard usable, phase == .failure else { return }
            serverRejection = nil
            phase = key == nil ? .start : .ready
            failure = nil
            render()
        case .retryMRZSave:
            guard usable, phase == .mrzSaveFailure, pendingMRZ != nil else { return }
            beginMRZCommit(then: afterMRZCommit)
        case .retrySave:
            guard usable, phase == .saveFailure, let pendingCheckpoint else { return }
            let attempt = attemptID
            phase = .saving
            render()
            guard current(attempt, .saving) else { return }
            operation = Task { [weak self] in await self?.commitCompletedRead(pendingCheckpoint, attempt: attempt) }
        case .cancelScan:
            guard phase == .scanning else { return }
            retire()
            phase = .ready
            event = nil
            serverStage = nil
            failure = nil
            render()
        case .usePortrait:
            guard usable, phase == .result, let result, let resultCapturedAt, hasPortrait else { return }
            let accepted = AcceptedPassportPortrait(attemptID: attemptID, read: result, printedMRZ: printedMRZ, capturedAt: resultCapturedAt, serverVerification: resultServerVerification)
            let deliver = onAccepted
            onAccepted = nil
            onClose = nil
            closed = true
            retire()
            clearEvidence()
            phase = .start
            render()
            guard visible, !backgrounded else { return }
            deliver?(accepted)
        }
    }

    func restoreMRZ(_ capture: SavedMRZCapture) throws {
        guard !closed, phase == .start else { throw FaceWorkflowStorageFailure.conflict }
        try capture.validate()
        retire()
        key = try PassportAccessKey(documentNumber: capture.fields.documentNumber,
            birthDateYYMMDD: capture.fields.birthDateYYMMDD, expiryDateYYMMDD: capture.fields.expiryDateYYMMDD)
        accessFields = capture.fields; printedMRZ = capture.printedMRZ
        pendingMRZ = capture; mrzCommitted = true; phase = .confirm
        render()
    }

    private func beginMRZCommit(then next: Phase) {
        guard let pendingMRZ, let persistMRZ else { return }
        afterMRZCommit = next; phase = .savingMRZ
        let attempt = attemptID
        render()
        guard current(attempt, .savingMRZ) else { return }
        operation = Task { [weak self] in
            do {
                try await persistMRZ(pendingMRZ)
                guard let self, self.current(attempt, .savingMRZ), !Task.isCancelled else { return }
                self.operation = nil; self.mrzCommitted = true; self.phase = next; self.render()
                if next == .ready, self.scanAfterMRZCommit { self.send(.scan) }
            } catch {
                guard let self, self.current(attempt, .savingMRZ), !Task.isCancelled else { return }
                self.operation = nil; self.phase = .mrzSaveFailure; self.render()
            }
        }
    }

    /// Call only for actual scene backgrounding, never CoreNFC's system-sheet resign-active.
    func setBackgrounded(_ value: Bool) {
        backgrounded = value
        if value, !closed { reset(failure: .interrupted) }
    }

    /// A new journey must not acquire camera/NFC resources until the retired operation settles.
    func waitForRetirement() async { await retirement?.value }

    private var usable: Bool { visible && !backgrounded && !closed }

    private func beginMRZ() {
        retire()
        clearEvidence()
        phase = .mrz
        failure = nil
        let attempt = attemptID
        let priorStop = retirement
        render()
        guard current(attempt, .mrz) else { return }
        operation = Task { [weak self] in
            await priorStop?.value
            guard let self, self.current(attempt, .mrz), !Task.isCancelled else { return }
            do {
                try await self.effects.startCamera(
                    { [weak self] candidates in self?.received(candidates, attempt: attempt) },
                    { [weak self] in self?.cameraFailed(attempt: attempt) })
            } catch {
                guard self.current(attempt, .mrz), !Task.isCancelled else { return }
                self.cameraFailed(attempt: attempt)
            }
        }
    }

    private func received(_ candidates: [[String]], attempt: UUID) {
        guard current(attempt, .mrz), let mrz = PassportMRZOCRParser.parseComplete(candidates: candidates),
              mrz.completeness == .complete,
              let prepared = try? PassportAccessKey(documentNumber: mrz.documentNumber,
                birthDateYYMMDD: mrz.birthDateYYMMDD, expiryDateYYMMDD: mrz.expiryDateYYMMDD) else { return }
        retire()
        printedMRZ = mrz
        key = prepared
        accessFields = PassportManualAccessFields(documentNumber: mrz.documentNumber,
            birthDateYYMMDD: mrz.birthDateYYMMDD, expiryDateYYMMDD: mrz.expiryDateYYMMDD)
        if persistMRZ != nil, let accessFields {
            do {
                pendingMRZ = try SavedMRZCapture(fields: accessFields, lines: mrz.normalizedLines)
                beginMRZCommit(then: .confirm)
            } catch { phase = .mrzSaveFailure; render() }
        } else { phase = .confirm; render() }
    }

    private func cameraFailed(attempt: UUID) {
        guard current(attempt, .mrz) else { return }
        retire()
        phase = .failure
        failure = .camera
        render()
    }

    private func beginRead(key: PassportAccessKey, trust: URL) {
        retire()
        phase = .scanning
        serverRejection = nil
        failure = nil
        correspondenceMismatchedFields = []
        event = nil
        let attempt = attemptID
        let priorStop = retirement
        render()
        guard current(attempt, .scanning) else { return }
        operation = Task { [weak self] in
            await priorStop?.value
            guard let self, self.current(attempt, .scanning), !Task.isCancelled else { return }
            do {
                let receive: @MainActor @Sendable (PassportReadEvent) -> Void = { [weak self] event in
                    guard let self, self.current(attempt, .scanning) else { return }
                    self.event = event
                    self.render()
                }
                let read: PassportReadObservation
                let verification: PassportServerVerification?
                if let serverRead = self.effects.serverRead {
                    let value = try await serverRead(key, trust, receive, { [weak self] stage in
                        guard let self, self.current(attempt, .scanning) else { return }
                        self.serverStage = stage; self.render()
                    }, { [weak self] read in
                        guard let self else { throw CancellationError() }
                        try self.admitLocalRead(read, attempt: attempt)
                    })
                    read = value.read; verification = value.verification
                    do {
                        try value.verification.validate(securityObject: read.securityObject, capturedAt: Date())
                        PassportServerDiagnostic.flow(.returnedBinding, passed: true).record(observer: self.diagnosticObserver)
                    } catch {
                        PassportServerDiagnostic.flow(.returnedBinding, passed: false).record(observer: self.diagnosticObserver)
                        throw error
                    }
                } else {
                    read = try await self.effects.read(key, trust, receive)
                    verification = nil
                }
                guard self.current(attempt, .scanning), !Task.isCancelled else { return }
                // Injected effects cannot turn a failed/missing proof into a verified result.
                let integrityValid = (read.basicAccessControl == .succeeded || read.pace == .succeeded) &&
                    read.countrySigningChain == .succeeded && read.documentSignature == .succeeded &&
                    read.dataGroupHashes == .succeeded && read.activeAuthentication != .failed &&
                    read.chipAuthentication != .failed && !read.securityObject.isEmpty
                PassportServerDiagnostic.flow(.evidenceIntegrity, passed: integrityValid).record(observer: self.diagnosticObserver)
                guard self.current(attempt, .scanning), !Task.isCancelled else { return }
                guard integrityValid else {
                    self.operation = nil
                    self.phase = .failure
                    self.failure = .unverifiedEvidence
                    self.render()
                    return
                }
                let corresponds = self.corresponds(read)
                guard self.current(attempt, .scanning), !Task.isCancelled else { return }
                guard corresponds else {
                    self.operation = nil
                    self.phase = .failure
                    self.failure = .correspondence
                    self.render()
                    return
                }
                let capture = AcceptedPassportPortrait(attemptID: attempt, read: read,
                    printedMRZ: self.printedMRZ, capturedAt: Date(), serverVerification: verification)
                await self.commitCompletedRead(capture, attempt: attempt)
            } catch {
                guard self.current(attempt, .scanning), !Task.isCancelled else { return }
                self.operation = nil
                if let local = error as? PassportLocalAdmissionFailure {
                    self.phase = .failure
                    self.failure = local == .correspondence ? .correspondence : .unverifiedEvidence
                    self.serverStage = nil; self.render(); return
                }
                if let rejected = error as? PassportServerRejection {
                    self.serverRejection = rejected
                    self.phase = .failure; self.failure = .server(rejected.failure); self.serverStage = nil; self.render()
                    return
                }
                if let server = error as? PassportServerFailure {
                    self.phase = .failure; self.failure = .server(server); self.serverStage = nil; self.render()
                    return
                }
                let failure = (error as? PassportReadFailure) ?? (error is CancellationError ? .cancelled : .readFailed)
                self.phase = failure == .cancelled ? .ready : .failure
                self.failure = failure == .cancelled ? nil : .read(failure)
                self.render()
            }
        }
    }

    private func commitCompletedRead(_ capture: AcceptedPassportPortrait, attempt: UUID) async {
        guard usable, attemptID == attempt, !Task.isCancelled else { return }
        pendingCheckpoint = capture
        event = nil
        if let persistCompletedRead {
            phase = .saving
            render()
            guard current(attempt, .saving), !Task.isCancelled else { return }
            do { try await persistCompletedRead(capture) }
            catch {
                guard current(attempt, .saving), !Task.isCancelled else { return }
                PassportServerDiagnostic.flow(.checkpoint, passed: false).record(observer: diagnosticObserver)
                guard current(attempt, .saving), !Task.isCancelled else { return }
                operation = nil
                phase = .saveFailure
                render()
                return
            }
            guard current(attempt, .saving), !Task.isCancelled else { return }
            PassportServerDiagnostic.flow(.checkpoint, passed: true).record(observer: diagnosticObserver)
            guard current(attempt, .saving), !Task.isCancelled else { return }
        }
        result = capture.read
        resultServerVerification = capture.serverVerification
        serverStage = nil
        resultCapturedAt = capture.capturedAt
        pendingCheckpoint = nil
        operation = nil
        phase = .result
        render()
    }

    private func admitLocalRead(_ read: PassportReadObservation, attempt: UUID) throws {
        guard current(attempt, .scanning), !Task.isCancelled else { throw CancellationError() }
        let valid = (read.basicAccessControl == .succeeded || read.pace == .succeeded) &&
            read.countrySigningChain == .succeeded && read.documentSignature == .succeeded &&
            read.dataGroupHashes == .succeeded && read.activeAuthentication != .failed &&
            read.chipAuthentication != .failed && !read.securityObject.isEmpty
        PassportServerDiagnostic.flow(.evidenceIntegrity, passed: valid).record(observer: diagnosticObserver)
        guard current(attempt, .scanning), !Task.isCancelled else { throw CancellationError() }
        guard valid else { throw PassportLocalAdmissionFailure.unverifiedEvidence }
        let matches = corresponds(read)
        guard current(attempt, .scanning), !Task.isCancelled else { throw CancellationError() }
        guard matches else { throw PassportLocalAdmissionFailure.correspondence }
    }

    private func corresponds(_ read: PassportReadObservation) -> Bool {
        if let printedMRZ {
            let comparison = PassportCorrespondenceObservation(printed: printedMRZ, chip: read)
            return recordCorrespondence(comparison.fields)
        }
        guard let fields = accessFields else { return false }
        func number(_ value: String) -> String {
            value.replacingOccurrences(of: "<", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        let comparisons: [PassportCorrespondenceObservation.Field: PassportCorrespondenceObservation.Comparison] = [
            .documentNumber: number(fields.documentNumber) == number(read.documentNumber) ? .matches : .differs,
            .birthDate: fields.birthDateYYMMDD == read.birthDateYYMMDD ? .matches : .differs,
            .expiryDate: fields.expiryDateYYMMDD == read.expiryDateYYMMDD ? .matches : .differs
        ]
        return recordCorrespondence(comparisons)
    }

    private func recordCorrespondence(_ comparisons: [PassportCorrespondenceObservation.Field: PassportCorrespondenceObservation.Comparison]) -> Bool {
        let mismatches = PassportCorrespondenceObservation.Field.allCases.filter { comparisons[$0] == .differs }
        correspondenceMismatchedFields = mismatches
        PassportServerDiagnostic.correspondence(comparisons).record(observer: diagnosticObserver)
        return mismatches.isEmpty
    }

    private func current(_ attempt: UUID, _ expected: Phase) -> Bool {
        usable && attemptID == attempt && phase == expected
    }

    private func reset(failure: Failure?) {
        retire()
        clearEvidence()
        phase = .start
        self.failure = failure
        render()
    }

    private func clearEvidence() {
        correspondenceMismatchedFields = []
        key = nil
        accessFields = nil
        printedMRZ = nil
        result = nil
        resultServerVerification = nil
        serverRejection = nil
        serverStage = nil
        resultCapturedAt = nil
        pendingCheckpoint = nil
        pendingMRZ = nil; mrzCommitted = false
        event = nil
    }

    private func retire() {
        serverRejection = nil
        actionTask?.cancel(); actionTask = nil
        beginWhenVisible = false
        attemptID = UUID()
        let retired = operation
        retired?.cancel()
        operation = nil
        let prior = retirement
        let stop = effects.stopCamera
        retirement = Task {
            await prior?.value
            await retired?.value
            await stop()
        }
    }

    private func render() { onChange?() }
}
