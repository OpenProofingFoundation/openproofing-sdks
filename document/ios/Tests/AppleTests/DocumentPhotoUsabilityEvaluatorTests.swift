import CoreGraphics
import CoreImage
import CoreText
import Foundation
import DocumentSDK
import ImageIO
import Testing
import UniformTypeIdentifiers
import Vision

@testable import DocumentCaptureApple

// swift-format requires trailing commas in multiline literals.
// swiftlint:disable trailing_comma

@Test
func readableFrontTextProducesUsableAssessment() async throws {
  let data = try textImage()
  let assessment = try await DocumentImageProcessingQueue.shared.run { _ in
    DocumentPhotoUsabilityEvaluator.evaluate(data: data, side: .front, orientation: nil)
  }

  #expect(assessment.usable)
  #expect(assessment.recognizedTextLineCount >= 6)
  #expect(assessment.recognizedCharacterCount >= 40)
  #expect(assessment.decodedPDF417Count == 0)
}

@Test
func pdf417ProducesUsableBackAssessmentWithoutExposingPayload() async throws {
  let data = try pdf417Image()
  let assessment = try await DocumentImageProcessingQueue.shared.run { _ in
    DocumentPhotoUsabilityEvaluator.evaluate(data: data, side: .back, orientation: nil)
  }

  #expect(assessment.usable)
  #expect(assessment.decodedPDF417Count == 1)
  #expect(assessment.decodedPDF417CharacterCount >= 40)
  #expect(assessment.recognizedCharacterCount == 0)
}

@Test
func backRequiresOnePDF417ToMeetTheMinimumLength() {
  let assessment = DocumentPhotoUsabilityEvaluator.assessBack(
    payloadCharacterCounts: [20, 20]
  )

  #expect(!assessment.usable)
  #expect(assessment.failures == [.pdf417NotDecoded])
  #expect(assessment.decodedPDF417Count == 2)
  #expect(assessment.decodedPDF417CharacterCount == 20)
}

@Test
func backReportsTheLongestQualifyingPDF417() {
  let assessment = DocumentPhotoUsabilityEvaluator.assessBack(
    payloadCharacterCounts: [12, 40]
  )

  #expect(assessment.usable)
  #expect(assessment.failures.isEmpty)
  #expect(assessment.decodedPDF417Count == 2)
  #expect(assessment.decodedPDF417CharacterCount == 40)
}

@Test
func undecodableImageFailsBothSidesClosed() {
  for side in [DocumentSide.front, .back] {
    let assessment = DocumentPhotoUsabilityEvaluator.evaluate(
      data: Data("not an image".utf8),
      side: side,
      orientation: nil
    )
    #expect(!assessment.usable)
    #expect(assessment.failures == [.imageUndecodable])
  }
}

@Test
func readableTextOutsideTheGuideCannotMakeTheFrontUsable() async throws {
  let data = try textImage()
  let assessment = try await DocumentImageProcessingQueue.shared.run { _ in
    DocumentPhotoUsabilityEvaluator.evaluate(
      data: data, side: .front, orientation: nil,
      visionRegionOfInterest: CGRect(x: 0.78, y: 0.05, width: 0.2, height: 0.9))
  }

  #expect(!assessment.usable)
  #expect(assessment.failures == [.insufficientReadableText])
}

@Test
func pdf417OutsideTheGuideCannotMakeTheBackUsable() async throws {
  let data = try pdf417ImageOnCanvas()
  let inside = try await DocumentImageProcessingQueue.shared.run { _ in
    DocumentPhotoUsabilityEvaluator.evaluate(
      data: data, side: .back, orientation: nil,
      visionRegionOfInterest: CGRect(x: 0.05, y: 0.2, width: 0.7, height: 0.6))
  }
  let outside = try await DocumentImageProcessingQueue.shared.run { _ in
    DocumentPhotoUsabilityEvaluator.evaluate(
      data: data, side: .back, orientation: nil,
      visionRegionOfInterest: CGRect(x: 0.82, y: 0.2, width: 0.16, height: 0.6))
  }

  #expect(inside.usable)
  #expect(!outside.usable)
  #expect(outside.failures == [.pdf417NotDecoded])
}

@Test
func nativeGuideMapsToVisionCoordinatesForEveryCaptureOrientation() throws {
  let native = DocumentCameraGuideRegion(minX: 0.1, minY: 0.2, width: 0.3, height: 0.4)
  let expected: [DocumentCameraOrientation: CGRect] = [
    .landscapeLeft: CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.4),
    .portrait: CGRect(x: 0.4, y: 0.6, width: 0.4, height: 0.3),
    .landscapeRight: CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.4),
    .portraitUpsideDown: CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.3),
  ]

  for orientation in DocumentCameraOrientation.allCases {
    let region = try #require(
      DocumentPhotoUsabilityEvaluator.visionRegionOfInterest(
        nativeGuideRegion: native,
        captureOrientation: orientation
      )
    )
    let expectedRegion = try #require(expected[orientation])
    #expect(approximatelyEqual(region, expectedRegion))
  }
}

@Test
func roiLocalDocumentObservationMapsBackToObservedPhoneGuide() throws {
  let nativeGuide = DocumentCameraGuideRegion(
    minX: 0.365_435_224_650_999_1,
    minY: 0.215_481_171_548_117_2,
    width: 0.269_129_550_698_001_9,
    height: 0.569_037_656_903_765_7
  )
  let guide = try #require(
    DocumentPhotoUsabilityEvaluator.visionRegionOfInterest(
      nativeGuideRegion: nativeGuide,
      captureOrientation: .portrait
    )
  )
  let orientedImageSize = CGSize(width: 6_048, height: 8_064)

  // Privacy-safe numeric geometry from the failing physical-device pass. The
  // segmentation observation is ROI-local, while `guide` is image-normalized.
  let roiLocalDocument = CGRect(
    x: 0.069_444_447_755_813_6,
    y: 0.054_687_5,
    width: 0.902_777_761_220_932,
    height: 0.882_812_5
  )
  let imageNormalizedDocument = try #require(
    DocumentPhotoGeometryPolicy.imageNormalizedRect(
      roiLocalDocument,
      fromRegionOfInterest: guide,
      orientedImageSize: orientedImageSize
    )
  )

  #expect(guide.contains(imageNormalizedDocument))
  #expect(
    DocumentPhotoGeometryPolicy.isCompleteID1Candidate(
      imageNormalizedDocument,
      inside: guide,
      orientedImageSize: orientedImageSize
    )
  )
}

@Test
func completeDocumentCandidateMustBeInsideTheGuideAndID1Shaped() {
  let guide = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
  let imageSize = CGSize(width: 1_000, height: 1_600)

  #expect(
    DocumentPhotoGeometryPolicy.isCompleteID1Candidate(
      CGRect(x: 0.25, y: 0.4, width: 0.5, height: 0.2),
      inside: guide,
      orientedImageSize: imageSize
    )
  )
  #expect(
    !DocumentPhotoGeometryPolicy.isCompleteID1Candidate(
      CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.2),
      inside: guide,
      orientedImageSize: imageSize
    )
  )
  #expect(
    !DocumentPhotoGeometryPolicy.isCompleteID1Candidate(
      CGRect(x: 0.2, y: 0.4, width: 0.5, height: 0.2),
      inside: guide,
      orientedImageSize: imageSize
    )
  )
  #expect(
    !DocumentPhotoGeometryPolicy.isCompleteID1Candidate(
      CGRect(x: 0.3, y: 0.35, width: 0.4, height: 0.3),
      inside: guide,
      orientedImageSize: imageSize
    )
  )
}

@Test
func documentReadabilityDistinguishesRequestFailureFromNegativeObservation() throws {
  let data = try pdf417Image()
  for side in [DocumentSide.front, .back] {
    let expectedStage: DocumentPhotoAnalysisFailure.Stage =
      side == .front ? .textRecognition : .barcodeDetection
    var performedRevision: Int?
    let assessment = DocumentPhotoUsabilityEvaluator.evaluate(
      data: data, side: side, orientation: nil,
      perform: { _, requests in
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(
          side == .front ? request is VNRecognizeTextRequest : request is VNDetectBarcodesRequest)
        performedRevision = request.revision
        throw NSError(
          domain: "com.apple.Vision", code: 9,
          userInfo: [NSLocalizedDescriptionKey: "PRIVATE_DOCUMENT_PAYLOAD"])
      })
    #expect(!assessment.usable)
    #expect(assessment.failures == [.analysisFailed])
    let failure = try #require(assessment.analysisFailure)
    #expect(failure.stage == expectedStage)
    #expect(failure.requestRevision == performedRevision)
    #expect(failure.domain == "com.apple.Vision")
    #expect(failure.code == 9)
    #expect(!failure.domainWasTruncated)
    let encoded = try JSONEncoder().encode(assessment)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE_DOCUMENT_PAYLOAD"))
    #expect(
      try JSONDecoder().decode(DocumentPhotoUsabilityAssessment.self, from: encoded) == assessment)
  }
}

@Test
func passportReadabilityDistinguishesRequestFailureFromUnreadableMRZ() throws {
  for card in [false, true] {
    let assessment = DocumentPhotoUsabilityEvaluator.evaluatePassport(
      data: Data(), card: card,
      perform: { _, requests in
        #expect(requests.count == 1)
        #expect(requests.first is VNRecognizeTextRequest)
        throw NSError(domain: "com.apple.Vision", code: 9)
      })
    #expect(!assessment.usable)
    #expect(assessment.side == (card ? .back : .front))
    #expect(assessment.failures == [.analysisFailed])
    #expect(assessment.analysisFailure?.stage == .textRecognition)
    #expect(assessment.analysisFailure?.code == 9)
  }
}

@Test
func completedEmptyReadabilityRequestsRemainNegativeObservations() throws {
  let data = try pdf417Image()
  for side in [DocumentSide.front, .back] {
    let assessment = DocumentPhotoUsabilityEvaluator.evaluate(
      data: data, side: side, orientation: nil, perform: { _, _ in })
    #expect(!assessment.usable)
    #expect(
      assessment.failures == (side == .front ? [.insufficientReadableText] : [.pdf417NotDecoded]))
    #expect(assessment.analysisFailure == nil)
  }
  let passport = DocumentPhotoUsabilityEvaluator.evaluatePassport(
    data: Data(), perform: { _, _ in })
  #expect(passport.failures == [.mrzNotReadable])
  #expect(passport.analysisFailure == nil)
}

@Test
func retainedReadabilityWithoutRequestDiagnosticStillDecodes() throws {
  let assessment = DocumentPhotoUsabilityEvaluator.assessBack(payloadCharacterCounts: [40])
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(assessment)) as? [String: Any])
  object.removeValue(forKey: "analysisFailure")
  let legacy = try JSONSerialization.data(withJSONObject: object)
  let decoded = try JSONDecoder().decode(DocumentPhotoUsabilityAssessment.self, from: legacy)
  #expect(decoded == assessment)
  #expect(decoded.analysisFailure == nil)
}

@Test
func readabilityRequestDiagnosticBoundsMultibyteErrorDomain() throws {
  let assessment = DocumentPhotoUsabilityEvaluator.evaluatePassport(
    data: Data(),
    perform: { _, _ in
      throw NSError(domain: String(repeating: "é", count: 100), code: 9)
    })
  let failure = try #require(assessment.analysisFailure)
  #expect(failure.domain.utf8.count == 128)
  #expect(failure.domain == String(repeating: "é", count: 64))
  #expect(failure.domainWasTruncated)
}

private func textImage() throws -> Data {
  let width = 1_600
  let height = 1_000
  let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  let context = try #require(
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  )
  context.setFillColor(CGColor(gray: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))

  let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 54, nil)
  let lines = [
    "DRIVER LICENSE",
    "DOCUMENT SAMPLE",
    "IDENTIFICATION CARD",
    "DATE OF BIRTH 01 01 1990",
    "EXPIRATION 01 01 2030",
    "CLASS C RESTRICTIONS NONE",
    "HEIGHT EYES ADDRESS",
    "ISSUED BY SAMPLE AUTHORITY",
  ]
  for (index, value) in lines.enumerated() {
    let attributed = NSAttributedString(
      string: value,
      attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1),
      ]
    )
    context.textPosition = CGPoint(x: 80, y: 850 - index * 100)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
  }
  return try pngData(from: try #require(context.makeImage()))
}

private func pdf417Image() throws -> Data {
  try pngData(from: pdf417CGImage())
}

private func pdf417CGImage() throws -> CGImage {
  let filter = try #require(CIFilter(name: "CIPDF417BarcodeGenerator"))
  let payload = "@ANSI 636000 SAMPLE PDF417 PAYLOAD FOR DOCUMENT USABILITY TESTING ONLY"
  filter.setValue(Data(payload.utf8), forKey: "inputMessage")
  let image = try #require(filter.outputImage).transformed(
    by: CGAffineTransform(scaleX: 5, y: 5)
  )
  let context = CIContext(options: [.cacheIntermediates: false])
  return try #require(context.createCGImage(image, from: image.extent))
}

private func pdf417ImageOnCanvas() throws -> Data {
  let width = 1_600
  let height = 1_000
  let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  let context = try #require(
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  )
  context.setFillColor(CGColor(gray: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.interpolationQuality = .none
  context.draw(try pdf417CGImage(), in: CGRect(x: 100, y: 300, width: 1_000, height: 400))
  return try pngData(from: try #require(context.makeImage()))
}

private func pngData(from image: CGImage) throws -> Data {
  let data = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
  )
  CGImageDestinationAddImage(destination, image, nil)
  try #require(CGImageDestinationFinalize(destination))
  return data as Data
}

private func approximatelyEqual(_ first: CGRect, _ second: CGRect) -> Bool {
  let tolerance = 0.000_000_1
  return abs(first.minX - second.minX) < tolerance
    && abs(first.minY - second.minY) < tolerance
    && abs(first.width - second.width) < tolerance
    && abs(first.height - second.height) < tolerance
}

// swiftlint:enable trailing_comma
