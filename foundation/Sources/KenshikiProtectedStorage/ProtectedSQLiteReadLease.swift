import Darwin
import Foundation
import SQLCipher

public enum ProtectedReadLeaseError: Error, Equatable {
    case unsupportedPolicy, invalidDuration, expired, closed
}

/// One bounded background operation, holding a stable read transaction between pages. Hardware
/// custody and the durable epoch are checked again on every page; no identity-while-unlocked
/// connection may use this API. Expiry retires caches when the process can execute; every page
/// checks the continuous deadline before reading and before returning its result.
public final class ProtectedSQLiteReadLease: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    private var lockDescriptor: Int32
    private let admit: (() throws -> Void) throws -> Void
    private let deadline: ContinuousClock.Instant
    private var expirationTask: Task<Void, Never>?
    private var expired = false
    private var borrowing = false
    private var closeRequested = false

    init(handle: OpaquePointer, lockDescriptor: Int32, duration: TimeInterval,
        admit: @escaping (() throws -> Void) throws -> Void) {
        self.handle = handle
        self.lockDescriptor = lockDescriptor
        self.admit = admit
        self.deadline = ContinuousClock.now.advanced(by: .seconds(duration))
        sqlite3_progress_handler(handle, 1_000, { raw in
            guard let raw else { return 1 }
            let lease = Unmanaged<ProtectedSQLiteReadLease>.fromOpaque(raw).takeUnretainedValue()
            return ContinuousClock.now >= lease.deadline ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
        let deadline = self.deadline
        self.expirationTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, tolerance: .zero, clock: .continuous) }
            catch { return } // Explicit closure cancels retirement; it already closed the handle.
            self?.expire()
        }
    }

    deinit { close() }

    /// Statements must be prepared and finalized within one callback. No pointer, statement or
    /// backup resource may escape; callers persist their value cursor, never a borrowed handle.
    @_spi(StorageAdapter)
    public func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        // Inspect terminal state without retaining this mutex while awaiting lifecycle admission.
        lock.lock()
        let terminal: ProtectedReadLeaseError? = handle == nil ? (expired ? .expired : .closed) : nil
        lock.unlock()
        if let terminal { throw terminal }
        var result: Result<T, Error>?
        do {
            // Lifecycle admission precedes the local lease mutex. A queued page must never
            // hold that mutex while waiting for a writer whose callback may reject nesting.
            try admit {
                lock.lock()
                defer { lock.unlock() }
                guard !borrowing else { throw ProtectedStoreLifecycleError.nestedAdmission }
                borrowing = true
                defer { borrowing = false; if closeRequested { closeLocked() } }
                if ContinuousClock.now >= deadline {
                    expired = true
                    closeLocked()
                }
                guard let handle else { throw expired ? ProtectedReadLeaseError.expired : .closed }
                result = Result {
                    let value = try body(handle)
                    guard ContinuousClock.now < deadline else {
                        expired = true
                        throw ProtectedReadLeaseError.expired
                    }
                    return value
                }
                var omitted = false
                while let statement = sqlite3_next_stmt(handle, nil) {
                    omitted = true
                    sqlite3_finalize(statement)
                }
                if omitted { throw ProtectedSQLiteError.unfinalizedStatements }
            }
            guard let result else { throw ProtectedSQLiteError.invalidKey }
            return try result.get()
        } catch {
            // A rejected nested borrow does not own the live callback's connection.
            if error as? ProtectedStoreLifecycleError != .nestedAdmission { close() }
            throw error
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if borrowing { closeRequested = true; return }
        closeLocked()
    }

    private func expire() {
        lock.lock()
        defer { lock.unlock() }
        expired = true
        closeLocked()
    }

    private func closeLocked() {
        expirationTask?.cancel()
        expirationTask = nil
        if let handle {
            sqlite3_set_authorizer(handle, nil, nil)
            sqlite3_progress_handler(handle, 0, nil, nil)
            while let statement = sqlite3_next_stmt(handle, nil) { sqlite3_finalize(statement) }
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(handle)
            self.handle = nil
        }
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    static func openLock(at databaseURL: URL, exclusive: Bool) throws -> Int32 {
        let descriptor = Darwin.open(databaseURL.path + ".lease-lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ProtectedStoreLifecycleError.ioFailure(errno) }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let saved = errno
            Darwin.close(descriptor)
            if saved == EWOULDBLOCK { throw ProtectedSQLiteError.unavailable(SQLITE_BUSY) }
            throw ProtectedStoreLifecycleError.ioFailure(saved)
        }
        return descriptor
    }

    static func releaseLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    static func retireReaders<T>(at databaseURL: URL, _ body: () throws -> T) throws -> T {
        let descriptor = try openLock(at: databaseURL, exclusive: true)
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        return try body()
    }
}
