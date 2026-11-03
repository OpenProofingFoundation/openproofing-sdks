import Foundation

/// Test handshakes must suspend the cooperative executor while the producer runs.
/// A dedicated thread also keeps the wait out of the dispatch pool that owns the
/// callback under test. The caller's original absolute deadline is unchanged.
func waitForDocumentTestSemaphore(
  _ semaphore: DispatchSemaphore, timeout: DispatchTime
) async -> DispatchTimeoutResult {
  await withCheckedContinuation { continuation in
    Thread.detachNewThread {
      continuation.resume(returning: semaphore.wait(timeout: timeout))
    }
  }
}
