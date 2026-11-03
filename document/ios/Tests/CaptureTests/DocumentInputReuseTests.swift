#if os(iOS)
  import CryptoKit
  import Foundation
  import ImageIO
  import UIKit
  @testable import DocumentCaptureApple
  import XCTest

  @testable import DocumentCapture
  import DocumentCaptureJournal
  @testable import CaptureEvidenceCustody

  @MainActor
  final class DocumentInputReuseTests: XCTestCase {
    func testSupportedContextCannotBeReusedAsThePreparedUsabilityDerivative() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      func png(_ width: Int, _ height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image {
          UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData())
      }
      func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
      let original = try png(200, 160), card = try png(100, 60), sourceHash = hash(original)
      let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
      let sourceOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
      let geometry = DocumentGeometryObservation(method: .visionDocumentSegmentation,
        implementationVersion: "synthetic", requestRevision: 1, confidence: 1,
        normalizedCoordinateQuantization: nil, analysisPixelWidth: nil, analysisPixelHeight: nil,
        regionOfInterest: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
        orientedPixelWidth: 200, orientedPixelHeight: 160,
        quadrilateral: .init(topLeft: .init(x: 0.25, y: 0.6875), topRight: .init(x: 0.75, y: 0.6875),
          bottomRight: .init(x: 0.75, y: 0.3125), bottomLeft: .init(x: 0.25, y: 0.3125)))
      let prepared = DerivedDocumentImage(data: card, derivation: .init(schemaVersion: 3,
        sourceSHA256: sourceHash, sourceOrientation: sourceOrientation, operation: .perspectiveCorrection,
        implementationVersion: "synthetic", geometry: geometry, outputPixelWidth: 100, outputPixelHeight: 60,
        outputUniformTypeIdentifier: "public.png", usesNonuniformScaling: false, outputSHA256: hash(card)))
      let context = try await AppleDocumentContextImagePreparer.prepareRetained(
        data: original, sourceSHA256: sourceHash, preparedDocument: prepared)
      XCTAssertTrue(context.derivation.supported)
      let captureID = UUID(), derivativeID = UUID()
      let manifest = CaptureRecords.DerivativeManifest(schemaVersion: 1, recordKind: "usabilityDerivative",
        captureID: captureID, sourceSHA256: sourceHash, derivation: context.derivation)
      let sourceManifest = CaptureRecords.Manifest(schemaVersion: 1, captureID: captureID, profile: .document,
        sessionID: CaptureSessionID(), captureTimestamp: .init(value: 1, timescale: 1, flags: 1, epoch: 0,
          clock: .captureSessionSynchronizationClock), processedAt: .now,
        fidelity: try PhotoFidelityMetadata.make(from: original), motionStatus: "synthetic", workflowID: UUID())
      try await CaptureSignedRecords.retainOriginal(id: captureID, original: original,
        manifest: JSONEncoder().encode(sourceManifest), store: fixture.store)
      try await CaptureSignedRecords.retainStage(id: derivativeID, kind: "usabilityDerivative", captureID: captureID,
        original: context.data, manifest: JSONEncoder().encode(manifest), store: fixture.store)
      do {
        _ = try await CaptureDocumentStages.derivative(derivativeID, captureID: captureID,
          sourceHash: sourceHash, store: fixture.store)
        XCTFail("Supported context was relabeled as a prepared usability derivative")
      } catch CaptureIntegrityError.integrityVerificationFailed {}
    }

    func testExtractionReusesVerifiedOriginalWithoutAnotherPayloadRead() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .document, workflowID: UUID())
      try await fixture.retain(manifest)
      let original = try await fixture.store.read(id: manifest.captureID)
      let before = await fixture.store.authenticatedReadCount
      let calls = RecoveryExtractionCounter()
      try await CaptureDocumentInspection.retainExtraction(
        manifest.captureID, store: fixture.store,
        retainedOriginal: original,
        operations: JourneyRecoveryIntegrationTests.operations(calls: calls))
      let reads = await fixture.store.authenticatedReadCount - before
      // Only the newly written extraction's mandatory authenticated readback.
      XCTAssertEqual(reads, 1)
      let count = await calls.count
      XCTAssertEqual(count, 1)
    }

    func testUsabilityReusesOriginalAndKeepsWriteReadback() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .document, workflowID: UUID())
      try await fixture.retain(manifest)
      let original = try await fixture.store.read(id: manifest.captureID)
      let before = await fixture.store.authenticatedReadCount
      _ = try await CaptureEvaluation.retain(
        source: .init(
          data: original.original,
          fidelity: manifest.fidelity, admission: nil, side: manifest.profile.side,
          captureID: manifest.captureID, profile: .document), store: fixture.store,
        retainedOriginal: original)
      let reads = await fixture.store.authenticatedReadCount - before
      // Store's authenticated publication readback plus existing explicit stage readback.
      XCTAssertEqual(reads, 2)
    }

    func testVisionExecutionFailureRetainsIndeterminateAssessmentAndOriginal() async throws {
      try await verifyAnalysisFailure(includeDetails: true)
      try await verifyAnalysisFailure(includeDetails: false)
    }

    private func verifyAnalysisFailure(includeDetails: Bool) async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseBack, workflowID: UUID())
      try await fixture.retain(manifest)
      let original = try await fixture.store.read(id: manifest.captureID)
      let source = CaptureDocumentSource(
        data: original.original, fidelity: manifest.fidelity, admission: nil,
        side: manifest.profile.side, captureID: manifest.captureID, profile: manifest.profile)
      let failure: DocumentPhotoAnalysisFailure? =
        includeDetails
        ? DocumentPhotoAnalysisFailure(
          stage: .barcodeDetection, requestRevision: 4,
          error: NSError(domain: "VNErrorDomain", code: 9)) : nil
      let operations = CaptureDocumentOperations(prepare: { source in
        let prepared = try JourneyRecoveryIntegrationTests.syntheticPreparation(source)
        return .init(
          derivative: prepared.derivative, quality: prepared.quality,
          usability: .init(
            side: source.side, usable: false, failures: [.analysisFailed],
            recognizedTextLineCount: 0, recognizedCharacterCount: 0,
            decodedPDF417Count: 0, decodedPDF417CharacterCount: 0, analysisFailure: failure))
      })
      let result = try await CaptureEvaluation.retain(
        source: source, store: fixture.store, retainedOriginal: original, operations: operations)
      XCTAssertEqual(result.outcome, .notAssessed)
      XCTAssertEqual(result.assessment?.analysisFailure, failure)
      let saved = try await CaptureDocumentStages.usability(
        captureID: source.captureID, sourceHash: source.fidelity.sha256, store: fixture.store)
      XCTAssertEqual(saved?.outcome, .notAssessed)
      XCTAssertEqual(saved?.assessment?.analysisFailure, failure)
      let retained = try await fixture.store.read(id: manifest.captureID)
      XCTAssertEqual(retained.original, original.original)
    }

    func testUsabilityRejectsChangedProfileOrSideBeforeProcessing() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .document, workflowID: UUID())
      try await fixture.retain(manifest)
      let original = try await fixture.store.read(id: manifest.captureID)
      for (profile, side) in [
        (CaptureRecords.Profile.licenseFront, DocumentSide.front),
        (CaptureRecords.Profile.document, DocumentSide.back),
      ] {
        do {
          _ = try await CaptureEvaluation.retain(
            source: .init(
              data: original.original,
              fidelity: manifest.fidelity, admission: manifest.admission, side: side,
              captureID: manifest.captureID, profile: profile), store: fixture.store,
            retainedOriginal: original)
          XCTFail("Changed document identity accepted")
        } catch CaptureIntegrityError.integrityVerificationFailed {}
      }
      let ids = try await fixture.store.list()
      XCTAssertEqual(ids, [manifest.captureID])
    }

    func testPortraitUsesVerifiedDerivativeWithoutRereadingItsPixels() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .licenseFront, workflowID: UUID())
      let source = CaptureDocumentSource(
        data: fixture.pixels, fidelity: manifest.fidelity,
        admission: nil, side: manifest.profile.side, captureID: manifest.captureID,
        profile: manifest.profile)
      let prepared = try JourneyRecoveryIntegrationTests.syntheticPreparation(source)
      let derivativeID = UUID()
      let link = CaptureRecords.DerivativeManifest(
        schemaVersion: 1, recordKind: "usabilityDerivative",
        captureID: manifest.captureID, sourceSHA256: manifest.fidelity.sha256,
        derivation: prepared.derivative.derivation)
      try await fixture.retain(manifest)
      try await CaptureSignedRecords.retainStage(
        id: derivativeID, kind: "usabilityDerivative", captureID: manifest.captureID,
        original: prepared.derivative.data, manifest: JSONEncoder().encode(link), store: fixture.store)
      let derivative = try await fixture.store.read(id: derivativeID)
      let before = await fixture.store.authenticatedReadCount
      try await CapturePortraitCustody.retain(
        captureID: manifest.captureID,
        sourceHash: manifest.fidelity.sha256, derivativeID: derivativeID, store: fixture.store,
        retainedDerivative: derivative,
        operations: JourneyRecoveryIntegrationTests.operations(calls: RecoveryExtractionCounter()))
      let reads = await fixture.store.authenticatedReadCount - before
      // One crop and one extraction record, each with authenticated publication readback.
      XCTAssertEqual(reads, 2)
    }

    func testOriginalSnapshotWithDifferentRecordIdentityIsRejectedBeforeExtraction() async throws {
      let fixture = try JourneyRecoveryIntegrationTests.RecoveryFixture()
      defer { fixture.cleanup() }
      let manifest = try fixture.manifest(profile: .document, workflowID: UUID())
      try await fixture.retain(manifest)
      let original = try await fixture.store.read(id: manifest.captureID)
      let calls = RecoveryExtractionCounter()
      do {
        try await CaptureDocumentInspection.retainExtraction(
          UUID(), store: fixture.store,
          retainedOriginal: original,
          operations: JourneyRecoveryIntegrationTests.operations(calls: calls))
        XCTFail("Wrong record identity accepted")
      } catch { XCTAssertTrue(error is CaptureIntegrityError) }
      let count = await calls.count
      XCTAssertEqual(count, 0)
    }
  }
#endif
