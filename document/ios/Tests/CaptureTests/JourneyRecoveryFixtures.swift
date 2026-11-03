#if os(iOS)
  import CryptoKit
  import Foundation
  import DocumentSDK
  @testable import CaptureEvidenceCustody
  import UIKit
  import XCTest

  @testable import DocumentCapture
  import DocumentCaptureJournal
  @testable import DocumentCaptureApple

  @MainActor
  enum JourneyRecoveryIntegrationTests {
    static func operations(calls: RecoveryExtractionCounter) -> CaptureDocumentOperations {
      var operations = CaptureDocumentOperations()
      operations.extract = { data in
        await calls.record()
        return try Self.syntheticExtraction(data)
      }
      operations.structured = { data in
        StructuredDocumentObservation(
          sourceSHA256: CaptureArtifactIntegrity.sha256(data), status: .failed,
          processingStatus: "synthetic", provider: "fixture", implementationVersion: "fixture_v1",
          issues: ["synthetic_test"])
      }
      operations.prepare = { try Self.syntheticPreparation($0) }
      operations.portrait = { data, derivation in
        try Self.syntheticPortrait(data, derivation: derivation)
      }
      return operations
    }

    static func syntheticPreparation(_ source: CaptureDocumentSource) throws
      -> AppleDocumentImagePreparer.PreparedImage
    {
      let geometry = DocumentGeometryObservation(
        method: .visionDocumentSegmentation,
        implementationVersion: "synthetic-recovery-fixture", requestRevision: 1, confidence: 1,
        normalizedCoordinateQuantization: nil, analysisPixelWidth: nil, analysisPixelHeight: nil,
        regionOfInterest: CGRect(x: 0, y: 0, width: 1, height: 1),
        orientedPixelWidth: 256, orientedPixelHeight: 384,
        quadrilateral: .init(
          topLeft: .init(x: 0, y: 1), topRight: .init(x: 1, y: 1),
          bottomRight: .init(x: 1, y: 0), bottomLeft: .init(x: 0, y: 0)))
      let derivation = DocumentImageDerivation(
        schemaVersion: 3, sourceSHA256: source.fidelity.sha256,
        sourceOrientation: source.fidelity.orientation, operation: .perspectiveCorrection,
        implementationVersion: "synthetic-recovery-fixture",
        geometry: geometry, outputPixelWidth: 256, outputPixelHeight: 384,
        outputUniformTypeIdentifier: "public.png", usesNonuniformScaling: false,
        outputSHA256: source.fidelity.sha256)
      return .init(
        derivative: .init(data: source.data, derivation: derivation),
        quality: .init(sharpness: 1, meanLuminance: 0.5, clippedHighlightRatio: 0),
        usability: .init(
          side: source.side, usable: true, failures: [], recognizedTextLineCount: 3,
          recognizedCharacterCount: 50, decodedPDF417Count: 0, decodedPDF417CharacterCount: 0))
    }

    static func syntheticPortrait(_ data: Data, derivation: DocumentImageDerivation) throws
      -> PortraitExtractionResult
    {
      let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
      return try ApplePortraitExtractor.render(
        image: image, sourceSHA256: derivation.outputSHA256,
        observations: [
          .init(boundingBox: .init(x: 0.2, y: 0.2, width: 0.3, height: 0.4), confidence: 1)
        ],
        requestRevision: 3, paddingFraction: 0.2)
    }

    nonisolated static func syntheticExtraction(_ data: Data) throws -> ArtifactExtraction {
      let fidelity = try PhotoFidelityMetadata.make(from: data)
      let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fidelity))
      let metadata = try PropertyListSerialization.data(
        fromPropertyList: ["Fixture": "synthetic"],
        format: .binary, options: 0)
      let values: [String: Any] = [
        "schemaVersion": 4, "fidelity": object,
        "imagePropertiesPlist": metadata.base64EncodedString(), "pdf417Payloads": [],
        "recognizedText": ["SYNTHETIC DOCUMENT"], "barcodeRequestRevision": 1,
        "textRequestRevision": 1, "detectedFaceCount": 0, "faceRequestRevision": 1,
      ]
      return try JSONDecoder().decode(
        ArtifactExtraction.self, from: JSONSerialization.data(withJSONObject: values))
    }

    @MainActor
    struct RecoveryFixture {
      let directory: URL
      let store: CaptureEvidenceStore
      let key: SymmetricKey
      let pixels: Data

      init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        key = SymmetricKey(size: .bits256)
        store = try CaptureSignedFixture.store(directory: directory, key: key)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
          size: CGSize(width: 256, height: 384), format: format)
        let image = renderer.image { context in
          UIColor.gray.setFill()
          context.fill(CGRect(x: 0, y: 0, width: 256, height: 384))
        }
        pixels = try XCTUnwrap(image.pngData())
      }

      func reopen() throws -> CaptureEvidenceStore {
        try CaptureSignedFixture.store(directory: directory, key: key)
      }

      func cleanup() { try? FileManager.default.removeItem(at: directory) }

      func retain(_ manifest: CaptureRecords.Manifest) async throws {
        try await CaptureSignedFixture.original(
          id: manifest.captureID, bytes: pixels, manifest: JSONEncoder().encode(manifest), store: store)
      }

      func retainExtraction(_ manifest: CaptureRecords.Manifest) async throws -> UUID {
        let fidelity = try JSONSerialization.jsonObject(
          with: JSONEncoder().encode(manifest.fidelity))
        let metadata = try PropertyListSerialization.data(
          fromPropertyList: ["Fixture": "synthetic"], format: .binary, options: 0)
        let extraction: [String: Any] = [
          "schemaVersion": 2, "fidelity": fidelity,
          "imagePropertiesPlist": metadata.base64EncodedString(),
          "pdf417Payloads": [], "recognizedText": ["SYNTHETIC FRONT TEXT"],
          "barcodeRequestRevision": 1, "textRequestRevision": 1,
        ]
        let link = CaptureRecords.ExtractionManifest(
          schemaVersion: 1, recordKind: "extraction", captureID: manifest.captureID,
          sourceSHA256: manifest.fidelity.sha256)
        return try await CaptureDocumentStages.retain(kind: "extraction", captureID: manifest.captureID,
          original: JSONSerialization.data(withJSONObject: extraction),
          manifest: JSONEncoder().encode(link), store: store)
      }

      func manifest(
        id: UUID = UUID(), profile: CaptureRecords.Profile, workflowID: UUID?,
        precedingFrontCaptureID: UUID? = nil, declaredHash: String? = nil
      ) throws -> CaptureRecords.Manifest {
        let hash =
          declaredHash ?? SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
        let fidelity = try JSONDecoder().decode(
          PhotoFidelityMetadata.self,
          from: JSONEncoder().encode(
            FidelityFixture(
              fileByteCount: pixels.count, sha256: hash)))
        return CaptureRecords.Manifest(
          schemaVersion: 1, captureID: id, profile: profile, sessionID: CaptureSessionID(),
          captureTimestamp: .init(
            value: 1, timescale: 1, flags: 1, epoch: 0, clock: .captureSessionSynchronizationClock),
          processedAt: Date(timeIntervalSince1970: 1), fidelity: fidelity,
          admission: nil, motionStatus: "synthetic_test_fixture", workflowID: workflowID,
          precedingFrontCaptureID: precedingFrontCaptureID)
      }
    }

    struct FidelityFixture: Encodable {
      let pixelWidth = 256
      let pixelHeight = 384
      let fileByteCount: Int
      let uniformTypeIdentifier = "public.png"
      let sha256: String
    }
  }

  actor RecoveryExtractionCounter {
    private(set) var count = 0
    func record() { count += 1 }
  }
#endif
