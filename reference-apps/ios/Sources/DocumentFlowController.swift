import DocumentSDK
import DocumentCaptureApple
import Foundation

/// Exact encoded source bytes supplied by the native capture adapter.
public struct DocumentFlowSource: Codable, Sendable {
    public let side: DocumentSide
    public let captureID: UUID
    public let capturedAt: Date
    public let nativeMetadata: Data
    public let data: Data
    public let sha256: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(side: DocumentSide, data: Data, sha256: String, pixelWidth: Int, pixelHeight: Int,
                captureID: UUID = UUID(), capturedAt: Date = Date(), nativeMetadata: Data = Data()) {
        self.captureID = captureID; self.capturedAt = capturedAt; self.nativeMetadata = nativeMetadata
        self.side = side; self.data = data; self.sha256 = sha256
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}

public struct DocumentFlowPrepared: Codable, Sendable {
    public let sourceSHA256: String
    public let data: Data
    public let sha256: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Encoded native SDK derivation, verified by the adapter before crossing this port.
    public let derivation: Data

    public init(sourceSHA256: String, data: Data, sha256: String,
                pixelWidth: Int, pixelHeight: Int, derivation: Data) {
        self.sourceSHA256 = sourceSHA256; self.data = data; self.sha256 = sha256
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.derivation = derivation
    }
}

public struct DocumentFlowReading: Codable, Sendable {
    public enum BarcodeOrigin: String, Codable, Equatable, Sendable { case admittedLiveMetadata }
    public let sourceSHA256: String
    public let recognizedText: [String]
    public let pdf417Payloads: [String]
    public let parsedPDF417: [AAMVAPDF417Result]
    public let licenseFront: LicenseFrontVisualFields?
    public let barcodeOrigin: BarcodeOrigin?

    /// Presentation derived from retained bytes; reading it never changes signed capture data.
    public var structuredPDF417Results: [AAMVAPDF417Result] {
        if barcodeOrigin == .admittedLiveMetadata || parsedPDF417.isEmpty {
            return pdf417Payloads.map(AAMVAPDF417Parser.parse)
        }
        return parsedPDF417
    }

    public init(sourceSHA256: String, recognizedText: [String], pdf417Payloads: [String],
                parsedPDF417: [AAMVAPDF417Result] = [], licenseFront: LicenseFrontVisualFields? = nil,
                barcodeOrigin: BarcodeOrigin? = nil) {
        self.sourceSHA256 = sourceSHA256; self.recognizedText = recognizedText
        self.pdf417Payloads = pdf417Payloads; self.parsedPDF417 = parsedPDF417; self.licenseFront = licenseFront
        self.barcodeOrigin = barcodeOrigin
    }
}

public struct DocumentFlowPortrait: Codable, Sendable {
    public let sourceSHA256: String
    public let data: Data
    public let sha256: String
    public let geometry: PortraitCropCandidate

    public init(sourceSHA256: String, data: Data, sha256: String, geometry: PortraitCropCandidate) {
        self.sourceSHA256 = sourceSHA256; self.data = data; self.sha256 = sha256; self.geometry = geometry
    }
}

/// Observations for holder review, without an authenticity or identity-acceptance verdict.
public struct DocumentFlowObservation: Codable, Sendable {
    public let source: DocumentFlowSource
    public let prepared: DocumentFlowPrepared?
    public let reading: DocumentFlowReading
    public let portraits: [DocumentFlowPortrait]
}

@MainActor public protocol DocumentFlowCamera: AnyObject {
    func start() async throws
    func start(side: DocumentSide) async throws
    func stop() async throws
    func capture(side: DocumentSide) async throws -> DocumentFlowSource
    func capture(side: DocumentSide, observationIdentity: DocumentCaptureObservationIdentity?) async throws -> DocumentFlowSource
    func observeAutomaticCapture(_ receive: @escaping @MainActor (DocumentCaptureObservationIdentity) -> Void)
    func observeLivePDF417(_ receive: @escaping @MainActor (String) -> Void)
    func capture(side: DocumentSide, observationIdentity: DocumentCaptureObservationIdentity?, livePDF417Candidate: String?) async throws -> DocumentFlowSource
}

extension DocumentFlowCamera {
    public func start(side: DocumentSide) async throws { try await start() }
    public func capture(side: DocumentSide, observationIdentity: DocumentCaptureObservationIdentity?) async throws -> DocumentFlowSource {
        // A camera without automatic admission must never silently downgrade an automatic request.
        guard observationIdentity == nil else { throw DocumentFlowFailure.capture }
        return try await capture(side: side)
    }
    public func observeAutomaticCapture(_ receive: @escaping @MainActor (DocumentCaptureObservationIdentity) -> Void) {}
    public func observeLivePDF417(_ receive: @escaping @MainActor (String) -> Void) {}
    public func capture(side: DocumentSide, observationIdentity: DocumentCaptureObservationIdentity?, livePDF417Candidate: String?) async throws -> DocumentFlowSource {
        guard livePDF417Candidate == nil else { throw DocumentFlowFailure.capture }
        return try await capture(side: side, observationIdentity: observationIdentity)
    }
}

@MainActor public struct DocumentFlowPorts {
    public let makeCamera: @MainActor () -> any DocumentFlowCamera
    public let prepare: @MainActor (DocumentFlowSource) async throws -> DocumentFlowPrepared
    public let extract: @MainActor (DocumentFlowSource) async throws -> DocumentFlowReading
    public let portraits: @MainActor (DocumentFlowPrepared) async throws -> [DocumentFlowPortrait]
    public let sha256: @MainActor (Data) -> String

    public init(makeCamera: @escaping @MainActor () -> any DocumentFlowCamera,
                prepare: @escaping @MainActor (DocumentFlowSource) async throws -> DocumentFlowPrepared,
                extract: @escaping @MainActor (DocumentFlowSource) async throws -> DocumentFlowReading,
                portraits: @escaping @MainActor (DocumentFlowPrepared) async throws -> [DocumentFlowPortrait],
                sha256: @escaping @MainActor (Data) -> String) {
        self.makeCamera = makeCamera; self.prepare = prepare; self.extract = extract
        self.portraits = portraits; self.sha256 = sha256
    }
}

public enum DocumentFlowPhase: Equatable, Sendable {
    case intro, starting, front, back, processing, restoring, deleting, review, failure
}

public enum DocumentFlowFailure: Error, Equatable, Sendable {
    case cameraStart, capture, preparation, extraction, portrait, sourceBinding, cameraSettlement
    case storageSave, storageRead, storageDelete, noSavedCapture
}

public enum DocumentFlowIntent: Sendable {
    case start, capture, retakeFront, retakeBack, reset, visible, hidden, retrySave, reopen, deleteSaved
    case frontCapture
    case automaticCapture(DocumentCaptureObservationIdentity)
    case barcodeCapture(String)
}

/// Document review with optional durable custody. The host supplies native acquisition and SDK processing;
/// camera ownership is serialized separately from cancellable image-analysis work.
@MainActor public final class DocumentFlowController {
    public private(set) var phase: DocumentFlowPhase = .intro
    public private(set) var failure: DocumentFlowFailure?
    public private(set) var front: DocumentFlowObservation?
    public private(set) var back: DocumentFlowObservation?
    public private(set) var processingSide: DocumentSide?
    public private(set) var persistenceState: DocumentFlowPersistenceState = .transient
    public var changed: @MainActor () -> Void = {}
    public var supportsPersistence: Bool { persistence != nil }

    private let ports: DocumentFlowPorts
    private let persistence: (any DocumentFlowPersistence)?
    private var saved: DocumentFlowSnapshot?
    private var pendingSave: DocumentFlowSnapshot?
    private var workflowID = UUID()
    private var publicationTail: Task<Void, Never>?
    private var visible = false
    private var foreground = false
    private var generation: UInt64 = 0
    private var workSerial: UInt64 = 0
    private var settlementRevision: UInt64 = 0
    private var camera: (any DocumentFlowCamera)?
    private var cameraGeneration: UInt64?
    private var cameraTail: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    private var processingSerial: UInt64?
    private var retiredProcessing: [UInt64: Task<Void, Never>] = [:]

    public init(ports: DocumentFlowPorts, persistence: (any DocumentFlowPersistence)? = nil) {
        self.ports = ports; self.persistence = persistence
    }

    public func send(_ intent: DocumentFlowIntent) {
        switch intent {
        case .visible: visible = true
        case .hidden: visible = false; withdraw()
        case .reset: withdraw()
        case .start:
            guard [.intro, .failure, .review].contains(phase) else { return }
            begin(side: .front)
        case .retakeFront: begin(side: .front)
        case .retakeBack:
            // An admitted save must settle before a retake can select its durable revision.
            guard front != nil, [.back, .review, .failure].contains(phase),
                failure != .storageSave, failure != .storageDelete else { return }
            begin(side: .back)
        case .retrySave: retrySave()
        case .reopen: restore()
        case .deleteSaved: deleteSaved()
        case .capture: capture(observationIdentity: nil)
        case .frontCapture:
            // The retained front surface cannot authorize acquisition of a later side.
            guard phase == .front else { return }
            capture(observationIdentity: nil)
        case .barcodeCapture(let candidate):
            guard phase == .back else { return }
            capture(observationIdentity: nil, livePDF417Candidate: candidate)
        case .automaticCapture(let identity):
            guard phase == .front else { return }
            capture(observationIdentity: identity)
        }
    }

    public func setForeground(_ value: Bool) {
        foreground = value
        if !value { withdraw() }
    }

    /// Wait for native retirement and even analysis ports that ignore cancellation.
    public func waitUntilSettled() async {
        while true {
            let revision = settlementRevision
            let active = processing, retired = Array(retiredProcessing.values), native = cameraTail, publication = publicationTail
            await active?.value
            for task in retired { await task.value }
            await native?.value
            await publication?.value
            if revision == settlementRevision { return }
        }
    }

    private func current(_ token: UInt64) -> Bool {
        token == generation && visible && foreground && !Task.isCancelled
    }

    private func invalidateProcessing() {
        generation &+= 1; workSerial &+= 1; settlementRevision &+= 1
        if let processing, let processingSerial {
            processing.cancel()
            retiredProcessing[processingSerial] = processing
        }
        processing = nil; processingSerial = nil
    }

    private func withdraw() {
        invalidateProcessing()
        front = nil; back = nil; failure = nil; processingSide = nil; phase = .intro
        saved = nil; pendingSave = nil; persistenceState = .transient; workflowID = UUID()
        requestStop(for: generation)
        changed()
    }

    private func begin(side: DocumentSide) {
        guard visible, foreground else { return }
        invalidateProcessing()
        if side == .front {
            front = nil; saved = nil; pendingSave = nil; workflowID = UUID(); persistenceState = .transient
        }
        back = nil; failure = nil; processingSide = nil; phase = .starting
        let token = generation
        enqueueCamera { [self] in
            guard await stopOwnedCamera() else {
                if current(token) { publishFailure(.cameraSettlement, token: token) }
                return
            }
            guard current(token) else { return }
            let candidate = ports.makeCamera()
            camera = candidate; cameraGeneration = token
            candidate.observeAutomaticCapture { [weak self] identity in
                guard let self, self.current(token), self.cameraGeneration == token else { return }
                self.send(.automaticCapture(identity))
            }
            candidate.observeLivePDF417 { [weak self] value in
                guard let self, self.current(token), self.cameraGeneration == token else { return }
                self.send(.barcodeCapture(value))
            }
            guard current(token) else { return }
            do {
                try await candidate.start(side: side)
                guard current(token) else { return }
                phase = side == .front ? .front : .back
                changed()
            } catch {
                guard current(token) else { return }
                publishFailure(.cameraStart, token: token)
            }
        }
        changed()
    }

    private func enqueueCamera(_ operation: @escaping @MainActor () async -> Void) {
        let previous = cameraTail
        settlementRevision &+= 1
        cameraTail = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// Only the serial camera queue mutates or retires an owned native camera.
    private func stopOwnedCamera() async -> Bool {
        guard let camera else { return true }
        do {
            try await camera.stop()
            self.camera = nil; cameraGeneration = nil
            return true
        } catch {
            // Keep the failed owner. A later explicit start must settle it before making another.
            return false
        }
    }

    private func requestStop(for token: UInt64) {
        enqueueCamera { [self] in
            if !(await stopOwnedCamera()), current(token), failure == nil {
                failure = .cameraSettlement; phase = .failure
                changed()
            }
        }
    }

    private func capture(observationIdentity: DocumentCaptureObservationIdentity?, livePDF417Candidate: String? = nil) {
        let side: DocumentSide
        switch phase {
        case .front: side = .front
        case .back: side = .back
        default: return
        }
        guard let camera, current(generation), cameraGeneration == generation else { return }
        let token = generation
        workSerial &+= 1; settlementRevision &+= 1
        let serial = workSerial
        processingSide = side; phase = .processing; failure = nil
        changed()
        guard current(token), phase == .processing else { return }
        processingSerial = serial
        processing = Task { @MainActor [self] in
            defer {
                retiredProcessing.removeValue(forKey: serial)
                if processingSerial == serial { processing = nil; processingSerial = nil }
            }
            await process(camera: camera, side: side, observationIdentity: observationIdentity, livePDF417Candidate: livePDF417Candidate, token: token)
        }
    }

    private func captured(on camera: any DocumentFlowCamera, side: DocumentSide,
                          observationIdentity: DocumentCaptureObservationIdentity?, livePDF417Candidate: String?, token: UInt64) async throws -> DocumentFlowSource {
        let previous = cameraTail
        settlementRevision &+= 1
        let job = Task { @MainActor [self] () -> Result<DocumentFlowSource, Error> in
            await previous?.value
            guard current(token), cameraGeneration == token else { return .failure(CancellationError()) }
            do { return .success(try await camera.capture(side: side, observationIdentity: observationIdentity, livePDF417Candidate: livePDF417Candidate)) }
            catch { return .failure(error) }
        }
        cameraTail = Task { _ = await job.value }
        return try await job.value.get()
    }

    private func process(camera: any DocumentFlowCamera, side: DocumentSide,
                         observationIdentity: DocumentCaptureObservationIdentity?, livePDF417Candidate: String?, token: UInt64) async {
        var step = DocumentFlowFailure.capture
        do {
            let source = try await captured(on: camera, side: side, observationIdentity: observationIdentity, livePDF417Candidate: livePDF417Candidate, token: token)
            guard current(token) else { return }
            try verify(source, side: side)
            guard current(token) else { return }
            let result: DocumentFlowObservation
            if let candidate = livePDF417Candidate {
                guard side == .back, !candidate.isEmpty else { throw DocumentFlowFailure.sourceBinding }
                // The native reader admitted these exact bytes. A barcode guide does not imply
                // a full-card rectangle, and this observation is not still-image OCR.
                result = DocumentFlowObservation(source: source, prepared: nil,
                    reading: .init(sourceSHA256: source.sha256, recognizedText: [], pdf417Payloads: [candidate],
                        barcodeOrigin: .admittedLiveMetadata), portraits: [])
            } else {
                step = .preparation
                let prepared = try await ports.prepare(source)
                guard current(token) else { return }
                try verify(prepared, source: source)
                guard current(token) else { return }
                step = .extraction
                let reading = try await ports.extract(source)
                guard current(token) else { return }
                guard reading.sourceSHA256 == source.sha256, reading.barcodeOrigin == nil else { throw DocumentFlowFailure.sourceBinding }
                step = .portrait
                let portraits = side == .front ? try await ports.portraits(prepared) : []
                guard current(token) else { return }
                try verify(portraits, prepared: prepared)
                guard current(token) else { return }
                result = DocumentFlowObservation(source: source, prepared: prepared, reading: reading, portraits: portraits)
            }
            if persistence != nil {
                let snapshot: DocumentFlowSnapshot
                if side == .front {
                    snapshot = DocumentFlowSnapshot(workflowID: workflowID, revision: 0, front: result, back: nil)
                } else {
                    guard let front, let saved else { throw DocumentFlowFailure.sourceBinding }
                    snapshot = DocumentFlowSnapshot(workflowID: workflowID, revision: saved.revision, front: front, back: result)
                }
                try await commit(snapshot, token: token, continueToBack: side == .front)
            } else {
                processingSide = nil
                if side == .front { front = result; begin(side: .back) }
                else { back = result; phase = .review; requestStop(for: token); changed() }
            }
        } catch {
            guard current(token) else { return }
            publishFailure((error as? DocumentFlowFailure) ?? step, token: token)
        }
    }

    /// An admitted write has its own task. UI withdrawal cancels publication, not the durable write.
    private func commit(_ snapshot: DocumentFlowSnapshot, token: UInt64, continueToBack: Bool) async throws {
        guard let persistence else { throw DocumentFlowFailure.storageSave }
        pendingSave = snapshot; persistenceState = .saving
        changed()
        guard current(token) else { return }
        let previous = publicationTail
        let write = Task { @MainActor in
            await previous?.value
            return try await persistence.save(snapshot)
        }
        settlementRevision &+= 1
        publicationTail = Task { _ = await write.result }
        let retained: DocumentFlowSnapshot
        do { retained = try await write.value }
        catch { throw DocumentFlowFailure.storageSave }
        guard current(token) else { return }
        guard retained.workflowID == snapshot.workflowID, retained.revision > snapshot.revision,
            try retained.hasExactContent(of: snapshot) else { throw DocumentFlowFailure.sourceBinding }
        try verify(retained)
        saved = retained; pendingSave = nil
        front = retained.front; back = retained.back
        processingSide = nil; persistenceState = .saved
        if continueToBack { begin(side: .back) }
        else { phase = .review; requestStop(for: token); changed() }
    }

    private func retrySave() {
        guard phase == .failure, failure == .storageSave, let pendingSave, current(generation) else { return }
        let snapshot = pendingSave
        launchPersistence(phase: .processing) { token in
            do { try await self.commit(snapshot, token: token, continueToBack: snapshot.back == nil) }
            catch {
                guard self.current(token) else { return }
                self.publishFailure((error as? DocumentFlowFailure) ?? .storageSave, token: token)
            }
        }
    }

    private func restore() {
        guard let persistence, [.intro, .failure, .review].contains(phase), current(generation) else { return }
        launchPersistence(phase: .restoring) { token in
            do {
                await self.publicationTail?.value
                guard self.current(token) else { return }
                try await self.settleCameraForPersistence(token: token)
                guard self.current(token) else { return }
                guard let restored = try await persistence.load() else { throw DocumentFlowFailure.noSavedCapture }
                guard self.current(token) else { return }
                try self.verify(restored)
                guard restored.revision > 0 else { throw DocumentFlowFailure.sourceBinding }
                self.saved = restored; self.workflowID = restored.workflowID
                self.front = restored.front; self.back = restored.back
                self.persistenceState = .restored; self.phase = .review
                self.changed()
            } catch {
                guard self.current(token) else { return }
                self.publishFailure((error as? DocumentFlowFailure) ?? .storageRead, token: token)
            }
        }
    }

    private func deleteSaved() {
        guard let persistence, [.intro, .failure, .review].contains(phase), current(generation) else { return }
        launchPersistence(phase: .deleting) { token in
            do {
                let previous = self.publicationTail
                let deletion = Task { @MainActor in
                    await previous?.value
                    try await persistence.delete()
                }
                self.settlementRevision &+= 1
                self.publicationTail = Task { _ = await deletion.result }
                try await deletion.value
                guard self.current(token) else { return }
                self.withdraw()
            } catch {
                guard self.current(token) else { return }
                self.publishFailure(.storageDelete, token: token)
            }
        }
    }

    private func settleCameraForPersistence(token: UInt64) async throws {
        let previous = cameraTail
        settlementRevision &+= 1
        let settled = Task { @MainActor [self] in
            await previous?.value
            guard current(token) else { return false }
            return await stopOwnedCamera()
        }
        cameraTail = Task { _ = await settled.value }
        guard await settled.value else { throw DocumentFlowFailure.cameraSettlement }
    }

    private func launchPersistence(phase next: DocumentFlowPhase, operation: @escaping @MainActor (UInt64) async -> Void) {
        invalidateProcessing()
        failure = nil; processingSide = nil; phase = next
        let token = generation, serial = workSerial
        changed()
        guard current(token), phase == next else { return }
        processingSerial = serial
        processing = Task { @MainActor [self] in
            defer {
                retiredProcessing.removeValue(forKey: serial)
                if processingSerial == serial { processing = nil; processingSerial = nil }
            }
            await operation(token)
        }
    }

    private func verify(_ snapshot: DocumentFlowSnapshot) throws {
        for (side, observation) in [(DocumentSide.front, Optional(snapshot.front)), (.back, snapshot.back)] {
            guard let observation else { continue }
            try verify(observation.source, side: side)
            guard observation.reading.sourceSHA256 == observation.source.sha256 else { throw DocumentFlowFailure.sourceBinding }
            if let prepared = observation.prepared {
                guard observation.reading.barcodeOrigin == nil else { throw DocumentFlowFailure.sourceBinding }
                try verify(prepared, source: observation.source)
                try verify(observation.portraits, prepared: prepared)
            } else {
                let reading = observation.reading
                guard side == .back, reading.barcodeOrigin == .admittedLiveMetadata,
                    reading.pdf417Payloads.count == 1, reading.pdf417Payloads.first?.isEmpty == false,
                    reading.recognizedText.isEmpty, reading.parsedPDF417.isEmpty,
                    reading.licenseFront == nil, observation.portraits.isEmpty else { throw DocumentFlowFailure.sourceBinding }
            }
        }
        guard snapshot.back?.source.captureID != snapshot.front.source.captureID else { throw DocumentFlowFailure.sourceBinding }
    }

    private func publishFailure(_ value: DocumentFlowFailure, token: UInt64) {
        guard current(token) else { return }
        failure = value; processingSide = nil; phase = .failure
        if value == .storageSave { persistenceState = .transient }
        requestStop(for: token)
        changed()
    }

    private func verify(_ source: DocumentFlowSource, side: DocumentSide) throws {
        guard source.side == side, !source.data.isEmpty, source.pixelWidth > 0, source.pixelHeight > 0,
              source.sha256 == ports.sha256(source.data) else { throw DocumentFlowFailure.sourceBinding }
    }

    private func verify(_ prepared: DocumentFlowPrepared, source: DocumentFlowSource) throws {
        guard prepared.sourceSHA256 == source.sha256, !prepared.data.isEmpty, !prepared.derivation.isEmpty,
              prepared.pixelWidth > 0, prepared.pixelHeight > 0,
              prepared.sha256 == ports.sha256(prepared.data) else { throw DocumentFlowFailure.sourceBinding }
    }

    private func verify(_ portraits: [DocumentFlowPortrait], prepared: DocumentFlowPrepared) throws {
        for portrait in portraits {
            let rect = portrait.geometry.pixelRect
            guard portrait.sourceSHA256 == prepared.sha256, !portrait.data.isEmpty,
                  portrait.sha256 == ports.sha256(portrait.data), rect.x >= 0, rect.y >= 0,
                  rect.width > 0, rect.height > 0,
                  rect.x <= prepared.pixelWidth, rect.width <= prepared.pixelWidth - rect.x,
                  rect.y <= prepared.pixelHeight, rect.height <= prepared.pixelHeight - rect.y
            else { throw DocumentFlowFailure.sourceBinding }
        }
    }
}
