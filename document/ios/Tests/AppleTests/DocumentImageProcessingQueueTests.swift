import Foundation
import Testing

@testable import DocumentCaptureApple

@Suite struct DocumentImageProcessingQueueTests {
  @Test func blockedNativeWorkLeavesAsyncTasksRunnableAndRejectsCancelledResult() async throws {
    let queue = DocumentImageProcessingQueue()
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let operation = Task {
      try await queue.run { _ in
        entered.continuation.yield(())
        // A finite watchdog makes executor starvation an assertion, not a hung suite.
        guard release.wait(timeout: .now() + 5) == .success else {
          throw ImageProcessingTestFailure.watchdogExpired
        }
        return 1
      }
    }
    defer { release.signal(); entered.continuation.finish() }
    var events = entered.stream.makeAsyncIterator()
    _ = await events.next()
    let marker = Task { 42 }
    #expect(await marker.value == 42)
    operation.cancel()
    release.signal()
    do {
      _ = try await operation.value
      Issue.record("Cancelled native work published its late result")
    } catch is CancellationError {}
    // Cancellation belongs to the operation, not the reusable processing queue.
    #expect(try await queue.run { _ in 7 } == 7)
  }

  @Test func cancellationBetweenNativeStagesPreventsTheNextStage() async throws {
    let queue = DocumentImageProcessingQueue()
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let secondStage = ImageProcessingInvocation()
    let operation = Task {
      try await queue.run { checkCancellation in
        entered.continuation.yield(())
        guard release.wait(timeout: .now() + 5) == .success else {
          throw ImageProcessingTestFailure.watchdogExpired
        }
        try checkCancellation()
        secondStage.record()
        return 1
      }
    }
    defer { release.signal(); entered.continuation.finish() }
    var events = entered.stream.makeAsyncIterator()
    _ = await events.next()
    operation.cancel()
    release.signal()
    do {
      _ = try await operation.value
      Issue.record("Cancelled processing continued to another native stage")
    } catch is CancellationError {}
    #expect(!secondStage.wasInvoked)
  }

  @Test func alreadyCancelledWorkNeverEntersNativeProcessing() async throws {
    let queue = DocumentImageProcessingQueue()
    let entered = ImageProcessingInvocation()
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await queue.run { _ in entered.record(); return 1 }
    }
    do {
      _ = try await operation.value
      Issue.record("Already cancelled work entered native processing")
    } catch is CancellationError {}
    #expect(!entered.wasInvoked)
  }
}

private enum ImageProcessingTestFailure: Error { case watchdogExpired }

private final class ImageProcessingInvocation: @unchecked Sendable {
  private let lock = NSLock()
  private var invoked = false
  var wasInvoked: Bool { lock.withLock { invoked } }
  func record() { lock.withLock { invoked = true } }
}
