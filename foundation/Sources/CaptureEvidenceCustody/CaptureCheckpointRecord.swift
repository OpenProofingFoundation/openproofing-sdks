import CryptoKit
import Darwin
import Foundation

/// Opaque capability-owned checkpoint bytes bound to their owner and monotonic revision.
/// Shared custody reads only the binding fields; capability code validates selection semantics.
public struct CaptureCheckpointRecord: Equatable, Sendable {
  public let workflowID: UUID
  public let revision: UInt64
  public let payload: Data

  private struct Binding: Decodable {
    let workflowID: UUID
    let revision: UInt64
  }

  public init(workflowID: UUID, revision: UInt64, payload: Data) throws {
    guard revision > 0 else { throw CaptureCheckpointError.invalidCheckpoint }
    let binding: Binding
    do { binding = try JSONDecoder().decode(Binding.self, from: payload) }
    catch { throw CaptureCheckpointError.invalidCheckpoint }
    guard binding.workflowID == workflowID, binding.revision == revision else {
      throw CaptureCheckpointError.invalidCheckpoint
    }
    self.workflowID = workflowID
    self.revision = revision
    self.payload = payload
  }

  static func decode(_ data: Data) throws -> Self {
    let binding: Binding
    do { binding = try JSONDecoder().decode(Binding.self, from: data) }
    catch { throw CaptureCheckpointError.invalidCheckpoint }
    return try Self(workflowID: binding.workflowID, revision: binding.revision, payload: data)
  }
}

public enum CaptureCheckpointError: Error, Equatable {
  case staleRevision, invalidCheckpoint
}

enum CaptureCheckpointCodec {
  static func withLock<T>(directory: URL, operation: () throws -> T) throws -> T {
    let descriptor = open(
      directory.appendingPathComponent("journey.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
    defer { flock(descriptor, LOCK_UN) }
    return try operation()
  }

  static func load(
    workflowID: UUID, directory: URL, cipher: CaptureEvidenceCipher
  ) throws -> CaptureCheckpointRecord? {
    let path = location(workflowID, directory: directory)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let data = try cipher.open(Data(contentsOf: path), binding(workflowID))
    let value = try CaptureCheckpointRecord.decode(data)
    guard value.workflowID == workflowID else {
      throw CaptureCheckpointError.invalidCheckpoint
    }
    return value
  }

  static func save(_ value: CaptureCheckpointRecord, directory: URL, cipher: CaptureEvidenceCipher) throws {
    let data = value.payload
    let bytes = try cipher.seal(data, binding(value.workflowID))
    #if os(iOS)
      try bytes.write(
        to: location(value.workflowID, directory: directory),
        options: [.atomic, .completeFileProtection])
    #else
      try bytes.write(to: location(value.workflowID, directory: directory), options: [.atomic])
    #endif
  }

  private static func location(_ id: UUID, directory: URL) -> URL {
    directory.appendingPathComponent(id.uuidString + ".journey")
  }

  private static func binding(_ id: UUID) -> Data {
    Data(("IdentityEvidenceStorage/journey-checkpoint/v1/" + id.uuidString).utf8)
  }
}
