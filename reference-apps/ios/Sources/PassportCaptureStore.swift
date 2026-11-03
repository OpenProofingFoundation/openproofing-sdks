import Foundation
import Darwin
@_spi(StorageAdapter) import KenshikiProtectedStorage
import SQLCipher

struct PassportCapturePersistence: Sendable {
    let load: @Sendable () async throws -> SavedPassportCapture?
    let save: @Sendable (SavedPassportCapture) async throws -> Void
    let delete: @Sendable () async throws -> Void
    var loadMRZ: @Sendable () async throws -> SavedMRZCapture? = { nil }
}

/// Construction errors retain their cause and remain retryable without replacing saved custody.
struct PassportCaptureStoreConstructionFailure: Error {
    let underlying: any Error
}

/// Both persistence surfaces share one successfully constructed owner. Concurrent opens coalesce;
/// failed construction clears only the pending task, so explicit retry can construct again.
actor PassportCaptureStoreProvider {
    private let makeStore: @Sendable () async throws -> PassportCaptureStore
    private var current: PassportCaptureStore?
    private var opening: Task<PassportCaptureStore, Error>?

    init(makeStore: @escaping @Sendable () async throws -> PassportCaptureStore) {
        self.makeStore = makeStore
    }

    func store() async throws -> PassportCaptureStore {
        if let current { return current }
        if let opening {
            do { return try await opening.value }
            catch { throw PassportCaptureStoreConstructionFailure(underlying: error) }
        }
        let operation = Task { try await makeStore() }
        opening = operation
        do {
            let value = try await operation.value
            current = value
            opening = nil
            return value
        } catch {
            opening = nil
            throw PassportCaptureStoreConstructionFailure(underlying: error)
        }
    }

    nonisolated var effects: PassportCapturePersistence {
        PassportCapturePersistence(load: { try await self.store().load() },
            save: { try await self.store().save($0) }, delete: { try await self.store().delete() },
            loadMRZ: { try await self.store().loadLatestMRZ() })
    }

    nonisolated var comparisonEffects: FaceWorkflowPersistence {
        FaceWorkflowPersistence(saveCapture: { try await self.store().saveFaceCapture($0) },
            loadCapture: { try await self.store().loadFaceCapture($0) },
            saveStage: { try await self.store().saveFaceStage($0) },
            loadStage: { try await self.store().loadFaceStage($0, engine: $1) },
            latestCaptureID: { try await self.store().latestFaceCaptureID() },
            appendEvent: { try await self.store().appendWorkflowEvent($0) },
            savePass: { try await self.store().saveLiquidPass($0) },
            loadPasses: { try await self.store().loadLiquidPasses($0) },
            loadEvents: { try await self.store().loadWorkflowEvents($0, after: $1) },
            saveSnapshot: { try await self.store().saveComparisonSnapshot($0) },
            loadSnapshot: { try await self.store().loadComparisonSnapshot($0) })
    }
}

/// One protected checkpoint. SQL and key borrows are synchronous inside this actor; no live
/// camera, SDK reader, keyed connection or decrypted page cache is kept between operations.
actor PassportCaptureStore {
    private let exists: @Sendable () throws -> Bool
    private let open: @Sendable (Bool) throws -> ProtectedSQLiteStore
    private let erase: @Sendable () throws -> Void
    private let recover: @Sendable () throws -> Void
    // This is a generation-bound owner, not an open/keyed SQLite connection. Keeping it
    // prevents an old repository from silently adopting a store recreated by another owner.
    private var owner: ProtectedSQLiteStore?

    init(exists: @escaping @Sendable () throws -> Bool,
         open: @escaping @Sendable (Bool) throws -> ProtectedSQLiteStore,
         erase: @escaping @Sendable () throws -> Void,
         recover: @escaping @Sendable () throws -> Void = {}) {
        self.exists = exists
        self.open = open
        self.erase = erase
        self.recover = recover
    }

    static func live(observeTrustedRoot: ((Bool) -> Void)? = nil) throws -> PassportCaptureStore {
        guard let applicationID = Bundle.main.bundleIdentifier,
              let group = Bundle.main.object(forInfoDictionaryKey: "KenshikiKeychainAccessGroup") as? String,
              !group.contains("$("), !group.isEmpty else {
            throw PassportCaptureStorageFailure.unavailable
        }
        let identity = try StoreKeyIdentity(applicationID: applicationID, storeID: "passport-reference-v1",
            purpose: "local-passport-checkpoint", keychainAccessGroup: group, accessPolicy: .identityWhenUnlocked)
        let trustedRoot = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        observeTrustedRoot?(trustedRoot.standardizedFileURL != trustedRoot.resolvingSymlinksInPath().standardizedFileURL)
        let url = databaseURL(applicationSupportRoot: trustedRoot)
        return PassportCaptureStore(exists: { try databaseExists(url) },
            open: { existing in
                if existing { return try ProtectedSQLiteStore(existingDatabaseURL: url, identity: identity) }
                return try ProtectedSQLiteStore(databaseURL: url, identity: identity)
            }, erase: { try ProtectedSQLiteStore.erasePersisted(databaseURL: url, identity: identity) },
            recover: { _ = try ProtectedSQLiteStore.recoverPendingErasure(databaseURL: url, identity: identity) })
    }

    /// Resolve only the OS-supplied trusted base. The store still rejects symlinked children,
    /// changed namespace bindings, corrupt records and missing keys without replacing them.
    static func databaseURL(applicationSupportRoot: URL) -> URL {
        applicationSupportRoot.resolvingSymlinksInPath()
            .appendingPathComponent("PassportCheckpoint", isDirectory: true)
            .appendingPathComponent("passport.sqlite")
    }

    nonisolated var effects: PassportCapturePersistence {
        PassportCapturePersistence(load: { try await self.load() },
            save: { try await self.save($0) }, delete: { try await self.delete() },
            loadMRZ: { try await self.loadLatestMRZ() })
    }

    nonisolated var comparisonEffects: FaceWorkflowPersistence {
        FaceWorkflowPersistence(saveCapture: { try await self.saveFaceCapture($0) },
            loadCapture: { try await self.loadFaceCapture($0) },
            saveStage: { try await self.saveFaceStage($0) },
            loadStage: { try await self.loadFaceStage($0, engine: $1) },
            latestCaptureID: { try await self.latestFaceCaptureID() },
            appendEvent: { try await self.appendWorkflowEvent($0) },
            savePass: { try await self.saveLiquidPass($0) }, loadPasses: { try await self.loadLiquidPasses($0) },
            loadEvents: { try await self.loadWorkflowEvents($0, after: $1) },
            saveSnapshot: { try await self.saveComparisonSnapshot($0) }, loadSnapshot: { try await self.loadComparisonSnapshot($0) })
    }

    func load() throws -> SavedPassportCapture? {
        try Task.checkCancellation()
        try recover()
        guard try exists() else { return nil }
        let store = try currentOwner(existing: true)
        return try store.withConnection { db in
            try PassportCaptureSchema.prepare(db)
            let statement = try PassportCaptureSchema.statement(db, "SELECT payload, payload_sha256, capture_id, captured_at_ms, portrait_sha256, sod_sha256 FROM passport_checkpoint WHERE slot = 1")
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw ProtectedSQLiteError.unavailable(status) }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, count <= SavedPassportCapture.maximumBytes,
                  let bytes = sqlite3_column_blob(statement, 0) else {
                throw PassportCaptureStorageFailure.invalidCapture
            }
            let data = Data(bytes: bytes, count: count)
            let capture = try SavedPassportCapture.decode(data)
            func text(_ index: Int32) -> String? {
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            }
            guard text(1) == SavedPassportCapture.digest(data), text(2) == capture.id.uuidString,
                  sqlite3_column_int64(statement, 3) == Int64(capture.capturedAt.timeIntervalSince1970 * 1000),
                  text(4) == capture.portraitSHA256, text(5) == capture.securityObjectSHA256 else {
                throw PassportCaptureStorageFailure.invalidCapture
            }
            return capture
        }
    }

    func save(_ capture: SavedPassportCapture) throws {
        try Task.checkCancellation()
        try recover()
        let bytes = try capture.encoded()
        let store = try currentOwner(existing: exists())
        try store.withConnection { db in
            try PassportCaptureSchema.prepare(db)
            try PassportCaptureSchema.execute(db, "BEGIN IMMEDIATE")
            do {
                let statement = try PassportCaptureSchema.statement(db, "INSERT INTO passport_checkpoint(slot, capture_id, captured_at_ms, verification_scope, payload_version, payload_sha256, portrait_sha256, sod_sha256, payload) VALUES(1, ?, ?, 'local_nfc', 1, ?, ?, ?, ?) ON CONFLICT(slot) DO UPDATE SET capture_id=excluded.capture_id, captured_at_ms=excluded.captured_at_ms, payload_sha256=excluded.payload_sha256, portrait_sha256=excluded.portrait_sha256, sod_sha256=excluded.sod_sha256, payload=excluded.payload")
                defer { sqlite3_finalize(statement) }
                try PassportCaptureSchema.bind(capture.id.uuidString, at: 1, to: statement)
                try PassportCaptureSchema.check(sqlite3_bind_int64(statement, 2, Int64(capture.capturedAt.timeIntervalSince1970 * 1000)))
                try PassportCaptureSchema.bind(SavedPassportCapture.digest(bytes), at: 3, to: statement)
                try PassportCaptureSchema.bind(capture.portraitSHA256, at: 4, to: statement)
                try PassportCaptureSchema.bind(capture.securityObjectSHA256, at: 5, to: statement)
                let status = bytes.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, 6, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                try PassportCaptureSchema.check(status)
                try PassportCaptureSchema.done(statement)
                try PassportCaptureSchema.execute(db, "COMMIT")
            } catch {
                try? PassportCaptureSchema.execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    func delete() throws {
        try Task.checkCancellation()
        // Foundation erases the ciphertext family and key and fences old handles, including
        // recovery of an interrupted deletion. No corrupt-row decode is needed to delete.
        if let owner { try owner.erase() }
        else { try erase() }
        owner = nil
    }

    private func currentOwner(existing: Bool) throws -> ProtectedSQLiteStore {
        if let owner { return owner }
        let acquired = try open(existing)
        owner = acquired
        return acquired
    }

    private static func databaseExists(_ url: URL) throws -> Bool {
        var attributes = stat()
        if url.path.withCString({ lstat($0, &attributes) }) == 0 {
            guard attributes.st_mode & S_IFMT == S_IFREG else { throw PassportCaptureStorageFailure.invalidCapture }
            return true
        }
        guard errno == ENOENT else { throw ProtectedStoreLifecycleError.ioFailure(errno) }
        return false
    }

    private func withWorkflowDatabase<T>(creating: Bool = false, _ body: (OpaquePointer) throws -> T) throws -> T {
        try Task.checkCancellation()
        try recover()
        let present = try exists()
        guard present || creating else { throw FaceWorkflowStorageFailure.missingRecord }
        return try currentOwner(existing: present).withConnection { db in
            try PassportCaptureSchema.prepare(db)
            return try body(db)
        }
    }

    private static func encode<T: Encodable>(_ value: T, limit: Int) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let bytes = try encoder.encode(value)
        guard !bytes.isEmpty, bytes.count <= limit else { throw FaceWorkflowStorageFailure.invalidRecord }
        return bytes
    }

    private static func bind(_ data: Data, at index: Int32, to query: OpaquePointer) throws {
        try PassportCaptureSchema.check(data.withUnsafeBytes {
            sqlite3_bind_blob(query, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        })
    }

    private static func payload<T: Decodable>(_ query: OpaquePointer, as type: T.Type, limit: Int) throws -> T {
        let count = Int(sqlite3_column_bytes(query, 0))
        guard count > 0, count <= limit, let raw = sqlite3_column_blob(query, 0),
              let digest = sqlite3_column_text(query, 1) else { throw FaceWorkflowStorageFailure.invalidRecord }
        let data = Data(bytes: raw, count: count)
        guard SavedPassportCapture.digest(data) == String(cString: digest) else { throw FaceWorkflowStorageFailure.invalidRecord }
        return try PropertyListDecoder().decode(type, from: data)
    }

    private static func transaction<T>(_ db: OpaquePointer, immediate: Bool = true, _ body: () throws -> T) throws -> T {
        try PassportCaptureSchema.execute(db, immediate ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try body()
            try PassportCaptureSchema.execute(db, "COMMIT")
            return result
        } catch {
            try? PassportCaptureSchema.execute(db, "ROLLBACK")
            throw error
        }
    }

    func saveFaceCapture(_ capture: SavedFaceCapture) throws {
        try capture.validate()
        let bytes = try Self.encode(capture, limit: 40 * 1024 * 1024)
        try withWorkflowDatabase(creating: true) { db in
            try Self.transaction(db) {
                try Self.validateCaptureEvent(db, capture: capture)
                // Existing operation IDs are immutable. A retry may only confirm identical bytes.
                let existing = try Self.readFaceCapture(db, id: capture.input.operationID)
                if let existing {
                    guard try Self.encode(existing, limit: 40 * 1024 * 1024) == bytes else { throw FaceWorkflowStorageFailure.conflict }
                    return
                }
                guard try PassportCaptureSchema.integer(db, "SELECT count(*) FROM face_capture") < 64,
                      try PassportCaptureSchema.integer(db, "SELECT COALESCE(sum(length(payload)),0) FROM face_capture") + bytes.count <= 256 * 1024 * 1024 else {
                    throw FaceWorkflowStorageFailure.capacity
                }
                let query = try PassportCaptureSchema.statement(db, "INSERT INTO face_capture VALUES(?,?,?,?,?,?,?)")
                defer { sqlite3_finalize(query) }
                try PassportCaptureSchema.bind(capture.input.operationID.uuidString, at: 1, to: query)
                if let workflow = capture.input.workflowID { try PassportCaptureSchema.bind(workflow.uuidString, at: 2, to: query) }
                else { try PassportCaptureSchema.check(sqlite3_bind_null(query, 2)) }
                try PassportCaptureSchema.check(sqlite3_bind_int64(query, 3, Int64(capture.recordedAt.timeIntervalSince1970 * 1000)))
                try PassportCaptureSchema.bind(capture.input.referenceSHA256, at: 4, to: query)
                try PassportCaptureSchema.bind(capture.input.selfieSHA256, at: 5, to: query)
                try PassportCaptureSchema.bind(SavedPassportCapture.digest(bytes), at: 6, to: query)
                try Self.bind(bytes, at: 7, to: query)
                try PassportCaptureSchema.done(query)
            }
        }
    }

    private static func readFaceCapture(_ db: OpaquePointer, id: UUID) throws -> SavedFaceCapture? {
        let query = try PassportCaptureSchema.statement(db, "SELECT payload,payload_sha256,reference_sha256,selfie_sha256,recorded_at_ms,workflow_id FROM face_capture WHERE operation_id=?")
        defer { sqlite3_finalize(query) }
        try PassportCaptureSchema.bind(id.uuidString, at: 1, to: query)
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ProtectedSQLiteError.unavailable(status) }
        let capture = try payload(query, as: SavedFaceCapture.self, limit: 40 * 1024 * 1024)
        try capture.validate()
        func text(_ column: Int32) -> String? { sqlite3_column_text(query, column).map { String(cString: $0) } }
        guard capture.input.operationID == id, capture.input.referenceSHA256 == text(2), capture.input.selfieSHA256 == text(3),
              Int64(capture.recordedAt.timeIntervalSince1970 * 1000) == sqlite3_column_int64(query, 4),
              capture.input.workflowID?.uuidString == text(5) else { throw FaceWorkflowStorageFailure.invalidRecord }
        try validateCaptureEvent(db, capture: capture)
        return capture
    }

    private static func validateCaptureEvent(_ db: OpaquePointer, capture: SavedFaceCapture) throws {
        guard let id = capture.input.captureEventID else { return }
        let query = try PassportCaptureSchema.statement(db, "SELECT payload,payload_sha256,workflow_id FROM workflow_event WHERE event_id=?")
        defer { sqlite3_finalize(query) }
        try PassportCaptureSchema.bind(id.uuidString, at: 1, to: query)
        guard sqlite3_step(query) == SQLITE_ROW else { throw FaceWorkflowStorageFailure.missingRecord }
        let event = try payload(query, as: SavedWorkflowEvent.self, limit: 262144)
        try event.validate()
        guard event.id == id, event.workflowID == capture.input.workflowID,
              sqlite3_column_text(query, 2).map({ String(cString: $0) }) == event.workflowID.uuidString,
              event.action == "selfie.captured", event.captureID == capture.input.captureContext?.captureID,
              event.imageSHA256 == capture.input.selfieSHA256 else { throw FaceWorkflowStorageFailure.invalidRecord }
    }

    func loadFaceCapture(_ id: UUID) throws -> SavedFaceCapture {
        try recover()
        guard try exists() else { throw FaceWorkflowStorageFailure.missingRecord }
        return try withWorkflowDatabase { db in
            guard let capture = try Self.readFaceCapture(db, id: id) else { throw FaceWorkflowStorageFailure.missingRecord }
            return capture
        }
    }

    func latestFaceCaptureID() throws -> UUID? {
        try recover()
        guard try exists() else { return nil }
        return try withWorkflowDatabase { db in
            guard let value = try PassportCaptureSchema.string(db, "SELECT operation_id FROM face_capture ORDER BY rowid DESC LIMIT 1") else { return nil }
            guard let id = UUID(uuidString: value) else { throw FaceWorkflowStorageFailure.invalidRecord }
            return id
        }
    }

    func saveFaceStage(_ stage: SavedFaceStage) throws {
        let bytes = try Self.encode(stage, limit: 1024 * 1024)
        try withWorkflowDatabase { db in
            try Self.transaction(db) {
                guard let capture = try Self.readFaceCapture(db, id: stage.operationID) else { throw FaceWorkflowStorageFailure.missingRecord }
                try stage.validate(for: capture)
                if let existing = try Self.readStage(db, id: stage.id, capture: capture) {
                    guard try Self.encode(existing, limit: 1024 * 1024) == bytes else { throw FaceWorkflowStorageFailure.conflict }
                    return
                }
                guard try PassportCaptureSchema.integer(db, "SELECT count(*) FROM face_stage") < 4096 else {
                    throw FaceWorkflowStorageFailure.capacity
                }
                if let parent = stage.precedingAuraID {
                    guard let prior = try Self.readStage(db, id: parent, capture: capture), prior.engine == .aura else {
                        throw FaceWorkflowStorageFailure.invalidRecord
                    }
                    let query = try PassportCaptureSchema.statement(db, "SELECT count(*) FROM face_stage WHERE stage_id=? AND operation_id=? AND engine='aura'")
                    defer { sqlite3_finalize(query) }
                    try PassportCaptureSchema.bind(parent.uuidString, at: 1, to: query)
                    try PassportCaptureSchema.bind(stage.operationID.uuidString, at: 2, to: query)
                    guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_int(query, 0) == 1 else { throw FaceWorkflowStorageFailure.invalidRecord }
                }
                let query = try PassportCaptureSchema.statement(db, "INSERT INTO face_stage SELECT ?,?,?,COALESCE(max(sequence),0)+1,?,?,?,? FROM face_stage WHERE operation_id=? AND engine=?")
                defer { sqlite3_finalize(query) }
                try PassportCaptureSchema.bind(stage.id.uuidString, at: 1, to: query)
                try PassportCaptureSchema.bind(stage.operationID.uuidString, at: 2, to: query)
                try PassportCaptureSchema.bind(stage.engine.rawValue, at: 3, to: query)
                try PassportCaptureSchema.check(sqlite3_bind_int64(query, 4, Int64(stage.recordedAt.timeIntervalSince1970 * 1000)))
                if let parent = stage.precedingAuraID { try PassportCaptureSchema.bind(parent.uuidString, at: 5, to: query) }
                else { try PassportCaptureSchema.check(sqlite3_bind_null(query, 5)) }
                try PassportCaptureSchema.bind(SavedPassportCapture.digest(bytes), at: 6, to: query)
                try Self.bind(bytes, at: 7, to: query)
                try PassportCaptureSchema.bind(stage.operationID.uuidString, at: 8, to: query)
                try PassportCaptureSchema.bind(stage.engine.rawValue, at: 9, to: query)
                try PassportCaptureSchema.done(query)
            }
        }
    }

    func loadFaceStage(_ id: UUID, engine: SavedFaceStage.Engine) throws -> SavedFaceStage? {
        try withWorkflowDatabase { db in
            guard let capture = try Self.readFaceCapture(db, id: id) else { throw FaceWorkflowStorageFailure.missingRecord }
            let query = try PassportCaptureSchema.statement(db, "SELECT payload,payload_sha256,stage_id,preceding_aura_id,recorded_at_ms FROM face_stage WHERE operation_id=? AND engine=? ORDER BY sequence DESC LIMIT 1")
            defer { sqlite3_finalize(query) }
            try PassportCaptureSchema.bind(id.uuidString, at: 1, to: query)
            try PassportCaptureSchema.bind(engine.rawValue, at: 2, to: query)
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw ProtectedSQLiteError.unavailable(status) }
            let stage = try Self.payload(query, as: SavedFaceStage.self, limit: 1024 * 1024)
            try stage.validate(for: capture)
            guard stage.engine == engine, sqlite3_column_text(query, 2).map({ String(cString: $0) }) == stage.id.uuidString,
                  sqlite3_column_text(query, 3).map({ String(cString: $0) }) == stage.precedingAuraID?.uuidString,
                  sqlite3_column_int64(query, 4) == Int64(stage.recordedAt.timeIntervalSince1970 * 1000) else {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
            if let parent = stage.precedingAuraID {
                guard let prior = try Self.readStage(db, id: parent, capture: capture), prior.engine == .aura else {
                    throw FaceWorkflowStorageFailure.invalidRecord
                }
            }
            return stage
        }
    }

    private static func readStage(_ db: OpaquePointer, id: UUID, capture: SavedFaceCapture) throws -> SavedFaceStage? {
        let query = try PassportCaptureSchema.statement(db, "SELECT payload,payload_sha256,operation_id,engine,recorded_at_ms,preceding_aura_id FROM face_stage WHERE stage_id=?")
        defer { sqlite3_finalize(query) }
        try PassportCaptureSchema.bind(id.uuidString, at: 1, to: query)
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ProtectedSQLiteError.unavailable(status) }
        let stage = try payload(query, as: SavedFaceStage.self, limit: 1024 * 1024)
        try stage.validate(for: capture)
        func text(_ index: Int32) -> String? { sqlite3_column_text(query, index).map { String(cString: $0) } }
        guard stage.id == id, text(2) == stage.operationID.uuidString, text(3) == stage.engine.rawValue,
              sqlite3_column_int64(query, 4) == Int64(stage.recordedAt.timeIntervalSince1970 * 1000),
              text(5) == stage.precedingAuraID?.uuidString else { throw FaceWorkflowStorageFailure.invalidRecord }
        return stage
    }

    func appendWorkflowEvent(_ event: SavedWorkflowEvent) throws {
        try event.validate()
        let bytes = try Self.encode(event, limit: 262144)
        try withWorkflowDatabase(creating: true) { db in
            try Self.transaction(db) {
                let existing = try PassportCaptureSchema.statement(db, "SELECT payload,payload_sha256 FROM workflow_event WHERE event_id=?")
                defer { sqlite3_finalize(existing) }
                try PassportCaptureSchema.bind(event.id.uuidString, at: 1, to: existing)
                let status = sqlite3_step(existing)
                if status == SQLITE_ROW {
                    let saved = try Self.payload(existing, as: SavedWorkflowEvent.self, limit: 262144)
                    try saved.validate()
                    guard try Self.encode(saved, limit: 262144) == bytes else { throw FaceWorkflowStorageFailure.conflict }
                    return
                }
                guard status == SQLITE_DONE else { throw ProtectedSQLiteError.unavailable(status) }
                guard try PassportCaptureSchema.integer(db, "SELECT count(*) FROM workflow_event") < 100000,
                      try PassportCaptureSchema.integer(db, "SELECT COALESCE(sum(length(payload)),0) FROM workflow_event") + bytes.count <= 128 * 1024 * 1024 else {
                    throw FaceWorkflowStorageFailure.capacity
                }
                let query = try PassportCaptureSchema.statement(db, "INSERT INTO workflow_event SELECT ?,?,COALESCE(max(sequence),0)+1,?,?,?,? FROM workflow_event WHERE workflow_id=?")
                defer { sqlite3_finalize(query) }
                try PassportCaptureSchema.bind(event.id.uuidString, at: 1, to: query)
                try PassportCaptureSchema.bind(event.workflowID.uuidString, at: 2, to: query)
                try PassportCaptureSchema.check(sqlite3_bind_int64(query, 3, Int64(event.occurredAt.timeIntervalSince1970 * 1000)))
                try PassportCaptureSchema.bind(event.action, at: 4, to: query)
                try PassportCaptureSchema.bind(SavedPassportCapture.digest(bytes), at: 5, to: query)
                try Self.bind(bytes, at: 6, to: query)
                try PassportCaptureSchema.bind(event.workflowID.uuidString, at: 7, to: query)
                try PassportCaptureSchema.done(query)
            }
        }
    }

    static let workflowPageMaximumBytes = 1024 * 1024

    func loadWorkflowEvents(_ workflowID: UUID, after sequence: Int = 0) throws -> [SavedWorkflowEvent] {
        guard sequence >= 0 else { throw FaceWorkflowStorageFailure.invalidRecord }
        try recover()
        guard try exists() else { return [] }
        return try withWorkflowDatabase { db in
            let query = try PassportCaptureSchema.statement(db, "SELECT payload,payload_sha256,event_id,sequence,occurred_at_ms,action FROM workflow_event WHERE workflow_id=? AND sequence>? ORDER BY sequence LIMIT 256")
            defer { sqlite3_finalize(query) }
            try PassportCaptureSchema.bind(workflowID.uuidString, at: 1, to: query)
            try PassportCaptureSchema.check(sqlite3_bind_int64(query, 2, Int64(sequence)))
            var result: [SavedWorkflowEvent] = []
            var payloadBytes = 0
            while true {
                let status = sqlite3_step(query)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw ProtectedSQLiteError.unavailable(status) }
                try Task.checkCancellation()
                let count = Int(sqlite3_column_bytes(query, 0))
                guard (1...262144).contains(count) else { throw FaceWorkflowStorageFailure.invalidRecord }
                // Inspect length before decoding: a legal 256-row page could otherwise
                // materialize 64 MiB before the archive's own byte limit is checked.
                if payloadBytes + count > Self.workflowPageMaximumBytes { return result }
                result.append(try Self.validatedWorkflowEvent(query, workflowID: workflowID, sequence: sequence + result.count + 1))
                payloadBytes += count
            }
        }
    }

    func loadLatestMRZ() throws -> SavedMRZCapture? {
        try recover()
        guard try exists() else { return nil }
        return try withWorkflowDatabase { db in
            let query = try PassportCaptureSchema.statement(db, "SELECT payload,payload_sha256,event_id,workflow_id FROM workflow_event WHERE action='passport.mrz.captured' ORDER BY rowid DESC LIMIT 1")
            defer { sqlite3_finalize(query) }
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw ProtectedSQLiteError.unavailable(status) }
            let event = try Self.payload(query, as: SavedWorkflowEvent.self, limit: 262144)
            try event.validate()
            guard event.action == "passport.mrz.captured", let mrz = event.mrz,
                  sqlite3_column_text(query, 2).map({ String(cString: $0) }) == event.id.uuidString,
                  sqlite3_column_text(query, 3).map({ String(cString: $0) }) == event.workflowID.uuidString else {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
            return mrz
        }
    }

    func saveLiquidPass(_ event: SavedLiquidPass) throws {
        let bytes = try Self.encode(event, limit: 65536)
        try withWorkflowDatabase { db in
            try Self.transaction(db) {
                guard let capture = try Self.readFaceCapture(db, id: event.operationID),
                      let aura = try Self.readStage(db, id: event.auraID, capture: capture) else {
                    throw FaceWorkflowStorageFailure.missingRecord
                }
                var validation = PassValidationContext()
                validation.auras[aura.id] = aura
                try event.validate(capture: capture, aura: aura)
                try Self.validateSnapshotBinding(db, event: event, capture: capture, aura: aura, validation: &validation)
                let prior = try Self.readLiquidPasses(db, capture: capture, validation: &validation)
                if let existing = prior.first(where: { $0.id == event.id }) {
                    guard try Self.encode(existing, limit: 65536) == bytes else { throw FaceWorkflowStorageFailure.conflict }
                    return
                }
                let attempt = prior.filter { $0.attemptID == event.attemptID }
                if event.status == .pending {
                    guard attempt.isEmpty else { throw FaceWorkflowStorageFailure.conflict }
                    try Self.validateLiquidPassTerminalFit(event)
                } else {
                    guard attempt.count == 1, let pending = attempt.first, pending.status == .pending,
                          pending.auraID == event.auraID, pending.matches(event.descriptor) else {
                        throw FaceWorkflowStorageFailure.conflict
                    }
                }
                let terminated = Set(prior.filter { $0.status != .pending }.map(\.attemptID))
                let outstanding = prior.filter { $0.status == .pending && !terminated.contains($0.attemptID) }.count
                let globalOutstanding = try PassportCaptureSchema.integer(db,
                    "SELECT count(*) FROM liquid_pass_event AS p WHERE p.status='pending' AND NOT EXISTS (SELECT 1 FROM liquid_pass_event AS t WHERE t.attempt_id=p.attempt_id AND t.operation_id=p.operation_id AND t.status IN ('completed','failed'))")
                try Self.validateLiquidPassCapacity(status: event.status, encodedBytes: bytes.count,
                    operationRows: prior.count, operationOutstanding: outstanding,
                    globalRows: PassportCaptureSchema.integer(db, "SELECT count(*) FROM liquid_pass_event"),
                    globalOutstanding: globalOutstanding,
                    globalBytes: PassportCaptureSchema.integer(db, "SELECT COALESCE(sum(length(payload)),0) FROM liquid_pass_event"))
                let query = try PassportCaptureSchema.statement(db, "INSERT INTO liquid_pass_event VALUES(?,?,?,?,?,?,?,?,?)")
                defer { sqlite3_finalize(query) }
                for (index, value) in [event.id.uuidString, event.attemptID.uuidString, event.operationID.uuidString,
                                       event.auraID.uuidString, event.descriptor.task.rawValue, event.status.rawValue].enumerated() {
                    try PassportCaptureSchema.bind(value, at: Int32(index + 1), to: query)
                }
                try PassportCaptureSchema.check(sqlite3_bind_int64(query, 7, Int64(event.recordedAt.timeIntervalSince1970 * 1000)))
                try PassportCaptureSchema.bind(SavedPassportCapture.digest(bytes), at: 8, to: query)
                try Self.bind(bytes, at: 9, to: query)
                try PassportCaptureSchema.done(query)
            }
        }
    }

    /// Prove that this descriptor can carry a complete failure before starting inference.
    /// The legal 8192-character / 32768-byte output can expand to 49150 UTF-16 bytes
    /// in a binary plist: CRLF pairs are single Characters, followed by one combining cluster.
    private static func validateLiquidPassTerminalFit(_ pending: SavedLiquidPass) throws {
        let maximum = Double.greatestFiniteMagnitude
        let metrics = LiquidRuntimeMetrics(modelSetupMilliseconds: maximum,
            imagePreparationMilliseconds: maximum / 2, grammarPreparationMilliseconds: maximum / 3,
            prefillMilliseconds: maximum / 4, generationMilliseconds: maximum / 5,
            cleanupMilliseconds: maximum / 6, activeMemoryBytes: Int.max,
            cacheMemoryBytes: Int.max - 1, peakMemoryBytes: Int.max - 2)
        let output = String(repeating: "\r\n", count: 8191) + "\u{00E9}" + String(repeating: "\u{0301}", count: 8192)
        let failure = LiquidPassFailure(reason: .invalidOutput, rawOutput: output,
            promptTokens: Int.max - 3, generatedTokens: Int.max - 4, metrics: metrics)
        let terminal = pending.failed(failure, code: String(repeating: "a", count: 126) + "\u{00E9}",
            durationMilliseconds: maximum / 7)
        do { _ = try encode(terminal, limit: 65536) }
        catch FaceWorkflowStorageFailure.invalidRecord { throw FaceWorkflowStorageFailure.capacity }
    }

    /// Every admitted pending record reserves one terminal row and its maximum encoded
    /// size. Admission and release of that reservation occur inside the same write transaction.
    static func validateLiquidPassCapacity(status: SavedLiquidPass.Status, encodedBytes: Int,
                                          operationRows: Int, operationOutstanding: Int,
                                          globalRows: Int, globalOutstanding: Int, globalBytes: Int) throws {
        guard (1...65536).contains(encodedBytes), operationRows >= 0, globalRows >= operationRows,
              (0...operationRows).contains(operationOutstanding),
              (operationOutstanding...globalRows).contains(globalOutstanding), globalBytes >= 0,
              status == .pending || (operationOutstanding > 0 && globalOutstanding > 0) else {
            throw FaceWorkflowStorageFailure.invalidRecord
        }
        guard operationRows < 1024, globalRows < 8192 else { throw FaceWorkflowStorageFailure.capacity }
        let delta = status == .pending ? 1 : -1
        let operationReserved = operationOutstanding + delta
        let globalReserved = globalOutstanding + delta
        // Check counts first so multiplication is bounded even for invalid over-capacity stores.
        guard operationRows + 1 + operationReserved <= 1024,
              globalRows + 1 + globalReserved <= 8192,
              globalBytes <= 32 * 1024 * 1024,
              globalBytes + encodedBytes + globalReserved * 65536 <= 32 * 1024 * 1024 else {
            throw FaceWorkflowStorageFailure.capacity
        }
    }

    func loadLiquidPasses(_ operationID: UUID) throws -> [SavedLiquidPass] {
        try recover()
        guard try exists() else { throw FaceWorkflowStorageFailure.missingRecord }
        return try withWorkflowDatabase { db in
            try Self.readLiquidPasses(db, operationID: operationID)
        }
    }

    /// Validation reuse is confined to one synchronous database operation. Nothing trusted
    /// survives connection closure: subsequent reads must authenticate the evidence again.
    private struct PassValidationContext {
        var snapshot: SavedComparisonSnapshot?
        var auras: [UUID: SavedFaceStage] = [:]
        var requests: [UUID: LiquidPassRequest] = [:]
    }

    static func readLiquidPasses(_ db: OpaquePointer, operationID: UUID) throws -> [SavedLiquidPass] {
        // Bind capture, snapshot and all attempts to one SQLite read snapshot, including
        // when another owner is appending evidence concurrently.
        try transaction(db, immediate: false) {
            guard let capture = try readFaceCapture(db, id: operationID) else { throw FaceWorkflowStorageFailure.missingRecord }
            var validation = PassValidationContext()
            return try readLiquidPasses(db, capture: capture, validation: &validation)
        }
    }

    private static func readLiquidPasses(_ db: OpaquePointer, capture: SavedFaceCapture,
                                       validation: inout PassValidationContext) throws -> [SavedLiquidPass] {
        let query = try PassportCaptureSchema.statement(db, "SELECT payload,payload_sha256,event_id,attempt_id,aura_id,pass,status,recorded_at_ms FROM liquid_pass_event WHERE operation_id=? ORDER BY rowid")
        defer { sqlite3_finalize(query) }
        try PassportCaptureSchema.bind(capture.input.operationID.uuidString, at: 1, to: query)
        var events: [SavedLiquidPass] = []
        var attempts: [UUID: SavedLiquidPass] = [:]
        var terminalAttempts: Set<UUID> = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return events }
            guard status == SQLITE_ROW, events.count < 1024 else { throw FaceWorkflowStorageFailure.invalidRecord }
            try Task.checkCancellation()
            let event = try payload(query, as: SavedLiquidPass.self, limit: 65536)
            let aura: SavedFaceStage
            if let cached = validation.auras[event.auraID] { aura = cached }
            else {
                guard let stored = try readStage(db, id: event.auraID, capture: capture) else { throw FaceWorkflowStorageFailure.missingRecord }
                validation.auras[event.auraID] = stored
                aura = stored
            }
            try event.validate(capture: capture, aura: aura)
            try validateSnapshotBinding(db, event: event, capture: capture, aura: aura, validation: &validation)
            func text(_ index: Int32) -> String? { sqlite3_column_text(query, index).map { String(cString: $0) } }
            guard event.id.uuidString == text(2), event.attemptID.uuidString == text(3), event.auraID.uuidString == text(4),
                  event.descriptor.task.rawValue == text(5), event.status.rawValue == text(6),
                  Int64(event.recordedAt.timeIntervalSince1970 * 1000) == sqlite3_column_int64(query, 7) else {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
            if event.status == .pending {
                guard attempts[event.attemptID] == nil else { throw FaceWorkflowStorageFailure.invalidRecord }
                attempts[event.attemptID] = event
            } else {
                guard let pending = attempts[event.attemptID], !terminalAttempts.contains(event.attemptID),
                      pending.auraID == event.auraID, pending.matches(event.descriptor) else { throw FaceWorkflowStorageFailure.invalidRecord }
                terminalAttempts.insert(event.attemptID)
            }
            events.append(event)
        }
    }

    func saveComparisonSnapshot(_ snapshot: SavedComparisonSnapshot) throws {
        let bytes = try Self.encode(snapshot, limit: 9 * 1024 * 1024)
        try withWorkflowDatabase { db in
            try Self.transaction(db) {
                guard let capture = try Self.readFaceCapture(db, id: snapshot.operationID) else { throw FaceWorkflowStorageFailure.missingRecord }
                try snapshot.validate(capture: capture)
                if let existing = try Self.readComparisonSnapshot(db, capture: capture) {
                    guard try Self.encode(existing, limit: 9 * 1024 * 1024) == bytes else { throw FaceWorkflowStorageFailure.conflict }
                    return
                }
                try Self.validateSnapshotArchive(db, snapshot: snapshot, capture: capture, requireCurrentBoundary: true)
                guard try PassportCaptureSchema.integer(db, "SELECT COALESCE(sum(length(payload)),0) FROM comparison_snapshot") + bytes.count <= 128 * 1024 * 1024 else { throw FaceWorkflowStorageFailure.capacity }
                let query = try PassportCaptureSchema.statement(db, "INSERT INTO comparison_snapshot VALUES(?,?,?)")
                defer { sqlite3_finalize(query) }
                try PassportCaptureSchema.bind(snapshot.operationID.uuidString, at: 1, to: query)
                try PassportCaptureSchema.bind(SavedPassportCapture.digest(bytes), at: 2, to: query)
                try Self.bind(bytes, at: 3, to: query)
                try PassportCaptureSchema.done(query)
            }
        }
    }

    func loadComparisonSnapshot(_ operationID: UUID) throws -> SavedComparisonSnapshot? {
        try withWorkflowDatabase { db in
            guard let capture = try Self.readFaceCapture(db, id: operationID) else { throw FaceWorkflowStorageFailure.missingRecord }
            return try Self.readComparisonSnapshot(db, capture: capture)
        }
    }

    private static func readComparisonSnapshot(_ db: OpaquePointer, capture: SavedFaceCapture) throws -> SavedComparisonSnapshot? {
        let query = try PassportCaptureSchema.statement(db, "SELECT payload,payload_sha256,operation_id FROM comparison_snapshot WHERE operation_id=?")
        defer { sqlite3_finalize(query) }
        try PassportCaptureSchema.bind(capture.input.operationID.uuidString, at: 1, to: query)
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ProtectedSQLiteError.unavailable(status) }
        let snapshot = try payload(query, as: SavedComparisonSnapshot.self, limit: 9 * 1024 * 1024)
        try snapshot.validate(capture: capture)
        try validateSnapshotArchive(db, snapshot: snapshot, capture: capture)
        guard sqlite3_column_text(query, 2).map({ String(cString: $0) }) == snapshot.operationID.uuidString else { throw FaceWorkflowStorageFailure.invalidRecord }
        return snapshot
    }

    private static func validateSnapshotBinding(_ db: OpaquePointer, event: SavedLiquidPass, capture: SavedFaceCapture,
                                                aura: SavedFaceStage, validation: inout PassValidationContext) throws {
        guard event.descriptor.profileID.hasSuffix("-v4") else { return }
        let expected: LiquidPassRequest
        if let request = validation.requests[aura.id] { expected = request }
        else {
            if validation.snapshot == nil {
                guard let snapshot = try readComparisonSnapshot(db, capture: capture) else { throw FaceWorkflowStorageFailure.missingRecord }
                validation.snapshot = snapshot
            }
            guard let snapshot = validation.snapshot else { throw FaceWorkflowStorageFailure.missingRecord }
            expected = try LiquidPassEvidence.request(capture: capture, aura: aura, snapshot: snapshot)
            validation.requests[aura.id] = expected
        }
        try event.descriptor.validateEvidence(request: expected)
    }

    private static func validateSnapshotArchive(_ db: OpaquePointer, snapshot: SavedComparisonSnapshot,
                                                capture: SavedFaceCapture, requireCurrentBoundary: Bool = false) throws {
        // The immutable archive must be the exact stored prefix, not caller-supplied telemetry.
        if let reason = snapshot.unavailableReason {
            guard let expected = snapshot.unavailableBoundary else { throw FaceWorkflowStorageFailure.invalidRecord }
            let actual = try historicalBoundary(db, capture: capture, through: requireCurrentBoundary ? nil : expected)
            guard actual.boundary == expected else { throw FaceWorkflowStorageFailure.conflict }
            switch (reason, actual.outcome) {
            case (.missingBoundary, .missing), (.supersededCapture, .superseded), (.capacity, .capacity): return
            default: throw FaceWorkflowStorageFailure.conflict
            }
        }
        guard let archive = snapshot.archive else { return }
        if capture.input.captureEventID != nil {
            guard case .found(let original) = try historicalBoundary(db, capture: capture).outcome,
                  original.throughEventID == archive.throughEventID else { throw FaceWorkflowStorageFailure.conflict }
        }
        let query = try PassportCaptureSchema.statement(db, "SELECT payload,payload_sha256,event_id,sequence,occurred_at_ms,action FROM workflow_event WHERE workflow_id=? ORDER BY sequence LIMIT ?")
        defer { sqlite3_finalize(query) }
        try PassportCaptureSchema.bind(archive.workflowID.uuidString, at: 1, to: query)
        try PassportCaptureSchema.check(sqlite3_bind_int(query, 2, Int32(archive.events.count)))
        for (index, expected) in archive.events.enumerated() {
            guard sqlite3_step(query) == SQLITE_ROW else { throw FaceWorkflowStorageFailure.missingRecord }
            let stored = try validatedWorkflowEvent(query, workflowID: archive.workflowID, sequence: index + 1)
            guard try encode(stored, limit: 262144) == encode(expected, limit: 262144) else {
                throw FaceWorkflowStorageFailure.conflict
            }
        }
    }

    private static func historicalBoundary(_ db: OpaquePointer, capture: SavedFaceCapture,
                                           through cutoff: SavedComparisonSnapshot.ScanBoundary? = nil) throws -> (outcome: SavedComparisonSnapshot.HistoricalBoundary, boundary: SavedComparisonSnapshot.ScanBoundary) {
        var scanner = SavedComparisonSnapshot.HistoricalScanner(capture: capture)
        guard let workflowID = capture.input.workflowID else { return (.missing, scanner.boundary) }
        let maximum = cutoff?.sequence ?? 4096
        let query = try PassportCaptureSchema.statement(db, "SELECT payload,payload_sha256,event_id,sequence,occurred_at_ms,action FROM workflow_event WHERE workflow_id=? AND sequence<=? ORDER BY sequence")
        defer { sqlite3_finalize(query) }
        try PassportCaptureSchema.bind(workflowID.uuidString, at: 1, to: query)
        try PassportCaptureSchema.check(sqlite3_bind_int(query, 2, Int32(maximum)))
        while scanner.count < maximum {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return (.missing, scanner.boundary) }
            guard status == SQLITE_ROW else { throw FaceWorkflowStorageFailure.invalidRecord }
            let event = try validatedWorkflowEvent(query, workflowID: workflowID, sequence: scanner.count + 1)
            if let outcome = try scanner.consume(event) { return (outcome, scanner.boundary) }
        }
        return (scanner.count >= 4096 ? .capacity : .missing, scanner.boundary)
    }

    /// All workflow readers bind indexed metadata to the exact authenticated payload.
    private static func validatedWorkflowEvent(_ query: OpaquePointer, workflowID: UUID, sequence: Int) throws -> SavedWorkflowEvent {
        let event = try payload(query, as: SavedWorkflowEvent.self, limit: 262144)
        try event.validate()
        func text(_ index: Int32) -> String? { sqlite3_column_text(query, index).map { String(cString: $0) } }
        guard event.workflowID == workflowID, event.id.uuidString == text(2),
              sqlite3_column_int64(query, 3) == Int64(sequence),
              sqlite3_column_int64(query, 4) == Int64(event.occurredAt.timeIntervalSince1970 * 1000),
              event.action == text(5) else { throw FaceWorkflowStorageFailure.invalidRecord }
        return event
    }

}

#if DEBUG
import CoreFoundation

/// Developer-only file handoff. Reads committed evidence under the inference lease and
/// never accepts caller paths, opens a listener, exports image pixels, or exports keys.
actor DebugComparisonDiagnostics {
    typealias Lease = @Sendable (@escaping @Sendable () async throws -> Data) async throws -> Data
    static let maximumRequestBytes = 4096
    static let maximumResponseBytes = 4 * 1024 * 1024
    private let directory: URL
    private let persistence: FaceWorkflowPersistence
    private let lease: Lease
    private let now: @Sendable () -> Date
    private var processing = false
    private var lastFingerprint: String?
    private var handled: [UUID] = []

    init(directory: URL, persistence: FaceWorkflowPersistence,
         lease: @escaping Lease = { work in try await FaceInferenceScheduler.shared.run(work) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.persistence = persistence; self.lease = lease; self.now = now
    }

    static func live(persistence: FaceWorkflowPersistence, directory: URL? = nil) throws -> DebugComparisonDiagnostics {
        DebugComparisonDiagnostics(directory: try directory ?? liveDirectory(), persistence: persistence)
    }

    private static func liveDirectory() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("KenshikiDiagnostics", isDirectory: true)
    }

    /// Caller holds the same inference lease as export writes, ordering erasure after
    /// in-flight inference and export settlement without retaining a database connection.
    static func eraseExports(directory: URL? = nil) throws {
        let location = try directory ?? liveDirectory()
        var info = stat()
        guard location.path.withCString({ lstat($0, &info) }) == 0 else {
            if errno == ENOENT { return }
            throw Failure.unsafeFile
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeFile }
        for name in ["request.json", "response.json"] {
            let file = location.appendingPathComponent(name)
            if file.path.withCString({ lstat($0, &info) }) == 0 { try FileManager.default.removeItem(at: file) }
            else if errno != ENOENT { throw Failure.unsafeFile }
        }
    }

    func run() async {
        while !Task.isCancelled {
            do { try await processNextRequest() }
            catch is CancellationError { return }
            catch { /* A locked or unavailable protected directory is retried on the next foreground tick. */ }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    func processNextRequest() async throws {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        try Task.checkCancellation()
        try prepareDirectory()
        try expireResponse()
        var requestID: UUID?
        var fingerprint: String?
        do {
            guard let file = try readRequest() else { return }
            fingerprint = SavedPassportCapture.digest(file.data) + ":" + String(file.modified.timeIntervalSince1970)
            if fingerprint == lastFingerprint { return }
            let request = try Request(file.data)
            requestID = request.id
            if handled.contains(request.id) { lastFingerprint = fingerprint; return }
            let age = now().timeIntervalSince(file.modified)
            guard age >= -5, age <= 300 else { throw Failure.staleRequest }
            let persistence = self.persistence
            let clock = self.now
            let modified = file.modified
            _ = try await lease {
                try Self.validateFreshness(modified: modified, now: clock())
                let data = try await Self.response(request: request, persistence: persistence)
                try Task.checkCancellation()
                try Self.validateFreshness(modified: modified, now: clock())
                try await self.write(data)
                return Data()
            }
            try Task.checkCancellation()
            handled.append(request.id)
            if handled.count > 32 { handled.removeFirst() }
            lastFingerprint = fingerprint
        } catch {
            try Task.checkCancellation()
            // Parse only the identifier for correlation when the rest of a request is invalid.
            if requestID == nil, let file = try? readRequest(),
               let object = try? JSONSerialization.jsonObject(with: file.data) as? [String: Any],
               let text = object["requestID"] as? String { requestID = UUID(uuidString: text) }
            let code = (error as? Failure)?.rawValue ?? Self.failureCode(error)
            let object: [String: Any] = ["version": 1, "kind": "kenshiki.debug-comparison-response",
                "requestID": requestID.map { $0.uuidString as Any } ?? NSNull(), "status": "failed", "errorCode": code]
            try write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            lastFingerprint = fingerprint
        }
    }

    private enum Failure: String, Error {
        case invalidRequest = "request_invalid", staleRequest = "request_stale", unsafeFile = "file_unsafe"
        case oversizedRequest = "request_too_large", oversizedResponse = "report_too_large"
        case missingComparison = "comparison_missing", invalidEvidence = "evidence_invalid"
    }
    private struct Request: Sendable {
        let id: UUID
        let operationID: UUID?
        init(_ data: Data) throws {
            guard data.count <= maximumRequestBytes,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["version", "requestID", "operationID"]),
                  let version = object["version"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
                  let text = object["requestID"] as? String, let id = UUID(uuidString: text) else {
                throw Failure.invalidRequest
            }
            self.id = id
            if let text = object["operationID"] as? String, let operationID = UUID(uuidString: text) { self.operationID = operationID }
            else if object["operationID"] == nil { operationID = nil }
            else { throw Failure.invalidRequest }
        }
    }
    private struct RequestFile { let data: Data; let modified: Date }

    private func prepareDirectory() throws {
        var info = stat()
        if directory.path.withCString({ lstat($0, &info) }) != 0 {
            guard errno == ENOENT else { throw Failure.unsafeFile }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            guard directory.path.withCString({ lstat($0, &info) }) == 0 else { throw Failure.unsafeFile }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeFile }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        var location = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try location.setResourceValues(values)
    }

    private func expireResponse() throws {
        let target = directory.appendingPathComponent("response.json")
        var info = stat()
        guard target.path.withCString({ lstat($0, &info) }) == 0 else {
            if errno == ENOENT { return }
            throw Failure.unsafeFile
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafeFile }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        if now().timeIntervalSince1970 - modified > 300 { try FileManager.default.removeItem(at: target) }
    }

    private func readRequest() throws -> RequestFile? {
        let path = directory.appendingPathComponent("request.json").path
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafeFile }
        guard info.st_size <= Self.maximumRequestBytes else { throw Failure.oversizedRequest }
        let data = try handle.read(upToCount: Self.maximumRequestBytes + 1) ?? Data()
        guard data.count <= Self.maximumRequestBytes else { throw Failure.oversizedRequest }
        return RequestFile(data: data, modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000))
    }

    private func write(_ data: Data) throws {
        guard data.count <= Self.maximumResponseBytes else { throw Failure.oversizedResponse }
        try Task.checkCancellation()
        let target = directory.appendingPathComponent("response.json")
        var info = stat()
        if target.path.withCString({ lstat($0, &info) }) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafeFile }
        } else if errno != ENOENT { throw Failure.unsafeFile }
        try data.write(to: target, options: [.atomic, .completeFileProtection])
        var location = target
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try location.setResourceValues(values)
    }

    private static func response(request: Request, persistence: FaceWorkflowPersistence) async throws -> Data {
        try Task.checkCancellation()
        let operationID: UUID
        if let requested = request.operationID { operationID = requested }
        else {
            guard let latest = try await persistence.latestCaptureID() else { throw Failure.missingComparison }
            operationID = latest
        }
        let capture = try await persistence.loadCapture(operationID)
        try capture.validate()
        let aura = try await persistence.loadStage(operationID, .aura)
        let legacy = try await persistence.loadStage(operationID, .liquid)
        let passes = try await persistence.loadPasses(operationID)
        let snapshot = try await persistence.loadSnapshot(operationID)
        if let aura { try aura.validate(for: capture) }
        if let legacy {
            try legacy.validate(for: capture)
            guard legacy.precedingAuraID == aura?.id else { throw Failure.invalidEvidence }
        }
        let terminated = Set(passes.filter { $0.status != .pending }.map(\.attemptID))
        let unresolved = passes.filter { $0.status == .pending && !terminated.contains($0.attemptID) }.count
        let visual = aura.flatMap { value in passes.isEmpty ? legacy?.liquid : LegacyLiquidArchive.presentation(
            capture: capture, aura: value, events: passes, settled: true, unavailableReason: snapshot?.unavailableReason) }
        let input = FaceInputTelemetry(operationID: operationID, referenceSHA256: capture.input.referenceSHA256,
            selfieSHA256: capture.input.selfieSHA256, referenceBytes: capture.input.reference.count,
            selfieBytes: capture.input.selfie.count, captureContext: capture.input.captureContext)
        let phase: FaceComparisonController.Phase = aura?.aura.map { .completed($0.score) } ?? aura?.errorCode.map { .failed($0) } ?? .idle
        let visualPhase: FaceComparisonController.VisualPhase = visual.map { .completed($0) } ?? legacy?.errorCode.map { .failed($0) } ?? .idle
        guard let text = FaceComparisonReportExport.make(input: input, phase: phase, visual: visualPhase,
            auraTelemetry: aura?.aura?.telemetry ?? [], duration: aura?.durationMilliseconds,
            visualDuration: visual?.durationMilliseconds),
            var report = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw Failure.invalidEvidence }
        var exported: [[String: Any]] = []
        var passBytes = 0
        for event in passes {
            try Task.checkCancellation()
            var object = try event.exportObject()
            if var descriptor = object["descriptor"] as? [String: Any] {
                if let context = descriptor["inputContext"] { descriptor["inputContext"] = redactedInput(context) }
                if let input = descriptor["modelInput"] { descriptor["modelInput"] = redactedInput(input) }
                object["descriptor"] = descriptor
            }
            passBytes += try JSONSerialization.data(withJSONObject: object).count
            guard passBytes <= maximumResponseBytes - 128 * 1024 else { throw Failure.oversizedResponse }
            exported.append(object)
        }
        report["liquidPasses"] = exported
        report["diagnosticObservation"] = ["source": "durable_records", "inferenceActive": false,
            "unresolvedPendingAttemptCount": unresolved, "reconciliationRequired": unresolved > 0,
            "inputDisclosure": "document_fields_redacted"] as [String: Any]
        if let snapshot, var metadata = try JSONSerialization.jsonObject(with: snapshot.manifest()) as? [String: Any] {
            metadata["unavailableReason"] = snapshot.unavailableReason?.rawValue
            if let boundary = snapshot.unavailableBoundary {
                metadata["unavailableBoundary"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(boundary))
            }
            report["comparisonSnapshot"] = metadata
        }
        if let archive = snapshot?.archive {
            var actions: [String: Int] = [:]
            for event in archive.events { try Task.checkCancellation(); actions[event.action, default: 0] += 1 }
            report["workflowSummary"] = ["workflowID": archive.workflowID.uuidString,
                "throughEventID": archive.throughEventID.uuidString, "eventCount": archive.events.count,
                "motionSampleCount": archive.events.reduce(0) { $0 + ($1.motion?.samples.count ?? 0) },
                "interactionCounts": actions, "rawArchiveIncluded": false] as [String: Any]
        }
        if let passport = capture.input.passport {
            report["passportReference"] = ["source": "stored_nfc", "captureID": passport.id.uuidString,
                "capturedAt": passport.capturedAt.formatted(.iso8601),
                "serverVerification": passport.serverVerification.map { $0.exportObject as Any } ?? "not_requested",
                "securityObjectSHA256": passport.securityObjectSHA256] as [String: Any]
        }
        let object: [String: Any] = ["version": 1, "kind": "kenshiki.debug-comparison-response",
            "requestID": request.id.uuidString, "operationID": operationID.uuidString, "status": "completed", "report": report]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= maximumResponseBytes else { throw Failure.oversizedResponse }
        return data
    }

    private static func redactedInput(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, entry in
                guard entry.key != "birthDateYYMMDD", entry.key != "possibleCurrentAges" else { return }
                result[entry.key] = redactedInput(entry.value)
            }
        }
        if let array = value as? [Any] { return array.map(redactedInput) }
        return value
    }

    private static func validateFreshness(modified: Date, now: Date) throws {
        let age = now.timeIntervalSince(modified)
        guard age >= -5, age <= 300 else { throw Failure.staleRequest }
    }

    private static func failureCode(_ error: Error) -> String {
        if let failure = error as? FaceWorkflowStorageFailure {
            switch failure {
            case .invalidRecord, .conflict: return "evidence_invalid"
            case .missingRecord: return "comparison_missing"
            case .capacity: return "report_too_large"
            case .unavailable: return "storage_unavailable"
            }
        }
        return "storage_unavailable"
    }
}
#endif
