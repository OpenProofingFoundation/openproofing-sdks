import Foundation
import DocumentCaptureApple
import CaptureEvidenceCustody

/// One bounded admission queue and one asynchronous writer. Pending bytes include in-flight IO.
public final class CaptureRecordingJournal: DocumentJourneyRecordingSink, @unchecked Sendable {
  enum Item: Sendable {
    case frame(DocumentTemporalFrame, UUID)
    case motion([DocumentTemporalMotionSample])
    case event(DocumentJourneyRecordingEvent)
    case milestone(DocumentJourneyRecordingEvent, UUID)
  }
  public let reference: CaptureRecordingReference
  public var recordingID: UUID { reference.recordingID }
  let clock: CaptureRecordingClock
  let policy: CaptureRecordingPolicy
  let diagnosticSink: @Sendable (CaptureRecordingDiagnostic) -> Void
  let store: CaptureEvidenceStore
  let lock = NSLock()
  let maximumPendingBytes: Int
  let maximumDiskBytes: Int
  let deadline: TimeInterval
  var queue: [Item] = []
  var submitted: Set<UUID> = []
  var milestones: Set<UUID> = []
  var milestoneWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  var pendingGap: DocumentJourneyRecordingEvent?
  var firstLoss: DocumentJourneyRecordingEvent?
  var coalescedGapEvents = 0
  var platformDropCallbacks = 0
  static let controlReserveBytes: Int = CaptureJournalEngineeringDefaults.controlReserveBytes
  var finishing = false
  var waiters: [CheckedContinuation<DocumentJourneyRecordingReceipt, Error>] = []
  var lastNotification: String?
  var reservations: [UUID: Int] = [:]
  var pendingBytes = 0
  var motionBatch: [DocumentTemporalMotionSample] = []
  private var latestMotionSample: DocumentTemporalMotionSample?
  var pump: Task<Void, Never>?
  var deadlineTask: Task<Void, Never>?
  var terminalReason: String?
  var writeFailed = false
  var sealed: DocumentJourneyRecordingReceipt?
  var tailID: UUID
  var tailHash: String
  var ordinal = 1
  var chargedBytes = 0
  var issueCount = 0
  var retainedStillCount = 0
  var frameCount = 0
  var motionCount = 0
  var refusedFrames = 0
  var refusedMotion = 0
  var acquisitionDiagnostics = RecordingAcquisitionDiagnostics()
  var handler: (@Sendable (String) -> Void)?
  var tiltBudgetWatch: TiltBudgetWatch?
  var tiltBudgetDeadline: Task<Void, Never>?

  /// Most recently admitted sample from this recording's existing sensor stream.
  /// This is transient presentation data, not proof of durable retention.
  /// Consumers must check the sample's boot timestamp before presenting it.
  public var latestMotionObservation: DocumentTemporalMotionSample? {
    lock.withLock {
      guard !finishing, sealed == nil, !writeFailed, terminalReason == nil else { return nil }
      return latestMotionSample
    }
  }

  public var status: String {
    lock.withLock {
      if writeFailed { return "failed" }
      return sealed?.status ?? (terminalReason == nil ? "recording" : "stopping")
    }
  }

  public static func start(
    workflowID: UUID, store: CaptureEvidenceStore, clock: CaptureRecordingClock,
    policy: CaptureRecordingPolicy = .retainedV2,
    maximumDuration: Double? = nil, maximumDiskBytes: Int? = nil, maximumPendingBytes: Int? = nil,
    diagnosticSink: @escaping @Sendable (CaptureRecordingDiagnostic) -> Void = { _ in }
  ) async throws -> CaptureRecordingJournal {
    let maximumDuration = maximumDuration ?? policy.maximumDuration
    let requestedMaximumDiskBytes = maximumDiskBytes ?? policy.maximumDiskBytes
    let maximumPendingBytes = maximumPendingBytes ?? policy.maximumPendingBytes
    guard maximumDuration.isFinite, maximumDuration > 0,
      requestedMaximumDiskBytes > 65_536, maximumPendingBytes > 0, !policy.version.isEmpty
    else {
      throw CaptureEvidenceStoreError.invalidRecord
    }
    let available = try await store.availableCapacityForRecording()
    guard let available, available > 1_073_807_360 else {
      throw CaptureEvidenceStoreError.invalidRecord
    }
    let maximumDiskBytes = min(requestedMaximumDiskBytes, Int(available - 1_073_741_824))
    let id = UUID()
    let payload = try JSONEncoder().encode(
      CaptureRecordingStart(
        schemaVersion: 1, maximumDuration: maximumDuration, maximumDiskBytes: maximumDiskBytes,
        maximumPendingBytes: maximumPendingBytes, startedAt: clock.now(),
        configurationVersion: policy.version))
    let hash = CapturePayloadIntegrity.sha256(payload)
    let link = CaptureRecordingLink(
      schemaVersion: 1, recordKind: "journeyRecordingStart", recordingID: id,
      workflowID: workflowID, ordinal: 0, previousID: nil, previousSHA256: nil,
      payloadSHA256: hash, frame: nil)
    let manifest = try JSONEncoder().encode(link)
    try await store.store(id: id, original: payload, manifest: manifest)
    let journal = CaptureRecordingJournal(
      reference: .init(recordingID: id, workflowID: workflowID, startSHA256: hash),
      store: store, clock: clock, policy: policy, diagnosticSink: diagnosticSink,
      maximumDuration: maximumDuration, maximumDiskBytes: maximumDiskBytes,
      maximumPendingBytes: maximumPendingBytes,
      startCharge: 2 * payload.count + 2 * manifest.count + 4096)
    journal.armDeadline(after: maximumDuration)
    return journal
  }

  init(
    reference: CaptureRecordingReference, store: CaptureEvidenceStore,
    clock: CaptureRecordingClock, policy: CaptureRecordingPolicy = .retainedV2,
    diagnosticSink: @escaping @Sendable (CaptureRecordingDiagnostic) -> Void = { _ in },
    maximumDuration: Double, maximumDiskBytes: Int, maximumPendingBytes: Int, startCharge: Int
  ) {
    self.clock = clock
    self.policy = policy
    self.diagnosticSink = diagnosticSink
    self.reference = reference
    self.store = store
    self.maximumDiskBytes = maximumDiskBytes
    self.maximumPendingBytes = maximumPendingBytes
    deadline = clock.uptime() + maximumDuration
    tailID = reference.recordingID
    tailHash = reference.startSHA256
    chargedBytes = startCharge
  }

  func armDeadline(after duration: Double) {
    lock.withLock {
      deadlineTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(duration)) } catch { return }
        guard let self else { return }
        self.lock.withLock {
          guard self.sealed == nil, !self.writeFailed else { return }
          self.terminalReason = self.terminalReason ?? "duration_limit"
          self.flushMotion()
          self.schedule()
        }
        self.notify()
      }
    }
  }

  public func setStatusHandler(_ callback: @escaping @Sendable (String) -> Void) {
    lock.withLock { handler = callback }
  }

  public func reserveFrame(byteCount: Int) -> UUID? {
    reserveFrame(byteCount: byteCount, loss: nil)
  }

  public func reserveFrame(byteCount: Int, failure: DocumentJourneyRecordingEvent) -> UUID? {
    reserveFrame(byteCount: byteCount, loss: failure)
  }

  private func reserveFrame(byteCount: Int, loss: DocumentJourneyRecordingEvent?) -> UUID? {
    let result = lock.withLock { () -> UUID? in
      guard !finishing, sealed == nil, !writeFailed else { return nil }
      guard accepting() else {
        recordAdmissionRefusal(.terminalAdmission, loss: loss)
        return nil
      }
      if let reason = frameCapacityRefusal(byteCount: byteCount) {
        refusedFrames += 1
        recordAdmissionRefusal(reason, loss: loss)
        return nil
      }
      let token = UUID()
      reservations[token] = byteCount
      pendingBytes += byteCount
      observeQueuePressure()
      return token
    }
    notify()
    return result
  }

  public func appendFrame(_ frame: DocumentTemporalFrame, reservation: UUID) {
    lock.withLock {
      guard !finishing, sealed == nil, !writeFailed else { return }
      guard !submitted.contains(reservation) else {
        terminalReason = terminalReason ?? "duplicate_frame_submission"
        schedule()
        return
      }
      guard reservations[reservation] == frame.payload.count,
        submitted.insert(reservation).inserted,
        !finishing, sealed == nil, !writeFailed
      else {
        pendingBytes -= reservations.removeValue(forKey: reservation) ?? 0
        terminalReason = "invalid_frame_reservation"
        schedule()
        return
      }
      queue.append(.frame(frame, reservation))
      schedule()
    }
    notify()
  }

  public func cancelReservation(_ reservation: UUID, reason _: String) {
    cancelReservation(reservation, loss: nil)
  }

  public func cancelReservation(_ reservation: UUID, failure: DocumentJourneyRecordingEvent) {
    cancelReservation(reservation, loss: failure)
  }

  private func cancelReservation(_ reservation: UUID, loss: DocumentJourneyRecordingEvent?) {
    lock.withLock {
      guard !finishing, sealed == nil, !writeFailed, reservations[reservation] != nil,
        !submitted.contains(reservation)
      else { return }
      pendingBytes -= reservations.removeValue(forKey: reservation) ?? 0
      refusedFrames += 1
      if loss?.kind != "frame_copy_failed" && loss?.kind != "frame_copy_cancelled" {
        countFrameRefusal(.otherCancellation)
      }
      if let loss { recordLoss(loss) }
      schedule()
    }
    notify()
  }
}

extension CaptureRecordingJournal {
  public func appendMotion(_ sample: DocumentTemporalMotionSample) {
    lock.withLock {
      guard !finishing, sealed == nil, !writeFailed else { return }
      guard accepting() else {
        refusedMotion += 1
        schedule()
        return
      }
      guard queue.count < 256 else {
        refusedMotion += 1
        return
      }
      latestMotionSample = sample
      motionBatch.append(sample)
      if motionBatch.count >= 100 {
        flushMotion()
        schedule()
      }
    }
    notify()
  }

  public func appendEvent(_ event: DocumentJourneyRecordingEvent) {
    lock.withLock {
      guard sealed == nil, !writeFailed, !finishing else { return }
      if ["frame_admission_failed", "frame_copy_failed", "frame_copy_cancelled", "frame_dropped"]
        .contains(event.kind)
      {
        recordLoss(event)
        schedule()
        return
      }
      guard terminalReason == nil else { return }
      guard queue.count < 256 else {
        terminalReason = "event_backpressure"
        schedule()
        return
      }
      flushMotion()
      queue.append(.event(event))
      if event.kind == "session_issue" { terminalReason = terminalReason ?? "session_issue" }
      schedule()
    }
    notify()
  }
}

extension CaptureRecordingJournal {
  func recordLoss(_ event: DocumentJourneyRecordingEvent) {
    let first = firstLoss == nil
    if first { firstLoss = event }
    if event.kind == "frame_dropped" { platformDropCallbacks += 1 }
    if event.kind == "frame_copy_failed" { countFrameRefusal(.copyFailed) }
    if event.kind == "frame_copy_cancelled" { countFrameRefusal(.copyCancelled) }
    // Persist the first loss once; later callbacks update bounded seal counters.
    // Replenishing a priority gap item could otherwise starve admitted frame and still writes.
    guard first else {
      coalescedGapEvents += 1
      return
    }
    pendingGap = event
  }

  public func reserveMilestone() -> UUID? {
    let token = lock.withLock { () -> UUID? in
      guard accepting() else {
        schedule()
        return nil
      }
      guard milestones.count < 2,
        chargedBytes <= maximumDiskBytes - Self.controlReserveBytes * (milestones.count + 2)
      else { return nil }
      let token = UUID()
      milestones.insert(token)
      return token
    }
    notify()
    return token
  }

  public func cancelMilestone(_ token: UUID) {
    lock.withLock {
      guard milestoneWaiters[token] == nil, milestones.remove(token) != nil else { return }
      schedule()
    }
  }

  public func appendStillRetained(_ event: DocumentJourneyRecordingEvent, reservation: UUID)
    async throws
  {
    try await withCheckedThrowingContinuation { continuation in
      let accepted = lock.withLock { () -> Bool in
        guard milestones.contains(reservation), milestoneWaiters[reservation] == nil,
          !finishing, !writeFailed, sealed == nil
        else { return false }
        milestoneWaiters[reservation] = continuation
        flushMotion()
        queue.append(.milestone(event, reservation))
        schedule()
        return true
      }
      if !accepted { continuation.resume(throwing: CaptureEvidenceStoreError.integrityFailure) }
    }
  }

  public func finish(reason: String) async throws -> DocumentJourneyRecordingReceipt {
    try await withCheckedThrowingContinuation { continuation in
      let result = lock.withLock { () -> Result<DocumentJourneyRecordingReceipt, Error>? in
        if writeFailed { return .failure(CaptureEvidenceStoreError.integrityFailure) }
        if let sealed { return .success(sealed) }
        waiters.append(continuation)
        terminalReason = terminalReason ?? reason
        flushMotion()
        schedule()
        return nil
      }
      notify()
      if let result { continuation.resume(with: result) }
    }
  }

  func accepting() -> Bool {
    if terminalReason != nil || writeFailed || sealed != nil { return false }
    if clock.uptime() >= deadline {
      terminalReason = "duration_limit"
      return false
    }
    return true
  }

  func flushMotion() {
    if !motionBatch.isEmpty {
      queue.append(.motion(motionBatch))
      motionBatch.removeAll(keepingCapacity: true)
    }
  }

  func schedule() {
    observeQueuePressure()
    let terminalWork =
      terminalReason != nil
      && (!motionBatch.isEmpty || (reservations.isEmpty && milestones.isEmpty))
    guard pump == nil, sealed == nil, !writeFailed,
      !queue.isEmpty || pendingGap != nil || terminalWork
    else { return }
    pump = Task { [self] in await drain() }
  }

  func notify() {
    notifyTiltBudget()
    let current = status
    let callback = lock.withLock { () -> (@Sendable (String) -> Void)? in
      guard lastNotification != current else { return nil }
      lastNotification = current
      return handler
    }
    callback?(current)
  }
}
