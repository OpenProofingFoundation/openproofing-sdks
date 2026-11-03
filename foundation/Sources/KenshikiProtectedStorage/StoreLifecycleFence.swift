import Darwin
import Foundation

public enum ProtectedStoreLifecycleError: Error, Equatable {
  case staleHandle, erasurePending, invalidLifecycle, nestedAdmission, ioFailure(Int32)
}

/// A cross-process lifecycle fence, not a cryptographic anti-rollback anchor. The encrypted store
/// holds admission throughout each complete synchronous borrow, and an erase intent survives crashes.
///
/// The legacy source is recorded by its place beside the store (a path relative to the database's
/// directory), never by an absolute path: iOS gives an app a new data container on every install,
/// so an absolute path stops matching at the first update and the store can never open again.
final class StoreLifecycleFence: @unchecked Sendable {
  private let databaseURL: URL
  private let recordURL: URL
  private let lockURL: URL
  private let temporaryURL: URL
  private let identityBinding: String
  private let local = NSLock()

  init(databaseURL: URL, identityBinding: String, legacySourceURL: URL? = nil) throws {
    guard !identityBinding.isEmpty, identityBinding.utf8.count <= 1024 else {
      throw ProtectedStoreLifecycleError.invalidLifecycle
    }
    self.databaseURL = databaseURL
    self.identityBinding = identityBinding
    recordURL = URL(fileURLWithPath: databaseURL.path + ".lifecycle")
    lockURL = URL(fileURLWithPath: databaseURL.path + ".lock")
    temporaryURL = URL(fileURLWithPath: databaseURL.path + ".lifecycle.new")
    try locked {
      if FileManager.default.fileExists(atPath: recordURL.path) {
        let saved = try load()
        if let legacySourceURL, saved.legacySource != relativeLegacyPath(legacySourceURL) {
          // Registered erasers may name the historical path even on a fresh installation.
          // Normalize only an entirely absent hint; a retained or substituted family conflicts.
          guard saved.legacySource == nil, try Self.legacyFamilyIsAbsent(legacySourceURL) else {
            throw ProtectedStoreLifecycleError.invalidLifecycle
          }
        }
      } else {
        let retained = ["", "-wal", "-shm", "-journal", ".encrypted-staging",
          ".encrypted-staging-wal", ".encrypted-staging-shm", ".encrypted-staging-journal"].contains {
          FileManager.default.fileExists(atPath: databaseURL.path + $0)
        }
        guard !retained else { throw ProtectedStoreLifecycleError.invalidLifecycle }
        let legacy = try legacySourceURL.flatMap { try Self.legacyFamilyIsAbsent($0) ? nil : relativeLegacyPath($0) }
        try persist(Record(version: Record.currentVersion, identityBinding: identityBinding, epoch: 0, erasurePending: false, legacySource: legacy))
      }
    }
  }

  /// lstat distinguishes absence from permissions, I/O failures and symlinks. This runs only
  /// under the lifecycle lock, so an absent historical hint never changes durable inventory.
  private static func legacyFamilyIsAbsent(_ url: URL) throws -> Bool {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      var attributes = stat()
      let result = (url.path + suffix).withCString { lstat($0, &attributes) }
      if result == 0 { return false }
      guard errno == ENOENT else { throw ProtectedStoreLifecycleError.ioFailure(errno) }
    }
    return true
  }

  func currentEpoch() throws -> Int64 {
    try locked {
      let record = try load()
      guard !record.erasurePending else { throw ProtectedStoreLifecycleError.erasurePending }
      return record.epoch
    }
  }

  func withAdmission<T>(epoch: Int64, _ body: () throws -> T) throws -> T {
    try locked {
      let record = try load()
      guard !record.erasurePending else { throw ProtectedStoreLifecycleError.erasurePending }
      guard record.epoch == epoch else { throw ProtectedStoreLifecycleError.staleHandle }
      return try body()
    }
  }

  /// Persist the next epoch before touching ciphertext. If cleanup fails, only explicit recovery
  /// may complete erasure; old handles cannot publish, reopen, or erase a newer generation.
  func erase(epoch: Int64, _ body: () throws -> Void) throws {
    try locked {
      let record = try beginErasureLocked(epoch: epoch)
      try body()
      try persist(Record(version: Record.currentVersion, identityBinding: identityBinding, epoch: record.epoch, erasurePending: false, legacySource: nil))
    }
  }

  /// Leave the existing durable intent pending while an associated key adapter settles.
  /// A bound owner supplies its epoch; a restart eraser explicitly selects the current intent.
  func prepareErasure(epoch: Int64?, _ body: () throws -> Void) throws -> Int64 {
    try locked {
      let current = try load()
      let ownerEpoch = epoch ?? (current.erasurePending ? current.epoch - 1 : current.epoch)
      let record = try beginErasureLocked(epoch: ownerEpoch)
      try body()
      return record.epoch
    }
  }

  func finishPreparedErasure(pendingEpoch: Int64, _ body: () throws -> Void) throws {
    try locked {
      let record = try load()
      guard record.erasurePending, record.epoch == pendingEpoch else {
        throw ProtectedStoreLifecycleError.staleHandle
      }
      try body()
      try persist(Record(version: Record.currentVersion, identityBinding: identityBinding,
        epoch: record.epoch, erasurePending: false, legacySource: nil))
    }
  }

  private func beginErasureLocked(epoch: Int64) throws -> Record {
    var record = try load()
    if record.erasurePending {
      guard epoch >= 0, epoch < Int64.max, record.epoch == epoch + 1 else {
        throw ProtectedStoreLifecycleError.staleHandle
      }
    } else {
      guard record.epoch == epoch, epoch < Int64.max else { throw ProtectedStoreLifecycleError.staleHandle }
      record = Record(version: Record.currentVersion, identityBinding: identityBinding,
        epoch: epoch + 1, erasurePending: true, legacySource: record.legacySource)
      try persist(record)
    }
    return record
  }

  /// Read-only observation of the atomic lifecycle record. No lock, directory, key or record is
  /// created. Normal admissions still acquire the lock and recheck the authoritative epoch.
  static func hasPendingErasure(databaseURL: URL, identityBinding: String) throws -> Bool {
    let url = URL(fileURLWithPath: databaseURL.path + ".lifecycle")
    var attributes = stat()
    if lstat(url.path, &attributes) != 0 {
      guard errno == ENOENT else { throw ProtectedStoreLifecycleError.ioFailure(errno) }
      return false
    }
    guard attributes.st_mode & S_IFMT == S_IFREG else { throw ProtectedStoreLifecycleError.invalidLifecycle }
    return try readRecord(url, identityBinding: identityBinding).erasurePending
  }

  /// A newly constructed owner may finish only an already durable erase intent. It cannot invent
  /// an erasure or reset the generation when opening retained data fails.
  func resumePendingErasure(_ body: () throws -> Void) throws {
    guard try recoverPendingErasure(body) else { throw ProtectedStoreLifecycleError.invalidLifecycle }
  }

  /// No-op without a durable erase intent. Useful at adopter startup before any open or publish.
  @discardableResult
  func recoverPendingErasure(_ body: () throws -> Void) throws -> Bool {
    try locked {
      let record = try load()
      guard record.erasurePending else { return false }
      try body()
      try persist(Record(version: Record.currentVersion, identityBinding: identityBinding, epoch: record.epoch, erasurePending: false, legacySource: nil))
      return true
    }
  }

  func retainedLegacySource() throws -> URL? {
    try locked {
      guard let path = try load().legacySource else { return nil }
      guard !path.hasPrefix("/") else { throw ProtectedStoreLifecycleError.invalidLifecycle }
      let source = absoluteLegacyURL(path)
      guard path.utf8.count <= 4096, source != databaseURL,
        source.standardizedFileURL == source.resolvingSymlinksInPath().standardizedFileURL else {
        throw ProtectedStoreLifecycleError.invalidLifecycle
      }
      return source
    }
  }

  /// The legacy source's path relative to the database's directory, with no symlink resolution:
  /// both URLs come from the same caller in the same container, so their shared prefix is literal.
  private func relativeLegacyPath(_ url: URL) -> String {
    let base = databaseURL.standardizedFileURL.deletingLastPathComponent().pathComponents
    let target = url.standardizedFileURL.pathComponents
    var shared = 0
    while shared < base.count, shared < target.count, base[shared] == target[shared] { shared += 1 }
    return (Array(repeating: "..", count: base.count - shared) + target[shared...]).joined(separator: "/")
  }

  private func absoluteLegacyURL(_ relative: String) -> URL {
    URL(fileURLWithPath: relative, relativeTo: databaseURL.standardizedFileURL.deletingLastPathComponent())
      .standardizedFileURL
  }

  private struct Record: Codable {
    /// Version 2 records the legacy source relative to the store. Version 1 recorded an absolute
    /// path, which iOS invalidates at the next install; such a record is not read.
    static let currentVersion = 2
    let version: Int
    let identityBinding: String
    let epoch: Int64
    let erasurePending: Bool
    let legacySource: String?
  }

  private func load() throws -> Record {
    try Self.readRecord(recordURL, identityBinding: identityBinding)
  }

  private static func readRecord(_ url: URL, identityBinding: String) throws -> Record {
    let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard descriptor >= 0 else { throw ProtectedStoreLifecycleError.ioFailure(errno) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let bytes = try file.read(upToCount: 4097) ?? Data()
    guard bytes.count <= 4096,
      let record = try? JSONDecoder().decode(Record.self, from: bytes),
      record.version == Record.currentVersion, record.identityBinding == identityBinding, record.epoch >= 0 else {
      throw ProtectedStoreLifecycleError.invalidLifecycle
    }
    return record
  }

  private func persist(_ record: Record) throws {
    let descriptor = temporaryURL.path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else { throw ProtectedStoreLifecycleError.ioFailure(errno) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try file.write(contentsOf: JSONEncoder().encode(record))
    try file.synchronize()
    let renamed = temporaryURL.path.withCString { source in
      recordURL.path.withCString { destination in Darwin.rename(source, destination) }
    }
    guard renamed == 0 else { throw ProtectedStoreLifecycleError.ioFailure(errno) }
    try Self.synchronizeDirectory(databaseURL.deletingLastPathComponent())
  }

  static func synchronizeDirectory(_ directoryURL: URL) throws {
    let directory = directoryURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard directory >= 0 else { throw ProtectedStoreLifecycleError.ioFailure(errno) }
    defer { Darwin.close(directory) }
    guard Darwin.fsync(directory) == 0 else { throw ProtectedStoreLifecycleError.ioFailure(errno) }
  }

  var isAdmittedOnCurrentThread: Bool {
    Thread.current.threadDictionary["com.kenshiki.storage.admission." + databaseURL.standardizedFileURL.path] != nil
  }

  private func locked<T>(_ body: () throws -> T) throws -> T {
    let admissionKey = "com.kenshiki.storage.admission." + databaseURL.standardizedFileURL.path
    guard Thread.current.threadDictionary[admissionKey] == nil else {
      throw ProtectedStoreLifecycleError.nestedAdmission
    }
    local.lock()
    defer { local.unlock() }
    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else { throw ProtectedStoreLifecycleError.ioFailure(errno) }
    defer { Darwin.close(descriptor) }
    var status: Int32
    repeat { status = flock(descriptor, LOCK_EX) } while status != 0 && errno == EINTR
    guard status == 0 else { throw ProtectedStoreLifecycleError.ioFailure(errno) }
    defer { flock(descriptor, LOCK_UN) }
    Thread.current.threadDictionary[admissionKey] = true
    defer { Thread.current.threadDictionary.removeObject(forKey: admissionKey) }
    return try body()
  }
}
