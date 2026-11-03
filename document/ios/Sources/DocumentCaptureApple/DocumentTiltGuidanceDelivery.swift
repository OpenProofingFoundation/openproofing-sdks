import Foundation

protocol CameraSessionTiltGuidanceControlling: Sendable {
  func setTiltGuidanceHandler(_ handler: @escaping @Sendable (DocumentTiltPresentation) -> Void)
  func beginTiltGuidance(
    runID: UUID, configuration: DocumentTiltConfiguration,
    cancellation: DocumentTiltStartCancellation,
    completion: @escaping @Sendable (Result<DocumentTiltPresentation, PhotoCaptureError>) -> Void)
  func endTiltGuidance(
    runID: UUID, reason: DocumentTiltReason, completion: @escaping @Sendable () -> Void)
}

/// One latest presentation; archival/controller delivery is upstream and never uses this stream.
final class DocumentTiltGuidanceDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var pair = AsyncStream.makeStream(
    of: DocumentTiltPresentation.self, bufferingPolicy: .bufferingNewest(1))
  private var generation: Int?
  private var runID: UUID?
  private var revision: UInt64 = 0
  private var unsupported = false
  var stream: AsyncStream<DocumentTiltPresentation> { lock.withLock { pair.stream } }

  deinit { pair.continuation.finish() }

  func finishUnsupported() {
    lock.withLock {
      unsupported = true
      pair.continuation.finish()
    }
  }

  func activate(generation: Int) {
    lock.withLock {
      self.generation = generation
      runID = nil
      revision = 0
    }
  }

  func begin(runID: UUID) {
    lock.withLock {
      self.runID = runID
      revision = 0
    }
  }

  func yield(_ value: DocumentTiltPresentation, generation: Int) {
    lock.withLock {
      guard self.generation == generation, runID == value.runID, value.revision > revision else {
        return
      }
      revision = value.revision
      pair.continuation.yield(value)
    }
  }

  func deactivate() {
    lock.withLock {
      generation = nil
      runID = nil
      pair.continuation.finish()
      if !unsupported {
        pair = AsyncStream.makeStream(
          of: DocumentTiltPresentation.self, bufferingPolicy: .bufferingNewest(1))
      }
    }
  }
}

/// Bounded analysis-to-owner delivery, independent of native terminal cleanup.
final class DocumentTiltGuidanceMailbox: @unchecked Sendable {
  struct Entry {
    let presentation: DocumentTiltPresentation
    let generation: UInt64
  }
  private let lock = NSLock()
  private var pending: Entry?
  private var scheduled = false

  func offer(_ presentation: DocumentTiltPresentation, generation: UInt64) -> Bool {
    lock.withLock {
      if let pending, pending.generation > generation { return false }
      pending = .init(presentation: presentation, generation: generation)
      guard !scheduled else { return false }
      scheduled = true
      return true
    }
  }

  func take() -> Entry? {
    lock.withLock {
      defer {
        pending = nil
        scheduled = false
      }
      return pending
    }
  }
}

/// Cancellation may precede the native queue's begin command; preserve that fact explicitly.
final class DocumentTiltStartCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  var isCancelled: Bool { lock.withLock { cancelled } }
  func cancel() { lock.withLock { cancelled = true } }
}
