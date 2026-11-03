import Foundation

/// A provisional opportunity for ordinary capture, not a guarantee of user completion time.
/// It ends supplementary work; the existing hard journal limits and photo custody remain authoritative.
/// The fixed `provisionalV1` reserve exceeds the default recording policy (`retainedV2`, 512 MiB and
/// 20 s), so under it tilt is always declined. A document presence policy names its own reserve
/// (S-02); `provisionalV1` stays as it was for opt-in practice until measured values replace it.
public struct CaptureTiltBudgetPolicy: Encodable, Equatable, Sendable {
  public static let provisionalV1 = Self(
    version: "optional-tilt-core-reserve-v1", coreReserveBytes: 4_294_967_296, coreReserveSeconds: 30.0)
  public let version: String
  public let coreReserveBytes: Int
  public let coreReserveSeconds: Double
  public init(version: String, coreReserveBytes: Int, coreReserveSeconds: Double) {
    self.version = version
    self.coreReserveBytes = coreReserveBytes
    self.coreReserveSeconds = coreReserveSeconds
  }
}

extension CaptureRecordingJournal {
  public struct TiltBudgetSnapshot: Encodable, Equatable, Sendable {
    public let recordingID: UUID
    public let policy: CaptureTiltBudgetPolicy
    public let recording: Bool
    public let chargedBytes: Int
    /// Includes an intentionally duplicated allowance for already charged in-flight frames.
    public let conservativePendingCharge: Int
    public let maximumDiskBytes: Int
    public let remainingSeconds: Double

    public var tiltBudgetAvailable: Bool {
      recording
        && maximumDiskBytes - chargedBytes - conservativePendingCharge > policy.coreReserveBytes
        && remainingSeconds > policy.coreReserveSeconds
    }
  }

  struct TiltBudgetWatch: Sendable {
    let owner: UUID
    let policy: CaptureTiltBudgetPolicy
    let handler: @Sendable (TiltBudgetSnapshot) -> Void
  }

  public func tiltBudgetSnapshot(
    now: TimeInterval? = nil, policy: CaptureTiltBudgetPolicy = .provisionalV1
  ) -> TiltBudgetSnapshot {
    lock.withLock { tiltBudgetSnapshotLocked(now: now ?? clock.uptime(), policy: policy) }
  }

  /// Atomic check-and-subscribe. One bounded watch survives failed attempts until photo capture resumes.
  public func watchTiltBudget(
    owner: UUID, policy: CaptureTiltBudgetPolicy = .provisionalV1,
    handler: @escaping @Sendable (TiltBudgetSnapshot) -> Void
  ) -> TiltBudgetSnapshot {
    lock.withLock {
      tiltBudgetDeadline?.cancel()
      tiltBudgetDeadline = nil
      tiltBudgetWatch = nil
      let snapshot = tiltBudgetSnapshotLocked(now: clock.uptime(), policy: policy)
      guard snapshot.tiltBudgetAvailable else { return snapshot }
      tiltBudgetWatch = .init(owner: owner, policy: policy, handler: handler)
      let duration = snapshot.remainingSeconds - snapshot.policy.coreReserveSeconds
      tiltBudgetDeadline = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(duration)) } catch { return }
        self?.notifyTiltBudget()
      }
      return snapshot
    }
  }

  public func clearTiltBudgetWatch(owner: UUID) {
    lock.withLock {
      guard tiltBudgetWatch?.owner == owner else { return }
      tiltBudgetWatch = nil
      tiltBudgetDeadline?.cancel()
      tiltBudgetDeadline = nil
    }
  }

  /// Called on admission/write notifications, outside the writer and camera locks. Never blocks on IO.
  func notifyTiltBudget() {
    let pending = lock.withLock { () -> (TiltBudgetWatch, TiltBudgetSnapshot)? in
      guard let watch = tiltBudgetWatch else { return nil }
      let snapshot = tiltBudgetSnapshotLocked(now: clock.uptime(), policy: watch.policy)
      guard !snapshot.tiltBudgetAvailable else { return nil }
      tiltBudgetWatch = nil
      tiltBudgetDeadline?.cancel()
      tiltBudgetDeadline = nil
      return (watch, snapshot)
    }
    if let (watch, snapshot) = pending { watch.handler(snapshot) }
  }

  private func tiltBudgetSnapshotLocked(
    now: TimeInterval, policy: CaptureTiltBudgetPolicy
  ) -> TiltBudgetSnapshot {
    // Every outstanding frame gets its doubled payload plus a control-sized metadata allowance.
    // Queue/control allowance deliberately overcounts frames and the in-flight writer. This is an
    // early supplementary cutoff, not an exact allocation or a reservation against other disk users.
    let pendingCharge =
      2 * pendingBytes
      + Self.controlReserveBytes * (queue.count + reservations.count + milestones.count + 3)
    return .init(
      recordingID: recordingID, policy: policy,
      recording: terminalReason == nil && !writeFailed && sealed == nil && !finishing
        && now < deadline,
      chargedBytes: chargedBytes, conservativePendingCharge: pendingCharge,
      maximumDiskBytes: maximumDiskBytes, remainingSeconds: max(0, deadline - now))
  }
}
