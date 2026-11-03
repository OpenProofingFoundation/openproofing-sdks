import CryptoKit
import Darwin
import Foundation

/// A disposable search cache, never the authority for retained bytes or source linkage.
/// File metadata detects ordinary mutation; authenticated record reads remain mandatory
/// before consuming a result. This cache is not a whole-lake tamper audit (`list` is).
struct CaptureEvidenceIndex: Codable {
  struct Fingerprint: Codable, Equatable {
    let size: UInt64
    let modified: Date
    let fileNumber: UInt64

    init(url: URL) throws {
      var value = stat()
      let result = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return lstat(path, &value)
      }
      guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      guard value.st_size >= 0 else { throw CaptureEvidenceStoreError.invalidRecord }
      size = UInt64(value.st_size)
      // Match Foundation's persisted Date rounding: subtract the reference epoch
      // BEFORE adding nanoseconds. Unix-epoch addition loses a bit of precision.
      modified = Date(
        timeIntervalSinceReferenceDate:
          Double(value.st_mtimespec.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate
          + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000)
      fileNumber = value.st_ino
    }
  }

  struct Entry: Codable {
    let fingerprint: Fingerprint
    let captureID: UUID?
    let sessionID: UUID?
    let recordKind: String?
    let recordingID: UUID?
    var recordingIDKnown: Bool?
    let isOriginal: Bool?

    init(manifest: Data, fingerprint: Fingerprint) {
      self.fingerprint = fingerprint
      recordingIDKnown = true
      let fields = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any]
      isOriginal =
        fields?["fidelity"] is [String: Any] && fields?["profile"] is String
        && fields?["captureID"] is String
      captureID = (fields?["captureID"] as? String).flatMap(UUID.init(uuidString:))
      let session = fields?["sessionID"]
      let sessionValue = session as? String ?? (session as? [String: String])?["rawValue"]
      sessionID = sessionValue.flatMap(UUID.init(uuidString:))
      recordKind = fields?["recordKind"] as? String
      recordingID = (fields?["recordingID"] as? String).flatMap(UUID.init(uuidString:))
    }
  }

  var version = 3
  var entries: [UUID: Entry] = [:]

  static func load(directory: URL, cipher: CaptureEvidenceCipher) -> Self? {
    guard let bytes = try? Data(contentsOf: location(directory)),
      let plaintext = try? cipher.open(bytes, binding),
      var index = try? JSONDecoder().decode(Self.self, from: plaintext),
      [1, 2, 3].contains(index.version)
    else { return nil }
    let hasRecordingSelector = index.version != 1
    for id in index.entries.keys where index.entries[id]?.recordingIDKnown == nil {
      index.entries[id]?.recordingIDKnown = hasRecordingSelector
    }
    index.version = 3
    return index
  }

  func persist(directory: URL, cipher: CaptureEvidenceCipher) throws {
    let plaintext = try JSONEncoder().encode(self)
    let bytes = try cipher.seal(plaintext, Self.binding)
    #if os(iOS)
      try bytes.write(to: Self.location(directory), options: [.atomic, .completeFileProtection])
    #else
      try bytes.write(to: Self.location(directory), options: [.atomic])
    #endif
  }

  static func load(directory: URL, key: SymmetricKey) -> Self? {
    load(directory: directory, cipher: CaptureEvidenceCipher(key: key))
  }
  func persist(directory: URL, key: SymmetricKey) throws {
    try persist(directory: directory, cipher: CaptureEvidenceCipher(key: key))
  }

  static func location(_ directory: URL) -> URL {
    directory.appendingPathComponent("metadata.index")
  }

  private static let binding = Data("IdentityEvidenceStorage/metadata-index/v1".utf8)
}
