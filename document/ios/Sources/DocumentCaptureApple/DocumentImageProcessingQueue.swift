import Foundation

/// Vision performs blocking work, including waits for its own asynchronous jobs.
/// A detached Swift task still occupies the cooperative executor; use a dispatch
/// worker so those jobs and the caller's cancellation can continue to make progress.
final class DocumentImageProcessingQueue: Sendable {
  static let shared = DocumentImageProcessingQueue()
  private let queue = DispatchQueue(label: "IdentityEvidenceSDK.DocumentImageProcessing", qos: .userInitiated)

  func run<Value: Sendable>(
    _ operation: @escaping @Sendable (_ checkCancellation: @Sendable () throws -> Void) throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    let cancellation = ImageProcessingCancellation()
    return try await withTaskCancellationHandler {
      let result: Value = try await withCheckedThrowingContinuation { continuation in
        queue.async {
          do {
            try cancellation.check()
            let value = try operation { try cancellation.check() }
            try cancellation.check()
            continuation.resume(returning: value)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
      try Task.checkCancellation()
      return result
    } onCancel: {
      cancellation.cancel()
    }
  }
}

private final class ImageProcessingCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() { lock.withLock { cancelled = true } }

  func check() throws {
    if lock.withLock({ cancelled }) { throw CancellationError() }
  }
}
