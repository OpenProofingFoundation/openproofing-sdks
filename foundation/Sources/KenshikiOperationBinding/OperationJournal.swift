import Foundation
import SQLCipher
@_spi(StorageAdapter) @_spi(StorageTestFixture) import KenshikiProtectedStorage

public enum OperationJournalError: Error, Equatable {
    case unavailable, unsupportedSchema, staleIntent, conflictingPreparation, missingIntent, capacity, recoveryMaterialRetired
}

public struct JournalIntent: Codable, Equatable, Sendable {
    public let id: String
    public let resourceID: String
    public let kind: String
    public let content: Data
    public let epoch: Int64
    public let generation: Int64
    public let revoking: Bool
}

public enum JournalRetainedOutcome: String, Codable, Sendable { case accepted, revoked, uncertain }
public enum JournalRetentionPolicy: Sendable { case ordinary, delegated }

public struct JournalRecord: Sendable {
    public let intent: JournalIntent
    public let operation: SealedOperation?
    public let prepared: Data?
    public let result: Data?
    public let state: String
    public let recoveryData: Data?
    public let recoveryExpiresAt: Int64?
    public let authorization: Data?
    public let admittedAt: Int64
    public let materialExpiresAt: Int64?
    public let contentDigest: String
    public let approvalID: String?
    public let retainedOutcome: JournalRetainedOutcome?
}

/// Minimal business association retained after ordinary request/result material is scrubbed.
public struct JournalOperationAssociation: Equatable, Sendable {
    public let operationID: String
    public let targetID: String
    public let kind: String
    public let contentDigest: String
    public let approvalID: String
}

/// One durable local consent/operation ledger. SQLite transactions serialize independent handles;
/// the namespace generation survives erase so a suspended old handle cannot publish afterward.
/// SQLCipher, hardware key admission and file protection are shared with the evidence stores.
/// No keyed connection survives a public operation.
public final class OperationJournal: @unchecked Sendable {
    private let store: ProtectedSQLiteStore
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let namespace: String
    public let url: URL
    private let now: @Sendable () -> Int64

    public convenience init(url: URL, namespace: String, identity: StoreKeyIdentity,
        legacyPlaintextURL: URL? = nil,
        retentionPolicy: JournalRetentionPolicy = .ordinary,
        legacyNamespacePolicy: JournalRetentionPolicy? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) throws {
        let store = try ProtectedSQLiteStore(databaseURL: url, identity: identity,
            legacyPlaintextURL: legacyPlaintextURL)
        try store.finishLegacyCutover()
        try self.init(store: store, namespace: namespace, retentionPolicy: retentionPolicy,
            legacyNamespacePolicy: legacyNamespacePolicy, now: now)
    }

    /// Reviewed adapters can compose an existing protected store without exporting a key or handle.
    @_spi(StorageAdapter)
    public init(store: ProtectedSQLiteStore, namespace: String,
        retentionPolicy: JournalRetentionPolicy = .ordinary,
        legacyNamespacePolicy: JournalRetentionPolicy? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) throws {
        guard !namespace.isEmpty, !namespace.contains("\0"), namespace.utf8.count <= 512 else {
            throw OperationJournalError.unavailable
        }
        self.url = store.databaseURL
        self.namespace = namespace
        self.now = now
        self.store = store
        try withDatabase {
        do {
            sqlite3_busy_timeout(database, 5_000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            try transaction {
                let version = try rows("PRAGMA user_version").first?.first?.integer ?? 0
                guard (0...8).contains(version) else { throw OperationJournalError.unsupportedSchema }
                try execute("CREATE TABLE IF NOT EXISTS journal_namespace(namespace TEXT PRIMARY KEY,generation INTEGER NOT NULL,admission_closed INTEGER NOT NULL DEFAULT 0,admission_grant BLOB)")
                try execute("CREATE TABLE IF NOT EXISTS journal_resource(namespace TEXT NOT NULL,resource TEXT NOT NULL,epoch INTEGER NOT NULL,current_id TEXT NOT NULL,PRIMARY KEY(namespace,resource))")
                try execute("CREATE TABLE IF NOT EXISTS journal_operation(namespace TEXT NOT NULL,id TEXT NOT NULL,resource TEXT NOT NULL,kind TEXT NOT NULL,content BLOB NOT NULL,epoch INTEGER NOT NULL,generation INTEGER NOT NULL,revoking INTEGER NOT NULL,state TEXT NOT NULL,operation BLOB,prepared BLOB,result BLOB,recovery BLOB,authorization BLOB,PRIMARY KEY(namespace,id))")
                if version == 1 {
                    try execute("ALTER TABLE journal_operation ADD COLUMN recovery BLOB")
                    try execute("ALTER TABLE journal_operation ADD COLUMN authorization BLOB")
                }
                if version == 1 || version == 2 {
                    try execute("ALTER TABLE journal_namespace ADD COLUMN admission_closed INTEGER NOT NULL DEFAULT 0")
                    try execute("ALTER TABLE journal_namespace ADD COLUMN admission_grant BLOB")
                }
                try execute("CREATE TABLE IF NOT EXISTS journal_custody(singleton INTEGER PRIMARY KEY CHECK(singleton=1),admission_closed INTEGER NOT NULL)")
                try execute("INSERT OR IGNORE INTO journal_custody(singleton,admission_closed) VALUES(1,0)")
                if version < 5 { try execute("ALTER TABLE journal_custody ADD COLUMN admission_epoch INTEGER NOT NULL DEFAULT 0") }
                if !(try rows("PRAGMA table_info(journal_custody)")).contains(where: { $0[1].text == "protective_only" }) {
                    try execute("ALTER TABLE journal_custody ADD COLUMN protective_only INTEGER NOT NULL DEFAULT 0")
                }
                if !(try rows("PRAGMA table_info(journal_custody)")).contains(where: { $0[1].text == "protective_owner" }) {
                    try execute("ALTER TABLE journal_custody ADD COLUMN protective_owner TEXT")
                }
                try execute("CREATE TABLE IF NOT EXISTS journal_protective_kind(kind TEXT PRIMARY KEY)")
                if version < 6 {
                    try execute("ALTER TABLE journal_operation ADD COLUMN recovery_expires_at INTEGER")
                    try execute("UPDATE journal_operation SET recovery_expires_at=unixepoch()+86400 WHERE kind='consented_photo_upload' AND recovery IS NOT NULL")
                }
                try execute("CREATE TABLE IF NOT EXISTS journal_retention(namespace TEXT NOT NULL,id TEXT NOT NULL,resource TEXT NOT NULL,kind TEXT NOT NULL,content_digest TEXT NOT NULL,admitted_at INTEGER NOT NULL,material_expires_at INTEGER,approval_id TEXT,retained_outcome TEXT,outcome_fact TEXT,PRIMARY KEY(namespace,id))")
                if !(try rows("PRAGMA table_info(journal_retention)")).contains(where: { $0[1].text == "outcome_fact" }) {
                    try execute("ALTER TABLE journal_retention ADD COLUMN outcome_fact TEXT")
                }
                try execute("CREATE TABLE IF NOT EXISTS journal_retention_control(singleton INTEGER PRIMARY KEY CHECK(singleton=1),checkpoint_pending INTEGER NOT NULL)")
                if !(try rows("PRAGMA table_info(journal_retention_control)")).contains(where: { $0[1].text == "checkpoint_completed" }) {
                    try execute("ALTER TABLE journal_retention_control ADD COLUMN checkpoint_completed INTEGER NOT NULL DEFAULT 0")
                }
                try execute("INSERT OR IGNORE INTO journal_retention_control(singleton,checkpoint_pending) VALUES(1,0)")
                if !(try rows("PRAGMA table_info(journal_namespace)")).contains(where: { $0[1].text == "retention_policy" }) {
                    try execute("ALTER TABLE journal_namespace ADD COLUMN retention_policy TEXT")
                }
                try execute("INSERT OR IGNORE INTO journal_namespace(namespace,generation,admission_closed) SELECT ?,0,admission_closed FROM journal_custody WHERE singleton=1", [.text(namespace)])
                try execute("UPDATE journal_namespace SET retention_policy=? WHERE namespace=? AND retention_policy IS NULL",
                    [.text(retentionPolicy == .delegated ? "delegated" : "ordinary"), .text(namespace)])
                if let legacyNamespacePolicy {
                    try execute("UPDATE journal_namespace SET retention_policy=? WHERE retention_policy IS NULL",
                        [.text(legacyNamespacePolicy == .delegated ? "delegated" : "ordinary")])
                }
                try migrateRetention()
                try execute("PRAGMA user_version=8")
            }
            try protectFiles()
            if try rows("SELECT checkpoint_pending>checkpoint_completed FROM journal_retention_control WHERE singleton=1").first?.first?.integer == 1 {
                try checkpointRetention()
            }
        } catch { throw error }
        }
    }

    /// Call synchronously when recording the owner's desired state, before asynchronous work.
    /// Identical queued intent retains its identity for retries; changed intent supersedes old work.
    public func declare(resourceID: String, kind: String, content: Data, revoking: Bool, recoveryData: Data? = nil, expectedGeneration: Int64? = nil, operationID: String? = nil, expectedAdmissionEpoch: Int64? = nil, recoveryExpiresAt: Int64? = nil, approvalID: String? = nil, materialExpiresAt: Int64? = nil) throws -> JournalIntent {
        try lockedTransaction {
            try validateAdmissionEpoch(expectedAdmissionEpoch)
            return try declareUnlocked(resourceID: resourceID, kind: kind, content: content, revoking: revoking, recoveryData: recoveryData, expectedGeneration: expectedGeneration, operationID: operationID, recoveryExpiresAt: recoveryExpiresAt, approvalID: approvalID, materialExpiresAt: materialExpiresAt)
        }
    }
    /// Allocate operation identity and target together, reusing exact approved content atomically.
    public func declareGeneratedTarget(kind: String, content: Data, recoveryData: Data?, expectedGeneration: Int64, expectedAdmissionEpoch: Int64? = nil, recoveryExpiresAt: Int64? = nil, approvalID: String? = nil) throws -> JournalIntent {
        try lockedTransaction {
            try validateAdmissionEpoch(expectedAdmissionEpoch)
            try validateProtectivePolicy(kind: kind, revoking: false, recoveryData: recoveryData)
            guard expectedGeneration == (try currentGeneration()),
                  try rows("SELECT admission_closed FROM journal_custody WHERE singleton=1").first?.first?.integer == 0,
                  try rows("SELECT admission_closed FROM journal_namespace WHERE namespace=?", [.text(namespace)]).first?.first?.integer == 0 else {
                throw OperationJournalError.staleIntent
            }
            if let id = try rows("SELECT t.id FROM journal_retention t LEFT JOIN journal_resource r ON r.namespace=t.namespace AND r.current_id=t.id WHERE t.namespace=? AND t.kind=? AND t.content_digest=? AND (t.approval_id IS ? OR ? IS NULL) AND (r.current_id IS NOT NULL OR t.retained_outcome IS NOT NULL) ORDER BY t.admitted_at DESC LIMIT 1",
                [.text(namespace), .text(kind), .text(SealedOperation.sha256(content)), approvalID.map(SQLValue.text) ?? .null, approvalID.map(SQLValue.text) ?? .null]).first?.first?.text {
                guard let record = try recordUnlocked(id), record.retainedOutcome == nil else { throw OperationJournalError.recoveryMaterialRetired }
                try validateRetention(id)

                guard record.result != nil || record.recoveryData == recoveryData || record.recoveryData == nil && record.recoveryExpiresAt != nil else { throw OperationJournalError.conflictingPreparation }
                return record.intent
            }
            let id = UUID().uuidString.lowercased()
            return try declareUnlocked(resourceID: id, kind: kind, content: content, revoking: false, recoveryData: recoveryData,
                expectedGeneration: expectedGeneration, operationID: id, recoveryExpiresAt: recoveryExpiresAt, approvalID: approvalID)
        }
    }
    public func currentIntents(kind: String) throws -> [JournalIntent] {
        try withDatabase {
            try rows("SELECT o.id FROM journal_operation o JOIN journal_resource r ON r.namespace=o.namespace AND r.current_id=o.id WHERE o.namespace=? AND o.kind=?",
                [.text(namespace), .text(kind)]).compactMap { row in
                guard let id = row.first?.text else { return nil }
                return try recordUnlocked(id)?.intent
            }
        }
    }
    private func declareUnlocked(resourceID: String, kind: String, content: Data, revoking: Bool,
        recoveryData: Data?, expectedGeneration: Int64?, operationID: String?, recoveryExpiresAt: Int64?, approvalID: String?, reconstructingRetired: Bool = false, materialExpiresAt: Int64? = nil) throws -> JournalIntent {
            guard materialExpiresAt == nil || materialExpiresAt! > 0 else { throw OperationJournalError.unavailable }
            try validateProtectivePolicy(kind: kind, revoking: revoking, recoveryData: recoveryData)
            let closed = try rows("SELECT admission_closed FROM journal_namespace WHERE namespace=?", [.text(namespace)]).first?.first?.integer
            let custodyClosed = try rows("SELECT admission_closed FROM journal_custody WHERE singleton=1").first?.first?.integer
            let observedGeneration = try currentGeneration()
            let protective = revoking && expectedGeneration == nil
            guard (closed == 0 || protective), (custodyClosed == 0 || protective),
                  expectedGeneration == nil || expectedGeneration == observedGeneration else { throw OperationJournalError.staleIntent }
            guard recoveryExpiresAt == nil || recoveryExpiresAt! > 0 else { throw OperationJournalError.capacity }
            guard (recoveryData?.count ?? 0) <= 1_048_576 else { throw OperationJournalError.capacity }
            guard !resourceID.isEmpty, !resourceID.contains("\0"), !kind.isEmpty, !kind.contains("\0"), !content.isEmpty, content.count <= 262_144 else { throw OperationJournalError.capacity }
            if let current = try currentUnlocked(resourceID), current.retainedOutcome != nil {
                guard reconstructingRetired && revoking || approvalID != nil && approvalID != current.approvalID else {
                    throw OperationJournalError.recoveryMaterialRetired
                }
            }
            if let approvalID {
                guard !approvalID.isEmpty, !approvalID.contains("\0"), approvalID.utf8.count <= 256 else { throw OperationJournalError.capacity }
                if let row = try rows("SELECT id,retained_outcome,content_digest,resource FROM journal_retention WHERE namespace=? AND approval_id=? AND kind=? LIMIT 1",
                    [.text(namespace), .text(approvalID), .text(kind)]).first {
                    guard row[1].text == nil else { throw OperationJournalError.recoveryMaterialRetired }
                    guard row[2].text == SealedOperation.sha256(content), row[3].text == resourceID else { throw OperationJournalError.conflictingPreparation }
                }
            }
            if let current = try currentUnlocked(resourceID), current.intent.kind == kind,
               current.intent.content == content, current.intent.revoking == revoking,
               approvalID == nil || current.approvalID == approvalID {
                guard recoveryData == nil || recoveryData == current.recoveryData else { throw OperationJournalError.conflictingPreparation }
                if let materialExpiresAt {
                    try execute("UPDATE journal_retention SET material_expires_at=MIN(material_expires_at,?) WHERE namespace=? AND id=? AND material_expires_at IS NOT NULL",
                        [.integer(materialExpiresAt), .text(namespace), .text(current.intent.id)])
                }
                try validateRetention(current.intent.id)
                return current.intent
            }
            if let current = try currentUnlocked(resourceID), current.authorization != nil, current.result == nil {
                throw OperationJournalError.conflictingPreparation
            }
            let generation = try currentGeneration()
            let epoch = (try rows("SELECT epoch FROM journal_resource WHERE namespace=? AND resource=?",
                [.text(namespace), .text(resourceID)]).first?.first?.integer ?? 0) + 1
            try execute("DELETE FROM journal_operation WHERE namespace=? AND id NOT IN (SELECT current_id FROM journal_resource WHERE namespace=?) AND state IN ('accepted','canceled','refused')", [.text(namespace), .text(namespace)])
            let count = try rows("SELECT COUNT(*) FROM journal_operation WHERE namespace=?", [.text(namespace)]).first?.first?.integer ?? 0
            guard count < 1_000 || revoking && count < 2_000 else { throw OperationJournalError.capacity }
            let id = operationID ?? UUID().uuidString.lowercased()
            guard !id.isEmpty, !id.contains("\0"), id.utf8.count <= 256,
                  try recordUnlocked(id) == nil else { throw OperationJournalError.conflictingPreparation }
            try execute("UPDATE journal_operation SET state='canceled' WHERE namespace=? AND resource=? AND state<>'accepted'",
                [.text(namespace), .text(resourceID)])
            try execute("INSERT INTO journal_operation(namespace,id,resource,kind,content,epoch,generation,revoking,state,recovery,recovery_expires_at) VALUES(?,?,?,?,?,?,?,?,'intent',?,?)",
                [.text(namespace), .text(id), .text(resourceID), .text(kind), .blob(content), .integer(epoch), .integer(generation), .integer(revoking ? 1 : 0), recoveryData.map(SQLValue.blob) ?? .null, recoveryExpiresAt.map(SQLValue.integer) ?? .null])
            try insertRetention(id: id, resource: resourceID, kind: kind, content: content, approvalID: approvalID, materialExpiresAt: materialExpiresAt)
            try execute("INSERT INTO journal_resource VALUES(?,?,?,?) ON CONFLICT(namespace,resource) DO UPDATE SET epoch=excluded.epoch,current_id=excluded.current_id",
                [.text(namespace), .text(resourceID), .integer(epoch), .text(id)])
            return JournalIntent(id: id, resourceID: resourceID, kind: kind, content: content, epoch: epoch, generation: generation, revoking: revoking)
    }

    private struct AdmissionGrant: Codable {
        let generation: Int64
        let intentIDs: Set<String>
    }

    /// Scope leases capture this value; erased/reopened custody cannot revive a held scope.
    public func generationToken() throws -> Int64 { try withDatabase { try currentGeneration() } }

    public func admissionEpoch() throws -> Int64 { try withDatabase { try admissionEpochUnlocked() } }
    private func admissionEpochUnlocked() throws -> Int64 {
        guard let epoch = try rows("SELECT admission_epoch FROM journal_custody WHERE singleton=1").first?.first?.integer else { throw OperationJournalError.unavailable }
        return epoch
    }
    private func validateAdmissionEpoch(_ expected: Int64?) throws {
        if let expected, expected != (try admissionEpochUnlocked()) { throw OperationJournalError.staleIntent }
    }

    /// Host-selected revocation kinds are enforced for every handle, including direct callers.
    /// This mode preserves old owner records and cannot be cleared by enrollment admission.
    public func restrictToProtectiveOperations(ownerBinding: String?, kinds: Set<String>) throws {
        try lockedTransaction {
            guard !kinds.isEmpty, kinds.count <= 32,
                kinds.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 128 }),
                ownerBinding == nil || ownerBinding!.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                try rows("SELECT admission_closed FROM journal_custody WHERE singleton=1").first?.first?.integer == 0 else {
                throw OperationJournalError.staleIntent
            }
            if let old = try rows("SELECT protective_owner FROM journal_custody WHERE singleton=1").first?.first?.text,
                old != ownerBinding { throw OperationJournalError.staleIntent }
            try execute("UPDATE journal_custody SET protective_only=1,protective_owner=?,admission_epoch=admission_epoch+1 WHERE singleton=1",
                [ownerBinding.map(SQLValue.text) ?? .null])
            try execute("DELETE FROM journal_protective_kind")
            for kind in kinds { try execute("INSERT INTO journal_protective_kind(kind) VALUES(?)", [.text(kind)]) }
        }
    }
    public func protectiveOnlyOwner() throws -> (restricted: Bool, ownerBinding: String?) {
        try withDatabase {
            guard let row = try rows("SELECT protective_only,protective_owner FROM journal_custody WHERE singleton=1").first,
                let restricted = row[0].integer else { throw OperationJournalError.unavailable }
            return (restricted != 0, row[1].text)
        }
    }
    private func validateProtectivePolicy(kind: String, revoking: Bool, recoveryData: Data?) throws {
        if try rows("SELECT protective_only FROM journal_custody WHERE singleton=1").first?.first?.integer == 1 {
            guard revoking, recoveryData == nil,
                try rows("SELECT kind FROM journal_protective_kind WHERE kind=?", [.text(kind)]).first != nil else {
                throw OperationJournalError.staleIntent
            }
        }
    }

    /// Whole-file custody is explicit; ordinary namespace erasure remains isolated.
    public func closeAllNamespaces() throws {
        try lockedTransaction {
            try execute("UPDATE journal_custody SET admission_closed=1,admission_epoch=admission_epoch+1 WHERE singleton=1")
            try execute("UPDATE journal_namespace SET admission_closed=1")
        }
    }
    public func resumeAllNamespacesAfterExplicitAdmission() throws {
        try lockedTransaction {
            try execute("UPDATE journal_custody SET admission_closed=0 WHERE singleton=1")
            try execute("UPDATE journal_namespace SET admission_closed=0")
        }
    }
    public func eraseAllNamespaces() throws {
        try withDatabase {
            try transaction {
                try execute("UPDATE journal_custody SET admission_closed=1,admission_epoch=admission_epoch+1 WHERE singleton=1")
                try execute("UPDATE journal_namespace SET generation=generation+1,admission_closed=1,admission_grant=NULL")
                try execute("UPDATE journal_custody SET protective_only=0,protective_owner=NULL WHERE singleton=1")
                try execute("DELETE FROM journal_protective_kind")
                try execute("DELETE FROM journal_retention")
                try execute("DELETE FROM journal_operation")
                try execute("DELETE FROM journal_resource")
            }
            try checkpoint()
        }
    }
    /// Validate runtime custody without requiring retained operation material to remain available.
    public func validateCustody(expectedGeneration: Int64, expectedAdmissionEpoch: Int64) throws {
        try withDatabase {
            try validateAdmissionEpoch(expectedAdmissionEpoch)
            guard expectedGeneration == (try currentGeneration()),
                try rows("SELECT admission_closed FROM journal_custody WHERE singleton=1").first?.first?.integer == 0,
                try rows("SELECT admission_closed FROM journal_namespace WHERE namespace=?", [.text(namespace)]).first?.first?.integer == 0 else {
                throw OperationJournalError.staleIntent
            }
        }
    }

    public func validateAdmitted(_ intent: JournalIntent) throws {
        try withDatabase {
            try validateUnlocked(intent)
            guard try rows("SELECT admission_closed FROM journal_custody WHERE singleton=1").first?.first?.integer == 0,
                  try rows("SELECT admission_closed FROM journal_namespace WHERE namespace=?", [.text(namespace)]).first?.first?.integer == 0 else {
                throw OperationJournalError.staleIntent
            }
        }
    }

    /// Close durable admission before draining existing writers. Erase preserves this fence.
    public func closeAdmission() throws {
        try lockedTransaction {
            try execute("UPDATE journal_namespace SET admission_closed=1 WHERE namespace=?", [.text(namespace)])
        }
    }

    /// An explicit owner action permits a new lifecycle alongside ONLY these existing
    /// revocations. A later deletion has a new identity and requires a new owner action.
    public func grantExplicitAdmission() throws {
        try lockedTransaction {
            let grant = AdmissionGrant(generation: try currentGeneration(), intentIDs: try currentRevocationIDs())
            try execute("UPDATE journal_namespace SET admission_closed=0,admission_grant=? WHERE namespace=?",
                [.blob(try JSONEncoder().encode(grant)), .text(namespace)])
        }
    }

    public func requiresExplicitAdmission() throws -> Bool {
        try withDatabase {
            guard let row = try rows("SELECT admission_closed,admission_grant FROM journal_namespace WHERE namespace=?", [.text(namespace)]).first,
                  let closed = row[0].integer else { throw OperationJournalError.unavailable }
            if closed != 0 { return true }
            let current = try currentRevocationIDs()
            if current.isEmpty { return false }
            guard let bytes = row[1].blob else { return true }
            let grant = try JSONDecoder().decode(AdmissionGrant.self, from: bytes)
            return grant.generation != (try currentGeneration()) || !current.isSubset(of: grant.intentIDs)
        }
    }

    private func currentRevocationIDs() throws -> Set<String> {
        let values = try rows("SELECT o.id FROM journal_operation o JOIN journal_resource r ON r.namespace=o.namespace AND r.current_id=o.id WHERE o.namespace=? AND o.revoking=1", [.text(namespace)])
        return Set(values.compactMap { $0.first?.text })
    }

    public func operationAssociations(approvalID: String, kind: String) throws -> [JournalOperationAssociation] {
        try withDatabase {
            guard !approvalID.isEmpty, !approvalID.contains("\0"), approvalID.utf8.count <= 256,
                !kind.isEmpty, !kind.contains("\0"), kind.utf8.count <= 256 else { throw OperationJournalError.unavailable }
            let matches = try rows(
                "SELECT id,resource,kind,content_digest,approval_id FROM journal_retention WHERE namespace=? AND approval_id=? AND kind=? ORDER BY admitted_at,id LIMIT 2001",
                [.text(namespace), .text(approvalID), .text(kind)])
            guard matches.count <= 2000 else { throw OperationJournalError.capacity }
            return try matches.map { row in
                guard let id = row[0].text, let target = row[1].text, let kind = row[2].text,
                    let digest = row[3].text, let approval = row[4].text else { throw OperationJournalError.unavailable }
                return JournalOperationAssociation(operationID: id, targetID: target, kind: kind, contentDigest: digest, approvalID: approval)
            }
        }
    }

    public func current(resourceID: String) throws -> JournalRecord? {
        try withDatabase { try currentUnlocked(resourceID) }
    }

    /// Cleanup intents are recovered independently of the originating task after restart.
    public func pendingRevocations(kind: String) throws -> [JournalIntent] {
        try withDatabase {
            let ids = try rows("SELECT current_id FROM journal_resource WHERE namespace=?", [.text(namespace)])
            return try ids.compactMap { row in
                guard let id = row.first?.text, let record = try recordUnlocked(id),
                      record.intent.revoking, record.intent.kind == kind else { return nil }
                return record.intent
            }
        }
    }

    /// The caller has independently authenticated the terminal state of these exact resources.
    public func completeRevocation(_ intent: JournalIntent) throws { try completeRevocations([intent]) }

    public func completeRevocations(_ intents: [JournalIntent]) throws {
        try withDatabase {
            try transaction {
                for intent in intents {
                    try validateUnlocked(intent)
                    guard intent.revoking else { throw OperationJournalError.staleIntent }
                }
                for intent in intents {
                    try execute("DELETE FROM journal_resource WHERE namespace=? AND resource=? AND current_id=?",
                        [.text(namespace), .text(intent.resourceID), .text(intent.id)])
                    try execute("DELETE FROM journal_operation WHERE namespace=? AND id=?", [.text(namespace), .text(intent.id)])
                }
                if let bytes = try rows("SELECT admission_grant FROM journal_namespace WHERE namespace=?", [.text(namespace)]).first?.first?.blob {
                    let old = try JSONDecoder().decode(AdmissionGrant.self, from: bytes)
                    let retained = AdmissionGrant(generation: old.generation, intentIDs: old.intentIDs.intersection(try currentRevocationIDs()))
                    try execute("UPDATE journal_namespace SET admission_grant=? WHERE namespace=?",
                        [.blob(try JSONEncoder().encode(retained)), .text(namespace)])
                }
            }
            try checkpoint()
        }
    }

    /// Retire an expired narrow capability without inventing a successful remote outcome.
    /// Preserve identity for the owner's existing admission grant; stale in-flight handles fail.
    public func markRevocationUnavailable(_ intent: JournalIntent, kind: String, redactedContent: Data) throws {
        try withDatabase {
            try transaction {
                try validateUnlocked(intent)
                guard intent.revoking, !kind.isEmpty, !kind.contains("\0"), !redactedContent.isEmpty else {
                    throw OperationJournalError.staleIntent
                }
                try execute("UPDATE journal_operation SET kind=?,content=?,state='unavailable',operation=NULL,prepared=NULL,result=NULL,recovery=NULL,authorization=NULL WHERE namespace=? AND id=?",
                    [.text(kind), .blob(redactedContent), .text(namespace), .text(intent.id)])
            }
            try checkpoint()
        }
    }

    /// Re-read immediately at a binary egress boundary; a captured old request body is not custody.
    public func recoveryPayload(_ intent: JournalIntent, now: Int64) throws -> Data {
        try withDatabase {
            try validateUnlocked(intent)
            guard let record = try recordUnlocked(intent.id), let payload = record.recoveryData,
                record.recoveryExpiresAt.map({ $0 > now }) ?? true else { throw OperationJournalError.staleIntent }
            return payload
        }
    }

    /// Bound raw recovery custody independently of immutable outcome metadata. Deadlines never
    /// refresh on retries; absence of bytes is not evidence of a completed remote operation.
    public func releaseExpiredPayloads(now: Int64) throws {
        try withDatabase {
            try transaction {
                try scrubExpiredRetention(now: now)
                try execute("UPDATE journal_operation SET recovery=NULL WHERE recovery_expires_at IS NOT NULL AND recovery_expires_at<=? AND recovery IS NOT NULL", [.integer(now)])
            }
            try checkpoint()
        }
    }

    /// Release accepted binary custody while retaining the exact prepared request for cache binding.
    public func releaseAcceptedPayload(_ intent: JournalIntent) throws {
        try withDatabase {
            try transaction {
                try validateUnlocked(intent)
                guard try recordUnlocked(intent.id)?.state == "accepted" else { throw OperationJournalError.staleIntent }
                try execute("UPDATE journal_operation SET recovery=NULL WHERE namespace=? AND id=?", [.text(namespace), .text(intent.id)])
            }
            try checkpoint()
        }
    }

    public func redactCompletedRecovery(_ intent: JournalIntent) throws {
        try withDatabase {
            try transaction {
                try validateUnlocked(intent)
                guard try recordUnlocked(intent.id)?.state == "accepted" else { throw OperationJournalError.staleIntent }
                try execute("UPDATE journal_operation SET prepared=NULL,recovery=NULL,authorization=NULL WHERE namespace=? AND id=?", [.text(namespace), .text(intent.id)])
            }
            try checkpoint()
        }
    }

    public func validate(_ intent: JournalIntent) throws {
        try withDatabase { try validateUnlocked(intent) }
    }

    public func savePrepared(_ intent: JournalIntent, operation: SealedOperation, bytes: Data, expectedAdmissionEpoch: Int64? = nil) throws {
        try lockedTransaction {
            try validateAdmissionEpoch(expectedAdmissionEpoch)
            try validateUnlocked(intent)
            guard operation.operationID == intent.id, operation.targetID == intent.resourceID,
                  operation.operationKind == intent.kind, operation.contentDigest == SealedOperation.sha256(intent.content),
                  bytes.count <= 524_288 else { throw OperationJournalError.conflictingPreparation }
            try operation.validate()
            let saved = try recordUnlocked(intent.id)
            if let previous = saved?.prepared {
                guard previous == bytes, saved?.operation == operation else { throw OperationJournalError.conflictingPreparation }
                return
            }
            try execute("UPDATE journal_operation SET operation=?,prepared=?,state='prepared' WHERE namespace=? AND id=?",
                [.blob(try JSONEncoder().encode(operation)), .blob(bytes), .text(namespace), .text(intent.id)])
        }
    }

    /// Persist the uncertain-delivery boundary before invoking the network port.
    public func beginDispatch(_ intent: JournalIntent, expectedAdmissionEpoch: Int64? = nil) throws {
        try lockedTransaction {
            try validateAdmissionEpoch(expectedAdmissionEpoch)
            try validateUnlocked(intent)
            guard let record = try recordUnlocked(intent.id), record.prepared != nil,
                  record.state == "prepared" || record.state == "authorized" || record.state == "dispatching" else { throw OperationJournalError.missingIntent }
            try execute("UPDATE journal_operation SET state='dispatching' WHERE namespace=? AND id=?", [.text(namespace), .text(intent.id)])
        }
    }

    public func beginAuthorization(_ intent: JournalIntent) throws {
        try lockedTransaction {
            try validateUnlocked(intent)
            guard let record = try recordUnlocked(intent.id), intent.revoking, record.prepared != nil,
                  record.recoveryData != nil, record.state == "prepared" || record.state == "authorizing" else {
                throw OperationJournalError.missingIntent
            }
            try execute("UPDATE journal_operation SET state='authorizing' WHERE namespace=? AND id=?", [.text(namespace), .text(intent.id)])
        }
    }

    /// Persist only after validating an authenticated acknowledgement bound to the exact request.
    public func authorized(_ intent: JournalIntent, acknowledgement: Data) throws {
        try lockedTransaction {
            try validateUnlocked(intent)
            guard let record = try recordUnlocked(intent.id), intent.revoking, record.prepared != nil,
                  record.recoveryData != nil, !acknowledgement.isEmpty, acknowledgement.count <= 1_048_576 else {
                throw OperationJournalError.missingIntent
            }
            if let previous = record.authorization {
                guard previous == acknowledgement else { throw OperationJournalError.conflictingPreparation }
                return
            }
            try execute("UPDATE journal_operation SET authorization=?,state='authorized' WHERE namespace=? AND id=?",
                [.blob(acknowledgement), .text(namespace), .text(intent.id)])
        }
    }

    /// An authenticated state read established the CURRENT desired revocation already holds.
    /// This terminal observation is explicitly distinct from an operation receipt.
    public func observedRevoked(_ intent: JournalIntent, authenticatedState: Data) throws {
        try lockedTransaction {
            try validateUnlocked(intent)
            guard intent.revoking, authenticatedState.count <= 1_048_576 else { throw OperationJournalError.staleIntent }
            try execute("UPDATE journal_retention SET outcome_fact='revoked' WHERE namespace=? AND id=?", [.text(namespace), .text(intent.id)])
            try execute("UPDATE journal_operation SET result=?,state='observed_revoked' WHERE namespace=? AND id=?",
                [.blob(authenticatedState), .text(namespace), .text(intent.id)])
        }
    }

    public func accepted(_ intent: JournalIntent, result: Data, expectedAdmissionEpoch: Int64? = nil) throws {
        try lockedTransaction {
            try validateAdmissionEpoch(expectedAdmissionEpoch)
            try validateProtectivePolicy(kind: intent.kind, revoking: intent.revoking, recoveryData: nil)
            // Late results may settle old history; they never change the current desired intent.
            guard intent.generation == (try currentGeneration()), let record = try recordUnlocked(intent.id),
                  record.intent == intent, record.retainedOutcome == nil, record.prepared != nil, result.count <= 1_048_576 else {
                throw OperationJournalError.staleIntent
            }
            try validateRetention(intent.id)
            if let previous = record.result, previous != result { throw OperationJournalError.conflictingPreparation }
            try execute("UPDATE journal_retention SET outcome_fact=? WHERE namespace=? AND id=?",
                [.text(intent.revoking ? "revoked" : "accepted"), .text(namespace), .text(intent.id)])
            try execute("UPDATE journal_operation SET result=?,state='accepted' WHERE namespace=? AND id=?",
                [.blob(result), .text(namespace), .text(intent.id)])
        }
    }

    /// Only an authoritative revision conflict of the CURRENT revocation permits a new attempt.
    /// An enable is never rebuilt against a later resource revision.
    public func renewRevocationAfterConflict(_ intent: JournalIntent, expectedAdmissionEpoch: Int64? = nil) throws -> JournalIntent {
        try lockedTransaction {
            try validateAdmissionEpoch(expectedAdmissionEpoch)
            guard try rows("SELECT admission_closed FROM journal_custody WHERE singleton=1").first?.first?.integer == 0,
                  try rows("SELECT admission_closed FROM journal_namespace WHERE namespace=?", [.text(namespace)]).first?.first?.integer == 0 else {
                throw OperationJournalError.staleIntent
            }
            try validateUnlocked(intent)
            guard intent.revoking, let old = try recordUnlocked(intent.id), old.recoveryData == nil,
                  old.result == nil, old.authorization == nil,
                  !["accepted", "observed_revoked", "unavailable", "refused", "canceled"].contains(old.state) else {
                throw OperationJournalError.staleIntent
            }
            try execute("DELETE FROM journal_operation WHERE namespace=? AND id NOT IN (SELECT current_id FROM journal_resource WHERE namespace=?) AND state IN ('accepted','canceled','refused')", [.text(namespace), .text(namespace)])
            let count = try rows("SELECT COUNT(*) FROM journal_operation WHERE namespace=?", [.text(namespace)]).first?.first?.integer ?? 0
            guard count < 2_000 else { throw OperationJournalError.capacity }
            let id = UUID().uuidString.lowercased()
            try execute("UPDATE journal_operation SET state='refused' WHERE namespace=? AND id=?", [.text(namespace), .text(intent.id)])
            try execute("INSERT INTO journal_operation(namespace,id,resource,kind,content,epoch,generation,revoking,state) VALUES(?,?,?,?,?,?,?,1,'intent')",
                [.text(namespace), .text(id), .text(intent.resourceID), .text(intent.kind), .blob(intent.content), .integer(intent.epoch), .integer(intent.generation)])
            try copyRetention(from: intent.id, to: id)
            try execute("UPDATE journal_resource SET current_id=? WHERE namespace=? AND resource=?",
                [.text(id), .text(namespace), .text(intent.resourceID)])
            return JournalIntent(id: id, resourceID: intent.resourceID, kind: intent.kind, content: intent.content,
                epoch: intent.epoch, generation: intent.generation, revoking: true)
        }
    }

    /// Replace only the current ordinary protective attempt after an exact service refusal.
    /// Delegated erasure authorization and all positive operations have separate lifecycles.
    public func renewProtectiveAfterExpiredUncommitted(_ intent: JournalIntent,
        refusal: ExpiredUncommittedRefusal, expectedAdmissionEpoch: Int64) throws -> JournalIntent {
        try lockedTransaction {
            try validateAdmissionEpoch(expectedAdmissionEpoch)
            try validateUnlocked(intent)
            guard try rows("SELECT admission_closed FROM journal_custody WHERE singleton=1").first?.first?.integer == 0,
                  try rows("SELECT admission_closed FROM journal_namespace WHERE namespace=?", [.text(namespace)]).first?.first?.integer == 0,
                  intent.revoking, let old = try recordUnlocked(intent.id), old.result == nil,
                  old.authorization == nil, old.recoveryData == nil, old.prepared != nil,
                  old.state == "prepared" || old.state == "dispatching", let operation = old.operation,
                  operation.operationID == intent.id, operation.targetID == intent.resourceID,
                  operation.operationKind == intent.kind, operation.contentDigest == SealedOperation.sha256(intent.content) else {
                throw OperationJournalError.staleIntent
            }
            try refusal.validate(for: operation)
            try execute("DELETE FROM journal_operation WHERE namespace=? AND id NOT IN (SELECT current_id FROM journal_resource WHERE namespace=?) AND state IN ('accepted','canceled','refused')", [.text(namespace), .text(namespace)])
            let count = try rows("SELECT COUNT(*) FROM journal_operation WHERE namespace=?", [.text(namespace)]).first?.first?.integer ?? 0
            guard count < 2_000 else { throw OperationJournalError.capacity }
            let next = JournalIntent(id: UUID().uuidString.lowercased(), resourceID: intent.resourceID,
                kind: intent.kind, content: intent.content, epoch: intent.epoch + 1, generation: intent.generation, revoking: true)
            try execute("INSERT INTO journal_operation(namespace,id,resource,kind,content,epoch,generation,revoking,state,recovery_expires_at) VALUES(?,?,?,?,?,?,?,1,'intent',?)",
                [.text(namespace), .text(next.id), .text(next.resourceID), .text(next.kind), .blob(next.content),
                 .integer(next.epoch), .integer(next.generation), old.recoveryExpiresAt.map(SQLValue.integer) ?? .null])
            try copyRetention(from: intent.id, to: next.id)
            try execute("UPDATE journal_operation SET state='refused' WHERE namespace=? AND id=?", [.text(namespace), .text(intent.id)])
            try execute("UPDATE journal_resource SET epoch=?,current_id=? WHERE namespace=? AND resource=?",
                [.integer(next.epoch), .text(next.id), .text(namespace), .text(intent.resourceID)])
            return next
        }
    }

    /// Only an authenticated exact-request refusal after the original proof expired permits
    /// replacing an uncommitted authorization attempt. No acknowledged delegation is replaced.
    public func renewUncommittedRevocationAfterExpiry(_ intent: JournalIntent, authoritativeNow: Int64,
        recoveryData: Data) throws -> JournalIntent {
        try withDatabase {
            let replacement = try transaction {
                try validateUnlocked(intent)
                guard intent.revoking, let old = try recordUnlocked(intent.id), old.authorization == nil,
                      old.result == nil, old.state == "authorizing", let operation = old.operation,
                      authoritativeNow > operation.expiresAt, old.recoveryData != nil,
                      recoveryData.count <= 65_536 else { throw OperationJournalError.staleIntent }
                let next = JournalIntent(id: UUID().uuidString.lowercased(), resourceID: intent.resourceID,
                    kind: intent.kind, content: intent.content, epoch: intent.epoch + 1,
                    generation: intent.generation, revoking: true)
                try execute("INSERT INTO journal_operation(namespace,id,resource,kind,content,epoch,generation,revoking,state,recovery) VALUES(?,?,?,?,?,?,?,1,'intent',?)",
                    [.text(namespace), .text(next.id), .text(next.resourceID), .text(next.kind), .blob(next.content),
                     .integer(next.epoch), .integer(next.generation), .blob(recoveryData)])
            try copyRetention(from: intent.id, to: next.id)
                try execute("UPDATE journal_resource SET epoch=?,current_id=? WHERE namespace=? AND resource=?",
                    [.integer(next.epoch), .text(next.id), .text(namespace), .text(next.resourceID)])
                try execute("DELETE FROM journal_operation WHERE namespace=? AND id=?", [.text(namespace), .text(intent.id)])
                return next
            }
            try checkpoint()
            return replacement
        }
    }

    /// Erase payloads, proofs and results while retaining only an application namespace counter.
    /// A busy WAL checkpoint is a failure requiring retry, never a successful erase report.
    public func erase() throws {
        try withDatabase {
            try transaction {
                try execute("UPDATE journal_namespace SET generation=generation+1,admission_grant=NULL WHERE namespace=?", [.text(namespace)])
                try execute("DELETE FROM journal_retention WHERE namespace=?", [.text(namespace)])
                try execute("DELETE FROM journal_operation WHERE namespace=?", [.text(namespace)])
                try execute("DELETE FROM journal_resource WHERE namespace=?", [.text(namespace)])
            }
            try checkpoint()
        }
    }

    private func checkpoint() throws {
        guard sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK else {
            throw OperationJournalError.unavailable
        }
    }

    private func validateUnlocked(_ intent: JournalIntent) throws {
        try validateProtectivePolicy(kind: intent.kind, revoking: intent.revoking, recoveryData: nil)
        guard intent.generation == (try currentGeneration()), let current = try currentUnlocked(intent.resourceID),
              current.intent == intent else { throw OperationJournalError.staleIntent }
        try validateRetention(intent.id)
    }

    private func currentGeneration() throws -> Int64 {
        guard let generation = try rows("SELECT generation FROM journal_namespace WHERE namespace=?", [.text(namespace)]).first?.first?.integer else {
            throw OperationJournalError.unavailable
        }
        return generation
    }

    private func currentUnlocked(_ resource: String) throws -> JournalRecord? {
        guard let id = try rows("SELECT current_id FROM journal_resource WHERE namespace=? AND resource=?",
            [.text(namespace), .text(resource)]).first?.first?.text else { return nil }
        return try recordUnlocked(id)
    }

    private func recordUnlocked(_ id: String) throws -> JournalRecord? {
        guard let row = try rows("SELECT id,resource,kind,content,epoch,generation,revoking,state,operation,prepared,result,recovery,authorization,recovery_expires_at FROM journal_operation WHERE namespace=? AND id=?",
            [.text(namespace), .text(id)]).first else { return nil }
        guard let id = row[0].text, let resource = row[1].text, let kind = row[2].text, let content = row[3].blob,
              let epoch = row[4].integer, let generation = row[5].integer, let revoking = row[6].integer, let state = row[7].text else {
            throw OperationJournalError.unavailable
        }
        let operation = try row[8].blob.map { try JSONDecoder().decode(SealedOperation.self, from: $0) }
        let metadata = try retention(id)
        return JournalRecord(intent: JournalIntent(id: id, resourceID: resource, kind: kind, content: content,
            epoch: epoch, generation: generation, revoking: revoking != 0), operation: operation,
            prepared: row[9].blob, result: row[10].blob, state: state, recoveryData: row[11].blob, recoveryExpiresAt: row[13].integer, authorization: row[12].blob, admittedAt: metadata.admittedAt, materialExpiresAt: metadata.deadline,
            contentDigest: metadata.digest, approvalID: metadata.approvalID, retainedOutcome: metadata.outcome)
    }

    /// Gateway SPI accepts only an independently authorized protective target mapping.
    /// It cannot recover a positive request or copy its former content.
    @_spi(ProtectiveRecovery) public func reconstructProtective(retired: JournalIntent, kind: String,
        minimalContent: Data, expectedAdmissionEpoch: Int64) throws -> JournalIntent {
        try lockedTransaction {
            try validateAdmissionEpoch(expectedAdmissionEpoch)
            guard retired.generation == (try currentGeneration()),
                let current = try currentUnlocked(retired.resourceID), current.intent == retired,
                current.retainedOutcome != nil, current.materialExpiresAt != nil,
                try rows("SELECT admission_closed FROM journal_custody WHERE singleton=1").first?.first?.integer == 0,
                try rows("SELECT admission_closed FROM journal_namespace WHERE namespace=?", [.text(namespace)]).first?.first?.integer == 0,
                minimalContent.count <= 2048,
                let object = try JSONSerialization.jsonObject(with: minimalContent) as? [String: String],
                object.count == 1, object.values.first == retired.resourceID,
                try CanonicalJSON.canonicalize(minimalContent) == minimalContent else {
                throw OperationJournalError.staleIntent
            }
            return try declareUnlocked(resourceID: retired.resourceID, kind: kind, content: minimalContent,
                revoking: true, recoveryData: nil, expectedGeneration: retired.generation, operationID: nil,
                recoveryExpiresAt: nil, approvalID: nil, reconstructingRetired: true)
        }
    }

    private struct Retention {
        let admittedAt: Int64
        let deadline: Int64?
        let digest: String
        let approvalID: String?
        let outcome: JournalRetainedOutcome?
    }
    private func retention(_ id: String) throws -> Retention {
        guard let row = try rows("SELECT admitted_at,material_expires_at,content_digest,approval_id,retained_outcome FROM journal_retention WHERE namespace=? AND id=?", [.text(namespace), .text(id)]).first,
            let admitted = row[0].integer, let digest = row[2].text else { throw OperationJournalError.unavailable }
        return Retention(admittedAt: admitted, deadline: row[1].integer, digest: digest,
            approvalID: row[3].text, outcome: row[4].text.flatMap(JournalRetainedOutcome.init(rawValue:)))
    }
    private func validateRetention(_ id: String) throws {
        let value = try retention(id)
        guard value.outcome == nil, value.deadline.map({ $0 > now() }) ?? true else {
            throw OperationJournalError.recoveryMaterialRetired
        }
    }
    private func insertRetention(id: String, resource: String, kind: String, content: Data, approvalID: String?, materialExpiresAt: Int64?) throws {
        let admitted = now()
        guard admitted > 0, admitted < 9_007_199_252_148_991 else { throw OperationJournalError.unavailable }
        let delegated = try rows("SELECT retention_policy FROM journal_namespace WHERE namespace=?", [.text(namespace)]).first?.first?.text == "delegated"
        let deadline: SQLValue = delegated ? .null : .integer(min(admitted + 2_592_000, materialExpiresAt ?? Int64.max))
        try execute("INSERT INTO journal_retention(namespace,id,resource,kind,content_digest,admitted_at,material_expires_at,approval_id) VALUES(?,?,?,?,?,?,?,?)",
            [.text(namespace), .text(id), .text(resource), .text(kind), .text(SealedOperation.sha256(content)),
             .integer(admitted), deadline, approvalID.map(SQLValue.text) ?? .null])
    }
    private func copyRetention(from original: String, to replacement: String) throws {
        try execute("INSERT INTO journal_retention(namespace,id,resource,kind,content_digest,admitted_at,material_expires_at,approval_id) SELECT namespace,?,resource,kind,content_digest,admitted_at,material_expires_at,approval_id FROM journal_retention WHERE namespace=? AND id=?",
            [.text(replacement), .text(namespace), .text(original)])
    }
    private func migrateRetention() throws {
        let original = try rows("SELECT o.namespace,o.id,o.resource,o.kind,o.content,o.operation,o.state,o.revoking FROM journal_operation o JOIN journal_namespace n ON n.namespace=o.namespace WHERE n.retention_policy IS NOT NULL AND NOT EXISTS(SELECT 1 FROM journal_retention t WHERE t.namespace=o.namespace AND t.id=o.id)")
        for row in original {
            guard let owner = row[0].text, let id = row[1].text, let resource = row[2].text,
                let kind = row[3].text, let content = row[4].blob else { throw OperationJournalError.unavailable }
            let operation: SealedOperation?
            do {
                operation = try row[5].blob.map {
                    let parsed = try JSONDecoder().decode(SealedOperation.self, from: $0)
                    try parsed.validate()
                    guard parsed.operationID == id, parsed.targetID == resource, parsed.operationKind == kind,
                        parsed.contentDigest == SealedOperation.sha256(content) else { throw OperationBindingError.contentMismatch }
                    return parsed
                }
            }
            catch { operation = nil } // Unreadable historical proof has no trustworthy recovery age.
            let delegated = try rows("SELECT retention_policy FROM journal_namespace WHERE namespace=?", [.text(owner)]).first?.first?.text == "delegated"
            let admitted = operation?.issuedAt ?? now()
            let bound = operation?.expiresAt.addingReportingOverflow(2_592_000)
            let ordinaryDeadline = bound.flatMap { $0.overflow ? nil : $0.partialValue } ?? now()
            let deadline: SQLValue = delegated ? .null : .integer(ordinaryDeadline)
            try execute("INSERT INTO journal_retention(namespace,id,resource,kind,content_digest,admitted_at,material_expires_at) VALUES(?,?,?,?,?,?,?)",
                [.text(owner), .text(id), .text(resource), .text(kind), .text(SealedOperation.sha256(content)), .integer(admitted), deadline])
        }
        try execute("UPDATE journal_retention SET outcome_fact=CASE WHEN EXISTS(SELECT 1 FROM journal_operation o WHERE o.namespace=journal_retention.namespace AND o.id=journal_retention.id AND (o.state='observed_revoked' OR (o.state='accepted' AND o.revoking=1))) THEN 'revoked' WHEN EXISTS(SELECT 1 FROM journal_operation o WHERE o.namespace=journal_retention.namespace AND o.id=journal_retention.id AND o.state='accepted') THEN 'accepted' ELSE outcome_fact END WHERE retained_outcome IS NULL AND outcome_fact IS NULL")
        try scrubExpiredRetention(now: now())
    }
    /// Legacy namespaces are never guessed from an unrelated opener's policy.
    public func pendingRetentionNamespaces() throws -> [String] {
        try withDatabase {
            try rows("SELECT DISTINCT o.namespace FROM journal_operation o WHERE NOT EXISTS(SELECT 1 FROM journal_retention t WHERE t.namespace=o.namespace AND t.id=o.id) ORDER BY o.namespace")
                .compactMap { $0.first?.text }
        }
    }
    /// Logical retirement is irreversible. Checkpoint retries run even if an earlier commit
    /// already scrubbed every due row; no successful maintenance implies NAND erasure.
    public func maintainRetention(now: Int64) throws {
        try withDatabase {
            try transaction { try scrubExpiredRetention(now: now) }
            try checkpointRetention()
        }
    }
    private func checkpointRetention() throws {
        guard let ticket = try rows("SELECT checkpoint_pending FROM journal_retention_control WHERE singleton=1").first?.first?.integer else {
            throw OperationJournalError.unavailable
        }
        try checkpoint()
        // A concurrent later scrub has its own greater ticket and remains pending.
        try execute("UPDATE journal_retention_control SET checkpoint_completed=MAX(checkpoint_completed,?) WHERE singleton=1", [.integer(ticket)])
    }
    private func scrubExpiredRetention(now: Int64) throws {
        try execute("UPDATE journal_retention_control SET checkpoint_pending=checkpoint_pending+1 WHERE singleton=1 AND EXISTS(SELECT 1 FROM journal_retention WHERE material_expires_at IS NOT NULL AND material_expires_at<=? AND retained_outcome IS NULL)", [.integer(now)])
        try execute("UPDATE journal_retention SET retained_outcome=COALESCE(outcome_fact,'uncertain') WHERE material_expires_at IS NOT NULL AND material_expires_at<=? AND retained_outcome IS NULL", [.integer(now)])
        try execute("UPDATE journal_operation SET content=X'',operation=NULL,prepared=NULL,result=NULL,recovery=NULL,authorization=NULL,state='retained_'||(SELECT retained_outcome FROM journal_retention t WHERE t.namespace=journal_operation.namespace AND t.id=journal_operation.id) WHERE EXISTS(SELECT 1 FROM journal_retention t WHERE t.namespace=journal_operation.namespace AND t.id=journal_operation.id AND t.retained_outcome IS NOT NULL)")
    }

    private func protectFiles() throws { /* protected store applies policy before returning */ }

    private func withDatabase<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            try store.withConnection { handle in
                database = handle
                defer { database = nil }
                return try body()
            }
        }
    }

    private func lockedTransaction<T>(_ body: () throws -> T) throws -> T {
        try withDatabase { try transaction(body) }
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private enum SQLValue {
        case text(String), integer(Int64), blob(Data), null
        var text: String? { if case .text(let value) = self { return value }; return nil }
        var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
        var blob: Data? { if case .blob(let value) = self { return value }; return nil }
    }
    private func execute(_ sql: String, _ values: [SQLValue] = []) throws { _ = try rows(sql, values) }
    private func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw OperationJournalError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let value): status = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient) }
            case .integer(let value): status = sqlite3_bind_int64(statement, index, value)
            case .blob(let value): status = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw OperationJournalError.unavailable }
        }
        var result: [[SQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw OperationJournalError.unavailable }
            result.append((0..<sqlite3_column_count(statement)).map { index in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
                case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
                    return .blob(Data(bytes: bytes, count: count))
                default: return .null
                }
            })
        }
    }
}
