#if os(iOS)
  import CryptoKit
  import Foundation
  import DocumentCaptureApple
  @_spi(CaptureTestFixture) @testable import CaptureEvidenceCustody
  @testable import DocumentCapture

  enum CaptureSignedFixture {
    static func store(directory: URL, key: SymmetricKey) throws -> CaptureEvidenceStore {
      try CaptureEvidenceStore(directory: directory, key: key, custodyLease: nil,
        signing: .testing(applicationID: "synthetic.capture-sdk.fixture", installationID: "synthetic-installation"))
    }

    @MainActor
    static func original(id: UUID, bytes: Data, manifest: Data, store: CaptureEvidenceStore) async throws {
      let value = try JSONDecoder().decode(CaptureRecords.Manifest.self, from: manifest)
      // Corruption/history fixtures deliberately remain unsigned to challenge strict readers.
      if value.workflowID != nil, value.fidelity.sha256 == CaptureArtifactIntegrity.sha256(bytes),
        value.fidelity.fileByteCount == bytes.count {
        try await CaptureSignedRecords.retainOriginal(id: id, original: bytes, manifest: manifest, store: store)
      } else {
        try await store.store(id: id, original: bytes, manifest: manifest)
      }
    }
  }
#endif
