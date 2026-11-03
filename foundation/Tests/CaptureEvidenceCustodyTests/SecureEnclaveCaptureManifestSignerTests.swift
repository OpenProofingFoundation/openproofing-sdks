import CryptoKit
import Foundation
import XCTest
@testable import CaptureEvidenceCustody
import KenshikiEvidenceManifest
@_spi(CustodyAdapter) @testable import KenshikiProtectedStorage

final class SecureEnclaveCaptureManifestSignerTests: XCTestCase {
  private func fixture() throws -> (SecureEnclaveCaptureManifestSigner, ManifestKeyMemory, ManifestSigningHardware) {
    let memory = ManifestKeyMemory(); let hardware = ManifestSigningHardware()
    let identity = try StoreKeyIdentity(applicationID: "test.app", storeID: "front", purpose: "capture-signing",
      keychainAccessGroup: "TEAM.test.app", accessPolicy: .identityWhenUnlocked)
    let key = try HardwareBoundSigningKeyCustody(identity: identity, storage: memory, hardware: hardware)
    return (.init(applicationID: identity.applicationID, custody: key), memory, hardware)
  }

  private func manifest(applicationID: String = "test.app", payload: Data = Data([1, 2, 3])) throws -> CaptureEvidenceManifest {
    let id = UUID()
    let context = try CapturePublicationContext(applicationID: applicationID, installationID: "local.installation",
      workflowID: UUID(), generation: 1, attemptID: UUID(), observedAtMilliseconds: 1)
    let hash = CaptureEvidenceManifest.sha256(payload)
    return try CaptureEvidenceManifest(context: context, recordID: id, recordKind: "captureOriginal",
      payloadSHA256: hash, capabilityManifestSHA256: CaptureEvidenceManifest.sha256(Data([4])),
      sources: [.init(recordID: id, role: "captureOriginal", sha256: hash)], policyIDs: ["synthetic.front.v1"])
  }

  func testExactManifestSignsAndVerifiesUsingIndependentlyRetainedKey() async throws {
    let (signer, _, hardware) = try fixture()
    let manifest = try manifest()
    let hash = try await signer.prepareSigningPublicKeyHash()
    let proof = try await signer.sign(manifest)
    XCTAssertEqual(proof.schemaVersion, "kenshiki.capture-evidence-p256-sha256.v1")
    XCTAssertEqual(proof.signingPublicKeyHash, hash)
    let verified = try await signer.verify(manifest, proof: proof, trustedSigningPublicKeyHash: hash)
    XCTAssertTrue(verified)
    XCTAssertEqual(hardware.creates, 1)
  }

  func testHistoricalReadAndUnpreparedSigningNeverCreateKey() async throws {
    let (signer, memory, hardware) = try fixture()
    let hash = try await signer.existingSigningPublicKeyHash()
    XCTAssertNil(hash)
    let proof = EvidenceManifestProof(schemaVersion: SecureEnclaveCaptureManifestSigner.proofSchemaVersion,
      signingPublicKeyHash: "untrusted", proofBytes: Data([1]))
    let verified = try await signer.verify(manifest(), proof: proof, trustedSigningPublicKeyHash: "untrusted")
    XCTAssertFalse(verified)
    do { _ = try await signer.sign(manifest()); XCTFail("unprepared signing must refuse") }
    catch { XCTAssertEqual(error as? ProtectedStoreKeyError, .missingKey) }
    XCTAssertNil(memory.bytes); XCTAssertEqual(hardware.creates, 0)
  }

  func testForeignApplicationWrongTrustSchemaAndChangedManifestAreRejected() async throws {
    let (signer, _, _) = try fixture()
    let original = try manifest()
    let hash = try await signer.prepareSigningPublicKeyHash()
    let proof = try await signer.sign(original)
    let changed = try manifest(payload: Data([8]))
    let changedVerified = try await signer.verify(changed, proof: proof, trustedSigningPublicKeyHash: hash)
    XCTAssertFalse(changedVerified)
    let wrongTrust = try await signer.verify(original, proof: proof, trustedSigningPublicKeyHash: "foreign")
    XCTAssertFalse(wrongTrust)
    let wrongSchema = EvidenceManifestProof(schemaVersion: EvidenceManifestProof.captureEvidenceSchemaVersion,
      signingPublicKeyHash: hash, proofBytes: proof.proofBytes)
    let schemaVerified = try await signer.verify(original, proof: wrongSchema, trustedSigningPublicKeyHash: hash)
    XCTAssertFalse(schemaVerified)
    do { _ = try await signer.sign(manifest(applicationID: "other.app")); XCTFail("foreign application must refuse") }
    catch { XCTAssertEqual(error as? EvidenceManifestError, .bindingMismatch) }
  }

  func testKeyLossAfterPublicationCannotVerifyOrProvisionReplacementInSameOwner() async throws {
    let (signer, memory, hardware) = try fixture()
    let manifest = try manifest()
    let hash = try await signer.prepareSigningPublicKeyHash()
    let proof = try await signer.sign(manifest)
    memory.bytes = nil
    let verified = try await signer.verify(manifest, proof: proof, trustedSigningPublicKeyHash: hash)
    XCTAssertFalse(verified)
    do { _ = try await signer.prepareSigningPublicKeyHash(); XCTFail("observed missing key must not rotate") }
    catch { XCTAssertEqual(error as? ProtectedStoreKeyError, .missingKey) }
    XCTAssertEqual(hardware.creates, 1)
  }

  func testExplicitEraseRetiresAllPublicationMethods() async throws {
    let (signer, memory, hardware) = try fixture()
    _ = try await signer.prepareSigningPublicKeyHash()
    try await signer.eraseKeyAfterCiphertextErasure()
    try await signer.eraseKeyAfterCiphertextErasure()
    XCTAssertNil(memory.bytes)
    do { _ = try await signer.prepareSigningPublicKeyHash(); XCTFail("retired signer must not restart") }
    catch { XCTAssertEqual(error as? ProtectedStoreKeyError, .missingKey) }
    XCTAssertEqual(hardware.creates, 1)
  }
}

private final class ManifestKeyMemory: StoreKeyRecordStorage, @unchecked Sendable {
  var bytes: Data?
  func load() throws -> Data? { bytes }
  func add(_ record: Data) throws -> Bool {
    guard bytes == nil else { return false }
    bytes = record; return true
  }
  func remove() throws { bytes = nil }
}

// Software test key handles are confined to this fixture; the production initializer cannot select it.
private final class ManifestSigningHardware: StoreHardwareSigning, @unchecked Sendable {
  var creates = 0
  func create() throws -> Data { creates += 1; return P256.Signing.PrivateKey().rawRepresentation }
  func publicKey(_ opaqueRepresentation: Data) throws -> Data {
    try P256.Signing.PrivateKey(rawRepresentation: opaqueRepresentation).publicKey.x963Representation
  }
  func sign(_ data: Data, opaqueRepresentation: Data) throws -> Data {
    try P256.Signing.PrivateKey(rawRepresentation: opaqueRepresentation).signature(for: data).derRepresentation
  }
}
