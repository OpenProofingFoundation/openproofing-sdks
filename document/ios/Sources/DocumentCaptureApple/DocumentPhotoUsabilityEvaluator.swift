import CoreGraphics
import Foundation
import DocumentSDK
import ImageIO
import Vision

public struct DocumentPhotoUsabilityAssessment: Codable, Equatable, Sendable {
  public enum Failure: String, Codable, Equatable, Sendable {
    case imageUndecodable
    case guideUnavailable
    case completeDocumentNotDetected
    case documentPreparationFailed
    case insufficientReadableText
    case pdf417NotDecoded
    case mrzNotReadable
    case analysisFailed
    case unsupportedProfile
  }

  public let side: DocumentSide
  public let usable: Bool
  public let failures: [Failure]
  public let recognizedTextLineCount: Int
  public let recognizedCharacterCount: Int
  public let decodedPDF417Count: Int
  public let decodedPDF417CharacterCount: Int
  /// Nil for completed requests and older retained assessments.
  public let analysisFailure: DocumentPhotoAnalysisFailure?

  public init(
    side: DocumentSide,
    usable: Bool,
    failures: [Failure],
    recognizedTextLineCount: Int,
    recognizedCharacterCount: Int,
    decodedPDF417Count: Int,
    decodedPDF417CharacterCount: Int,
    analysisFailure: DocumentPhotoAnalysisFailure? = nil
  ) {
    self.side = side
    self.usable = usable
    self.failures = failures
    self.recognizedTextLineCount = recognizedTextLineCount
    self.recognizedCharacterCount = recognizedCharacterCount
    self.decodedPDF417Count = decodedPDF417Count
    self.decodedPDF417CharacterCount = decodedPDF417CharacterCount
    self.analysisFailure = analysisFailure
  }

  public static func preparationFailure(
    side: DocumentSide,
    error: DocumentImagePreparationError
  ) -> Self {
    let failure: Failure
    switch error {
    case .imageUndecodable, .sourceIntegrityMismatch:
      failure = .imageUndecodable
    case .guideUnavailable:
      failure = .guideUnavailable
    case .documentNotDetected, .invalidDocumentGeometry:
      failure = .completeDocumentNotDetected
    case .perspectiveCorrectionFailed, .derivativeEncodingFailed:
      failure = .documentPreparationFailed
    }
    return Self(
      side: side,
      usable: false,
      failures: [failure],
      recognizedTextLineCount: 0,
      recognizedCharacterCount: 0,
      decodedPDF417Count: 0,
      decodedPDF417CharacterCount: 0
    )
  }

  private enum CodingKeys: String, CodingKey {
    case side
    case usable = "isUsable"
    case failures
    case recognizedTextLineCount
    case recognizedCharacterCount
    case decodedPDF417Count
    case decodedPDF417CharacterCount
    case analysisFailure
  }
}

public struct DocumentPhotoUsabilityEvaluator: Sendable {
  public init() {}

  typealias RequestPerformer = (VNImageRequestHandler, [VNRequest]) throws -> Void

  public func evaluate(
    _ photo: CapturedDocumentPhoto
  ) async -> DocumentPhotoUsabilityAssessment {
    let data = photo.data
    let side = photo.side
    let orientation = photo.fidelity.orientation
    guard let visionRegionOfInterest = Self.visionRegionOfInterest(from: photo.admission) else {
      return Self.failed(side: side, reason: .guideUnavailable)
    }
    do {
      return try await DocumentImageProcessingQueue.shared.run { _ in
        Self.evaluate(
          data: data,
          side: side,
          orientation: orientation,
          visionRegionOfInterest: visionRegionOfInterest,
          requiresCompleteDocument: true
        )
      }
    } catch {
      return Self.failed(side: side, reason: .documentPreparationFailed)
    }
  }

  static func evaluate(
    data: Data,
    side: DocumentSide,
    orientation: Int?,
    visionRegionOfInterest: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
    requiresCompleteDocument: Bool = false,
    perform: RequestPerformer = { try $0.perform($1) }
  ) -> DocumentPhotoUsabilityAssessment {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      return failed(side: side, reason: .imageUndecodable)
    }

    let imageOrientation =
      orientation
      .flatMap { CGImagePropertyOrientation(rawValue: UInt32($0)) }
      ?? .up
    if requiresCompleteDocument {
      guard
        DocumentPhotoGeometryPolicy.containsCompleteID1(
          in: image,
          orientation: imageOrientation,
          regionOfInterest: visionRegionOfInterest
        )
      else { return failed(side: side, reason: .completeDocumentNotDetected) }
    }
    switch side {
    case .front:
      return evaluateFront(
        image,
        orientation: imageOrientation,
        visionRegionOfInterest: visionRegionOfInterest,
        perform: perform
      )
    case .back:
      return evaluateBack(
        image,
        orientation: imageOrientation,
        visionRegionOfInterest: visionRegionOfInterest,
        perform: perform
      )
    }
  }

  private static func evaluateFront(
    _ image: CGImage,
    orientation: CGImagePropertyOrientation,
    visionRegionOfInterest: CGRect,
    perform: RequestPerformer
  ) -> DocumentPhotoUsabilityAssessment {
    let request = VNRecognizeTextRequest()
    request.regionOfInterest = visionRegionOfInterest
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.minimumTextHeight = DocumentCaptureTuning.Readability.minimumStillTextHeight
    do {
      try perform(VNImageRequestHandler(cgImage: image, orientation: orientation), [request])
      let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
      let characterCount = candidates.reduce(0) { $0 + $1.string.count }
      let usable =
        candidates.count >= DocumentCaptureTuning.Readability.minimumTextLines
        && characterCount >= DocumentCaptureTuning.Readability.minimumTextCharacters
      return DocumentPhotoUsabilityAssessment(
        side: .front,
        usable: usable,
        failures: usable ? [] : [.insufficientReadableText],
        recognizedTextLineCount: candidates.count,
        recognizedCharacterCount: characterCount,
        decodedPDF417Count: 0,
        decodedPDF417CharacterCount: 0
      )
    } catch {
      return analysisFailed(side: .front, stage: .textRecognition, request: request, error: error)
    }
  }

  private static func evaluateBack(
    _ image: CGImage,
    orientation: CGImagePropertyOrientation,
    visionRegionOfInterest: CGRect,
    perform: RequestPerformer
  ) -> DocumentPhotoUsabilityAssessment {
    let request = VNDetectBarcodesRequest()
    request.regionOfInterest = visionRegionOfInterest
    do {
      try DocumentVisionRequests.configurePDF417(request)
      try perform(VNImageRequestHandler(cgImage: image, orientation: orientation), [request])
      let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
      return assessBack(payloadCharacterCounts: payloads.map(\.count))
    } catch {
      return analysisFailed(side: .back, stage: .barcodeDetection, request: request, error: error)
    }
  }

  static func evaluatePassport(
    data: Data, card: Bool = false, perform: RequestPerformer = { try $0.perform($1) }
  ) -> DocumentPhotoUsabilityAssessment {
    let side: DocumentSide = card ? .back : .front
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    do { try perform(VNImageRequestHandler(data: data, orientation: .up), [request]) } catch {
      return analysisFailed(side: side, stage: .textRecognition, request: request, error: error)
    }
    let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    // MRZ interpretation belongs to the independent passport capability.
    let readable = false
    return DocumentPhotoUsabilityAssessment(
      side: side, usable: readable, failures: readable ? [] : [.mrzNotReadable],
      recognizedTextLineCount: lines.count,
      recognizedCharacterCount: lines.reduce(0) { $0 + $1.count },
      decodedPDF417Count: 0, decodedPDF417CharacterCount: 0)
  }

  static func assessBack(
    payloadCharacterCounts: [Int]
  ) -> DocumentPhotoUsabilityAssessment {
    let maximumCharacterCount = payloadCharacterCounts.max() ?? 0
    let usable =
      maximumCharacterCount >= DocumentCaptureTuning.Readability.minimumPDF417Characters
    return DocumentPhotoUsabilityAssessment(
      side: .back,
      usable: usable,
      failures: usable ? [] : [.pdf417NotDecoded],
      recognizedTextLineCount: 0,
      recognizedCharacterCount: 0,
      decodedPDF417Count: payloadCharacterCounts.count,
      decodedPDF417CharacterCount: maximumCharacterCount
    )
  }

  static func visionRegionOfInterest(
    from admission: DocumentCaptureAdmissionSnapshot?
  ) -> CGRect? {
    guard
      let nativeGuideRegion = admission?.nativeCaptureDeviceGuideRegion,
      let captureOrientation = admission?.captureOrientation
    else { return nil }
    return visionRegionOfInterest(
      nativeGuideRegion: nativeGuideRegion,
      captureOrientation: captureOrientation
    )
  }

  static func visionRegionOfInterest(
    nativeGuideRegion: DocumentCameraGuideRegion,
    captureOrientation: DocumentCameraOrientation
  ) -> CGRect? {
    let orientedTopLeftRegion = nativeGuideRegion.convertedToVideoBuffer(
      orientation: captureOrientation
    )
    guard let topLeftRect = orientedTopLeftRegion.normalizedTopLeftRect else { return nil }
    return CGRect(
      x: topLeftRect.minX,
      y: 1 - topLeftRect.maxY,
      width: topLeftRect.width,
      height: topLeftRect.height
    )
  }

  private static func analysisFailed(
    side: DocumentSide, stage: DocumentPhotoAnalysisFailure.Stage, request: VNRequest, error: Error
  ) -> DocumentPhotoUsabilityAssessment {
    DocumentPhotoUsabilityAssessment(
      side: side, usable: false, failures: [.analysisFailed],
      recognizedTextLineCount: 0, recognizedCharacterCount: 0,
      decodedPDF417Count: 0, decodedPDF417CharacterCount: 0,
      analysisFailure: .init(stage: stage, requestRevision: request.revision, error: error))
  }

  private static func failed(
    side: DocumentSide,
    reason: DocumentPhotoUsabilityAssessment.Failure
  ) -> DocumentPhotoUsabilityAssessment {
    DocumentPhotoUsabilityAssessment(
      side: side,
      usable: false,
      failures: [reason],
      recognizedTextLineCount: 0,
      recognizedCharacterCount: 0,
      decodedPDF417Count: 0,
      decodedPDF417CharacterCount: 0
    )
  }
}
