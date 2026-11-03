import Foundation

/// Optional capability: existing controllers without it expose a finished geometry stream.
protocol CameraSessionGeometryProviding: Sendable {
  func setGeometryObservationHandler(
    _ handler: @escaping @Sendable (DocumentLiveGeometryObservation) -> Void)
}

/// Lock-bound stream delivery; no per-observation Task or main-actor hop.
final class DocumentGeometryObservationDelivery: @unchecked Sendable {
  private var currentStream: AsyncStream<DocumentLiveGeometryObservation>
  var stream: AsyncStream<DocumentLiveGeometryObservation> { lock.withLock { currentStream } }
  private var continuation: AsyncStream<DocumentLiveGeometryObservation>.Continuation
  private let lock = NSLock()
  private var terminal = false
  private var generation: Int?
  private var latestRevision: UInt64?

  init() {
    let pair = AsyncStream.makeStream(
      of: DocumentLiveGeometryObservation.self, bufferingPolicy: .bufferingNewest(1))
    currentStream = pair.stream
    continuation = pair.continuation
  }

  deinit { continuation.finish() }
  func finish() {
    lock.withLock {
      terminal = true
      continuation.finish()
    }
  }

  func activate(generation: Int) {
    lock.withLock {
      self.generation = generation
      latestRevision = nil
    }
  }

  /// Finish the old subscription on lifecycle change; it may drain its last buffered value.
  /// Consumers cancel or fence their old subscription when their session ends.
  /// A new session obtains a fresh stream; callbacks from the old generation are rejected.
  func deactivate() {
    lock.withLock {
      generation = nil
      continuation.finish()
      guard !terminal else { return }
      let pair = AsyncStream.makeStream(
        of: DocumentLiveGeometryObservation.self,
        bufferingPolicy: .bufferingNewest(1))
      currentStream = pair.stream
      continuation = pair.continuation
    }
  }

  func yield(_ packet: DocumentLiveGeometryObservation, generation: Int) {
    lock.withLock {
      guard self.generation == generation,
        latestRevision.map({ packet.geometryRevision >= $0 }) ?? true
      else { return }
      latestRevision = packet.geometryRevision
      continuation.yield(packet)
    }
  }
}

extension AVFoundationCameraSessionController: CameraSessionGeometryProviding {
  func setGeometryObservationHandler(
    _ handler: @escaping @Sendable (DocumentLiveGeometryObservation) -> Void
  ) {
    sessionQueue.sync { geometryObservationHandler = handler }
  }

  /// Runs on sessionQueue, independently of still admission and adaptive controls.
  func publishLiveGeometry(_ packet: DocumentLiveGeometryObservation, generation: UInt64) {
    guard state.nativeCaptureReady, generation == state.geometryObservationGeneration,
      packet.geometryRevision == state.geometryRevision
    else { return }
    geometryObservationHandler(packet)
  }
}

// Actual clock-object changes need a fence even when CMTime.epoch is unchanged.
extension AVFoundationCameraSessionController {
  func resetGeometryObservationEpoch(
    reason: DocumentLiveGeometryObservation.ResetReason,
    preservingPendingClockBinding: Bool = false
  ) {
    let preservePending =
      preservingPendingClockBinding && reason == .clockChanged
      && state.tiltGuidance.holding && state.tiltGuidance.beginCompletion != nil
      && !state.tiltGuidance.controllerStarted
    if !preservePending {
      cancelTiltGuidance(reason: reason == .clockChanged ? .clockChanged : .geometryChanged)
    }
    #if os(iOS)
      refreshAnalysisGeometry(
        resetReason: reason, preservingPendingClockBinding: preservePending)
    #else
      state.geometryRevision &+= 1
      state.frameAnalyzer?.updateGuideRegion(
        nil, geometryRevision: state.geometryRevision,
        resetReason: reason)
    #endif
  }
}

/// At most one queued owner callback and one newest packet while the native owner is busy.
final class DocumentGeometryObservationMailbox: @unchecked Sendable {
  struct Entry {
    let packet: DocumentLiveGeometryObservation
    let generation: UInt64
  }
  private let lock = NSLock()
  private var pending: Entry?
  private var scheduled = false

  func offer(_ packet: DocumentLiveGeometryObservation, generation: UInt64) -> Bool {
    lock.withLock {
      if let pending, pending.generation > generation { return false }
      pending = Entry(packet: packet, generation: generation)
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

extension AVFoundationCameraSessionController {
  func enqueueLiveGeometry(_ packet: DocumentLiveGeometryObservation, generation: UInt64) {
    guard geometryMailbox.offer(packet, generation: generation) else { return }
    sessionQueue.async { [self] in
      guard let entry = geometryMailbox.take() else { return }
      publishLiveGeometry(entry.packet, generation: entry.generation)
    }
  }
}
