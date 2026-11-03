import CryptoKit
import Foundation
import DocumentCaptureApple
import CaptureEvidenceCustody

public enum CapturePayloadIntegrity {
  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

enum CaptureTemporalPayload {
  static func sha256(_ data: Data) async -> String { CapturePayloadIntegrity.sha256(data) }

  static func validate(_ payload: Data, metadata: DocumentTemporalFrameMetadata) async throws {
    try Task.checkCancellation()
    guard metadata.width > 0, metadata.height > 0, !metadata.planes.isEmpty,
      metadata.timestamp.timescale > 0, metadata.timestamp.flags & 1 != 0,
      metadata.timestamp.flags & 28 == 0, metadata.hostTimeSeconds?.isFinite != false,
      CapturePayloadIntegrity.sha256(payload) == metadata.sha256
    else { throw CaptureEvidenceStoreError.integrityFailure }
    var end = 0
    for plane in metadata.planes {
      guard plane.offset == end, plane.width > 0, plane.height > 0,
        plane.packedBytesPerRow > 0, plane.sourceBytesPerRow >= plane.packedBytesPerRow,
        plane.byteCount > 0, plane.byteCount <= payload.count - end,
        plane.byteCount / plane.height == plane.packedBytesPerRow,
        plane.byteCount.isMultiple(of: plane.height)
      else { throw CaptureEvidenceStoreError.integrityFailure }
      end += plane.byteCount
    }
    guard end == payload.count else { throw CaptureEvidenceStoreError.integrityFailure }
  }
}

/// Only the fields required for authenticated original-to-journal linkage. Additional host
/// annotations remain opaque. Legacy profile names require the host's explicit side table.
struct CaptureRecordingStillManifest: Decodable {
  struct Session: Decodable { let rawValue: UUID }
  struct Fidelity: Decodable { let sha256: String }
  let captureID: UUID
  let workflowID: UUID?
  let profile: String
  let side: String?
  let sessionID: Session
  let fidelity: Fidelity
  let captureTimestamp: DocumentCaptureClockTimestamp
  let journeyRecording: CaptureRecordingReference?
}
