import Foundation

/// Resource exclusion only: no process-global custody policy or erase state.
/// A lease is retained by the store, including references held by delayed publishers.
final class CaptureCustodyLease: @unchecked Sendable {
  private final class Registry: @unchecked Sendable {
    let lock = NSLock()
    var owners: [UUID: CaptureCustodyConfiguration] = [:]
  }
  private static let registry = Registry()
  private let id: UUID
  private init(id: UUID) { self.id = id }

  static func acquire(_ configuration: CaptureCustodyConfiguration) throws -> CaptureCustodyLease {
    try registry.lock.withLock {
      for owner in registry.owners.values {
        let left = owner.directory.resolvingSymlinksInPath().path + "/"
        let right = configuration.directory.resolvingSymlinksInPath().path + "/"
        let sameKey =
          owner.keychainService == configuration.keychainService
          && owner.keychainAccount == configuration.keychainAccount
          && owner.accessGroup == configuration.accessGroup
        guard !sameKey, !left.hasPrefix(right), !right.hasPrefix(left)
        else { throw CaptureEvidenceStoreError.custodyInUse }
      }
      let id = UUID()
      registry.owners[id] = configuration
      return CaptureCustodyLease(id: id)
    }
  }

  func release() {
    _ = Self.registry.lock.withLock { Self.registry.owners.removeValue(forKey: id) }
  }
  deinit { release() }
}
