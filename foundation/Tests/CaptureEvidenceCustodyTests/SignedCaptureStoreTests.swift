import CryptoKit
import Foundation
import KenshikiEvidenceManifest
import XCTest
@testable import CaptureEvidenceCustody

final class SignedCaptureStoreTests: XCTestCase {
  let key = SymmetricKey(data: Data(repeating: 0x3e, count: 32))
  let payload = Data("synthetic original pixels".utf8)
  let metadata = Data("synthetic capability manifest".utf8)
  let workflow = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  let attempt = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

  func directory() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: value) }
    return value
  }

  private func signing(_ signer: FixtureManifestSigner) throws -> CaptureSigningConfiguration {
    try .init(applicationID: "fixture.capture", installationID: "fixture-installation", workflowEpoch: 0, signer: signer)
  }

  func publication(_ config: CaptureSigningConfiguration, id: UUID) async throws -> CaptureEvidenceManifest {
    try await .init(context: config.context(workflowID: workflow, attemptID: attempt,
      observedAt: Date(timeIntervalSince1970: 1_800_000_000)), recordID: id, recordKind: "original",
      payloadSHA256: CaptureEvidenceManifest.sha256(payload),
      capabilityManifestSHA256: CaptureEvidenceManifest.sha256(metadata),
      sources: [.init(recordID: id, role: "original", sha256: CaptureEvidenceManifest.sha256(payload))],
      policyIDs: ["capture-retention-v1"])
  }

  func testProofPayloadAndOriginalManifestPublishInOneEnvelopeAndSurviveReopening() async throws {
    let root = try directory(), id = UUID(), signer = FixtureManifestSigner()
    let config = try signing(signer)
    let store = try CaptureEvidenceStore(directory: root, key: key)
    try await store.storeSigned(id: id, original: payload, manifest: metadata,
      publication: try await publication(config, id: id), signing: config)
    let reopened = try CaptureEvidenceStore(directory: root, key: key)
    let saved = try await reopened.readSigned(id: id, workflowID: workflow, attemptID: attempt, signing: config)
    XCTAssertEqual(saved.record.original, payload)
    XCTAssertEqual(saved.record.manifest, metadata)
    let ordinaryMetadata = try await reopened.metadata(id: id)
    XCTAssertEqual(ordinaryMetadata, metadata, "Signing must not replace a capability's manifest schema")
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    XCTAssertEqual(files.filter { $0.pathExtension == "evidence" }.count, 1)
    XCTAssertFalse(files.contains { $0.pathExtension == "staging" })
  }

  func testUnsignedHistoryCannotEnterTheSignedReadPathOrMintASigningKey() async throws {
    let root = try directory(), id = UUID(), signer = FixtureManifestSigner()
    let config = try signing(signer)
    let store = try CaptureEvidenceStore(directory: root, key: key)
    try await store.store(id: id, original: payload, manifest: metadata)
    do {
      _ = try await store.readSigned(id: id, workflowID: workflow, attemptID: attempt, signing: config)
      XCTFail("Unsigned history is not a signed capture")
    } catch CaptureEvidenceStoreError.unsignedHistoricalRecord {}
    XCTAssertEqual(signer.prepareCalls, 0)
  }

  func testChangedWorkflowAttemptAndInstallationCannotReuseAnOtherwiseValidProof() async throws {
    let root = try directory(), id = UUID(), signer = FixtureManifestSigner()
    let config = try signing(signer)
    let store = try CaptureEvidenceStore(directory: root, key: key)
    try await store.storeSigned(id: id, original: payload, manifest: metadata,
      publication: try await publication(config, id: id), signing: config)
    for (expectedWorkflow, expectedAttempt) in [(UUID(), attempt), (workflow, UUID())] {
      do {
        _ = try await store.readSigned(id: id, workflowID: expectedWorkflow, attemptID: expectedAttempt, signing: config)
        XCTFail("Superseded acquisition ownership must not be accepted")
      } catch EvidenceManifestError.bindingMismatch {}
    }
    let other = try CaptureSigningConfiguration(applicationID: config.applicationID, installationID: "other-installation",
      workflowEpoch: 0, signer: signer)
    do {
      _ = try await store.readSigned(id: id, workflowID: workflow, attemptID: attempt, signing: other)
      XCTFail("Another installation cannot reuse this proof")
    } catch EvidenceManifestError.bindingMismatch {}
  }

  func testMissingSigningKeyRefusesReadWithoutProvisioningAReplacement() async throws {
    let root = try directory(), id = UUID(), signer = FixtureManifestSigner()
    let config = try signing(signer)
    let store = try CaptureEvidenceStore(directory: root, key: key)
    try await store.storeSigned(id: id, original: payload, manifest: metadata,
      publication: try await publication(config, id: id), signing: config)
    let before = signer.prepareCalls
    signer.hideExistingKey()
    do {
      _ = try await store.readSigned(id: id, workflowID: workflow, attemptID: attempt, signing: config)
      XCTFail("A read cannot silently replace missing signing custody")
    } catch EvidenceManifestError.untrustedSigningKey {}
    XCTAssertEqual(signer.prepareCalls, before)
  }

  func testAValidEncryptedEnvelopeWithAForgedSignatureIsRefused() async throws {
    let root = try directory(), id = UUID(), signer = FixtureManifestSigner()
    let config = try signing(signer), manifest = try await publication(config, id: id)
    let proof = try await signer.sign(manifest)
    var bytes = proof.proofBytes; bytes[bytes.count - 1] ^= 1
    let forged = SignedCaptureEvidenceManifest(manifest: manifest, proof: .init(schemaVersion: proof.schemaVersion,
      signingPublicKeyHash: proof.signingPublicKeyHash, proofBytes: bytes))
    let store = try CaptureEvidenceStore(directory: root, key: key)
    try CaptureEvidenceEnvelope.write(record: .init(id: id, original: payload, manifest: metadata),
      cipher: CaptureEvidenceCipher(key: key), to: root.appendingPathComponent(id.uuidString + ".evidence"),
      expectedSHA256: nil, signedManifest: forged)
    do {
      _ = try await store.readSigned(id: id, workflowID: workflow, attemptID: attempt, signing: config)
      XCTFail("Authenticated encryption cannot replace signature verification")
    } catch EvidenceManifestError.invalidProof {}
  }

  func testErasureDuringSigningFencesTheSuspendedPublication() async throws {
    let root = try directory(), id = UUID(), gate = SigningGate()
    let signer = FixtureManifestSigner(beforeSign: { await gate.enter() })
    let config = try signing(signer), manifest = try await publication(config, id: id)
    let store = try CaptureEvidenceStore(directory: root, key: key)
    let task = Task { [payload = payload, metadata = metadata] in try await store.storeSigned(id: id, original: payload, manifest: metadata,
      publication: manifest, signing: config) }
    await gate.waitForEntry()
    try await store.revokeAndRemoveAll()
    await gate.release()
    do { try await task.value; XCTFail("A stale signer callback must not republish erased evidence") }
    catch CaptureEvidenceStoreError.custodyRevoked {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString + ".evidence").path))
  }

  func testMaintenanceEraseAlsoRejectsAStaleSigningCallbackAfterReopeningAdmission() async throws {
    let root = try directory(), id = UUID(), gate = SigningGate()
    let signer = FixtureManifestSigner(beforeSign: { await gate.enter() })
    let config = try signing(signer), manifest = try await publication(config, id: id)
    let store = try CaptureEvidenceStore(directory: root, key: key)
    let task = Task { [payload = payload, metadata = metadata] in try await store.storeSigned(id: id, original: payload, manifest: metadata,
      publication: manifest, signing: config) }
    await gate.waitForEntry()
    try await store.removeAll()
    await gate.release()
    do { try await task.value; XCTFail("A stale signer callback must not republish erased evidence") }
    catch CaptureEvidenceStoreError.custodyRevoked {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString + ".evidence").path))
  }
}

private final class FixtureManifestSigner: EvidenceManifestSigning, @unchecked Sendable {
  private let key = P256.Signing.PrivateKey()
  private let lock = NSLock()
  private var preparations = 0
  private var hidden = false
  private let beforeSign: @Sendable () async -> Void
  var prepareCalls: Int { lock.withLock { preparations } }
  init(beforeSign: @escaping @Sendable () async -> Void = {}) { self.beforeSign = beforeSign }
  func hideExistingKey() { lock.withLock { hidden = true } }
  private var keyHash: String {
    Data(SHA256.hash(data: key.publicKey.x963Representation)).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  func prepareSigningPublicKeyHash() async throws -> String {
    lock.withLock { preparations += 1 }; return keyHash
  }
  func existingSigningPublicKeyHash() async throws -> String? { lock.withLock { hidden ? nil : keyHash } }
  func sign(_ manifest: CaptureEvidenceManifest) async throws -> EvidenceManifestProof {
    await beforeSign()
    return .init(schemaVersion: "fixture.p256.v1", signingPublicKeyHash: keyHash,
      proofBytes: try key.signature(for: manifest.signingBytes()).derRepresentation)
  }
  func verify(_ manifest: CaptureEvidenceManifest, proof: EvidenceManifestProof,
    trustedSigningPublicKeyHash: String) async throws -> Bool {
    guard proof.schemaVersion == "fixture.p256.v1", proof.signingPublicKeyHash == keyHash,
      trustedSigningPublicKeyHash == keyHash,
      let signature = try? P256.Signing.ECDSASignature(derRepresentation: proof.proofBytes) else { return false }
    return key.publicKey.isValidSignature(signature, for: try manifest.signingBytes())
  }
}

private actor SigningGate {
  private var entered = false
  private var entryWaiter: CheckedContinuation<Void, Never>?
  private var resumeSigner: CheckedContinuation<Void, Never>?
  func enter() async {
    entered = true; entryWaiter?.resume(); entryWaiter = nil
    await withCheckedContinuation { resumeSigner = $0 }
  }
  func waitForEntry() async { if !entered { await withCheckedContinuation { entryWaiter = $0 } } }
  func release() { resumeSigner?.resume(); resumeSigner = nil }
}
