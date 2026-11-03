import CoreVideo
import Foundation
import Vision

struct DetectedDocumentRegion {
  let observation: VNRectangleObservation
  let fillRatio: Double
  let aspectRatio: Double
  let center: CGPoint
  let corners: [CGPoint]

  var bufferTopLeftBounds: CGRect? {
    let xCoordinates = corners.map(\.x)
    let yCoordinates = corners.map { 1 - $0.y }
    guard let minX = xCoordinates.min(), let maxX = xCoordinates.max(),
      let minY = yCoordinates.min(), let maxY = yCoordinates.max()
    else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}

/// Vision state used only from `DocumentFrameAnalyzer.analysisQueue`.
final class DocumentRegionDetector {
  typealias Transition = DocumentLiveGeometryObservation.Transition
  private(set) var observationMethod: String?
  private(set) var availability = DocumentLiveGeometryObservation.Availability.guideUnavailable
  private(set) var transition = DocumentLiveGeometryObservation.Transition.unavailable
  private(set) var trackingOutcome = DocumentLiveGeometryObservation.TrackingOutcome.notAttempted
  private(set) var requestRevision: Int?
  private(set) var requestFacts: [DocumentGeometryRequestFact] = []
  private var analysisMode = DocumentLiveGeometryObservation.AnalysisMode.trackingAssisted
  private let adaptive: Bool
  private var pixelSize = CGSize(width: 1, height: 1)

  init(adaptive: Bool = false) { self.adaptive = adaptive }

  private(set) var guideRegionVision: CGRect?
  private var trackedRectangle: VNRectangleObservation?
  private var trackingFrameCount = 0
  private var trackingHandler = VNSequenceRequestHandler()

  func reset() {
    trackedRectangle = nil
    trackingFrameCount = 0
    trackingHandler = VNSequenceRequestHandler()
  }

  func updateGuideRegion(bufferTopLeft region: CGRect?) {
    guideRegionVision = region.map {
      CGRect(
        x: $0.minX,
        y: 1 - $0.maxY,
        width: $0.width,
        height: $0.height
      )
    }
    reset()
  }

  func updateAnalysisMode(_ mode: DocumentLiveGeometryObservation.AnalysisMode) {
    guard analysisMode != mode else { return }
    analysisMode = mode
    reset()
  }

  func locate(in pixelBuffer: CVPixelBuffer) -> DetectedDocumentRegion? {
    observationMethod = nil
    trackingOutcome = .notAttempted
    requestRevision = nil
    requestFacts.removeAll(keepingCapacity: true)
    availability = .guideUnavailable
    transition = .unavailable
    guard guideRegionVision != nil else { return nil }
    let hadTrack = trackedRectangle != nil
    let periodicRefresh = hadTrack && trackingFrameCount >= 4
    pixelSize = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    if analysisMode == .freshDetection {
      let document = detectDocument(in: pixelBuffer)
      if document != nil { availability = .observed }
      transition = document == nil ? .unavailable : .freshDetection
      return document
    }
    if let tracked = trackedDocument(in: pixelBuffer) {
      observationMethod = "VNTrackRectangleRequest"
      availability = .observed
      transition = .tracked
      return tracked
    }

    let document = detectDocument(in: pixelBuffer)
    transition = Self.transition(
      hadTrack: hadTrack, periodicRefresh: periodicRefresh,
      detected: document != nil)
    if document != nil { availability = .observed }
    trackedRectangle = document?.observation
    trackingFrameCount = 0
    trackingHandler = VNSequenceRequestHandler()
    return document
  }

  static func transition(
    hadTrack: Bool, periodicRefresh: Bool, detected: Bool
  ) -> Transition {
    guard detected else { return hadTrack ? .lost : .unavailable }
    guard hadTrack else { return .initialDetection }
    return periodicRefresh ? .periodicDetectionRefresh : .trackingLostThenDetected
  }

  func guideFillRatio(for document: DetectedDocumentRegion?) -> Double? {
    guard
      let document,
      let guideRegionVision,
      guideRegionVision.width > 0,
      guideRegionVision.height > 0
    else {
      return nil
    }
    return document.fillRatio / Double(guideRegionVision.width * guideRegionVision.height)
  }

  func aspectFitFillRatio(for document: DetectedDocumentRegion?) -> Double? {
    guard let document, let guideRegionVision else { return nil }
    let xCoordinates = document.corners.map(\.x)
    let yCoordinates = document.corners.map(\.y)
    guard let minX = xCoordinates.min(), let maxX = xCoordinates.max(),
      let minY = yCoordinates.min(), let maxY = yCoordinates.max()
    else { return nil }
    return DocumentAdaptiveFramingPolicy.aspectFitFill(
      polygonArea: document.fillRatio,
      bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
      guide: guideRegionVision)
  }

  func isInsideGuide(_ document: DetectedDocumentRegion?) -> Bool? {
    guard let document else { return nil }
    return areCornersInsideGuide(document.corners)
  }

  func areCornersInsideGuide(_ corners: [CGPoint]) -> Bool? {
    guard let guideRegionVision else { return nil }
    return corners.allSatisfy { point in
      point.x >= guideRegionVision.minX
        && point.x <= guideRegionVision.maxX
        && point.y >= guideRegionVision.minY
        && point.y <= guideRegionVision.maxY
    }
  }

  private func trackedDocument(in pixelBuffer: CVPixelBuffer) -> DetectedDocumentRegion? {
    guard let trackedRectangle, trackingFrameCount < 4 else { return nil }
    let request = VNTrackRectangleRequest(rectangleObservation: trackedRectangle)
    request.trackingLevel = .fast
    requestRevision = request.revision
    trackingOutcome = .rejected
    do {
      try trackingHandler.perform([request], on: pixelBuffer)
      let observation = request.results?.first as? VNRectangleObservation
      let document = observation.flatMap { $0.confidence >= 0.5 ? self.document(from: $0) : nil }
      let accepted = document.map(acceptsForGuidance) ?? false
      requestFacts.append(
        .completed(
          .rectangleTracking, revision: request.revision, count: request.results?.count ?? 0,
          accepted: accepted))
      guard let observation, let document, accepted else { return nil }
      trackingOutcome = .accepted
      self.trackedRectangle = observation
      trackingFrameCount += 1
      return document
    } catch {
      requestFacts.append(.failed(.rectangleTracking, revision: request.revision, error: error))
      trackingOutcome = .failed
      return nil
    }
  }

  private func detectDocument(in pixelBuffer: CVPixelBuffer) -> DetectedDocumentRegion? {
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
    let documentRequest = VNDetectDocumentSegmentationRequest()
    documentRequest.regionOfInterest = detectionRegion
    do {
      try handler.perform([documentRequest])
      if let segmented = documentRequest.results?.first {
        if let document = segmentedDocument(from: segmented) {
          observationMethod = "VNDetectDocumentSegmentationRequest"
          requestRevision = documentRequest.revision
          requestFacts.append(
            .completed(
              .documentSegmentation, revision: documentRequest.revision,
              count: documentRequest.results?.count ?? 0, accepted: true))
          return document
        }
      }
      requestFacts.append(
        .completed(
          .documentSegmentation, revision: documentRequest.revision,
          count: documentRequest.results?.count ?? 0, accepted: false))
    } catch {
      requestFacts.append(
        .failed(
          .documentSegmentation, revision: documentRequest.revision, error: error))
      // Constrained rectangle detection below is the documented fallback.
    }

    return detectRectangles(using: handler)
  }

  /// Segmentation returns one proposal, so an image-sized result must not hide the card from
  /// rectangle fallback. Require the segmented document to fit the visible guide; outside movement
  /// capture, the fallback retains adaptive center admission for an oversized card's reframing.
  func segmentedDocument(from observation: VNRectangleObservation) -> DetectedDocumentRegion? {
    guard let document = document(from: observation), isInsideGuide(document) == true else {
      return nil
    }
    return document
  }

  private func detectRectangles(using handler: VNImageRequestHandler) -> DetectedDocumentRegion? {
    let request = VNDetectRectanglesRequest()
    request.maximumObservations = 16
    request.regionOfInterest = detectionRegion
    request.minimumAspectRatio = 0.3
    request.maximumAspectRatio = adaptive ? 1 : 0.95
    request.minimumSize = 0.1
    request.quadratureTolerance = 30
    request.minimumConfidence = 0.4
    requestRevision = request.revision

    do {
      try handler.perform([request])
      observationMethod = "VNDetectRectanglesRequest"
      availability = .noAcceptedRectangle
      let document = selectRectangle(from: request.results ?? [])
      requestFacts.append(
        .completed(
          .rectangleDetection, revision: request.revision, count: request.results?.count ?? 0,
          accepted: document != nil))
      return document
    } catch {
      requestFacts.append(.failed(.rectangleDetection, revision: request.revision, error: error))
      availability = .analysisFailed
      return nil
    }
  }

  func selectRectangle(from observations: [VNRectangleObservation]) -> DetectedDocumentRegion? {
    observations.compactMap(document(from:))
      .filter { acceptsForGuidance($0) }
      .max { $0.fillRatio < $1.fillRatio }
  }

  private func document(from observation: VNRectangleObservation) -> DetectedDocumentRegion? {
    let horizontalLength =
      (distance(observation.topLeft, observation.topRight)
        + distance(observation.bottomLeft, observation.bottomRight)) / 2
    let verticalLength =
      (distance(observation.topLeft, observation.bottomLeft)
        + distance(observation.topRight, observation.bottomRight)) / 2
    guard horizontalLength > 0, verticalLength > 0 else { return nil }

    let aspectRatio = max(horizontalLength, verticalLength) / min(horizontalLength, verticalLength)
    guard (adaptive ? (1.0...2.2) : (1.35...2.1)).contains(aspectRatio) else { return nil }
    let points =
      [observation.topLeft, observation.topRight]
      + [observation.bottomRight, observation.bottomLeft]
    let signedArea = zip(points, points.dropFirst() + [points[0]]).reduce(0) { sum, pair in
      sum + (pair.0.x * pair.1.y) - (pair.1.x * pair.0.y)
    }
    let fillRatio = abs(Double(signedArea)) / 2
    guard fillRatio >= 0.05 else { return nil }

    return DetectedDocumentRegion(
      observation: observation,
      fillRatio: fillRatio,
      aspectRatio: Double(aspectRatio),
      center: CGPoint(
        x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
        y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
      ),
      corners: points
    )
  }

  private func acceptsForGuidance(_ document: DetectedDocumentRegion) -> Bool {
    // Movement holds adaptive reframing. Its target must be inside the visible guide,
    // rather than whichever larger surrounding rectangle shares the guide's center.
    guard adaptive, analysisMode != .freshDetection else { return isInsideGuide(document) == true }
    guard let guide = guideRegionVision else { return false }
    return guide.contains(document.center)
  }

  private var detectionRegion: CGRect {
    adaptive ? CGRect(x: 0, y: 0, width: 1, height: 1) : (guideRegionVision ?? .zero)
  }

  private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
    hypot(
      (first.x - second.x) * (adaptive ? pixelSize.width : 1),
      (first.y - second.y) * (adaptive ? pixelSize.height : 1))
  }
}
