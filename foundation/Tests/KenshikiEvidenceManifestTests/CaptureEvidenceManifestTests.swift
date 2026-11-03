import Foundation
import XCTest
@testable import KenshikiEvidenceManifest

final class CaptureEvidenceManifestTests: XCTestCase {
  func testCaptureProofSchemaPreservesThePublishedWireContract() throws {
    let proof = EvidenceManifestProof(schemaVersion: EvidenceManifestProof.captureEvidenceSchemaVersion,
      signingPublicKeyHash: "externally-pinned-key", proofBytes: Data([1, 2, 3]))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    XCTAssertEqual(String(decoding: try encoder.encode(proof), as: UTF8.self),
      "{\"proofBytes\":\"AQID\",\"schemaVersion\":\"kenshiki.capture-evidence-proof.v1\",\"signingPublicKeyHash\":\"externally-pinned-key\"}")
    XCTAssertEqual(try JSONDecoder().decode(EvidenceManifestProof.self,
      from: encoder.encode(proof)), proof)
  }

  let record = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
  let payload = Data("synthetic-pixels".utf8)
  let metadata = Data("synthetic-capability-manifest".utf8)

  func context(application: String = "com.example.capture", installation: String = "installation-one",
    generation: UInt64 = 7) throws -> CapturePublicationContext {
    try .init(applicationID: application, installationID: installation,
      workflowID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!, generation: generation,
      attemptID: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!, observedAtMilliseconds: 1_800_000_000_000)
  }

  func manifest() throws -> CaptureEvidenceManifest {
    try .init(context: context(), recordID: record, recordKind: "document-original",
      payloadSHA256: CaptureEvidenceManifest.sha256(payload),
      capabilityManifestSHA256: CaptureEvidenceManifest.sha256(metadata),
      sources: [.init(recordID: record, role: "original", sha256: CaptureEvidenceManifest.sha256(payload))],
      policyIDs: ["capture-policy-v1"])
  }

  func testCanonicalBytesAreStableDomainSeparatedAndBindOpaqueManifest() throws {
    let value = try manifest()
    let bytes = try value.signingBytes()
    XCTAssertTrue(bytes.starts(with: Data("kenshiki:capture-evidence-manifest:v1\0{".utf8)))
    XCTAssertEqual(bytes, try JSONDecoder().decode(CaptureEvidenceManifest.self,
      from: JSONEncoder().encode(value)).signingBytes())
    try value.requireBinding(context: context(), recordID: record, payload: payload, capabilityManifest: metadata)
    XCTAssertThrowsError(try value.requireBinding(context: context(), recordID: record,
      payload: payload, capabilityManifest: Data("substituted".utf8)))
    XCTAssertThrowsError(try value.requireBinding(context: context(), recordID: record,
      payload: Data("substituted".utf8), capabilityManifest: metadata))
  }

  func testCanonicalBytesMatchTheIndependentlyGeneratedPortableFixture() throws {
    struct Fixture: Decodable {
      let manifest: CaptureEvidenceManifest
      let payloadUTF8: String
      let capabilityManifestUTF8: String
      let signingUTF8: String
      let sha256: String
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
      root.appendingPathComponent("contracts/evidence-manifest-v1/canonical.json")))
    let bytes = try fixture.manifest.signingBytes()
    XCTAssertEqual(bytes, Data(fixture.signingUTF8.utf8))
    XCTAssertEqual(CaptureEvidenceManifest.sha256(bytes), fixture.sha256)
    try fixture.manifest.requireBinding(context: fixture.manifest.context, recordID: record,
      payload: Data(fixture.payloadUTF8.utf8), capabilityManifest: Data(fixture.capabilityManifestUTF8.utf8))
  }

  func testContextAndRecordSubstitutionsCannotReuseAnUnchangedManifest() throws {
    let value = try manifest()
    for altered in [try context(application: "com.other.app"), try context(installation: "other-installation"), try context(generation: 8)] {
      XCTAssertThrowsError(try value.requireBinding(context: altered, recordID: record,
        payload: payload, capabilityManifest: metadata))
    }
    XCTAssertThrowsError(try value.requireBinding(context: context(), recordID: UUID(), payload: payload,
      capabilityManifest: metadata))
  }

  func testDecodedUnsupportedSchemaAndInvalidFieldsAreRefusedBeforeSigning() throws {
    let bytes = try JSONEncoder().encode(manifest())
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    for (key, replacement) in [("schemaVersion", "future"), ("payloadSHA256", "ABC"), ("recordKind", " ")] {
      var changed = object; changed[key] = replacement
      let changedBytes = try JSONSerialization.data(withJSONObject: changed)
      XCTAssertThrowsError(try JSONDecoder().decode(CaptureEvidenceManifest.self, from: changedBytes))
    }
  }

  func testUnknownFieldsAreRefusedAtTheManifestAndNestedBoundaries() throws {
    let data = try JSONEncoder().encode(manifest())
    let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for location in ["manifest", "context", "source"] {
      var object = raw
      if location == "manifest" { object["unbound"] = true }
      else if location == "context" {
        var context = try XCTUnwrap(object["context"] as? [String: Any]); context["unbound"] = true
        object["context"] = context
      } else {
        var sources = try XCTUnwrap(object["sources"] as? [[String: Any]]); sources[0]["unbound"] = true
        object["sources"] = sources
      }
      let encoded = try JSONSerialization.data(withJSONObject: object)
      XCTAssertThrowsError(try JSONDecoder().decode(CaptureEvidenceManifest.self, from: encoded))
    }
  }

  func testDerivativesRequireACompleteOrderedAcyclicLineage() throws {
    let derivative = UUID()
    func build(_ steps: [EvidenceLineageStep]) throws -> CaptureEvidenceManifest {
      try .init(context: context(), recordID: derivative, recordKind: "portrait",
        payloadSHA256: "b".repeat64, capabilityManifestSHA256: "c".repeat64,
        sources: [.init(recordID: record, role: "original", sha256: "a".repeat64)],
        derivatives: [.init(recordID: derivative, role: "portrait", sha256: "b".repeat64)],
        lineage: steps, modelIDs: ["crop-model-v1"], policyIDs: ["crop-policy-v1"])
    }
    XCTAssertThrowsError(try build([]))
    XCTAssertThrowsError(try build([.init(inputRecordID: derivative, outputRecordID: derivative, transformationSHA256: "d".repeat64)]))
    XCTAssertNoThrow(try build([.init(inputRecordID: record, outputRecordID: derivative, transformationSHA256: "d".repeat64)]))
  }

  func testPublicationMustActuallyVerifyTheProofEvenWhenEveryBindingMatches() async throws {
    let value = try manifest()
    let proof = EvidenceManifestProof(schemaVersion: "test-proof", signingPublicKeyHash: "external-pinned-key",
      proofBytes: Data("forged-signature".utf8))
    let signed = SignedCaptureEvidenceManifest(manifest: value, proof: proof)
    do {
      try await signed.verify(using: RejectingSigner(), trustedSigningPublicKeyHash: "external-pinned-key",
        expectedContext: value.context, expectedRecordID: record, payload: payload, capabilityManifest: metadata)
      XCTFail("Matching hashes and a matching claimed key do not replace signature verification")
    } catch EvidenceManifestError.invalidProof {}
  }
}

private extension String { var repeat64: String { String(repeating: self, count: 64) } }

private struct RejectingSigner: EvidenceManifestSigning {
  func prepareSigningPublicKeyHash() async throws -> String { "external-pinned-key" }
  func existingSigningPublicKeyHash() async throws -> String? { "external-pinned-key" }
  func sign(_ manifest: CaptureEvidenceManifest) async throws -> EvidenceManifestProof {
    throw EvidenceManifestError.invalidProof
  }
  func verify(_ manifest: CaptureEvidenceManifest, proof: EvidenceManifestProof,
    trustedSigningPublicKeyHash: String) async throws -> Bool { false }
}
