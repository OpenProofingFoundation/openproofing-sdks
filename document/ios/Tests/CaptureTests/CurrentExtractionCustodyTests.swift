#if os(iOS)
import Foundation
import XCTest
import DocumentSDK
@testable import CaptureEvidenceCustody
@testable import DocumentCapture
@testable import DocumentCaptureApple

@MainActor
final class CurrentExtractionCustodyTests: XCTestCase {
  private typealias Fixture = JourneyRecoveryIntegrationTests.RecoveryFixture

  func testRetainedLegacySchemasStayUnavailableAndInvalidRecordsFail() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    for schema in 1...3 {
      let bytes = try encodedExtraction(fixture.pixels, schema: schema)
      let record = CaptureEvidenceRecord(id: UUID(), original: bytes, manifest: Data())
      XCTAssertNil(try CaptureDocumentStages.extraction(record, source: fixture.pixels))
    }
    let current = CaptureEvidenceRecord(id: UUID(), original: try encodedExtraction(fixture.pixels), manifest: Data())
    XCTAssertEqual(try CaptureDocumentStages.extraction(current, source: fixture.pixels)?.schemaVersion, 4)
    for failure in Failure.allCases {
      let value = try extraction(fixture.pixels, failure: failure)
      XCTAssertThrowsError(try CaptureDocumentStages.validateCurrentExtraction(value, source: fixture.pixels)) { error in
        guard case .integrityVerificationFailed? = error as? CaptureIntegrityError else {
          return XCTFail("Unexpected refusal type: \(type(of: error))")
        }
      }
    }
    let malformed = CaptureEvidenceRecord(id: UUID(), original: Data([0xff]), manifest: Data())
    XCTAssertThrowsError(try CaptureDocumentStages.extraction(malformed, source: fixture.pixels))
  }

  func testOriginalExtractionReplacesLegacyOnceAndExactRetryPreservesCiphertext() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let manifest = try fixture.manifest(profile: .document, workflowID: UUID())
    try await fixture.retain(manifest)
    let legacyID = try await fixture.retainExtraction(manifest)
    let legacyBefore = try Data(contentsOf: fixture.directory.appendingPathComponent(legacyID.uuidString + ".evidence"))
    let counter = RecoveryExtractionCounter()
    let operations = JourneyRecoveryIntegrationTests.operations(calls: counter)
    try await CaptureDocumentInspection.retainExtraction(manifest.captureID, store: fixture.store, operations: operations)
    let beforeRetry = try ciphertext(fixture)
    try await CaptureDocumentInspection.retainExtraction(manifest.captureID, store: fixture.store, operations: operations)
    let extractionCount = await counter.count
    XCTAssertEqual(extractionCount, 1)
    XCTAssertEqual(try ciphertext(fixture), beforeRetry)
    XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent(legacyID.uuidString + ".evidence")), legacyBefore)
    let records = try await CaptureDocumentStages.records("extraction", captureID: manifest.captureID,
      sourceHash: manifest.fidelity.sha256, store: fixture.store)
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(try records.compactMap { try CaptureDocumentStages.extraction($0, source: fixture.pixels) }.count, 1)
  }

  func testDocumentExtractionReplacesLegacyOnceAndExactRetryPreservesCiphertext() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
    try await fixture.retain(manifest)
    let counter = RecoveryExtractionCounter()
    let operations = JourneyRecoveryIntegrationTests.operations(calls: counter)
    let usability = try await prepare(fixture, manifest: manifest, operations: operations)
    let derivativeID = try XCTUnwrap(usability.derivativeRecordID)
    let link = CaptureDocumentWorkflow.DocumentExtractionLink(recordKind: "documentExtraction",
      captureID: manifest.captureID, sourceSHA256: manifest.fidelity.sha256,
      derivativeRecordID: derivativeID, derivativeSHA256: manifest.fidelity.sha256)
    let legacyID = try await CaptureDocumentStages.retain(kind: "documentExtraction", captureID: manifest.captureID,
      original: encodedExtraction(fixture.pixels, schema: 3), manifest: JSONEncoder().encode(link), store: fixture.store)
    let legacyBefore = try Data(contentsOf: fixture.directory.appendingPathComponent(legacyID.uuidString + ".evidence"))
    _ = try await CaptureDocumentWorkflow.assess(sourceHash: manifest.fidelity.sha256, captureID: manifest.captureID,
      profile: .licenseFront, usability: usability, store: fixture.store, operations: operations)
    let beforeRetry = try ciphertext(fixture)
    _ = try await CaptureDocumentWorkflow.assess(sourceHash: manifest.fidelity.sha256, captureID: manifest.captureID,
      profile: .licenseFront, usability: usability, store: fixture.store, operations: operations)
    let extractionCount = await counter.count
    XCTAssertEqual(extractionCount, 1)
    XCTAssertEqual(try ciphertext(fixture), beforeRetry)
    XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent(legacyID.uuidString + ".evidence")), legacyBefore)
    let records = try await CaptureDocumentStages.records("documentExtraction", captureID: manifest.captureID,
      sourceHash: manifest.fidelity.sha256, store: fixture.store)
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(try records.compactMap { try CaptureDocumentStages.extraction($0, source: fixture.pixels) }.count, 1)
  }

  func testFreshOriginalOutputsRefuseObsoleteUnknownAndMismatchedResultsBeforePublication() async throws {
    for failure in Failure.allCases {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .document, workflowID: UUID())
      try await fixture.retain(manifest)
      let before = try ciphertext(fixture)
      let value = try extraction(fixture.pixels, failure: failure)
      var operations = JourneyRecoveryIntegrationTests.operations(calls: RecoveryExtractionCounter())
      operations.structured = nil
      operations.extract = { _ in value }
      do {
        try await CaptureDocumentInspection.retainExtraction(manifest.captureID, store: fixture.store, operations: operations)
        XCTFail("A stale or source-mismatched observation was published")
      } catch CaptureIntegrityError.integrityVerificationFailed {}
      XCTAssertEqual(try ciphertext(fixture), before)
      let records = try await CaptureDocumentStages.records("extraction", captureID: manifest.captureID,
        sourceHash: manifest.fidelity.sha256, store: fixture.store)
      XCTAssertTrue(records.isEmpty)
    }
  }

  func testFreshDocumentOutputsRefuseObsoleteUnknownAndMismatchedResultsBeforePublication() async throws {
    for failure in Failure.allCases {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      try await fixture.retain(manifest)
      let counter = RecoveryExtractionCounter()
      var operations = JourneyRecoveryIntegrationTests.operations(calls: counter)
      let usability = try await prepare(fixture, manifest: manifest, operations: operations)
      let derivativeID = try XCTUnwrap(usability.derivativeRecordID)
      let derivative = try await CaptureDocumentStages.derivative(derivativeID, captureID: manifest.captureID,
        sourceHash: manifest.fidelity.sha256, store: fixture.store)
      XCTAssertEqual(derivative.original, fixture.pixels)
      let value = try extraction(derivative.original, failure: failure)
      operations.extract = { _ in
        await counter.record()
        return value
      }
      do {
        _ = try await CaptureDocumentWorkflow.assess(sourceHash: manifest.fidelity.sha256,
          captureID: manifest.captureID, profile: .licenseFront, usability: usability,
          store: fixture.store, operations: operations)
        XCTFail("A stale or source-mismatched document extraction was published")
      } catch CaptureDocumentRecoveryError.stageFailed {}
      let extractionCount = await counter.count
      XCTAssertEqual(extractionCount, 1)
      let records = try await CaptureDocumentStages.records("documentExtraction", captureID: manifest.captureID,
        sourceHash: manifest.fidelity.sha256, store: fixture.store)
      XCTAssertTrue(records.isEmpty)
      let original = try await fixture.store.read(id: manifest.captureID)
      XCTAssertEqual(original.original, fixture.pixels)
    }
  }

  private enum Failure: CaseIterable, Equatable { case obsolete, unknown, hash, length, structuredSource }

  private func extraction(_ bytes: Data, failure: Failure) throws -> ArtifactExtraction {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedExtraction(bytes)) as? [String: Any])
    switch failure {
    case .obsolete: object["schemaVersion"] = 3
    case .unknown: object["schemaVersion"] = 999
    case .hash, .length:
      var fidelity = try XCTUnwrap(object["fidelity"] as? [String: Any])
      if failure == .hash { fidelity["sha256"] = String(repeating: "0", count: 64) }
      else { fidelity["fileByteCount"] = bytes.count + 1 }
      object["fidelity"] = fidelity
    case .structuredSource: break
    }
    var result = try JSONDecoder().decode(ArtifactExtraction.self, from: JSONSerialization.data(withJSONObject: object))
    if failure == .structuredSource {
      result.structuredDocument = StructuredDocumentObservation(sourceSHA256: String(repeating: "0", count: 64),
        status: .failed, processingStatus: "synthetic", provider: "fixture", implementationVersion: "fixture_v1",
        issues: ["synthetic_test"])
    }
    return result
  }

  private func encodedExtraction(_ bytes: Data, schema: Int = 4) throws -> Data {
    let extraction = try JourneyRecoveryIntegrationTests.syntheticExtraction(bytes)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(extraction)) as? [String: Any])
    object["schemaVersion"] = schema
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func prepare(_ fixture: Fixture, manifest: CaptureRecords.Manifest,
    operations: CaptureDocumentOperations) async throws -> CaptureUsability {
    let source = CaptureDocumentSource(data: fixture.pixels, fidelity: manifest.fidelity, admission: nil,
      side: manifest.profile.side, captureID: manifest.captureID, profile: manifest.profile)
    return try await CaptureEvaluation.retain(source: source, store: fixture.store, operations: operations)
  }

  private func ciphertext(_ fixture: Fixture) throws -> [String: Data] {
    var files: [String: Data] = [:]
    for url in try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
    where url.pathExtension == "evidence" { files[url.lastPathComponent] = try Data(contentsOf: url) }
    return files
  }
}
#endif
