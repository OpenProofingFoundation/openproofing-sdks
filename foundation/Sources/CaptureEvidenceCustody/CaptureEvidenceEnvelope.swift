import CryptoKit
import Foundation
import KenshikiEvidenceManifest

/// V2 separates independently authenticated routing metadata from encrypted native payload bytes.
/// Header: 8-byte magic, UInt32 big-endian metadata length, sealed metadata, sealed payload.
enum CaptureEvidenceEnvelope {
  static let magic = Data([0x49, 0x45, 0x43, 0x41, 0x50, 0x32, 0x0D, 0x0A])
  static let maximumMetadataBytes = 16 * 1024 * 1024

  struct Metadata: Codable {
    let version: Int
    let id: UUID
    let manifest: Data
    let byteCount: Int
    let digest: String
    let signedManifest: SignedCaptureEvidenceManifest?
  }

  struct Header {
    let metadata: Metadata
    let sealedMetadata: Data
    let payloadOffset: UInt64
  }

  /// A non-nil `expectedSHA256` is the caller's digest of these exact in-memory bytes, and is
  /// sealed as the envelope digest without re-hashing them: recomputing it here would compare the
  /// buffer with itself. It is refused only if malformed. A well-formed but false declaration is
  /// refused by the read-back the caller must perform — `CaptureEvidenceStore.store` reads every
  /// publication back, and `payload(_:key:handle:)` requires SHA-256 of the decrypted bytes to
  /// equal this digest. Nil computes the digest.
  static func write(
    record: CaptureEvidenceRecord, cipher: CaptureEvidenceCipher, to url: URL, expectedSHA256: String?,
    signedManifest: SignedCaptureEvidenceManifest? = nil
  ) throws {
    let id = record.id
    let original = record.original
    let manifest = record.manifest
    let digest: String
    if let expectedSHA256 {
      guard isDigest(expectedSHA256) else { throw failure }
      digest = expectedSHA256
    } else {
      digest = hash(original)
    }
    let metadata = Metadata(
      version: 2, id: id, manifest: manifest,
      byteCount: original.count, digest: digest, signedManifest: signedManifest)
    let metadataData = try JSONEncoder().encode(metadata)
    guard metadataData.count <= maximumMetadataBytes - 28 else { throw failure }
    let sealedMetadata = try cipher.seal(metadataData, metadataBinding(id))
    let payload = try cipher.seal(original, payloadBinding(id, sealedMetadata: sealedMetadata))
    var prefix = magic
    let count = UInt32(sealedMetadata.count)
    prefix.append(contentsOf: [
      UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
      UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count),
    ])
    #if os(iOS)
      try prefix.write(to: url, options: [.withoutOverwriting, .completeFileProtection])
    #else
      try prefix.write(to: url, options: .withoutOverwriting)
    #endif
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: sealedMetadata)
    try handle.write(contentsOf: payload)
    try handle.synchronize()
  }

  static func header(id: UUID, cipher: CaptureEvidenceCipher, handle: FileHandle) throws -> Header? {
    try handle.seek(toOffset: 0)
    guard try exact(8, handle: handle) == magic else { return nil }
    let bytes = try exact(4, handle: handle)
    let length = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length >= 28, Int(length) <= maximumMetadataBytes else { throw failure }
    let sealed = try exact(Int(length), handle: handle)
    let decoded = try cipher.open(sealed, metadataBinding(id))
    let metadata = try JSONDecoder().decode(Metadata.self, from: decoded)
    guard metadata.version == 2, metadata.id == id, metadata.byteCount > 0,
      !metadata.manifest.isEmpty, metadata.digest.count == 64,
      metadata.digest.allSatisfy(\.isHexDigit)
    else { throw failure }
    let offset = UInt64(12) + UInt64(length)
    let count = UInt64(metadata.byteCount)
    guard count <= UInt64.max - offset - 28,
      try handle.seekToEnd() == offset + count + 28
    else { throw failure }
    return Header(metadata: metadata, sealedMetadata: sealed, payloadOffset: offset)
  }

  static func payload(_ header: Header, cipher: CaptureEvidenceCipher, handle: FileHandle) throws -> Data {
    try handle.seek(toOffset: header.payloadOffset)
    let combined = try exact(header.metadata.byteCount + 28, handle: handle)
    let data = try cipher.open(combined,
      payloadBinding(header.metadata.id, sealedMetadata: header.sealedMetadata))
    guard hash(data) == header.metadata.digest else { throw failure }
    return data
  }

  static func write(record: CaptureEvidenceRecord, key: SymmetricKey, to url: URL,
    expectedSHA256: String?) throws
  {
    try write(record: record, cipher: CaptureEvidenceCipher(key: key), to: url,
      expectedSHA256: expectedSHA256)
  }

  static func header(id: UUID, key: SymmetricKey, handle: FileHandle) throws -> Header? {
    try header(id: id, cipher: CaptureEvidenceCipher(key: key), handle: handle)
  }

  static func payload(_ header: Header, key: SymmetricKey, handle: FileHandle) throws -> Data {
    try payload(header, cipher: CaptureEvidenceCipher(key: key), handle: handle)
  }

  private static func exact(_ count: Int, handle: FileHandle) throws -> Data {
    guard let data = try handle.read(upToCount: count), data.count == count else { throw failure }
    return data
  }

  private static func metadataBinding(_ id: UUID) -> Data {
    Data(("IdentityEvidenceStorage/v2/metadata/" + id.uuidString).utf8)
  }

  private static func payloadBinding(_ id: UUID, sealedMetadata: Data) -> Data {
    Data(("IdentityEvidenceStorage/v2/payload/" + id.uuidString + "/" + hash(sealedMetadata)).utf8)
  }

  /// Test-only observation of SHA-256 work, reported as the digested byte count. Task-local, so
  /// concurrent tests cannot see each other's work; nil (a no-op) everywhere else.
  @TaskLocal static var digestObserver: (@Sendable (Int) -> Void)?

  static func hash(_ data: Data) -> String {
    digestObserver?(data.count)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// The exact spelling `hash(_:)` produces: 64 lowercase hex digits.
  private static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  private static var failure: CaptureEvidenceStoreError { .integrityFailure }
}
