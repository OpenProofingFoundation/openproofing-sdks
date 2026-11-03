import CoreMedia
import Foundation
import DocumentCaptureApple
import CaptureEvidenceCustody

extension CaptureRecordingJournal {
  enum WriteFailure: Error { case diskLimit }
  func drain() async {
    do {
      while true {
        let next = lock.withLock { nextItem() }
        if let next {
          try await write(next)
          continue
        }
        let shouldSeal = lock.withLock { () -> Bool in
          guard terminalReason != nil, reservations.isEmpty, milestones.isEmpty,
            queue.isEmpty, pendingGap == nil
          else { return false }
          finishing = true
          return true
        }
        if shouldSeal {
          try await seal()
          return
        }
        let done = lock.withLock { () -> Bool in
          guard canParkWriter() else { return false }
          pump = nil
          return true
        }
        if done { return }
      }
    } catch {
      lock.withLock {
        deadlineTask?.cancel()
        writeFailed = true
        terminalReason = "storage_failure"
        queue.removeAll()
        motionBatch.removeAll()
        reservations.removeAll()
        pendingBytes = 0
        pump = nil
      }
      resolveMilestones(.failure(CaptureEvidenceStoreError.integrityFailure))
      finishWaiters(.failure(CaptureEvidenceStoreError.integrityFailure))
      notify()
    }
  }

  /// Called under admission lock; a terminal request observed here must be consumed before parking.
  func canParkWriter() -> Bool {
    queue.isEmpty && pendingGap == nil
      && (terminalReason == nil || !reservations.isEmpty || !milestones.isEmpty)
  }

  func write(_ item: Item) async throws {
    let data: Data
    let kind: String
    var frame: DocumentTemporalFrameMetadata?
    var reservation: UUID?
    var milestone: UUID?
    var samples = 0
    var eventValue: DocumentJourneyRecordingEvent?
    switch item {
    case .frame(let value, let token):
      data = value.payload
      kind = "journeyRecordingFrame"
      frame = value.metadata
      reservation = token
    case .motion(let values):
      data = try JSONEncoder().encode(values)
      kind = "journeyRecordingMotion"
      samples = values.count
    case .milestone(let value, let token):
      milestone = token
      eventValue = value
      data = try JSONEncoder().encode(value)
      kind = "journeyRecordingEvent"
    case .event(let value):
      eventValue = value
      data = try JSONEncoder().encode(value)
      kind = "journeyRecordingEvent"
    }
    defer { releaseFrameReservation(reservation) }
    do {
      _ = try await append(data: data, kind: kind, frame: frame, milestone: milestone)
    } catch WriteFailure.diskLimit {
      if milestone != nil { throw WriteFailure.diskLimit }
      recordDiskLoss(frame: frame, samples: samples)
      return
    }
    lock.withLock {
      if frame != nil { frameCount += 1 }
      motionCount += samples
      if let eventValue { countEvent(eventValue) }
    }
    completeMilestone(milestone)
  }

  private func recordDiskLoss(frame: DocumentTemporalFrameMetadata?, samples: Int) {
    lock.withLock {
      terminalReason = "disk_limit"
      if let frame {
        refusedFrames += 1
        countFrameRefusal(.diskCapacity)
        recordLoss(
          .init(
            kind: "frame_write_failed",
            hostTimeSeconds: frame.hostTimeSeconds ?? clock.uptime(),
            timestamp: frame.timestamp, contextCode: "disk_limit"))
      }
      refusedMotion += samples
    }
    notify()
  }

  private func releaseFrameReservation(_ reservation: UUID?) {
    guard let reservation else { return }
    lock.withLock {
      pendingBytes -= reservations.removeValue(forKey: reservation) ?? 0
      submitted.remove(reservation)
    }
  }

  private func completeMilestone(_ milestone: UUID?) {
    guard let milestone else { return }
    let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      milestones.remove(milestone)
      return milestoneWaiters.removeValue(forKey: milestone)
    }
    waiter?.resume()
  }

  private func nextItem() -> Item? {
    if let gap = pendingGap {
      pendingGap = nil
      return .event(gap)
    }
    if !queue.isEmpty { return queue.removeFirst() }
    if terminalReason != nil { flushMotion() }
    return queue.isEmpty ? nil : queue.removeFirst()
  }

  func countEvent(_ event: DocumentJourneyRecordingEvent) {
    if event.kind == "still_retained" { retainedStillCount += 1 }
    if CaptureRecordingVerification.isIssue(event.kind) { issueCount += 1 }
  }

  func append(
    data: Data, kind: String, frame: DocumentTemporalFrameMetadata? = nil, milestone: UUID? = nil
  ) async throws -> Int {
    let hash = frame?.sha256 ?? CapturePayloadIntegrity.sha256(data)
    let link = CaptureRecordingLink(
      schemaVersion: 1, recordKind: kind, recordingID: recordingID,
      workflowID: reference.workflowID, ordinal: ordinal,
      previousID: tailID, previousSHA256: tailHash, payloadSHA256: hash, frame: frame)
    let manifest = try JSONEncoder().encode(link)
    let charge = 2 * data.count + 2 * manifest.count + 4096
    let admitted = lock.withLock { () -> Bool in
      let ownReserve = milestone == nil ? 0 : 1
      let reserve =
        kind == "journeyRecordingSeal"
        ? 0
        : Self.controlReserveBytes * (1 + milestones.count - ownReserve)
      guard milestone == nil || charge <= Self.controlReserveBytes,
        charge <= maximumDiskBytes - chargedBytes - reserve
      else { return false }
      chargedBytes += charge
      return true
    }
    guard admitted else { throw WriteFailure.diskLimit }
    let id = UUID()
    let storeStarted = clock.uptime()
    var storeFailed = true
    defer {
      recordStoreAwait(
        kind: kind, elapsed: clock.uptime() - storeStarted,
        failed: storeFailed)
    }
    try await store.store(id: id, original: data, manifest: manifest, expectedSHA256: hash)
    storeFailed = false
    tailID = id
    tailHash = hash
    ordinal += 1
    return charge
  }

  func seal() async throws {
    let value = lock.withLock {
      CaptureRecordingSeal(
        status: terminalReason == "completed" && refusedFrames == 0 && refusedMotion == 0
          && issueCount == 0 && firstLoss == nil && frameCount > 0 && motionCount > 0
          && retainedStillCount > 0
          ? "complete" : "partial",
        reason: terminalReason ?? "interrupted", frameCount: frameCount,
        motionSampleCount: motionCount, issueCount: issueCount,
        retainedStillCount: retainedStillCount, refusedFrames: refusedFrames,
        refusedMotionSamples: refusedMotion,
        firstLossTimestamp: firstLoss?.timestamp,
        firstLossHostTimeSeconds: firstLoss?.hostTimeSeconds,
        firstLossReason: firstLoss.map { $0.kind + ":" + String(($0.contextCode ?? "").prefix(256)) },
        coalescedGapEvents: coalescedGapEvents, platformDropCallbacks: platformDropCallbacks,
        acquisitionDiagnostics: acquisitionDiagnostics)
    }
    _ = try await append(data: JSONEncoder().encode(value), kind: "journeyRecordingSeal")
    lock.withLock {
      deadlineTask?.cancel()
      sealed = .init(
        recordingID: recordingID, status: value.status,
        frameCount: frameCount, motionSampleCount: motionCount)
      pump = nil
    }
    try? await store.checkpointMetadataIndex()
    if let receipt = lock.withLock({ sealed }) { finishWaiters(.success(receipt)) }
    notify()
  }

  func resolveMilestones(_ result: Result<Void, Error>) {
    let pending = lock.withLock {
      let values = Array(milestoneWaiters.values)
      milestoneWaiters.removeAll()
      milestones.removeAll()
      return values
    }
    for waiter in pending { waiter.resume(with: result) }
  }

  func finishWaiters(_ result: Result<DocumentJourneyRecordingReceipt, Error>) {
    let pending = lock.withLock {
      let values = waiters
      waiters.removeAll()
      return values
    }
    for waiter in pending { waiter.resume(with: result) }
  }
}
