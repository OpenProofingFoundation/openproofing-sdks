import Darwin
import DocumentSDK
import DocumentCaptureApple
import Foundation
import CaptureEvidenceCustody
import KenshikiEvidenceManifest
@_spi(StorageAdapter) import KenshikiProtectedStorage
import SQLCipher

/// Dedicated local document custody. Signatures bind retained observations, not sensor authenticity.
/// Each committed revision is immutable; only explicit deletion removes saved captures.
actor DocumentFlowSQLiteStore: DocumentFlowPersistence {
    enum Failure: Error { case unavailable, invalidRecord, staleRevision, retired }

    struct Configuration: Sendable {
        let applicationID: String
        let exists: @Sendable () throws -> Bool
        let open: @Sendable (Bool) throws -> ProtectedSQLiteStore
        let pending: @Sendable () throws -> Bool
        let prepareErase: @Sendable () throws -> ProtectedSQLiteErasure
        let signer: any EvidenceManifestSigning
        let eraseSigning: @Sendable () async throws -> Void
    }
    private struct Row: Equatable, Sendable {
        let revision: UInt64
        let id: UUID
        let payload: Data
        let metadata: Data
        let signed: Data
        let anchor: String
    }
    private struct Descriptor: Codable, Equatable {
        let schemaVersion: Int
        let workflowID: UUID
        let revision: UInt64
        let frontCaptureID: UUID
        let backCaptureID: UUID?
        let payloadSHA256: String
        let motion: [MotionReference]?
    }
    private struct MotionReference: Codable, Equatable, Sendable {
        let recordID: UUID
        let captureID: UUID
        let payloadSHA256: String
        let metadataSHA256: String
        let signedManifestSHA256: String
    }
    private struct MotionRow: Equatable, Sendable {
        let id: UUID
        let captureID: UUID
        let payload: Data
        let metadata: Data
        let signed: Data
        let anchor: String
        var reference: MotionReference {
            .init(recordID: id, captureID: captureID, payloadSHA256: CaptureEvidenceManifest.sha256(payload),
                metadataSHA256: CaptureEvidenceManifest.sha256(metadata), signedManifestSHA256: CaptureEvidenceManifest.sha256(signed))
        }
    }
    private struct MotionDescriptor: Codable, Equatable {
        let schemaVersion: Int
        let workflowID: UUID
        let originalRevision: UInt64
        let captureID: UUID
        let side: DocumentSide
        let sourceSHA256: String
        let sourceMetadataSHA256: String
    }
    private let resolve: @Sendable () throws -> Configuration
    private var configuration: Configuration?
    // A lifecycle-bound owner, never an open SQLite connection or decrypted page cache.
    private var owner: ProtectedSQLiteStore?
    private var tail: Task<Void, Never>?
    private var epoch = UUID()
    private var deleting = false
    private var erasureRequired = false

    init() { resolve = { try Self.production() } }
    init(configuration: Configuration) { resolve = { configuration } }

    private func configured() throws -> Configuration {
        if let configuration { return configuration }
        let value = try resolve(); configuration = value; return value
    }
    private func database(_ config: Configuration, existing: Bool) throws -> ProtectedSQLiteStore {
        if let owner { return owner }
        let value = try config.open(existing); owner = value; return value
    }

    func save(_ snapshot: DocumentFlowSnapshot) async throws -> DocumentFlowSnapshot {
        guard !deleting, !erasureRequired else { throw Failure.retired }
        let token = epoch, previous = tail
        // Caller cancellation cannot tear down an admitted publication.
        let job = Task { await previous?.value; return try await self.publish(snapshot, token: token) }
        tail = Task { _ = await job.result }
        return try await job.value
    }

    private func publish(_ input: DocumentFlowSnapshot, token: UUID) async throws -> DocumentFlowSnapshot {
        guard epoch == token, !deleting, !erasureRequired else { throw Failure.retired }
        try Self.validate(input)
        let config = try configured()
        guard try !config.pending() else { erasureRequired = true; throw Failure.retired }
        let store = try database(config, existing: config.exists())
        let (admitted, admittedMotion) = try store.withConnection { db in
            try Self.schema(db, create: true)
            let row = try Self.current(db)
            let snapshot = try row.map { try JSONDecoder().decode(DocumentFlowSnapshot.self, from: $0.payload) }
            return (row, try snapshot.map { try Self.motionRows(db, snapshot: $0) } ?? [])
        }
        let retained: DocumentFlowSnapshot?
        if let admitted { retained = try await verified(admitted, motion: admittedMotion, config: config) }
        else { retained = nil }
        guard epoch == token, !deleting, !erasureRequired else { throw Failure.retired }
        if let retained, retained.workflowID == input.workflowID, retained.revision > input.revision,
            try retained.hasExactContent(of: input) {
            guard try store.withConnection({ db in
                try Self.current(db) == admitted && Self.motionRows(db, snapshot: retained) == admittedMotion
            }) else { throw Failure.staleRevision }
            return retained
        }
        if input.revision > 0 {
            guard let admitted, let old = retained else { throw Failure.staleRevision }
            guard admitted.revision == input.revision, old.workflowID == input.workflowID,
                try Self.encode(old.front) == Self.encode(input.front) else { throw Failure.staleRevision }
        } else {
            guard input.back == nil else { throw Failure.invalidRecord }
            guard retained?.workflowID != input.workflowID else { throw Failure.staleRevision }
        }
        let revision = (admitted?.revision ?? 0) + 1
        guard revision <= 9_007_199_254_740_991 else { throw Failure.invalidRecord }
        let snapshot = DocumentFlowSnapshot(workflowID: input.workflowID, revision: revision, front: input.front, back: input.back)
        let anchor: String
        if let admitted { anchor = admitted.anchor }
        else { anchor = try await config.signer.prepareSigningPublicKeyHash() }
        let existingMotion = try store.withConnection { try Self.motionRows($0, snapshot: snapshot) }
        var motion: [MotionRow] = [], newMotion: [MotionRow] = []
        for observation in [Optional(snapshot.front), snapshot.back].compactMap({ $0 }) {
            let facts = try JSONDecoder().decode(DocumentFlowCaptureMetadata.self, from: observation.source.nativeMetadata)
            guard let evidence = facts.motionEvidence else {
                guard !existingMotion.contains(where: { $0.captureID == observation.source.captureID }) else { throw Failure.invalidRecord }
                continue
            }
            if let row = existingMotion.first(where: { $0.captureID == observation.source.captureID }) {
                try await verifyMotion(row, snapshot: snapshot, config: config, anchor: anchor)
                motion.append(row)
            } else {
                let id = UUID(), bytes = try Self.encode(evidence)
                let metadata = try Self.encode(Self.motionDescriptor(snapshot, source: observation.source, originalRevision: revision))
                let manifest = try Self.motionManifest(snapshot, source: observation.source, id: id,
                    originalRevision: revision, payload: bytes, metadata: metadata, applicationID: config.applicationID, anchor: anchor)
                let signed = SignedCaptureEvidenceManifest(manifest: manifest, proof: try await config.signer.sign(manifest))
                let row = MotionRow(id: id, captureID: observation.source.captureID, payload: bytes,
                    metadata: metadata, signed: try Self.encode(signed), anchor: anchor)
                try await verifyMotion(row, snapshot: snapshot, config: config, anchor: anchor)
                motion.append(row); newMotion.append(row)
            }
        }
        let payload = try Self.encode(snapshot), descriptor = Self.descriptor(snapshot, payload: payload, motion: motion.map(\.reference))
        guard payload.count <= 134_217_728 else { throw Failure.invalidRecord }
        let metadata = try Self.encode(descriptor), id = UUID()
        var sources = [EvidenceArtifactReference(recordID: id, role: "document-review", sha256: CaptureEvidenceManifest.sha256(payload))]
        for observation in [Optional(snapshot.front), snapshot.back].compactMap({ $0 }) {
            sources.append(.init(recordID: observation.source.captureID, role: "optical-source", sha256: observation.source.sha256))
        }
        sources += motion.map { .init(recordID: $0.id, role: "capture-motion", sha256: CaptureEvidenceManifest.sha256($0.payload)) }
        let manifest = try CaptureEvidenceManifest(context: Self.context(snapshot, applicationID: config.applicationID, anchor: anchor),
            recordID: id, recordKind: "document-review", payloadSHA256: CaptureEvidenceManifest.sha256(payload),
            capabilityManifestSHA256: CaptureEvidenceManifest.sha256(metadata), sources: sources,
            policyIDs: ["local-document-review-v1"])
        let signed = SignedCaptureEvidenceManifest(manifest: manifest, proof: try await config.signer.sign(manifest))
        let row = Row(revision: revision, id: id, payload: payload, metadata: metadata, signed: try Self.encode(signed), anchor: anchor)
        _ = try await verified(row, motion: motion, config: config)
        guard epoch == token, !deleting, !erasureRequired else { throw Failure.retired }
        try store.withConnection { db in
            try Self.schema(db, create: false)
            try PassportCaptureSchema.execute(db, "BEGIN IMMEDIATE")
            do {
                guard try Self.current(db) == admitted else { throw Failure.staleRevision }
                if let retained {
                    guard try Self.motionRows(db, snapshot: retained) == admittedMotion else { throw Failure.staleRevision }
                }
                guard try Self.motionRows(db, snapshot: snapshot) == existingMotion else { throw Failure.staleRevision }
                try Self.migrateForWrite(db)
                for item in newMotion { try Self.insertMotion(item, db: db) }
                try Self.insert(row, db: db)
                guard try Self.motionRows(db, snapshot: snapshot) == motion else { throw Failure.invalidRecord }
                guard try Self.current(db) == row else { throw Failure.invalidRecord }
                try PassportCaptureSchema.execute(db, "COMMIT")
            } catch {
                let original = error
                do { try PassportCaptureSchema.execute(db, "ROLLBACK") } catch { throw error }
                throw original
            }
        }
        return snapshot
    }

    func load() async throws -> DocumentFlowSnapshot? {
        guard !deleting, !erasureRequired else { throw Failure.retired }
        let token = epoch, previous = tail
        await previous?.value
        guard token == epoch, !deleting, !erasureRequired else { throw Failure.retired }
        let config = try configured()
        guard try !config.pending() else { erasureRequired = true; throw Failure.retired }
        guard try config.exists() else {
            if let owner { try owner.withConnection { _ -> Void in throw Failure.retired } }
            return nil
        }
        let store = try database(config, existing: true)
        let (optionalRow, motion) = try store.withConnection { db in
            try Self.schema(db, create: false)
            let row = try Self.current(db)
            let snapshot = try row.map { try JSONDecoder().decode(DocumentFlowSnapshot.self, from: $0.payload) }
            return (row, try snapshot.map { try Self.motionRows(db, snapshot: $0) } ?? [])
        }
        guard let row = optionalRow else { return nil }
        let value = try await verified(row, motion: motion, config: config)
        guard token == epoch, !deleting, !erasureRequired else { throw Failure.retired }
        // Reborrow the same lifecycle owner after verification, detecting external erase/replacement.
        guard try store.withConnection({ db in
            try Self.current(db) == row && Self.motionRows(db, snapshot: value) == motion
        }) else { throw Failure.staleRevision }
        return value
    }

    func delete() async throws {
        guard !deleting else { throw Failure.retired }
        deleting = true; erasureRequired = true; epoch = UUID()
        defer { deleting = false }
        await tail?.value
        let config = try configured()
        // Keep foundation's durable erasure intent pending across auxiliary signing-key cleanup.
        // A failed cleanup remains erase-only, including after constructing a fresh app owner.
        let erasure: ProtectedSQLiteErasure
        if let owner { erasure = try owner.prepareErasure() }
        else { erasure = try config.prepareErase() }
        owner = nil
        try await config.eraseSigning()
        try erasure.finish()
        configuration = nil; erasureRequired = false
    }

    private func verified(_ row: Row, motion: [MotionRow], config: Configuration) async throws -> DocumentFlowSnapshot {
        guard let key = try await config.signer.existingSigningPublicKeyHash(), key == row.anchor else {
            throw EvidenceManifestError.untrustedSigningKey
        }
        let snapshot = try JSONDecoder().decode(DocumentFlowSnapshot.self, from: row.payload)
        try Self.validate(snapshot)
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: row.metadata)
        guard snapshot.revision == row.revision, snapshot.revision > 0 else { throw Failure.invalidRecord }
        switch descriptor.schemaVersion {
        case 1:
            guard motion.isEmpty, descriptor.motion == nil,
                descriptor == Self.descriptor(snapshot, payload: row.payload, motion: nil) else { throw Failure.invalidRecord }
            for observation in [Optional(snapshot.front), snapshot.back].compactMap({ $0 }) {
                guard try JSONDecoder().decode(DocumentFlowCaptureMetadata.self, from: observation.source.nativeMetadata).motionEvidence == nil else { throw Failure.invalidRecord }
            }
        case 2:
            guard descriptor == Self.descriptor(snapshot, payload: row.payload, motion: motion.map(\.reference)) else { throw Failure.invalidRecord }
            let expected = try [Optional(snapshot.front), snapshot.back].compactMap { $0 }.filter {
                try JSONDecoder().decode(DocumentFlowCaptureMetadata.self, from: $0.source.nativeMetadata).motionEvidence != nil
            }.map { $0.source.captureID }
            guard motion.map(\.captureID) == expected else { throw Failure.invalidRecord }
            for item in motion { try await verifyMotion(item, snapshot: snapshot, config: config, anchor: key) }
        default: throw Failure.invalidRecord
        }
        let signed = try JSONDecoder().decode(SignedCaptureEvidenceManifest.self, from: row.signed)
        let expectedSources = [EvidenceArtifactReference(recordID: row.id, role: "document-review", sha256: CaptureEvidenceManifest.sha256(row.payload))]
            + [Optional(snapshot.front), snapshot.back].compactMap { $0 }.map {
                EvidenceArtifactReference(recordID: $0.source.captureID, role: "optical-source", sha256: $0.source.sha256)
            }
        let allSources = expectedSources + motion.map {
            EvidenceArtifactReference(recordID: $0.id, role: "capture-motion", sha256: CaptureEvidenceManifest.sha256($0.payload))
        }
        guard signed.manifest.sources == allSources, signed.manifest.derivatives.isEmpty,
            signed.manifest.lineage.isEmpty, signed.manifest.recordKind == "document-review",
            signed.manifest.policyIDs == ["local-document-review-v1"] else { throw Failure.invalidRecord }
        try await signed.verify(using: config.signer, trustedSigningPublicKeyHash: key,
            expectedContext: Self.context(snapshot, applicationID: config.applicationID, anchor: key),
            expectedRecordID: row.id, payload: row.payload, capabilityManifest: row.metadata)
        return snapshot
    }

    private static func descriptor(_ value: DocumentFlowSnapshot, payload: Data, motion: [MotionReference]?) -> Descriptor {
        Descriptor(schemaVersion: motion == nil ? 1 : 2, workflowID: value.workflowID, revision: value.revision,
            frontCaptureID: value.front.source.captureID, backCaptureID: value.back?.source.captureID,
            payloadSHA256: CaptureEvidenceManifest.sha256(payload), motion: motion)
    }
    private static func context(_ value: DocumentFlowSnapshot, applicationID: String, anchor: String) throws -> CapturePublicationContext {
        let date = (value.back ?? value.front).source.capturedAt.timeIntervalSince1970 * 1000
        guard date.isFinite, date >= 1, date <= 9_007_199_254_740_991 else { throw Failure.invalidRecord }
        return try .init(applicationID: applicationID, installationID: "local-signing-key:" + anchor,
            workflowID: value.workflowID, generation: value.revision, attemptID: value.front.source.captureID,
            observedAtMilliseconds: Int64(date))
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func validate(_ value: DocumentFlowSnapshot) throws {
        guard value.back?.source.captureID != value.front.source.captureID else { throw Failure.invalidRecord }
        for (side, optional) in [(DocumentSide.front, Optional(value.front)), (.back, value.back)] {
            guard let observation = optional else { continue }
            let source = observation.source, reading = observation.reading
            guard source.side == side, !source.data.isEmpty, source.pixelWidth > 0, source.pixelHeight > 0,
                source.sha256 == CaptureEvidenceManifest.sha256(source.data), !source.nativeMetadata.isEmpty,
                reading.sourceSHA256 == source.sha256,
                side == .front || observation.portraits.isEmpty else { throw Failure.invalidRecord }
            let native = try JSONDecoder().decode(DocumentFlowCaptureMetadata.self, from: source.nativeMetadata)
            try native.requireBinding(to: source)
            guard let prepared = observation.prepared else {
                guard side == .back, reading.barcodeOrigin == .admittedLiveMetadata,
                    let candidate = native.admittedLivePDF417Candidate,
                    native.admission?.qualityGate == .livePDF417AutoCapture,
                    !candidate.isEmpty, reading.pdf417Payloads == [candidate],
                    reading.recognizedText.isEmpty, reading.parsedPDF417.isEmpty,
                    reading.licenseFront == nil, observation.portraits.isEmpty else { throw Failure.invalidRecord }
                continue
            }
            guard reading.barcodeOrigin == nil, native.admittedLivePDF417Candidate == nil,
                prepared.sourceSHA256 == source.sha256, !prepared.data.isEmpty,
                prepared.sha256 == CaptureEvidenceManifest.sha256(prepared.data), prepared.pixelWidth > 0,
                prepared.pixelHeight > 0 else { throw Failure.invalidRecord }
            let derivation = try JSONDecoder().decode(DocumentImageDerivation.self, from: prepared.derivation)
            guard derivation.supported, derivation.sourceSHA256 == source.sha256,
                derivation.outputSHA256 == prepared.sha256, derivation.outputPixelWidth == prepared.pixelWidth,
                derivation.outputPixelHeight == prepared.pixelHeight else { throw Failure.invalidRecord }
            for portrait in observation.portraits {
                let rect = portrait.geometry.pixelRect
                guard portrait.sourceSHA256 == prepared.sha256, !portrait.data.isEmpty,
                    portrait.sha256 == CaptureEvidenceManifest.sha256(portrait.data), rect.x >= 0, rect.y >= 0,
                    rect.width > 0, rect.height > 0, rect.x <= prepared.pixelWidth, rect.y <= prepared.pixelHeight,
                    rect.width <= prepared.pixelWidth - rect.x, rect.height <= prepared.pixelHeight - rect.y
                else { throw Failure.invalidRecord }
            }
        }
    }

    private static func motionDescriptor(_ snapshot: DocumentFlowSnapshot, source: DocumentFlowSource, originalRevision: UInt64) -> MotionDescriptor {
        .init(schemaVersion: 1, workflowID: snapshot.workflowID, originalRevision: originalRevision,
            captureID: source.captureID, side: source.side, sourceSHA256: source.sha256,
            sourceMetadataSHA256: CaptureEvidenceManifest.sha256(source.nativeMetadata))
    }
    private static func motionManifest(_ snapshot: DocumentFlowSnapshot, source: DocumentFlowSource, id: UUID,
        originalRevision: UInt64, payload: Data, metadata: Data, applicationID: String, anchor: String) throws -> CaptureEvidenceManifest {
        let milliseconds = source.capturedAt.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds >= 1, milliseconds <= 9_007_199_254_740_991 else { throw Failure.invalidRecord }
        let context = try CapturePublicationContext(applicationID: applicationID, installationID: "local-signing-key:" + anchor,
            workflowID: snapshot.workflowID, generation: originalRevision, attemptID: source.captureID,
            observedAtMilliseconds: Int64(milliseconds))
        return try .init(context: context, recordID: id, recordKind: "capture-motion",
            payloadSHA256: CaptureEvidenceManifest.sha256(payload), capabilityManifestSHA256: CaptureEvidenceManifest.sha256(metadata),
            sources: [.init(recordID: id, role: "capture-motion", sha256: CaptureEvidenceManifest.sha256(payload)),
                .init(recordID: source.captureID, role: "optical-source", sha256: source.sha256)],
            policyIDs: ["local-document-motion-v1"])
    }
    private func verifyMotion(_ row: MotionRow, snapshot: DocumentFlowSnapshot, config: Configuration, anchor: String) async throws {
        guard row.anchor == anchor,
            let observation = [Optional(snapshot.front), snapshot.back].compactMap({ $0 }).first(where: { $0.source.captureID == row.captureID })
        else { throw Failure.invalidRecord }
        let descriptor = try JSONDecoder().decode(MotionDescriptor.self, from: row.metadata)
        guard descriptor.originalRevision > 0, descriptor.originalRevision <= snapshot.revision,
            descriptor == Self.motionDescriptor(snapshot, source: observation.source, originalRevision: descriptor.originalRevision),
            let evidence = try JSONDecoder().decode(DocumentFlowCaptureMetadata.self, from: observation.source.nativeMetadata).motionEvidence,
            try Self.encode(evidence) == row.payload else { throw Failure.invalidRecord }
        let expected = try Self.motionManifest(snapshot, source: observation.source, id: row.id,
            originalRevision: descriptor.originalRevision, payload: row.payload, metadata: row.metadata,
            applicationID: config.applicationID, anchor: anchor)
        let signed = try JSONDecoder().decode(SignedCaptureEvidenceManifest.self, from: row.signed)
        guard signed.manifest == expected else { throw Failure.invalidRecord }
        try await signed.verify(using: config.signer, trustedSigningPublicKeyHash: anchor,
            expectedContext: expected.context, expectedRecordID: row.id, payload: row.payload, capabilityManifest: row.metadata)
    }
    private static let motionSQL = "CREATE TABLE document_capture_motion(record_id TEXT PRIMARY KEY NOT NULL,source_capture_id TEXT NOT NULL UNIQUE,payload BLOB NOT NULL,metadata BLOB NOT NULL,signed_manifest BLOB NOT NULL,key_anchor TEXT NOT NULL) STRICT"
    private static func migrateForWrite(_ db: OpaquePointer) throws {
        try schema(db, create: false)
        if try PassportCaptureSchema.integer(db, "PRAGMA user_version") == 1 {
            try PassportCaptureSchema.execute(db, motionSQL)
            try PassportCaptureSchema.execute(db, "PRAGMA user_version=2")
        }
        try schema(db, create: false)
    }
    private static func motionRows(_ db: OpaquePointer, snapshot: DocumentFlowSnapshot) throws -> [MotionRow] {
        guard try PassportCaptureSchema.integer(db, "PRAGMA user_version") == 2 else { return [] }
        return try [Optional(snapshot.front), snapshot.back].compactMap { $0 }.compactMap { observation in
            let query = try PassportCaptureSchema.statement(db, "SELECT record_id,payload,metadata,signed_manifest,key_anchor FROM document_capture_motion WHERE source_capture_id=?")
            defer { sqlite3_finalize(query) }
            try PassportCaptureSchema.bind(observation.source.captureID.uuidString, at: 1, to: query)
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let idText = sqlite3_column_text(query, 0),
                let id = UUID(uuidString: String(cString: idText)), let anchor = sqlite3_column_text(query, 4) else { throw Failure.invalidRecord }
            func blob(_ index: Int32) throws -> Data {
                let size = Int(sqlite3_column_bytes(query, index))
                guard size > 0, size <= 134_217_728, let bytes = sqlite3_column_blob(query, index) else { throw Failure.invalidRecord }
                return Data(bytes: bytes, count: size)
            }
            return try MotionRow(id: id, captureID: observation.source.captureID, payload: blob(1), metadata: blob(2), signed: blob(3), anchor: String(cString: anchor))
        }
    }
    private static func insertMotion(_ row: MotionRow, db: OpaquePointer) throws {
        let query = try PassportCaptureSchema.statement(db, "INSERT INTO document_capture_motion VALUES(?,?,?,?,?,?)")
        defer { sqlite3_finalize(query) }
        try PassportCaptureSchema.bind(row.id.uuidString, at: 1, to: query)
        try PassportCaptureSchema.bind(row.captureID.uuidString, at: 2, to: query)
        for (index, data) in [(Int32(3), row.payload), (4, row.metadata), (5, row.signed)] {
            try data.withUnsafeBytes { bytes in
                try PassportCaptureSchema.check(sqlite3_bind_blob(query, index, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
            }
        }
        try PassportCaptureSchema.bind(row.anchor, at: 6, to: query); try PassportCaptureSchema.done(query)
    }

    private static let recordsSQL = "CREATE TABLE document_capture_records(revision INTEGER PRIMARY KEY CHECK(revision>0),record_id TEXT NOT NULL UNIQUE,payload BLOB NOT NULL,metadata BLOB NOT NULL,signed_manifest BLOB NOT NULL,key_anchor TEXT NOT NULL) STRICT"
    private static let currentSQL = "CREATE TABLE document_capture_current(slot INTEGER PRIMARY KEY CHECK(slot=1),revision INTEGER NOT NULL REFERENCES document_capture_records(revision)) STRICT"
    private static func schema(_ db: OpaquePointer, create: Bool) throws {
        if try PassportCaptureSchema.integer(db, "PRAGMA user_version") == 0, create {
            try PassportCaptureSchema.execute(db, "BEGIN IMMEDIATE")
            do {
                if try PassportCaptureSchema.integer(db, "PRAGMA user_version") == 0 {
                    guard try PassportCaptureSchema.integer(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT GLOB '_kenshiki_*' AND name NOT GLOB 'sqlite_*'") == 0 else { throw Failure.invalidRecord }
                    try PassportCaptureSchema.execute(db, recordsSQL); try PassportCaptureSchema.execute(db, currentSQL)
                    try PassportCaptureSchema.execute(db, "PRAGMA user_version=1")
                }
                try PassportCaptureSchema.execute(db, "COMMIT")
            } catch {
                let original = error
                do { try PassportCaptureSchema.execute(db, "ROLLBACK") } catch { throw error }
                throw original
            }
        }
        let version = try PassportCaptureSchema.integer(db, "PRAGMA user_version")
        guard [1, 2].contains(version),
            try PassportCaptureSchema.integer(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT GLOB '_kenshiki_*' AND name NOT GLOB 'sqlite_*'") == (version == 1 ? 2 : 3),
            try PassportCaptureSchema.string(db, "SELECT sql FROM sqlite_master WHERE name='document_capture_records'") == recordsSQL,
            try PassportCaptureSchema.string(db, "SELECT sql FROM sqlite_master WHERE name='document_capture_current'") == currentSQL else { throw Failure.invalidRecord }
        if version == 2 {
            guard try PassportCaptureSchema.string(db, "SELECT sql FROM sqlite_master WHERE name='document_capture_motion'") == motionSQL else { throw Failure.invalidRecord }
        }
    }
    private static func current(_ db: OpaquePointer) throws -> Row? {
        let statement = try PassportCaptureSchema.statement(db, "SELECT r.revision,r.record_id,r.payload,r.metadata,r.signed_manifest,r.key_anchor FROM document_capture_current c JOIN document_capture_records r ON c.revision=r.revision WHERE c.slot=1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE {
            guard try PassportCaptureSchema.integer(db, "SELECT count(*) FROM document_capture_records") == 0,
                try PassportCaptureSchema.integer(db, "SELECT count(*) FROM document_capture_current") == 0 else { throw Failure.invalidRecord }
            if try PassportCaptureSchema.integer(db, "PRAGMA user_version") == 2 {
                guard try PassportCaptureSchema.integer(db, "SELECT count(*) FROM document_capture_motion") == 0 else { throw Failure.invalidRecord }
            }
            return nil
        }
        guard status == SQLITE_ROW, sqlite3_column_int64(statement, 0) > 0,
            let idText = sqlite3_column_text(statement, 1), let id = UUID(uuidString: String(cString: idText)),
            let anchor = sqlite3_column_text(statement, 5) else { throw Failure.invalidRecord }
        func blob(_ index: Int32) throws -> Data {
            let size = Int(sqlite3_column_bytes(statement, index))
            guard size > 0, size <= 134_217_728, let pointer = sqlite3_column_blob(statement, index) else { throw Failure.invalidRecord }
            return Data(bytes: pointer, count: size)
        }
        return try Row(revision: UInt64(sqlite3_column_int64(statement, 0)), id: id,
            payload: blob(2), metadata: blob(3), signed: blob(4), anchor: String(cString: anchor))
    }
    private static func insert(_ row: Row, db: OpaquePointer) throws {
        let statement = try PassportCaptureSchema.statement(db, "INSERT INTO document_capture_records VALUES(?,?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        try PassportCaptureSchema.check(sqlite3_bind_int64(statement, 1, Int64(row.revision)))
        try PassportCaptureSchema.bind(row.id.uuidString, at: 2, to: statement)
        for (index, data) in [(Int32(3), row.payload), (4, row.metadata), (5, row.signed)] {
            try data.withUnsafeBytes { bytes in
                try PassportCaptureSchema.check(sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
            }
        }
        try PassportCaptureSchema.bind(row.anchor, at: 6, to: statement); try PassportCaptureSchema.done(statement)
        try PassportCaptureSchema.execute(db, "INSERT INTO document_capture_current VALUES(1,\(row.revision)) ON CONFLICT(slot) DO UPDATE SET revision=excluded.revision")
    }
    private static func production() throws -> Configuration {
        guard let app = Bundle.main.bundleIdentifier,
            let group = Bundle.main.object(forInfoDictionaryKey: "KenshikiKeychainAccessGroup") as? String,
            !group.isEmpty, !group.contains("$(") else { throw Failure.unavailable }
        let identity = try StoreKeyIdentity(applicationID: app, storeID: "document-reference-v1",
            purpose: "local-document-capture", keychainAccessGroup: group, accessPolicy: .identityWhenUnlocked)
        let signingIdentity = try StoreKeyIdentity(applicationID: app, storeID: "document-reference-v1",
            purpose: "local-document-capture-signing", keychainAccessGroup: group, accessPolicy: .identityWhenUnlocked)
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let url = root.resolvingSymlinksInPath().appendingPathComponent("DocumentCapture", isDirectory: true).appendingPathComponent("document.sqlite")
        let signer = try SecureEnclaveCaptureManifestSigner(identity: signingIdentity)
        return Configuration(applicationID: app, exists: {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.unavailable }
                return true
            }
            guard errno == ENOENT else { throw Failure.unavailable }
            return false
        }, open: { existing in
            if existing { return try ProtectedSQLiteStore(existingDatabaseURL: url, identity: identity) }
            return try ProtectedSQLiteStore(databaseURL: url, identity: identity)
        }, pending: { try ProtectedSQLiteStore.hasPendingErasure(databaseURL: url, identity: identity) },
            prepareErase: { try ProtectedSQLiteStore.prepareErasure(databaseURL: url, identity: identity) }, signer: signer,
            eraseSigning: { try await signer.eraseKeyAfterCiphertextErasure() })
    }
}
