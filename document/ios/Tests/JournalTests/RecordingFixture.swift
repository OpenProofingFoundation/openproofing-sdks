import CryptoKit
import Foundation
import DocumentCaptureApple
@testable import CaptureEvidenceCustody

@testable import DocumentCaptureJournal

extension CaptureRecordingClock {
  static var fixture: Self {
    .init(
      now: { Date(timeIntervalSince1970: 1_700_000_000) },
      uptime: { ProcessInfo.processInfo.systemUptime })
  }
}

struct RecordingFixture {
  enum Profile: String, Codable {
    case licenseFront = "fixture-front"
    case licenseBack = "fixture-back"
    var side: Side { self == .licenseFront ? .front : .back }
  }
  enum Side: String { case front, back }
  struct Manifest: Codable {
    struct Session: Codable { let rawValue: UUID }
    struct Fidelity: Codable { let sha256: String }
    let schemaVersion = 1
    let captureID: UUID
    let profile: Profile
    let side: String
    let sessionID: Session
    let captureTimestamp: DocumentCaptureClockTimestamp
    let fidelity: Fidelity
    let workflowID: UUID
    var journeyRecording: CaptureRecordingReference?
  }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let key = SymmetricKey(size: .bits256)
  let store: CaptureEvidenceStore
  static let payload = Data([19, 20, 21])
  init() throws { store = try CaptureEvidenceStore(directory: directory, key: key) }
  func reopen() throws -> CaptureEvidenceStore { try .init(directory: directory, key: key) }
  func cleanup() { try? FileManager.default.removeItem(at: directory) }
  func manifest(profile: Profile, workflowID: UUID) throws -> Manifest {
    .init(
      captureID: UUID(), profile: profile, side: profile.side.rawValue,
      sessionID: .init(rawValue: UUID()),
      captureTimestamp: .init(
        value: 1, timescale: 1, flags: 1, epoch: 0,
        clock: .captureSessionSynchronizationClock),
      fidelity: .init(sha256: CapturePayloadIntegrity.sha256(Self.payload)), workflowID: workflowID)
  }
  func retain(_ manifest: Manifest) async throws {
    try await store.store(
      id: manifest.captureID, original: Self.payload,
      manifest: JSONEncoder().encode(manifest))
  }
}
