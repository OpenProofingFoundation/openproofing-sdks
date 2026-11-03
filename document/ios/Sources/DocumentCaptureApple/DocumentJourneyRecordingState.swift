import Foundation

extension DocumentTemporalRecorder {
  /// Only state mutation occurs under the lock. Drain this operation's small
  /// callback batch after unlocking so even a reentrant sink cannot deadlock.
  func withState<Result>(_ body: () -> Result) -> Result {
    lock.lock()
    let result = body()
    let actions = pendingSinkActions.map { action in
      (beginSinkCallback(), action)
    }
    pendingSinkActions.removeAll(keepingCapacity: true)
    lock.unlock()
    for (ticket, action) in actions {
      action()
      finishSinkCallback(ticket)
    }
    return result
  }

  /// Capture the admitted callback frontier; later attachments cannot extend it.
  func detachJourneySink(completion: @escaping @Sendable () -> Void) {
    let ready = withState {
      journeySink = nil
      frameGeneration &+= 1
      let frontier = callbackTicket
      guard activeSinkCallbacks.contains(where: { $0 <= frontier }) else { return true }
      sinkDetachWaiters.append((frontier, completion))
      return false
    }
    if ready { completion() }
  }

  /// Called under the state lock, including before native frame copying begins.
  func beginSinkCallback() -> UInt64 {
    callbackTicket &+= 1
    activeSinkCallbacks.insert(callbackTicket)
    return callbackTicket
  }

  func finishSinkCallback(_ ticket: UInt64) {
    lock.lock()
    activeSinkCallbacks.remove(ticket)
    var ready: [@Sendable () -> Void] = []
    sinkDetachWaiters.removeAll { frontier, completion in
      guard !activeSinkCallbacks.contains(where: { $0 <= frontier }) else { return false }
      ready.append(completion)
      return true
    }
    lock.unlock()
    for completion in ready { completion() }
  }

  func emit(_ event: DocumentJourneyRecordingEvent) {
    guard let sink = journeySink else { return }
    pendingSinkActions.append { sink.appendEvent(event) }
  }

  func emitMotion(_ sample: DocumentTemporalMotionSample) {
    guard let sink = journeySink else { return }
    pendingSinkActions.append { sink.appendMotion(sample) }
  }
}
