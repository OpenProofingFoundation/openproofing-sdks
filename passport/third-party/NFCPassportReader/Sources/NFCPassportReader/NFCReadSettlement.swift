import Foundation

/// Serializes the terminal outcome and continuation delivery for one passport read.
///
/// The tag task, cancellation handler, and CoreNFC invalidation callback can race.
/// The first recorded outcome wins; subsequent records cannot replace it. Recording
/// and releasing are separate operations: the reader records an outcome before asking
/// CoreNFC to invalidate, then releases only from the matching invalidation callback.
/// This keeps passive authentication outside the live NFC session.
///
/// The lock protects state transitions. Continuations and observation callbacks run
/// after unlocking, so caller code cannot re-enter while the state lock is held.
/// This generic state machine has no CoreNFC dependency and can be exercised off-device.
public final class NFCReadSettlement<Value>: @unchecked Sendable {
    public enum Outcome {
        case success(Value)
        case failure(Error)
    }

    /// Which context settled, for the log line that attributes the next field report.
    public enum Settler: String, Sendable {
        case readTask = "read_task"
        case sessionInvalidation = "session_invalidation"
        case readerAbort = "reader_abort"
        case taskCancellation = "task_cancellation"
        case unavailable = "unavailable"
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Outcome?
    private var settledBy: Settler?
    private var didArm = false
    private var releaseRequested = false
    private var didRelease = false
    private let onSettled: (Settler, Bool) -> Void

    private struct Delivery {
        let continuation: CheckedContinuation<Value, Error>
        let outcome: Outcome
    }

    /// - Parameter onSettled: called with the settler and whether it WON (true) or arrived after
    ///   the decision (false). The reader routes this to its logger; tests capture it.
    public init(onSettled: @escaping (Settler, Bool) -> Void = { _, _ in }) {
        self.onSettled = onSettled
    }

    /// Hand over the continuation. A terminal event recorded before arming is retained, not lost;
    /// if release was also requested, arming delivers it immediately.
    public func arm(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        precondition(!didArm, "NFCReadSettlement armed twice")
        didArm = true
        self.continuation = continuation
        let delivery = takeDeliveryIfReady()
        lock.unlock()
        resume(delivery)
    }

    /// Record the terminal outcome. Returns true if this call won; false if another context had
    /// already recorded the decision. Recording never releases the awaiting caller by itself.
    @discardableResult
    public func record(_ outcome: Outcome, by settler: Settler) -> Bool {
        lock.lock()
        let won = settledBy == nil
        if won {
            settledBy = settler
            self.outcome = outcome
        }
        let delivery = takeDeliveryIfReady()
        lock.unlock()
        onSettled(settler, won)
        resume(delivery)
        return won
    }

    /// Release the recorded outcome to the awaiting caller. CoreNFC-backed reads call this only
    /// from the matching session's invalidation callback. Safe before either `arm` or `record`:
    /// delivery occurs once both pieces arrive.
    @discardableResult
    public func release() -> Bool {
        lock.lock()
        releaseRequested = true
        let delivery = takeDeliveryIfReady()
        lock.unlock()
        resume(delivery)
        return delivery != nil
    }

    private func takeDeliveryIfReady() -> Delivery? {
        guard releaseRequested, !didRelease, let continuation, let outcome else { return nil }
        didRelease = true
        self.continuation = nil
        self.outcome = nil
        return Delivery(continuation: continuation, outcome: outcome)
    }

    private func resume(_ delivery: Delivery?) {
        guard let delivery else { return }
        switch delivery.outcome {
        case .success(let value): delivery.continuation.resume(returning: value)
        case .failure(let error): delivery.continuation.resume(throwing: error)
        }
    }

    public var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settledBy != nil
    }

    public var winner: Settler? {
        lock.lock()
        defer { lock.unlock() }
        return settledBy
    }

    public var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRelease
    }
}
