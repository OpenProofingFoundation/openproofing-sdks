import XCTest
@testable import KenshikiReference

@MainActor final class FaceInferenceSchedulerTests: XCTestCase {
    func testCancelledQueuedInferenceNeverRunsAndNextWaitsForEngineSettlement() async throws {
        let scheduler = FaceInferenceScheduler()
        let engine = SchedulerEngineProbe()
        let cancellations = SchedulerCancellationProbe()
        let first = Task { try await scheduler.run { await engine.run(1) } }
        try await wait { await engine.started() == [1] }
        let cancelled = Task {
            do { return try await scheduler.run { await engine.run(2) } }
            catch { await cancellations.record(error); throw error }
        }
        try await wait { await scheduler.queuedCount == 1 }
        cancelled.cancel()
        try await wait { await cancellations.count == 1 }
        let remaining = await scheduler.queuedCount
        XCTAssertEqual(remaining, 0)
        let next = Task { try await scheduler.run { await engine.run(3) } }
        try await wait { await scheduler.queuedCount == 1 }
        let before = await engine.started()
        XCTAssertEqual(before, [1])
        await engine.finish()
        let firstValue = try await first.value
        XCTAssertEqual(firstValue, 1)
        do { _ = try await cancelled.value; XCTFail("Cancelled queued inference executed") } catch { }
        let nextValue = try await next.value
        XCTAssertEqual(nextValue, 3)
        let calls = await engine.started()
        let peak = await engine.peak()
        XCTAssertEqual(calls, [1, 3])
        XCTAssertEqual(peak, 1)
    }

    func testCancelledFullQueueReleasesCapacityBeforeActiveInferenceSettles() async throws {
        let scheduler = FaceInferenceScheduler()
        let engine = SchedulerEngineProbe()
        let cancellations = SchedulerCancellationProbe()
        let first = Task { try await scheduler.run { await engine.run(1) } }
        try await wait { await engine.started() == [1] }
        var queued: [Task<Int, Error>] = []
        for id in 2...5 {
            queued.append(Task {
                do { return try await scheduler.run { await engine.run(id) } }
                catch { await cancellations.record(error); throw error }
            })
        }
        try await wait { await scheduler.queuedCount == 4 }
        queued.forEach { $0.cancel() }
        // Canceling active work must not release its lease before the native call settles.
        first.cancel()
        try await wait { await cancellations.count == 4 }
        let pending = await scheduler.queuedCount
        let cancellationErrors = await cancellations.allCancelled
        XCTAssertEqual(pending, 0)
        XCTAssertTrue(cancellationErrors)
        let next = Task { try await scheduler.run { await engine.run(6) } }
        try await wait { await scheduler.queuedCount == 1 }
        let before = await engine.started()
        XCTAssertEqual(before, [1])
        await engine.finish()
        _ = try await first.value
        for task in queued {
            do { _ = try await task.value; XCTFail("Canceled waiter ran") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        let result = try await next.value
        let calls = await engine.started()
        let peak = await engine.peak()
        XCTAssertEqual(result, 6)
        XCTAssertEqual(calls, [1, 6])
        XCTAssertEqual(peak, 1)
    }

    private func wait(_ ready: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await ready()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let complete = await ready()
        XCTAssertTrue(complete)
    }
}

private actor SchedulerCancellationProbe {
    private var cancellations: [Bool] = []
    var count: Int { cancellations.count }
    var allCancelled: Bool { cancellations.allSatisfy { $0 } }
    func record(_ error: Error) { cancellations.append(error is CancellationError) }
}

private actor SchedulerEngineProbe {
    private var calls: [Int] = []
    private var active = 0
    private var maximum = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func run(_ id: Int) async -> Int {
        calls.append(id); active += 1; maximum = max(active, maximum)
        if id == 1 { await withCheckedContinuation { continuation = $0 } }
        active -= 1
        return id
    }
    func finish() { continuation?.resume(); continuation = nil }
    func started() -> [Int] { calls }
    func peak() -> Int { maximum }
}
