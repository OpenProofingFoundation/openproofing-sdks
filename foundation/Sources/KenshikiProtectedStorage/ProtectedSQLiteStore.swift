import CryptoKit
import Foundation
import KenshikiSQLCipherBridge
import SQLCipher

public enum ProtectedSQLiteError: Error, Equatable {
    case invalidLocation, unavailable(Int32), cipherUnavailable, invalidKey, migrationRequired, destinationExists, migrationConflict, unfinalizedStatements
}

/// One encrypted SQLite database family in a dedicated directory. Hosts own the schema; this
/// foundation owns encryption, temporary storage, file protection and non-destructive opening.
/// `withConnection` is restricted to reviewed SQL adapters, never renderers or public key custody.
public final class ProtectedSQLiteStore: @unchecked Sendable {
    private let useKey: ((_ existingCiphertext: Bool, _ body: (UnsafeRawBufferPointer) throws -> Void) throws -> Void)
    private let lifecycle: StoreLifecycleFence
    private let epoch: Int64
    private let destroyKey: () throws -> Void
    private let accessPolicy: StoreAccessPolicy
    public let databaseURL: URL
    /// Remains in the adopter's erase inventory until its exclusive startup cutover removes it.
    public let retainedLegacySourceURL: URL?

    public convenience init(databaseURL: URL, identity: StoreKeyIdentity, legacyPlaintextURL: URL? = nil) throws {
        let vault = HardwareBoundStoreKeyCustody(identity: identity)
        try self.init(databaseURL: databaseURL, identity: identity, legacyPlaintextURL: legacyPlaintextURL, custody: vault)
    }

    /// An independent reader may reopen an owned store, but cannot create a new generation when
    /// the database is absent or disappears while admission is pending.
    public convenience init(existingDatabaseURL: URL, identity: StoreKeyIdentity) throws {
        let vault = HardwareBoundStoreKeyCustody(identity: identity)
        try self.init(databaseURL: existingDatabaseURL, identity: identity, custody: vault, requiresExisting: true)
    }

    internal convenience init(databaseURL: URL, identity: StoreKeyIdentity, legacyPlaintextURL: URL? = nil,
        custody: HardwareBoundStoreKeyCustody, requiresExisting: Bool = false) throws {
        try self.init(databaseURL: databaseURL, accessPolicy: identity.accessPolicy, requiresExisting: requiresExisting,
            legacyPlaintextURL: legacyPlaintextURL, identityBinding: identity.account, destroyKey: {
                try custody.destroyAfterCiphertextErasure()
            }, useKey: { existing, body in
                try custody.withDatabaseKey(existingCiphertext: existing, body)
            })
    }

    // Internal injection exercises the real codec on macOS/simulator without pretending hardware
    // custody succeeded. Production callers cannot choose a software key or weaken a profile.
    internal convenience init(databaseURL: URL, key: Data, legacyPlaintextURL: URL? = nil) throws {
        try self.init(databaseURL: databaseURL, accessPolicy: .identityWhenUnlocked,
            legacyPlaintextURL: legacyPlaintextURL, identityBinding: "test-only", destroyKey: {}, useKey: { _, body in
                try key.withUnsafeBytes(body)
            })
    }

    private init(databaseURL: URL, accessPolicy: StoreAccessPolicy, requiresExisting: Bool = false, legacyPlaintextURL: URL?,
        identityBinding: String, destroyKey: @escaping () throws -> Void,
        useKey: @escaping ((_ existingCiphertext: Bool, _ body: (UnsafeRawBufferPointer) throws -> Void) throws -> Void)) throws {
        try Self.validateLocation(databaseURL, legacy: legacyPlaintextURL)
        if requiresExisting, !FileManager.default.fileExists(atPath: databaseURL.path) {
            throw ProtectedSQLiteError.unavailable(SQLITE_CANTOPEN)
        }
        self.databaseURL = databaseURL
        self.accessPolicy = accessPolicy
        self.useKey = useKey
        self.destroyKey = destroyKey
        try Self.prepareDirectory(databaseURL, policy: accessPolicy)
        let lifecycle = try StoreLifecycleFence(databaseURL: databaseURL, identityBinding: identityBinding,
            legacySourceURL: legacyPlaintextURL)
        self.lifecycle = lifecycle
        self.retainedLegacySourceURL = try lifecycle.retainedLegacySource()
        self.epoch = try lifecycle.currentEpoch()
        try lifecycle.withAdmission(epoch: epoch) {
        if requiresExisting, !FileManager.default.fileExists(atPath: databaseURL.path) {
            throw ProtectedSQLiteError.unavailable(SQLITE_CANTOPEN)
        }
        try Self.protectFamily(databaseURL, policy: accessPolicy)
        let existing = (Self.family(databaseURL) + Self.family(URL(fileURLWithPath: databaseURL.path + ".encrypted-staging"))).contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let orphaned = !FileManager.default.fileExists(atPath: databaseURL.path)
            && Self.family(databaseURL).dropFirst().contains { FileManager.default.fileExists(atPath: $0.path) }
        guard !orphaned else { throw ProtectedSQLiteError.unavailable(SQLITE_CANTOPEN) }
        try useKey(existing) { key in
            guard key.count == 32 else { throw ProtectedSQLiteError.invalidKey }
            if !FileManager.default.fileExists(atPath: databaseURL.path), let source = retainedLegacySourceURL {
                try Self.migratePlaintext(source: source, destination: databaseURL, key: key, policy: accessPolicy)
            }
            let pointer = try Self.open(databaseURL, readOnly: requiresExisting)
            do {
                try Self.applyKey(key, to: pointer)
                try Self.configure(pointer)
                try Self.verify(pointer)
                if !requiresExisting {
                    try Self.execute(pointer, "CREATE TABLE IF NOT EXISTS _kenshiki_protected_store(identity TEXT PRIMARY KEY CHECK(identity IS NOT NULL));")
                }
                let saved = try Self.scalar(pointer, "SELECT identity FROM _kenshiki_protected_store LIMIT 1")
                if let saved {
                    guard saved == identityBinding else { throw ProtectedSQLiteError.invalidKey }
                } else {
                    guard !requiresExisting else { throw ProtectedSQLiteError.invalidKey }
                    try Self.bindAndRun(pointer, "INSERT INTO _kenshiki_protected_store(identity) VALUES(?)", values: [.text(identityBinding)])
                }
                try Self.protectFamily(databaseURL, policy: accessPolicy)
                sqlite3_close_v2(pointer)
            } catch {
                sqlite3_close_v2(pointer)
                throw error
            }
        }
        }
    }

    /// The handle belongs to SQLCipher. All adapter files touching it must import SQLCipher rather
    /// than SQLite3. The callback must not retain it, close it, change codec settings or rekey it.
    @_spi(StorageAdapter)
    public func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try borrow(foundationOperation: false, body)
    }

    func withFoundationConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try borrow(foundationOperation: true, body)
    }

    private func borrow<T>(foundationOperation: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        return try lifecycle.withAdmission(epoch: epoch) {
        var result: Result<T, Error>?
        try useKey(true) { key in
            // No keyed connection or decrypted SQLite page cache survives this admission.
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw ProtectedSQLiteError.unavailable(SQLITE_CANTOPEN)
            }
            let handle = try Self.open(databaseURL)
            let operation = Result<T, Error> {
                try Self.applyKey(key, to: handle)
                try Self.configure(handle)
                Self.installAuthorizer(handle, foundationOperation: foundationOperation)
                return try body(handle)
            }
            // Cleanup must execute even when SQL, admission or file protection fails. close_v2 alone
            // would retain the keyed connection behind an accidentally unfinalized statement.
            let protection = Result { try Self.protectFamily(databaseURL, policy: accessPolicy) }
            let closed = Result { try Self.closeBorrowedConnection(handle) }
            switch (closed, protection) {
            case (.failure(let error), _), (_, .failure(let error)): result = .failure(error)
            default: result = operation
            }
        }
        guard let result else { throw ProtectedSQLiteError.invalidKey }
        return try result.get()
        }
    }

    private static func closeBorrowedConnection(_ handle: OpaquePointer) throws {
        var omittedFinalizer = false
        while let statement = sqlite3_next_stmt(handle, nil) {
            omittedFinalizer = true
            sqlite3_finalize(statement)
        }
        let status = sqlite3_close(handle)
        guard status == SQLITE_OK else {
            // Only unsupported escaped C resources (for example a backup handle) can remain here.
            // Report failure rather than claim custody was released successfully.
            sqlite3_close_v2(handle)
            throw ProtectedSQLiteError.unavailable(status)
        }
        if omittedFinalizer { throw ProtectedSQLiteError.unfinalizedStatements }
    }

    /// Stable paged reads are admitted only for background observations. A lease is one bounded
    /// operation, not a second foreground cache; ordinary foreground borrows always close.
    @_spi(StorageAdapter)
    public func makeReadLease(maximumDuration: TimeInterval = 120) throws -> ProtectedSQLiteReadLease {
        guard accessPolicy == .backgroundAfterFirstUnlock else { throw ProtectedReadLeaseError.unsupportedPolicy }
        guard maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 120 else {
            throw ProtectedReadLeaseError.invalidDuration
        }
        return try lifecycle.withAdmission(epoch: epoch) {
            var lease: ProtectedSQLiteReadLease?
            try useKey(true) { key in
                let descriptor = try ProtectedSQLiteReadLease.openLock(at: databaseURL, exclusive: false)
                var pointer: OpaquePointer?
                do {
                    let handle = try Self.open(databaseURL, readOnly: true)
                    pointer = handle
                    try Self.applyKey(key, to: handle)
                    try Self.configure(handle)
                    try Self.execute(handle, "PRAGMA query_only=ON; BEGIN DEFERRED TRANSACTION;")
                    _ = try Self.scalar(handle, "SELECT count(*) FROM sqlite_master")
                    Self.installAuthorizer(handle, foundationOperation: false, readOnly: true)
                    try Self.protectFamily(databaseURL, policy: accessPolicy)
                    let binding = Self.keyBinding(key)
                    lease = ProtectedSQLiteReadLease(handle: handle, lockDescriptor: descriptor,
                        duration: maximumDuration, admit: { body in
                            try self.lifecycle.withAdmission(epoch: self.epoch) {
                                try self.useKey(true) { current in
                                    guard Self.keyBinding(current) == binding else {
                                        throw ProtectedSQLiteError.invalidKey
                                    }
                                    try body()
                                }
                            }
                        })
                } catch {
                    if let pointer { sqlite3_close_v2(pointer) }
                    ProtectedSQLiteReadLease.releaseLock(descriptor)
                    throw error
                }
            }
            guard let lease else { throw ProtectedSQLiteError.invalidKey }
            return lease
        }
    }

    private static func keyBinding(_ key: UnsafeRawBufferPointer) -> Data {
        var hash = SHA256()
        hash.update(bufferPointer: key)
        return Data(hash.finalize())
    }

    /// Current and recreated sidecars inherit the directory policy; explicit checks cover existing
    /// sidecars. Call before an adapter returns a handle-based result to its owner.
    public func protectFiles() throws {
        if lifecycle.isAdmittedOnCurrentThread {
            // A storage adapter may reapply inherited policy inside its existing admission.
            try Self.protectFamily(databaseURL, policy: accessPolicy)
        } else {
            try lifecycle.withAdmission(epoch: epoch) {
                try Self.protectFamily(databaseURL, policy: accessPolicy)
            }
        }
    }

    /// Advance a durable generation before deleting ciphertext. All prior handles are fenced,
    /// cleanup errors remain pending, and key removal occurs only after file deletion is durable.
    public func erase() throws {
        try lifecycle.erase(epoch: epoch) {
            try Self.removeCiphertext(databaseURL: databaseURL, legacy: retainedLegacySourceURL)
            try destroyKey()
        }
    }

    /// Retains this namespace's existing durable erase intent across associated custody cleanup.
    /// Only the returned handle may finish this exact pending epoch. Ordinary opening remains refused.
    @_spi(StorageAdapter)
    public func prepareErasure() throws -> ProtectedSQLiteErasure {
        try Self.prepareErasure(fence: lifecycle, epoch: epoch) {
            try Self.removeCiphertext(databaseURL: self.databaseURL, legacy: self.retainedLegacySourceURL)
            try self.destroyKey()
        }
    }

    /// Explicit startup/retry erasure without decrypting or creating a data key.
    @_spi(StorageAdapter)
    public static func prepareErasure(databaseURL: URL, identity: StoreKeyIdentity) throws -> ProtectedSQLiteErasure {
        let custody = HardwareBoundStoreKeyCustody(identity: identity)
        return try prepareOwnedErasure(databaseURL: databaseURL, identity: identity,
            destroyKey: { try custody.destroyAfterCiphertextErasure() })
    }

    /// Missing-store discovery must not create directories, lifecycle records or keys.
    @_spi(StorageAdapter)
    public static func hasPendingErasure(databaseURL: URL, identity: StoreKeyIdentity) throws -> Bool {
        try validateLocation(databaseURL, legacy: nil)
        return try StoreLifecycleFence.hasPendingErasure(databaseURL: databaseURL, identityBinding: identity.account)
    }

    private static func prepareOwnedErasure(databaseURL: URL, identity: StoreKeyIdentity,
        destroyKey: @escaping () throws -> Void) throws -> ProtectedSQLiteErasure {
        try validateLocation(databaseURL, legacy: nil)
        try prepareDirectory(databaseURL, policy: identity.accessPolicy)
        let fence = try StoreLifecycleFence(databaseURL: databaseURL, identityBinding: identity.account)
        let legacy = try fence.retainedLegacySource()
        return try prepareErasure(fence: fence, epoch: nil) {
            try removeCiphertext(databaseURL: databaseURL, legacy: legacy)
            try destroyKey()
        }
    }

    private static func prepareErasure(fence: StoreLifecycleFence, epoch: Int64?,
        cleanup: @escaping () throws -> Void) throws -> ProtectedSQLiteErasure {
        let pending = try fence.prepareErasure(epoch: epoch, cleanup)
        return ProtectedSQLiteErasure {
            try fence.finishPreparedErasure(pendingEpoch: pending, cleanup)
        }
    }

    /// Restart recovery is permitted only for an erase intent already persisted by this store.
    public static func resumePendingErasure(databaseURL: URL, identity: StoreKeyIdentity,
        legacyPlaintextURL: URL? = nil) throws {
        try validateLocation(databaseURL, legacy: legacyPlaintextURL)
        try prepareDirectory(databaseURL, policy: identity.accessPolicy)
        let fence = try StoreLifecycleFence(databaseURL: databaseURL, identityBinding: identity.account,
            legacySourceURL: legacyPlaintextURL)
        let legacy = try fence.retainedLegacySource()
        let custody = HardwareBoundStoreKeyCustody(identity: identity)
        try fence.resumePendingErasure {
            try removeCiphertext(databaseURL: databaseURL, legacy: legacy)
            try custody.destroyAfterCiphertextErasure()
        }
    }

    /// Complete only an already durable erase request, including when ciphertext deletion
    /// finished before a process exit. Returns false without creating a database or a data key.
    @discardableResult
    public static func recoverPendingErasure(databaseURL: URL, identity: StoreKeyIdentity) throws -> Bool {
        try validateLocation(databaseURL, legacy: nil)
        try prepareDirectory(databaseURL, policy: identity.accessPolicy)
        let fence = try StoreLifecycleFence(databaseURL: databaseURL, identityBinding: identity.account)
        let legacy = try fence.retainedLegacySource()
        let custody = HardwareBoundStoreKeyCustody(identity: identity)
        return try fence.recoverPendingErasure {
            try removeCiphertext(databaseURL: databaseURL, legacy: legacy)
            try custody.destroyAfterCiphertextErasure()
        }
    }

    /// Explicit registered erasure does not require decrypting a damaged database or recovering a
    /// missing data key. The namespace-bound lifecycle intent still fences every old handle first.
    public static func erasePersisted(databaseURL: URL, identity: StoreKeyIdentity,
        legacyPlaintextURL: URL? = nil) throws {
        let custody = HardwareBoundStoreKeyCustody(identity: identity)
        try erasePersisted(databaseURL: databaseURL, identity: identity,
            legacyPlaintextURL: legacyPlaintextURL, custody: custody)
    }

    static func erasePersisted(databaseURL: URL, identity: StoreKeyIdentity,
        legacyPlaintextURL: URL? = nil, custody: HardwareBoundStoreKeyCustody) throws {
        try eraseOwned(databaseURL: databaseURL, identity: identity, legacyPlaintextURL: legacyPlaintextURL,
            destroyKey: { try custody.destroyAfterCiphertextErasure() })
    }

    private static func eraseOwned(databaseURL: URL, identity: StoreKeyIdentity,
        legacyPlaintextURL: URL?, destroyKey: () throws -> Void) throws {
        try validateLocation(databaseURL, legacy: legacyPlaintextURL)
        try prepareDirectory(databaseURL, policy: identity.accessPolicy)
        let fence = try StoreLifecycleFence(databaseURL: databaseURL, identityBinding: identity.account,
            legacySourceURL: legacyPlaintextURL)
        let legacy = try fence.retainedLegacySource()
        let cleanup = {
            try removeCiphertext(databaseURL: databaseURL, legacy: legacy)
            try destroyKey()
        }
        do { try fence.erase(epoch: fence.currentEpoch(), cleanup) }
        catch ProtectedStoreLifecycleError.erasurePending { try fence.resumePendingErasure(cleanup) }
    }

    #if DEBUG
    /// Deliberate synthetic test fixture, absent from Release. No ordinary initializer selects it.
    @_spi(StorageTestFixture)
    public static func testing(databaseURL: URL, identity: StoreKeyIdentity, key: Data,
        legacyPlaintextURL: URL? = nil, requiresExisting: Bool = false) throws -> ProtectedSQLiteStore {
        guard identity.applicationID.hasPrefix("synthetic.") || identity.applicationID.hasPrefix("test.") else {
            throw ProtectedStoreKeyError.invalidIdentity
        }
        return try ProtectedSQLiteStore(databaseURL: databaseURL, accessPolicy: identity.accessPolicy,
            requiresExisting: requiresExisting, legacyPlaintextURL: legacyPlaintextURL, identityBinding: identity.account,
            destroyKey: {}, useKey: { _, body in try key.withUnsafeBytes(body) })
    }
    /// Explicit synthetic erasure exercises the same file/generation path without opening pages.
    /// It never accesses a real Keychain and is absent from Release.
    @_spi(StorageTestFixture)
    public static func eraseTesting(databaseURL: URL, identity: StoreKeyIdentity,
        legacyPlaintextURL: URL? = nil) throws {
        guard identity.applicationID.hasPrefix("synthetic.") || identity.applicationID.hasPrefix("test.") else {
            throw ProtectedStoreKeyError.invalidIdentity
        }
        try eraseOwned(databaseURL: databaseURL, identity: identity,
            legacyPlaintextURL: legacyPlaintextURL, destroyKey: {})
    }

    @_spi(StorageTestFixture)
    public static func prepareErasureTesting(databaseURL: URL, identity: StoreKeyIdentity) throws -> ProtectedSQLiteErasure {
        guard identity.applicationID.hasPrefix("synthetic.") || identity.applicationID.hasPrefix("test.") else {
            throw ProtectedStoreKeyError.invalidIdentity
        }
        return try prepareOwnedErasure(databaseURL: databaseURL, identity: identity, destroyKey: {})
    }
    #endif

    /// Includes encrypted staging, lifecycle metadata, locks, and explicitly retained migration input.
    public var retainedFiles: [URL] {
        Self.family(databaseURL) + Self.family(URL(fileURLWithPath: databaseURL.path + ".encrypted-staging"))
            + Self.lifecycleFiles(databaseURL) + (retainedLegacySourceURL.map(Self.family) ?? [])
    }

    private static func lifecycleFiles(_ url: URL) -> [URL] {
        [".lifecycle", ".lifecycle.new", ".lock", ".lease-lock"].map { URL(fileURLWithPath: url.path + $0) }
    }

    private static func removeCiphertext(databaseURL: URL, legacy: URL?) throws {
        try ProtectedSQLiteReadLease.retireReaders(at: databaseURL) {
            let files = family(databaseURL) + family(URL(fileURLWithPath: databaseURL.path + ".encrypted-staging"))
                + (legacy.map(family) ?? [])
            for file in files where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            for directory in Set(files.map { $0.deletingLastPathComponent() }) {
                try StoreLifecycleFence.synchronizeDirectory(directory)
            }
        }
    }

    private static func validateLocation(_ url: URL, legacy: URL?) throws {
        guard url.isFileURL, !url.path.contains("\0"), url.lastPathComponent != ".",
            url.deletingLastPathComponent().path != "/",
            url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL,
            legacy?.standardizedFileURL != url.standardizedFileURL else { throw ProtectedSQLiteError.invalidLocation }
        if let legacy {
            guard legacy.isFileURL,
                legacy.standardizedFileURL == legacy.resolvingSymlinksInPath().standardizedFileURL else {
                throw ProtectedSQLiteError.invalidLocation
            }
        }
    }

    static func family(_ url: URL) -> [URL] {
        ["", "-wal", "-shm", "-journal"].map { URL(fileURLWithPath: url.path + $0) }
    }

    private static func prepareDirectory(_ url: URL, policy: StoreAccessPolicy) throws {
        let directory = url.deletingLastPathComponent()
        let permitted = Set((family(url) + family(URL(fileURLWithPath: url.path + ".encrypted-staging"))
            + lifecycleFiles(url)).map(\.lastPathComponent))
        if FileManager.default.fileExists(atPath: directory.path) {
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let transientNames = Set((family(url).dropFirst() + family(URL(fileURLWithPath: url.path + ".encrypted-staging")))
                .map(\.lastPathComponent) + [url.lastPathComponent + ".lifecycle.new"])
            for child in children {
                guard permitted.contains(child.lastPathComponent) else { throw ProtectedSQLiteError.invalidLocation }
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ProtectedSQLiteError.invalidLocation }
                } catch {
                    let cocoa = error as NSError
                    let missing = cocoa.domain == NSCocoaErrorDomain
                        && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code)
                    guard missing && transientNames.contains(child.lastPathComponent) else { throw error }
                }
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: protectionAttributes(policy))
        // Existing policy is not changed before the namespace's lifecycle binding is admitted.
        // New directories already inherit their fixed class from createDirectory attributes.
        var excluded = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try excluded.setResourceValues(resources)
    }

    private static func protectionAttributes(_ policy: StoreAccessPolicy) -> [FileAttributeKey: Any] {
        #if os(iOS)
        return [.protectionKey: policy == .identityWhenUnlocked
            ? FileProtectionType.complete : FileProtectionType.completeUntilFirstUserAuthentication,
            .posixPermissions: 0o700]
        #else
        return [.posixPermissions: 0o700]
        #endif
    }

    static func protect(_ url: URL, policy: StoreAccessPolicy) throws {
        try FileManager.default.setAttributes(protectionAttributes(policy), ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private static func protectFamily(_ url: URL, policy: StoreAccessPolicy) throws {
        try protect(url.deletingLastPathComponent(), policy: policy)
        for file in family(url) + lifecycleFiles(url) where FileManager.default.fileExists(atPath: file.path) {
            try protect(file, policy: policy)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    static func open(_ url: URL, readOnly: Bool = false) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let status = sqlite3_open_v2(url.path, &pointer, flags, nil)
        guard status == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw ProtectedSQLiteError.unavailable(status)
        }
        return pointer
    }

    static func applyKey(_ key: UnsafeRawBufferPointer, to db: OpaquePointer) throws {
        try withRawCodecKey(key) { encoded in
            guard kenshiki_sqlcipher_key(UnsafeMutableRawPointer(db), encoded.baseAddress, Int32(encoded.count)) == SQLITE_OK else {
                throw ProtectedSQLiteError.invalidKey
            }
        }
        guard let version = try scalar(db, "PRAGMA cipher_version"), version.hasPrefix("4.") else {
            throw ProtectedSQLiteError.cipherUnavailable
        }
    }

    // SQLCipher's documented raw-key form avoids password derivation for an already random
    // 256-bit key. The temporary ASCII representation is wiped as soon as sqlite3_key copies it.
    private static func withRawCodecKey<T>(_ key: UnsafeRawBufferPointer,
        _ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        guard key.count == 32 else { throw ProtectedSQLiteError.invalidKey }
        var encoded = Data(count: 67)
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        let hex = Array("0123456789abcdef".utf8)
        encoded[0] = 120; encoded[1] = 39; encoded[66] = 39
        for (index, byte) in key.enumerated() {
            encoded[2 + index * 2] = hex[Int(byte >> 4)]
            encoded[3 + index * 2] = hex[Int(byte & 15)]
        }
        return try encoded.withUnsafeBytes(body)
    }

    private static func configure(_ db: OpaquePointer) throws {
        try execute(db, "PRAGMA cipher_memory_security=ON; PRAGMA temp_store=MEMORY; PRAGMA secure_delete=ON; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;")
        // This first keyed read rejects plain files/wrong keys before changing the journal mode.
        _ = try scalar(db, "SELECT count(*) FROM sqlite_master")
        guard try scalar(db, "PRAGMA journal_mode=WAL") == "wal",
            try scalar(db, "PRAGMA temp_store") == "2" else { throw ProtectedSQLiteError.cipherUnavailable }
    }

    static func verify(_ db: OpaquePointer) throws {
        guard try scalar(db, "PRAGMA quick_check") == "ok" else { throw ProtectedSQLiteError.unavailable(SQLITE_CORRUPT) }
        // SQLCipher returns no rows when all page authentication codes verify.
        guard try scalar(db, "PRAGMA cipher_integrity_check") == nil else { throw ProtectedSQLiteError.unavailable(SQLITE_CORRUPT) }
    }

    private static func installAuthorizer(_ db: OpaquePointer, foundationOperation: Bool, readOnly: Bool = false) {
        sqlite3_set_authorizer(db, { context, operation, first, second, _, _ in
            if context == UnsafeMutableRawPointer(bitPattern: 2) {
                if operation == SQLITE_PRAGMA {
                    let name = first.map { String(cString: $0).lowercased() } ?? ""
                    return second == nil && ["user_version", "query_only", "cipher_version"].contains(name) ? SQLITE_OK : SQLITE_DENY
                }
                guard [SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE].contains(operation) else { return SQLITE_DENY }
            }
            if operation == SQLITE_ATTACH || operation == SQLITE_DETACH { return SQLITE_DENY }
            let name = first.map { String(cString: $0).lowercased() } ?? ""
            let argument = second.map { String(cString: $0).lowercased() }
            if context == nil, [SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE, SQLITE_DROP_TABLE,
                SQLITE_ALTER_TABLE, SQLITE_CREATE_TABLE, SQLITE_CREATE_TRIGGER, SQLITE_DROP_TRIGGER].contains(operation),
                name.hasPrefix("_kenshiki_") || (argument?.hasPrefix("_kenshiki_") ?? false) {
                return SQLITE_DENY
            }
            if operation == SQLITE_FUNCTION, ["sqlcipher_export", "load_extension"].contains(argument ?? name) {
                return SQLITE_DENY
            }
            if operation == SQLITE_PRAGMA {
                if ["key", "rekey", "writable_schema", "temp_store_directory", "data_store_directory"].contains(name) || name.hasPrefix("cipher_") && argument != nil {
                    return SQLITE_DENY
                }
                if let argument {
                    switch name {
                    case "temp_store": return ["memory", "2"].contains(argument) ? SQLITE_OK : SQLITE_DENY
                    case "journal_mode": return argument == "wal" ? SQLITE_OK : SQLITE_DENY
                    case "synchronous": return ["full", "2"].contains(argument) ? SQLITE_OK : SQLITE_DENY
                    case "secure_delete": return ["on", "1"].contains(argument) ? SQLITE_OK : SQLITE_DENY
                    default: break
                    }
                }
            }
            return SQLITE_OK
        }, readOnly ? UnsafeMutableRawPointer(bitPattern: 2) : (foundationOperation ? UnsafeMutableRawPointer(bitPattern: 1) : nil))
    }

    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw ProtectedSQLiteError.unavailable(result) }
    }

    enum Value { case text(String), bytes(UnsafeRawBufferPointer) }
    static func bindAndRun(_ db: OpaquePointer, _ sql: String, values: [Value]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProtectedSQLiteError.unavailable(sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let status: Int32
            switch value {
            case let .text(text): status = sqlite3_bind_text(statement, Int32(offset + 1), text, -1, transient)
            case let .bytes(bytes): status = sqlite3_bind_blob(statement, Int32(offset + 1), bytes.baseAddress, Int32(bytes.count), transient)
            }
            guard status == SQLITE_OK else { throw ProtectedSQLiteError.unavailable(status) }
        }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw ProtectedSQLiteError.unavailable(status) }
    }

    static func scalar(_ db: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProtectedSQLiteError.unavailable(sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else {
            if status == SQLITE_DONE { return nil }
            throw ProtectedSQLiteError.unavailable(status)
        }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    /// The legacy source is read-only, including any retained WAL, and remains untouched. A failed
    /// export never replaces canonical ciphertext. The adopter retires the source only after its
    /// exclusive startup cutover; filesystem deletion is not forensic flash erasure.
    private static func migratePlaintext(source: URL, destination: URL, key: UnsafeRawBufferPointer,
        policy: StoreAccessPolicy) throws {
        let header = try FileHandle(forReadingFrom: source)
        let first: Data
        do { first = try header.read(upToCount: 16) ?? Data(); try header.close() }
        catch { try header.close(); throw error }
        guard first == Data("SQLite format 3\0".utf8) else { throw ProtectedSQLiteError.migrationRequired }
        let staging = URL(fileURLWithPath: destination.path + ".encrypted-staging")
        // An interrupted export is never accepted merely because a staged file exists.
        for file in family(staging) where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        let writer = try open(staging)
        defer { sqlite3_close_v2(writer) }
        do {
            try applyKey(key, to: writer)
            try execute(writer, "PRAGMA cipher_memory_security=ON; PRAGMA temp_store=MEMORY; PRAGMA synchronous=FULL;")
            // An explicit read-only URI prevents attached-database creation or source mutation.
            let sourceURI = source.absoluteString + "?mode=ro"
            try bindAndRun(writer, "ATTACH DATABASE ? AS plaintext KEY ''", values: [.text(sourceURI)])
            try execute(writer, "BEGIN;")
            guard try scalar(writer, "PRAGMA plaintext.quick_check") == "ok" else {
                throw ProtectedSQLiteError.unavailable(SQLITE_CORRUPT)
            }
            let before = try LegacySQLiteCutover.commitment(source)
            let version = try scalar(writer, "PRAGMA plaintext.user_version") ?? "0"
            let vacuum = try scalar(writer, "PRAGMA plaintext.auto_vacuum") ?? "0"
            guard version.allSatisfy(\.isNumber), ["0", "1", "2"].contains(vacuum) else {
                throw ProtectedSQLiteError.unavailable(SQLITE_CORRUPT)
            }
            try execute(writer, "PRAGMA main.auto_vacuum=\(vacuum); SELECT sqlcipher_export('main','plaintext'); PRAGMA main.user_version=\(version);")
            guard try LegacySQLiteCutover.commitment(source) == before else {
                throw ProtectedSQLiteError.migrationConflict
            }
            try LegacySQLiteCutover.record(db: writer, source: source, commitment: before)
            try execute(writer, "COMMIT; DETACH DATABASE plaintext;")
            try verify(writer)
            try protect(staging, policy: policy)
            let written = try FileHandle(forWritingTo: staging)
            do { try written.synchronize(); try written.close() }
            catch { try written.close(); throw error }
            // Rename is atomic within this dedicated directory. Existing canonical data is refused.
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw ProtectedSQLiteError.destinationExists }
            try FileManager.default.moveItem(at: staging, to: destination)
            try StoreLifecycleFence.synchronizeDirectory(destination.deletingLastPathComponent())
        } catch {
            // Retain staging for diagnostics/retry; it is already encrypted and its parent protected.
            throw error
        }
    }
}

/// A handle to one already durable erase intent, not a new lifecycle or storage engine.
/// Finish only after associated key cleanup succeeds. Dropping the handle leaves recovery pending.
@_spi(StorageAdapter)
public final class ProtectedSQLiteErasure: @unchecked Sendable {
    private let lock = NSLock()
    private let complete: () throws -> Void
    private var finished = false

    fileprivate init(complete: @escaping () throws -> Void) { self.complete = complete }

    public func finish() throws {
        try lock.withLock {
            guard !finished else { return }
            try complete()
            finished = true
        }
    }
}
