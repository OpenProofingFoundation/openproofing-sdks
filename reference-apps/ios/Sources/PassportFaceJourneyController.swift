import BiometricCapture
import Foundation

enum PassportFaceJourneyIntent: Equatable { case begin, cancel, done, retake, details, examples, copyReport, useSavedPassport, useSavedMRZ, resumeComparison, retryComparison, deleteSavedPassport, retryStorage, savedWork, developerTools, homeBack, reviewDeletion }

enum PassportStorageStartupStage: String, Codable {
    case constructing, passportLoad, passportValidation, mrzLoad, comparisonLookup, ready
}

/// Owns one in-memory journey. Acquisition and inference remain in their existing controllers.
@MainActor final class PassportFaceJourneyController {
    enum Phase: Equatable { case introduction, passport, selfie, comparing, result, interrupted }
    enum HomePage: Equatable { case overview, savedWork, developerTools, deletionConfirmation }
    struct CaptureToken: Equatable {
        let sessionID: UUID
        let captureID: UUID
    }

    private(set) var phase: Phase = .introduction
    private(set) var homePage: HomePage = .overview
    private(set) var sessionID = UUID()
    private(set) var reference: AcceptedPassportPortrait?
    private(set) var captureToken: CaptureToken?
    private(set) var detailsExpanded = false
    enum MotionProjectionState: Equatable { case idle, loading, ready, failed }
    private(set) var motionProjectionState: MotionProjectionState = .idle
    private(set) var workflowMotion: WorkflowMotionProjection?
    private var motionProjectionTask: Task<Void, Never>?
    private var motionProjectionRevision = UUID()
    enum StorageState: Equatable { case disabled, loading, ready, saving, deleting, failed, deleteFailed }
    private(set) var storageState: StorageState = .disabled
    #if DEBUG
    var onStorageHealthChange: ((PassportStorageStartupStage, (any Error)?) -> Void)?
    #endif
    private(set) var savedPassport: SavedPassportCapture?
    private(set) var savedMRZ: SavedMRZCapture?
    private(set) var restoredMRZ: SavedMRZCapture?
    private(set) var savedComparisonID: UUID?
    private(set) var activeComparisonID: UUID?
    private var workflowID = UUID()
    private(set) var restoredPassport: SavedPassportCapture?
    var passportServerVerification: PassportServerVerification? { reference?.serverVerification ?? restoredPassport?.serverVerification }
    var referencePortrait: Data? { reference?.read.portrait ?? restoredPassport?.nfc.portrait }
    private var referenceID: UUID? { reference?.attemptID ?? restoredPassport?.id }
    var canUseSavedPassport: Bool { savedPassport != nil && storageState == .ready }
    var hasSavedWork: Bool { savedPassport != nil || savedMRZ != nil || savedComparisonID != nil }
    var comparisonPhase: FaceComparisonController.Phase { comparison.phase }
    var visualPhase: FaceComparisonController.VisualPhase { comparison.visualPhase }
    var visualPartialResult: FaceVisualAssessmentCompletion? { comparison.visualPartialResult }
    var comparisonDurationMilliseconds: Double? { comparison.durationMilliseconds }
    var visualWaitingForComparison: Bool { comparison.visualWaitingForComparison }
    var inputTelemetry: FaceInputTelemetry? { comparison.inputTelemetry }
    var auraTelemetry: [FaceTelemetryField] { comparison.auraTelemetry }
    var visualDurationMilliseconds: Double? { comparison.visualDurationMilliseconds }
    var canRetryComparison: Bool { comparisonPersistence != nil && activeComparisonID != nil && !comparison.isProcessing }
    var canExportReport: Bool { comparison.canExportReport }
    var onChange: (() -> Void)?
    var onWithdraw: (() -> Void)?
    var onExamples: (() -> Void)?
    var onCopyReport: ((String) -> Void)?
    private let comparison: FaceComparisonController
    private let persistence: PassportCapturePersistence?
    private let comparisonPersistence: FaceWorkflowPersistence?
    private let trustBundleSHA256: String?
    private let evidence: WorkflowEvidenceRecorder?
    private var evidenceTask: Task<Void, Never>?
    var recordsEvidence: Bool { evidence != nil }
    var evidenceStatus: WorkflowEvidenceRecorder.Status? { evidence?.status }
    var onEvidenceChange: (() -> Void)?
    private var publishedEvidenceStatus: WorkflowEvidenceRecorder.Status?
    private var storageTask: Task<Void, Never>?
    private var saveTask: Task<Void, Error>?
    private var storageRevision = UUID()

    init(comparison: FaceComparisonController, persistence: PassportCapturePersistence? = nil,
         trustBundleSHA256: String? = nil, evidence: WorkflowEvidenceRecorder? = nil,
         comparisonPersistence: FaceWorkflowPersistence? = nil) {
        self.comparison = comparison
        self.persistence = persistence
        self.comparisonPersistence = comparisonPersistence
        self.trustBundleSHA256 = trustBundleSHA256
        self.evidence = evidence
        evidence?.onChange = { [weak self] in self?.evidenceChanged() }
        comparison.onChange = { [weak self] in self?.comparisonChanged() }
        loadSavedPassport()
    }

    func send(_ intent: PassportFaceJourneyIntent) {
        switch intent {
        case .savedWork, .developerTools, .homeBack, .reviewDeletion:
            guard phase == .introduction || phase == .interrupted, storageState != .deleting else { return }
            switch intent {
            case .savedWork: homePage = .savedWork
            case .developerTools: homePage = .developerTools
            case .homeBack: homePage = homePage == .deletionConfirmation ? .savedWork : .overview
            case .reviewDeletion:
                guard homePage == .savedWork, persistence != nil else { return }
                homePage = .deletionConfirmation
            default: return
            }
            onChange?()
        case .begin:
            guard phase == .introduction || phase == .interrupted,
                  storageState != .deleting, storageState != .deleteFailed else { return }
            if evidence != nil { beginRecordedJourney(saved: nil) }
            else { retire(to: .passport) }
        case .cancel, .done:
            evidence?.stop(intent == .cancel ? "workflow.cancelled" : "workflow.done")
            retire(to: .introduction)
        case .retake:
            guard phase == .result, referenceID != nil else { return }
            if let evidence {
                guard evidenceTask == nil else { return }
                let session = sessionID
                evidenceTask = Task { [weak self] in
                    do {
                        _ = try await evidence.record("selfie.retake")
                        guard let self, self.sessionID == session else { return }
                        self.evidenceTask = nil; self.beginSelfie()
                    } catch {
                        guard let self, self.sessionID == session else { return }
                        self.evidenceTask = nil
                    }
                }
            } else { beginSelfie() }
        case .details:
            guard phase == .result || phase == .comparing else { return }
            detailsExpanded.toggle()
            if detailsExpanded { refreshWorkflowMotion() }
            else { clearMotionProjection() }
            onChange?()
        case .copyReport:
            guard phase == .result || phase == .comparing,
                  let report = reportForExport() else { return }
            if let evidence {
                guard evidenceTask == nil else { return }
                let session = sessionID
                let operation = activeComparisonID
                let passStore = comparisonPersistence
                evidenceTask = Task { [weak self] in
                    do {
                        let boundary = try await evidence.record("report.copy")
                        let archive = try await evidence.export(through: boundary)
                        var body = try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any] ?? [:]
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                        body["workflowEvidence"] = try JSONSerialization.jsonObject(with: encoder.encode(archive))
                        let motion = try await evidence.motionProjection(through: boundary)
                        body["workflowMotion"] = try JSONSerialization.jsonObject(with: encoder.encode(motion))
                        if let operation, let passStore {
                            let passes = try await passStore.loadPasses(operation)
                            body["liquidPasses"] = try passes.map { try $0.exportObject() }
                            if let snapshot = try await passStore.loadSnapshot(operation) {
                                body["comparisonSnapshot"] = try JSONSerialization.jsonObject(with: encoder.encode(snapshot))
                            }
                        }
                        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
                        guard let self, self.sessionID == session, !Task.isCancelled else { return }
                        self.evidenceTask = nil
                        self.onCopyReport?(String(decoding: bytes, as: UTF8.self))
                    } catch {
                        guard let self, self.sessionID == session else { return }
                        self.evidenceTask = nil
                        self.onEvidenceChange?()
                    }
                }
            } else { onCopyReport?(report) }
        case .examples:
            guard phase == .introduction || phase == .interrupted,
                  homePage == .developerTools else { return }
            onExamples?()
        case .useSavedPassport:
            guard phase == .introduction || phase == .interrupted,
                  canUseSavedPassport, let savedPassport else { return }
            do { try savedPassport.validate() } catch { storageState = .failed; onChange?(); return }
            if evidence != nil { beginRecordedJourney(saved: savedPassport) }
            else {
                retire(to: .introduction)
                restoredPassport = savedPassport
                beginSelfie()
            }
        case .useSavedMRZ:
            guard phase == .introduction || phase == .interrupted, storageState == .ready, let savedMRZ else { return }
            if evidence != nil { beginRecordedJourney(saved: nil, mrz: savedMRZ) }
            else { retire(to: .passport); restoredMRZ = savedMRZ; onChange?() }
        case .resumeComparison:
            guard phase == .introduction || phase == .interrupted,
                  storageState == .ready, let savedComparisonID else { return }
            restoreComparison(savedComparisonID, run: false)
        case .retryComparison:
            guard phase == .result, !comparison.isProcessing, let activeComparisonID else { return }
            clearMotionProjection()
            restoreComparison(activeComparisonID, run: true)
        case .deleteSavedPassport:
            guard phase == .introduction || phase == .interrupted,
                  homePage == .deletionConfirmation else { return }
            deleteSavedPassport()
        case .retryStorage:
            guard phase == .introduction || phase == .interrupted else { return }
            if storageState == .deleteFailed { deleteSavedPassport() }
            else { loadSavedPassport() }
        }
    }

    @discardableResult
    func acceptPassport(_ value: AcceptedPassportPortrait, session: UUID) -> Bool {
        guard phase == .passport, sessionID == session,
              value.read.portrait?.isEmpty == false, value.read.dg2?.isEmpty == false,
              value.read.dg2Digest?.isEmpty == false, !value.read.securityObject.isEmpty,
              value.read.basicAccessControl == .succeeded || value.read.pace == .succeeded,
              value.read.countrySigningChain == .succeeded, value.read.documentSignature == .succeeded,
              value.read.dataGroupHashes == .succeeded,
              value.read.activeAuthentication != .failed, value.read.chipAuthentication != .failed else { return false }
        if persistence != nil {
            guard storageState == .ready, let savedPassport,
                  savedPassport.id == value.attemptID, savedPassport.capturedAt == value.capturedAt,
                  savedPassport.portraitSHA256 == SavedPassportCapture.digest(value.read.portrait ?? Data()),
                  savedPassport.securityObjectSHA256 == SavedPassportCapture.digest(value.read.securityObject),
                  savedPassport.serverVerification == value.serverVerification else { return false }
        }
        do { try value.serverVerification?.validate(securityObject: value.read.securityObject, capturedAt: value.capturedAt) }
        catch { return false }
        reference = value
        beginSelfie()
        return true
    }

    func checkpointSelfie(_ capture: CapturedSelfie, token: CaptureToken, selection: FaceCaptureSelectionRecord? = nil) async throws {
        guard phase == .selfie, captureToken == token, sessionID == token.sessionID else { throw CancellationError() }
        let event = try await evidence?.record("selfie.captured", captureID: capture.id, imageSHA256: capture.sha256)
        try await comparison.checkpointCapture(capture, id: token.captureID, eventID: event?.id, selection: selection)
        if comparisonPersistence != nil { savedComparisonID = token.captureID }
    }

    @discardableResult
    func acceptSelfie(_ value: AcceptedSelfie, token: CaptureToken) -> Bool {
        guard phase == .selfie, token == captureToken, token.sessionID == sessionID,
              value.snapshot.sourceEncodedSHA256 == value.capture.sha256,
              let referenceID else { return false }
        captureToken = nil
        activeComparisonID = token.captureID
        phase = .comparing
        onChange?()
        guard phase == .comparing, token.sessionID == sessionID else { return false }
        return comparison.acceptCapture(id: token.captureID, currentReferenceID: referenceID,
            selfie: value.capture.encodedPNG, selfieSHA256: value.capture.sha256,
            captureContext: FaceCaptureContext(capture: value.capture), selection: value.selection, preparedSelfie: value.preparedSelfie)
    }

    func cancelCapture(_ token: CaptureToken) {
        guard phase == .selfie, captureToken == token else { return }
        evidence?.stop("workflow.capture_cancelled")
        retire(to: .introduction)
    }

    func interrupt() {
        guard phase != .introduction, phase != .interrupted else { return }
        evidence?.stop("workflow.backgrounded")
        retire(to: .interrupted)
    }

    func recordAction(_ action: String) async throws {
        guard let evidence else { return }
        let boundary = try await evidence.record(action)
        if action == "selfie.compare", let token = captureToken {
            try await comparison.freezeComparisonSnapshot(operationID: token.captureID, through: boundary.id)
        }
    }

    private func beginRecordedJourney(saved: SavedPassportCapture?, mrz: SavedMRZCapture? = nil) {
        guard evidenceTask == nil, let evidence else { return }
        retire(to: .introduction)
        let session = sessionID
        evidenceTask = Task { [weak self] in
            do {
                try await evidence.start(workflowID: session)
                guard let self, self.sessionID == session, !Task.isCancelled else { return }
                self.evidenceTask = nil
                if let saved { self.restoredPassport = saved; self.beginSelfie() }
                else {
                    if let mrz { _ = try await evidence.record("passport.mrz.restored", captureID: mrz.id) }
                    guard self.sessionID == session else { return }
                    self.restoredMRZ = mrz; self.phase = .passport; self.onChange?()
                }
            } catch {
                guard let self, self.sessionID == session else { return }
                self.evidenceTask = nil; self.storageState = .failed; self.onChange?()
            }
        }
    }

    func checkpointMRZ(_ capture: SavedMRZCapture, session: UUID) async throws {
        guard phase == .passport, sessionID == session else { throw CancellationError() }
        guard let evidence else { return }
        _ = try await evidence.record("passport.mrz.captured", mrz: capture)
        guard sessionID == session else { throw CancellationError() }
        savedMRZ = capture
    }

    private func restoreComparison(_ id: UUID, run: Bool) {
        guard evidenceTask == nil, let comparisonPersistence else { return }
        if !run { retire(to: .introduction) }
        let session = sessionID
        evidenceTask = Task { [weak self] in
            do {
                let capture = try await comparisonPersistence.loadCapture(id)
                try capture.validate()
                let aura = try await comparisonPersistence.loadStage(id, .aura)
                var liquid = try await comparisonPersistence.loadStage(id, .liquid)
                let passes = try await comparisonPersistence.loadPasses(id)
                if let aura, !passes.isEmpty {
                    let snapshot = try await comparisonPersistence.loadSnapshot(id)
                    let restored = LegacyLiquidArchive.presentation(capture: capture, aura: aura, events: passes,
                        unavailableReason: snapshot?.unavailableReason)
                    liquid = SavedFaceStage(operationID: id, engine: .liquid, durationMilliseconds: restored.durationMilliseconds,
                        liquid: restored, precedingAuraID: aura.id)
                }
                guard let self, self.sessionID == session, !Task.isCancelled else { return }
                if !run {
                    self.workflowID = capture.input.workflowID ?? session
                    try await self.evidence?.start(workflowID: self.workflowID, resume: true)
                    guard self.sessionID == session, !Task.isCancelled else { return }
                } else {
                    let boundary = try await self.evidence?.record("comparison.retry")
                    try await self.comparison.freezeComparisonSnapshot(operationID: id, through: boundary?.id, recovering: true)
                }
                self.restoredPassport = capture.input.passport
                self.activeComparisonID = id
                self.evidenceTask = nil
                self.phase = run ? .comparing : .result
                if run { try self.comparison.runSaved(capture) }
                else { try self.comparison.restore(capture, aura: aura, liquid: liquid) }
                if self.detailsExpanded { self.refreshWorkflowMotion() }
                self.onChange?()
            } catch {
                guard let self, self.sessionID == session else { return }
                self.evidenceTask = nil; self.storageState = .failed; self.onChange?()
            }
        }
    }

    private func beginSelfie() {
        guard let referenceID, let portrait = referencePortrait else { return }
        let id = comparison.beginCapture(referenceID: referenceID, reference: portrait,
            passport: restoredPassport ?? savedPassport, workflowID: workflowID)
        captureToken = CaptureToken(sessionID: sessionID, captureID: id)
        clearMotionProjection()
        detailsExpanded = false
        phase = .selfie
        onChange?()
    }

    private func comparisonChanged() {
        guard phase == .comparing || phase == .result else { return }
        if comparison.hasResult { phase = .result }
        onChange?()
    }

    private func evidenceChanged() {
        guard let current = evidence?.status, publishedEvidenceStatus != current else { return }
        // Every sensor window remains durable. Only a change to the state displayed by
        // the host invalidates its view; a recording heartbeat is not a UI update.
        publishedEvidenceStatus = current
        onEvidenceChange?()
    }

    /// Read all persisted pages through a fresh acknowledged boundary, including earlier
    /// passport/MRZ/NFC and retake windows. Sensor heartbeats do not rebuild this sheet.
    func refreshWorkflowMotion() {
        guard detailsExpanded, phase == .result || phase == .comparing else { return }
        motionProjectionTask?.cancel()
        motionProjectionRevision = UUID()
        let revision = motionProjectionRevision
        let session = sessionID
        workflowMotion = nil
        guard let evidence else { motionProjectionState = .idle; return }
        motionProjectionState = .loading
        motionProjectionTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let boundary = try await evidence.record("telemetry.review")
                let projection = try await evidence.motionProjection(through: boundary)
                guard let self, self.sessionID == session,
                      self.motionProjectionRevision == revision, !Task.isCancelled else { return }
                self.workflowMotion = projection; self.motionProjectionState = .ready
                self.motionProjectionTask = nil; self.onChange?()
            } catch {
                guard let self, self.sessionID == session,
                      self.motionProjectionRevision == revision, !Task.isCancelled else { return }
                self.workflowMotion = nil; self.motionProjectionState = .failed
                self.motionProjectionTask = nil; self.onChange?()
            }
        }
    }

    private func clearMotionProjection() {
        motionProjectionTask?.cancel(); motionProjectionTask = nil
        motionProjectionRevision = UUID(); workflowMotion = nil; motionProjectionState = .idle
    }

    private func reportForExport() -> String? {
        guard let report = comparison.reportForExport(),
              var body = try? JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any] else { return nil }
        let capture = restoredPassport ?? savedPassport.flatMap { $0.id == referenceID ? $0 : nil }
        var provenance: [String: Any] = [
            "source": restoredPassport == nil ? "live_nfc" : "stored_nfc",
            "serverVerification": passportServerVerification == nil ? "not_requested" : "verified",
            "captureID": referenceID.map { $0.uuidString as Any } ?? NSNull()
        ]
        if let capture {
            provenance["capturedAt"] = capture.capturedAt.formatted(.iso8601)
            provenance["localTrustBundleSHA256"] = capture.localTrustBundleSHA256.map { $0 as Any } ?? NSNull()
            provenance["securityObjectSHA256"] = capture.securityObjectSHA256
        }
        if let server = passportServerVerification {
            provenance["serverReceipt"] = server.exportObject
            provenance["serverVerificationFreshness"] = restoredPassport == nil ? "read_session" : "historical"
        }
        body["passportReference"] = provenance
        guard let encoded = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    private func retire(to next: Phase) {
        clearMotionProjection()
        evidenceTask?.cancel(); evidenceTask = nil
        sessionID = UUID()
        workflowID = sessionID
        activeComparisonID = nil
        restoredMRZ = nil
        captureToken = nil
        reference = nil
        restoredPassport = nil
        detailsExpanded = false
        comparison.clear()
        phase = next
        homePage = .overview
        onWithdraw?()
        onChange?()
    }

    private func loadSavedPassport() {
        guard let persistence, storageState != .deleting else { return }
        storageTask?.cancel()
        let revision = UUID()
        storageRevision = revision
        storageState = .loading
        let pendingSave = saveTask
        storageTask = Task { [weak self] in
            _ = try? await pendingSave?.value
            var startupStage = PassportStorageStartupStage.passportLoad
            do {
                try Task.checkCancellation()
                self?.publishStorageHealth(stage: startupStage)
                let saved = try await persistence.load()
                startupStage = .passportValidation
                try saved?.validate()
                startupStage = .mrzLoad
                let mrz = try await persistence.loadMRZ()
                startupStage = .comparisonLookup
                let latestComparison = try await self?.comparisonPersistence?.latestCaptureID()
                guard let self, self.storageRevision == revision, !Task.isCancelled else { return }
                self.savedPassport = saved
                self.savedMRZ = mrz
                self.savedComparisonID = latestComparison
                self.storageState = .ready
                self.publishStorageHealth(stage: .ready)
                self.onChange?()
            } catch {
                guard let self, self.storageRevision == revision, !Task.isCancelled else { return }
                self.storageState = .failed
                if let construction = error as? PassportCaptureStoreConstructionFailure {
                    self.publishStorageHealth(stage: .constructing, error: construction.underlying)
                } else { self.publishStorageHealth(stage: startupStage, error: error) }
                self.onChange?()
            }
        }
    }

    private func publishStorageHealth(stage: PassportStorageStartupStage, error: (any Error)? = nil) {
        #if DEBUG
        onStorageHealthChange?(stage, error)
        #endif
    }

    func checkpointPassport(_ value: AcceptedPassportPortrait, session: UUID) async throws {
        guard phase == .passport, sessionID == session else { throw CancellationError() }
        guard let persistence else { return }
        let capture = try SavedPassportCapture(value, trustBundleSHA256: trustBundleSHA256)
        storageTask?.cancel()
        let priorSave = saveTask
        let revision = UUID()
        storageRevision = revision
        storageState = .saving
        let task = Task<Void, Error> { [weak self] in
            _ = try? await priorSave?.value
            do {
                try Task.checkCancellation()
                try await persistence.save(capture)
                _ = try await self?.evidence?.record("passport.nfc.committed", captureID: capture.id, imageSHA256: capture.portraitSHA256)
                guard let self, self.storageRevision == revision, !Task.isCancelled else { return }
                self.savedPassport = capture
                self.storageState = .ready
                self.onChange?()
            } catch {
                guard let self, self.storageRevision == revision, !Task.isCancelled else { return }
                self.storageState = .failed
                self.onChange?()
                throw error
            }
        }
        saveTask = task
        try await task.value
        guard storageRevision == revision, savedPassport?.id == capture.id, storageState == .ready else {
            throw CancellationError()
        }
    }

    private func deleteSavedPassport() {
        guard let persistence, storageState != .deleting else { return }
        storageTask?.cancel()
        saveTask?.cancel()
        let pendingSave = saveTask
        let revision = UUID()
        storageRevision = revision
        storageState = .deleting
        savedPassport = nil
        savedMRZ = nil; savedComparisonID = nil; activeComparisonID = nil
        onChange?()
        storageTask = Task { [weak self] in
            // Even a non-cooperative writer must finish before erasure. Later capture saves
            // cannot start while deletion is active, and old completions cannot republish it.
            _ = try? await pendingSave?.value
            do {
                try Task.checkCancellation()
                await self?.evidence?.discardForErasure()
                try Task.checkCancellation()
                try await persistence.delete()
                guard let self, self.storageRevision == revision, !Task.isCancelled else { return }
                self.savedPassport = nil
                self.saveTask = nil
                self.storageState = .ready
                self.homePage = .savedWork
                self.onChange?()
            } catch {
                guard let self, self.storageRevision == revision, !Task.isCancelled else { return }
                self.storageState = .deleteFailed
                self.homePage = .savedWork
                self.onChange?()
            }
        }
    }
}
