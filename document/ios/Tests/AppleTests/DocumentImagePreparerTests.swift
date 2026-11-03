import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import DocumentSDK
import ImageIO
import Testing
import Vision

@testable import DocumentCaptureApple

@available(iOS 17.0, *)
@Test
func roiLocalRectangleCornersMapToTheOrientedFullImage() throws {
  let observation = VNRectangleObservation(
    requestRevision: 1,
    topLeft: CGPoint(x: 0, y: 1),
    topRight: CGPoint(x: 1, y: 1),
    bottomRight: CGPoint(x: 1, y: 0),
    bottomLeft: CGPoint(x: 0, y: 0)
  )
  let quadrilateral = try #require(
    DocumentStillGeometryDetector.imageNormalizedQuadrilateral(
      observation,
      fromRegionOfInterest: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4),
      orientedImageSize: CGSize(width: 1_000, height: 600)
    )
  )

  #expect(approximatelyEqual(quadrilateral.topLeft, DocumentNormalizedPoint(x: 0.2, y: 0.7)))
  #expect(approximatelyEqual(quadrilateral.topRight, DocumentNormalizedPoint(x: 0.8, y: 0.7)))
  #expect(
    approximatelyEqual(quadrilateral.bottomRight, DocumentNormalizedPoint(x: 0.8, y: 0.3))
  )
  #expect(
    approximatelyEqual(quadrilateral.bottomLeft, DocumentNormalizedPoint(x: 0.2, y: 0.3))
  )
}

@Test
func invalidSelfIntersectingDocumentGeometryFailsClosed() {
  let observation = geometryObservation(
    quadrilateral: DocumentQuadrilateral(
      topLeft: DocumentNormalizedPoint(x: 0.1, y: 0.9),
      topRight: DocumentNormalizedPoint(x: 0.9, y: 0.1),
      bottomRight: DocumentNormalizedPoint(x: 0.9, y: 0.9),
      bottomLeft: DocumentNormalizedPoint(x: 0.1, y: 0.1)
    )
  )

  #expect(!DocumentPhotoGeometryPolicy.isCompleteID1Candidate(observation))
}

@Test
func proposalSelectionRejectsImageBoundaryAndAcceptsID1Geometry() throws {
  let imageBoundary = geometryObservation(
    method: .ossDocumentScannerOpenCV,
    regionOfInterest: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
    quadrilateral: DocumentQuadrilateral(
      topLeft: DocumentNormalizedPoint(x: 0, y: 1),
      topRight: DocumentNormalizedPoint(x: 1, y: 1),
      bottomRight: DocumentNormalizedPoint(x: 1, y: 0),
      bottomLeft: DocumentNormalizedPoint(x: 0, y: 0)
    )
  )
  let id1 = geometryObservation(
    regionOfInterest: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
    quadrilateral: DocumentQuadrilateral(
      topLeft: DocumentNormalizedPoint(x: 0.2, y: 0.81),
      topRight: DocumentNormalizedPoint(x: 0.8, y: 0.81),
      bottomRight: DocumentNormalizedPoint(x: 0.8, y: 0.19),
      bottomLeft: DocumentNormalizedPoint(x: 0.2, y: 0.19)
    )
  )

  #expect(!DocumentPhotoGeometryPolicy.isCompleteID1Candidate(imageBoundary))
  #expect(
    DocumentPhotoGeometryPolicy.completeID1Candidate(from: [imageBoundary, id1]) == id1
  )
}

@Test
func proposalSelectionFailsClosedWhenEveryProposalViolatesTheGuide() {
  let imageBoundary = geometryObservation(
    method: .ossDocumentScannerOpenCV,
    regionOfInterest: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
    quadrilateral: DocumentQuadrilateral(
      topLeft: DocumentNormalizedPoint(x: 0, y: 1),
      topRight: DocumentNormalizedPoint(x: 1, y: 1),
      bottomRight: DocumentNormalizedPoint(x: 1, y: 0),
      bottomLeft: DocumentNormalizedPoint(x: 0, y: 0)
    )
  )

  #expect(DocumentPhotoGeometryPolicy.completeID1Candidate(from: [imageBoundary]) == nil)
}

@Test
func detectorQuantizationPermitsOnlyItsRecordedContainmentResolution() {
  let quantized = geometryObservation(
    method: .ossDocumentScannerOpenCV,
    regionOfInterest: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
    normalizedCoordinateQuantization: DocumentNormalizedPoint(x: 0.0045, y: 0.0034),
    quadrilateral: DocumentQuadrilateral(
      topLeft: DocumentNormalizedPoint(x: 0.303, y: 0.816),
      topRight: DocumentNormalizedPoint(x: 0.902, y: 0.816),
      bottomRight: DocumentNormalizedPoint(x: 0.902, y: 0.184),
      bottomLeft: DocumentNormalizedPoint(x: 0.303, y: 0.184)
    )
  )
  let unquantized = geometryObservation(
    method: .ossDocumentScannerOpenCV,
    regionOfInterest: quantized.regionOfInterest,
    quadrilateral: quantized.quadrilateral
  )

  #expect(DocumentPhotoGeometryPolicy.isCompleteID1Candidate(quantized))
  #expect(!DocumentPhotoGeometryPolicy.isCompleteID1Candidate(unquantized))
}

@Test
func visionProposalCannotBorrowOpenCVQuantizationAllowance() {
  let observation = geometryObservation(
    normalizedCoordinateQuantization: DocumentNormalizedPoint(x: 0.01, y: 0.01),
    quadrilateral: DocumentQuadrilateral(
      topLeft: DocumentNormalizedPoint(x: 0.049, y: 0.8),
      topRight: DocumentNormalizedPoint(x: 0.65, y: 0.8),
      bottomRight: DocumentNormalizedPoint(x: 0.65, y: 0.2),
      bottomLeft: DocumentNormalizedPoint(x: 0.049, y: 0.2)
    )
  )

  #expect(!DocumentPhotoGeometryPolicy.isCompleteID1Candidate(observation))
}

@Test
func perspectiveCorrectionProducesAnID1ShapedZeroOriginDerivative() throws {
  let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(
    to: CGRect(x: 0, y: 0, width: 1_000, height: 600)
  )
  let observation = geometryObservation(
    quadrilateral: DocumentQuadrilateral(
      topLeft: DocumentNormalizedPoint(x: 0.1, y: 0.9),
      topRight: DocumentNormalizedPoint(x: 0.9, y: 0.9),
      bottomRight: DocumentNormalizedPoint(x: 0.9, y: 0.1),
      bottomLeft: DocumentNormalizedPoint(x: 0.1, y: 0.1)
    )
  )

  let corrected = try AppleDocumentImagePreparer.perspectiveCorrected(
    image,
    geometry: observation
  )

  #expect(corrected.extent.origin == .zero)
  #expect(corrected.extent.width > 0)
  #expect(corrected.extent.height > 0)
  let aspect = corrected.extent.width / corrected.extent.height
  #expect((1.6...1.7).contains(aspect))
}

@Test
func documentImageDerivationEncodesItsTransformationIdentity() throws {
  let derivation = DocumentImageDerivation(
    schemaVersion: 3,
    sourceSHA256: String(repeating: "a", count: 64),
    sourceOrientation: 6,
    operation: .perspectiveCorrection,
    implementationVersion: "apple-core-image-ci-perspective-correction-v1",
    geometry: geometryObservation(
      quadrilateral: DocumentQuadrilateral(
        topLeft: DocumentNormalizedPoint(x: 0.1, y: 0.9),
        topRight: DocumentNormalizedPoint(x: 0.9, y: 0.9),
        bottomRight: DocumentNormalizedPoint(x: 0.9, y: 0.1),
        bottomLeft: DocumentNormalizedPoint(x: 0.1, y: 0.1)
      )
    ),
    outputPixelWidth: 800,
    outputPixelHeight: 480,
    outputUniformTypeIdentifier: "public.png",
    usesNonuniformScaling: false,
    outputSHA256: String(repeating: "b", count: 64)
  )

  let encoded = try JSONEncoder().encode(derivation)
  let decoded = try JSONDecoder().decode(DocumentImageDerivation.self, from: encoded)

  #expect(decoded.schemaVersion == 3)
  #expect(decoded.operation == .perspectiveCorrection)
  #expect(decoded.implementationVersion == "apple-core-image-ci-perspective-correction-v1")
}

@Test
func stillQualityMeasurementsAreDeterministicForAUniformImage() throws {
  let colorSpace = CGColorSpaceCreateDeviceGray()
  let context = try #require(
    CGContext(
      data: nil,
      width: 64,
      height: 48,
      bitsPerComponent: 8,
      bytesPerRow: 64,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    )
  )
  context.setFillColor(gray: 1, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
  let quality = DocumentStillQualityAnalyzer.analyze(try #require(context.makeImage()))

  #expect(quality.sharpness == 0)
  #expect(quality.meanLuminance == 1)
  #expect(quality.clippedHighlightRatio == 1)
}

@Test
func everyExifOrientationProducesAZeroOriginImageWithExpectedDimensions() throws {
  let context = try #require(
    CGContext(
      data: nil,
      width: 3,
      height: 2,
      bitsPerComponent: 8,
      bytesPerRow: 12,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  )
  let image = try #require(context.makeImage())

  for rawValue in 1...8 {
    let orientation = try #require(CGImagePropertyOrientation(rawValue: UInt32(rawValue)))
    let oriented = AppleDocumentImagePreparer.orientedImage(image, orientation: orientation)
    let swapsAxes = [5, 6, 7, 8].contains(rawValue)
    #expect(oriented.extent.origin == .zero)
    #expect(oriented.extent.width == (swapsAxes ? 2 : 3))
    #expect(oriented.extent.height == (swapsAxes ? 3 : 2))
  }
}

@Test
func preparationRejectsBytesThatDoNotMatchTheBoundSourceDigest() throws {
  let data = try tinyPNGFixture()

  #expect(throws: DocumentImagePreparationError.sourceIntegrityMismatch) {
    try AppleDocumentImagePreparer.prepare(
      data: data,
      side: .front,
      orientation: nil,
      sourceSHA256: String(repeating: "0", count: 64),
      regionOfInterest: CGRect(x: 0, y: 0, width: 1, height: 1)
    )
  }
}

@Test
func preparationFailuresRemainTypedUnusableCandidateAssessments() {
  let geometryFailure = DocumentPhotoUsabilityAssessment.preparationFailure(
    side: .front,
    error: .invalidDocumentGeometry
  )
  let processingFailure = DocumentPhotoUsabilityAssessment.preparationFailure(
    side: .back,
    error: .perspectiveCorrectionFailed
  )

  #expect(!geometryFailure.usable)
  #expect(geometryFailure.failures == [.completeDocumentNotDetected])
  #expect(!processingFailure.usable)
  #expect(processingFailure.failures == [.documentPreparationFailed])
}

/// Optional controlled replay. Ordinary test runs deliberately do not require
/// sensitive device artifacts. Set both variables and run this test once per
/// accepted side to prove preparation against an immutable local capture.
@Test
func capturedArtifactPreparationReplayWhenConfigured() throws {
  let environment = ProcessInfo.processInfo.environment
  guard
    let path = environment["IDENTITY_EVIDENCE_REPLAY_IMAGE"],
    let sideValue = environment["IDENTITY_EVIDENCE_REPLAY_SIDE"],
    let side = DocumentSide(rawValue: sideValue)
  else { return }

  let data = try Data(contentsOf: URL(fileURLWithPath: path))
  let sourceHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  let regionOfInterest = try #require(
    DocumentPhotoUsabilityEvaluator.visionRegionOfInterest(
      nativeGuideRegion: DocumentCameraGuideRegion(
        minX: 0.365_435_224_650_999_1,
        minY: 0.215_481_171_548_117_2,
        width: 0.269_129_550_698_001_9,
        height: 0.569_037_656_903_765_7
      ),
      captureOrientation: .portrait
    )
  )
  let prepared = try AppleDocumentImagePreparer.prepare(
    data: data,
    side: side,
    orientation: 6,
    sourceSHA256: sourceHash,
    regionOfInterest: regionOfInterest
  )
  if let outputPath = environment["IDENTITY_EVIDENCE_REPLAY_OUTPUT"] {
    try prepared.derivative.data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
  }

  #expect(prepared.derivative.derivation.sourceSHA256 == sourceHash)
  #expect(prepared.derivative.derivation.outputSHA256 != sourceHash)
  #expect(prepared.derivative.derivation.outputPixelWidth > 0)
  #expect(prepared.derivative.derivation.outputPixelHeight > 0)
  #expect(!prepared.derivative.derivation.usesNonuniformScaling)
  #expect(prepared.usability.usable)
  #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sourceHash)
  print(
    "PREPARATION_REPLAY side=\(side.rawValue) "
      + "detector=\(prepared.derivative.derivation.geometry.method.rawValue) "
      + "pixels=\(prepared.derivative.derivation.outputPixelWidth)x"
      + "\(prepared.derivative.derivation.outputPixelHeight) "
      + "textLines=\(prepared.usability.recognizedTextLineCount) "
      + "textCharacters=\(prepared.usability.recognizedCharacterCount) "
      + "pdf417Count=\(prepared.usability.decodedPDF417Count) "
      + "pdf417Characters=\(prepared.usability.decodedPDF417CharacterCount) "
      + "sharpness=\(prepared.quality.sharpness) "
      + "meanLuminance=\(prepared.quality.meanLuminance) "
      + "clippedHighlights=\(prepared.quality.clippedHighlightRatio)"
  )
}

/// Optional detector-specific replay. This bypasses Vision selection so the
/// OSS proposal and the shared guide/ID-1 gate are exercised independently.
@Test
func openCVArtifactProposalReplayWhenConfigured() throws {
  let environment = ProcessInfo.processInfo.environment
  guard let path = environment["IDENTITY_EVIDENCE_OPENCV_REPLAY_IMAGE"] else { return }

  let data = try Data(contentsOf: URL(fileURLWithPath: path))
  let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  let regionOfInterest = try #require(
    DocumentPhotoUsabilityEvaluator.visionRegionOfInterest(
      nativeGuideRegion: DocumentCameraGuideRegion(
        minX: 0.365_435_224_650_999_1,
        minY: 0.215_481_171_548_117_2,
        width: 0.269_129_550_698_001_9,
        height: 0.569_037_656_903_765_7
      ),
      captureOrientation: .portrait
    )
  )
  let proposal = try #require(
    OpenCVDocumentGeometryProposalSource.propose(
      in: image,
      orientation: .right,
      regionOfInterest: regionOfInterest
    )
  )

  #expect(proposal.method == .ossDocumentScannerOpenCV)
  #expect(proposal.requestRevision == nil)
  #expect(proposal.confidence == nil)
  let accepted = DocumentPhotoGeometryPolicy.isCompleteID1Candidate(proposal)
  let expected = environment["IDENTITY_EVIDENCE_OPENCV_REPLAY_EXPECTED"] ?? "accepted"
  #expect(accepted == (expected == "accepted"))
  print(
    "OPENCV_PROPOSAL_REPLAY accepted=\(accepted) "
      + "quadrilateral=\(proposal.quadrilateral)"
  )
}

private func geometryObservation(
  method: DocumentGeometryObservation.DetectionMethod = .visionDocumentSegmentation,
  regionOfInterest: CGRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9),
  normalizedCoordinateQuantization: DocumentNormalizedPoint? = nil,
  quadrilateral: DocumentQuadrilateral
) -> DocumentGeometryObservation {
  DocumentGeometryObservation(
    method: method,
    implementationVersion: "test",
    requestRevision: method == .visionDocumentSegmentation ? 1 : nil,
    confidence: method == .visionDocumentSegmentation ? 1 : nil,
    normalizedCoordinateQuantization: normalizedCoordinateQuantization,
    analysisPixelWidth: nil,
    analysisPixelHeight: nil,
    regionOfInterest: regionOfInterest,
    orientedPixelWidth: 1_000,
    orientedPixelHeight: 600,
    quadrilateral: quadrilateral
  )
}

private func approximatelyEqual(
  _ first: DocumentNormalizedPoint,
  _ second: DocumentNormalizedPoint
) -> Bool {
  abs(first.x - second.x) < 0.000_001 && abs(first.y - second.y) < 0.000_001
}
