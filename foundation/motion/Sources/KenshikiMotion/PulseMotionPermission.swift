import Foundation
#if os(iOS)
import CoreMotion
#endif

/// Explicit product permission gate shared with the Pulse Motion & Fitness flow.
/// CMMotionManager itself has no authorization-request API in the supported SDK.
/// The bounded activity query requests the system grant; activity data is discarded.
@MainActor
public final class PulseMotionPermission {
  public enum Status: String, Codable, Sendable {
    case notRequested, requesting, authorized, denied, unavailable
  }
  private var generation = UUID()
  private let statusOverride: (() -> Status)?
  private let queryOverride: ((@escaping @MainActor @Sendable () -> Void) -> Void)?
  #if os(iOS)
  private let activity = CMMotionActivityManager()
  #endif

  public init() {
    statusOverride = nil
    queryOverride = nil
  }

  init(status: @escaping () -> Status,
       query: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void) {
    statusOverride = status
    queryOverride = query
  }

  public var status: Status {
    if let statusOverride { return statusOverride() }
    #if os(iOS)
    guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
    switch CMMotionActivityManager.authorizationStatus() {
    case .authorized: return .authorized
    case .denied, .restricted: return .denied
    case .notDetermined: return .notRequested
    @unknown default: return .unavailable
    }
    #else
    return .unavailable
    #endif
  }

  public func request(completion: @escaping @MainActor @Sendable (Status) -> Void) {
    generation = UUID()
    let attempt = generation
    guard status == .notRequested else { completion(status); return }
    completion(.requesting)
    guard generation == attempt else { return }
    let finished: @MainActor @Sendable () -> Void = { [weak self] in
      guard let self, self.generation == attempt else { return }
      completion(self.status)
    }
    if let queryOverride {
      queryOverride(finished)
      return
    }
    #if os(iOS)
    let now = Date()
    activity.queryActivityStarting(from: now.addingTimeInterval(-1), to: now, to: .main) { _, _ in
      Task { @MainActor in finished() }
    }
    #endif
  }

  public func cancel() { generation = UUID() }
}
