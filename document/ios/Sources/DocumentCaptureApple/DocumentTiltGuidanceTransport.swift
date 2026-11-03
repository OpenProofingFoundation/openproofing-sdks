import Foundation

/// The controller runs only on analysisQueue. The lock synchronizes native invalidation and
/// watchdog readback with each bounded consume/archive/publication transaction.
final class DocumentTiltGuidanceTransport: @unchecked Sendable {
  private let lock = NSLock()
  private var runID: UUID?
  private var invalidation: DocumentTiltReason?
  private var controller: DocumentTiltController?
  private var armed = false
  private var lastReceipt: Double?
  private let recorder: DocumentTemporalRecorder?
  private let handler: @Sendable (DocumentTiltPresentation) -> Void

  init(
    recorder: DocumentTemporalRecorder?,
    handler: @escaping @Sendable (DocumentTiltPresentation) -> Void
  ) {
    self.recorder = recorder
    self.handler = handler
  }

  /// A pending, cancelled or terminal attempt cannot change ordinary analysis policy.
  var usesFreshDetections: Bool {
    lock.withLock {
      armed && invalidation == nil && controller?.configuration.usesFreshDetections == true
    }
  }

  /// Native owner reserves the run before enqueueing begin, so an immediate end cannot be lost.
  func prepare(runID: UUID) {
    lock.withLock {
      self.runID = runID
      invalidation = nil
      armed = false
      lastReceipt = nil
    }
  }

  func invalidate(runID: UUID, reason: DocumentTiltReason) {
    lock.withLock {
      guard self.runID == runID else { return }
      invalidation = invalidation ?? reason
      armed = false
    }
  }

  /// Begin and admission are one analysis transaction. A cancelled queued command still archives
  /// its control-only attempt, but that bookkeeping cannot announce a live movement baseline.
  func begin(
    runID: UUID, configuration: DocumentTiltConfiguration,
    hostSeconds: Double = DocumentTemporalRecorder.hostNow()
  ) -> DocumentTiltPresentation? {
    lock.withLock {
      guard self.runID == runID else { return nil }
      controller = DocumentTiltController(runID: runID, configuration: configuration)
      guard let initial = controller?.initialUpdate else { return nil }
      if let invalidation {
        recorder?.observeTiltGuidance(initial)
        finish(reason: invalidation)
        return nil
      }
      armed = !initial.presentation.phase.terminal
      lastReceipt = armed ? hostSeconds : nil
      publish(initial)
      return armed ? controller?.presentation : nil
    }
  }

  func consume(_ packet: DocumentLiveGeometryObservation, hostSeconds: Double) {
    lock.withLock {
      guard armed, invalidation == nil, var current = controller else { return }
      lastReceipt = hostSeconds
      let update = current.consume(packet)
      controller = current
      if update.presentation.phase.terminal { armed = false }
      publish(update)
    }
  }

  func end(runID: UUID, reason: DocumentTiltReason) {
    lock.withLock {
      guard controller?.runID == runID else { return }
      let effectiveReason = self.runID == runID ? invalidation ?? reason : reason
      if self.runID == runID {
        invalidation = effectiveReason
        armed = false
      }
      finish(reason: effectiveReason)
    }
  }

  func endActive(reason: DocumentTiltReason) {
    lock.withLock {
      guard controller?.runID == runID else { return }
      let reason = invalidation ?? reason
      invalidation = reason
      armed = false
      finish(reason: reason)
    }
  }

  func silenceExceeded(runID: UUID, now: Double, maximum: Double) -> Bool {
    lock.withLock {
      self.runID == runID && armed && lastReceipt.map { now - $0 > maximum } == true
    }
  }

  private func finish(reason: DocumentTiltReason) {
    guard var current = controller else { return }
    let update =
      [.skipped, .userSkipped].contains(reason)
      ? current.skip(reason: reason) : current.cancel(reason: reason)
    controller = current
    publish(update)
  }

  private func publish(_ update: DocumentTiltUpdate) {
    guard update.event != nil else { return }
    recorder?.observeTiltGuidance(update)
    handler(update.presentation)
  }
}

extension DocumentTemporalRecorder {
  func observeTiltGuidance(_ update: DocumentTiltUpdate) {
    withState {
      emit(
        .init(
          kind: "tilt_guidance", hostTimeSeconds: Self.hostNow(),
          timestamp: update.event?.captureTimestamp, tiltGuidance: update))
    }
    #if DEBUG
      DocumentTiltDiagnosticTrace.record(update, sink: diagnosticSink)
    #endif
  }
}
