import Foundation

/// One live native model operation, including cancellation settlement, across all attempts.
actor FaceInferenceScheduler {
    static let shared = FaceInferenceScheduler()
    private var busy = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    var queuedCount: Int { waiters.count }

    func run<Value: Sendable>(_ work: @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await work()
    }

    private func acquire() async throws {
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancellation can arrive before the handler's actor hop registers.
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard waiters.count < 4 else { continuation.resume(throwing: FaceWorkflowStorageFailure.capacity); return }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().continuation.resume() }
    }
}
