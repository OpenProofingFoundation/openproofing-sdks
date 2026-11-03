#if os(iOS)
import Foundation
import KenshikiEvidenceManifest
import XCTest
@testable import DocumentCapture
@testable import CaptureEvidenceCustody
import DocumentCaptureApple

@MainActor
final class CaptureSignedPublicationTests: XCTestCase {
  func testOriginalAndAnalysisRoundTripRequireTheSameSignedSourceAndOwner() async throws {
    let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
    defer { fixture.cleanup() }
    let workflow = UUID()
    let manifest = try fixture.manifest(profile: .document, workflowID: workflow)
    try await fixture.retain(manifest)
    let retained = try await CaptureSignedRecords.original(id: manifest.captureID, workflowID: workflow, store: fixture.store)
    XCTAssertEqual(retained.record.original, fixture.pixels)
    XCTAssertEqual(retained.publication.manifest.context.attemptID, manifest.captureID)
    XCTAssertEqual(retained.publication.manifest.context.applicationID, "synthetic.capture-sdk.fixture")
    let link = CaptureRecords.ExtractionManifest(schemaVersion: 1, recordKind: "syntheticAnalysis",
      captureID: manifest.captureID, sourceSHA256: manifest.fidelity.sha256)
    let id = try await CaptureDocumentStages.retain(kind: "syntheticAnalysis", captureID: manifest.captureID,
      original: Data("synthetic observed result".utf8), manifest: CaptureDocumentStages.encode(link), store: fixture.store)
    let reopened = try fixture.reopen()
    let result = try await CaptureSignedRecords.stage(id: id, captureID: manifest.captureID, store: reopened)
    XCTAssertEqual(result.original, Data("synthetic observed result".utf8))
    do {
      _ = try await CaptureSignedRecords.original(id: manifest.captureID, workflowID: UUID(), store: reopened)
      XCTFail("Another workflow cannot adopt an otherwise valid signature")
    } catch CaptureIntegrityError.integrityVerificationFailed {}
  }

  func testUnsignedOriginalCannotBeRecoveredOrUsedToSignNewAnalysis() async throws {
    let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
    defer { fixture.cleanup() }
    let manifest = try fixture.manifest(profile: .document, workflowID: UUID())
    try await fixture.store.store(id: manifest.captureID, original: fixture.pixels, manifest: JSONEncoder().encode(manifest))
    do {
      _ = try await CaptureSignedRecords.original(id: manifest.captureID, store: fixture.store)
      XCTFail("Historical AEAD is not a signed source")
    } catch CaptureEvidenceStoreError.unsignedHistoricalRecord {}
    do {
      _ = try await CaptureDocumentStages.retain(kind: "syntheticAnalysis", captureID: manifest.captureID,
        original: Data([1]), manifest: Data([2]), store: fixture.store)
      XCTFail("A new stage must not upgrade an unsigned original retroactively")
    } catch CaptureEvidenceStoreError.unsignedHistoricalRecord {}
  }

  func testAnotherAcquisitionCannotAdoptASignedStage() async throws {
    let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
    defer { fixture.cleanup() }
    let workflow = UUID()
    let first = try fixture.manifest(profile: .document, workflowID: workflow)
    let second = try fixture.manifest(profile: .document, workflowID: workflow)
    try await fixture.retain(first); try await fixture.retain(second)
    let link = CaptureRecords.ExtractionManifest(schemaVersion: 1, recordKind: "syntheticAnalysis",
      captureID: first.captureID, sourceSHA256: first.fidelity.sha256)
    let id = try await CaptureDocumentStages.retain(kind: "syntheticAnalysis", captureID: first.captureID,
      original: Data([1]), manifest: CaptureDocumentStages.encode(link), store: fixture.store)
    do {
      _ = try await CaptureSignedRecords.stage(id: id, captureID: second.captureID, store: fixture.store)
      XCTFail("Equal pixels do not permit stage substitution between acquisitions")
    } catch EvidenceManifestError.bindingMismatch {}
  }
}
#endif
