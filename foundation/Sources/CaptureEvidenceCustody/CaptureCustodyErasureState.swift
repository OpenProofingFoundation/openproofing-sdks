import Darwin
import Foundation

/// A write-ahead erase intent, preallocated before this generation can publish evidence.
/// It contains no identity or key material. Unknown/truncated contents fail integrity checks.
/// In-place mutation allows intent to persist even if the directory refuses unlink/rename.
enum CaptureCustodyErasureState {
  /// Used only for an explicit owner erase, including unreadable old custody metadata. Normal
  /// opening never overwrites a corrupt intent or treats it as permission to discard evidence.
  static func prepareExplicitErasure(directory: URL, fileManager: FileManager) throws {
    #if os(iOS)
      let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
      try Data([1]).write(to: location(directory), options: [.atomic, .completeFileProtection])
    #else
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try Data([1]).write(to: location(directory), options: [.atomic])
    #endif
    let file = try FileHandle(forWritingTo: location(directory))
    defer { try? file.close() }
    try file.synchronize()
    try synchronizeDirectory(directory)
  }
  static func location(_ directory: URL) -> URL {
    directory.appendingPathComponent("custody.erasure")
  }

  static func pending(directory: URL, fileManager: FileManager) throws -> Bool {
    let url = location(directory)
    guard fileManager.fileExists(atPath: url.path) else { return false }
    let bytes = try Data(contentsOf: url)
    guard bytes == Data([0]) || bytes == Data([1]) else {
      throw CaptureEvidenceStoreError.integrityFailure
    }
    return bytes == Data([1])
  }

  static func prepare(directory: URL, fileManager: FileManager) throws -> Bool {
    let url = location(directory)
    if fileManager.fileExists(atPath: url.path) {
      return try pending(directory: directory, fileManager: fileManager)
    }
    #if os(iOS)
      try Data([0]).write(to: url, options: [.atomic, .completeFileProtection])
    #else
      try Data([0]).write(to: url, options: [.atomic])
    #endif
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.synchronize()
    try synchronizeDirectory(directory)
    return false
  }

  static func markPending(directory: URL, fileManager: FileManager) throws {
    let file = try FileHandle(forWritingTo: location(directory))
    defer { try? file.close() }
    try file.write(contentsOf: Data([1]))
    try file.synchronize()
    guard try pending(directory: directory, fileManager: fileManager) else {
      throw CaptureEvidenceStoreError.integrityFailure
    }
  }

  /// Only the runtime calls this after both records and their Keychain key are gone.
  /// The publication lock file goes too: an erased location retains no custody file.
  static func finish(directory: URL, fileManager: FileManager) throws {
    for url in [location(directory), directory.appendingPathComponent("journey.lock")]
    where fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
    try synchronizeDirectory(directory)
  }

  /// Successful record-only maintenance keeps its key/generation. Persist deleted entries
  /// before restoring active state, otherwise a crash could revive a partial archive.
  static func completeMaintenance(directory: URL, fileManager _: FileManager) throws {
    try synchronizeDirectory(directory)
    let file = try FileHandle(forWritingTo: location(directory))
    defer { try? file.close() }
    try file.write(contentsOf: Data([0]))
    try file.synchronize()
  }

  private static func synchronizeDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
