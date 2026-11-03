import AVFoundation
import CoreImage
import Foundation
import ImageIO

/// Queue-confined video-frame analyzer. The sole unchecked conformance covers
/// AVFoundation's delegate callback and non-Sendable Core Image context; all
/// mutable fields below are accessed only on `analysisQueue`.
final class DocumentFrameAnalyzer: NSObject, @unchecked Sendable {
  typealias ObservationHandler = @Sendable (DocumentCaptureQualityObservation) -> Void
  typealias FocusHandler = @Sendable (CGPoint) -> Void

  let ingressQueue = DispatchQueue(label: "IdentityEvidenceSDK.DocumentFrameIngress")
  private let analysisSlot = DispatchSemaphore(value: 1)
  let analysisQueue = DispatchQueue(label: "IdentityEvidenceSDK.DocumentFrameAnalyzer")

  let tiltGuidanceTransport: DocumentTiltGuidanceTransport
  private var geometryHistory = DocumentLiveGeometryHistory()
  private var geometryAnalysisMode = DocumentLiveGeometryObservation.AnalysisMode.trackingAssisted
  private let geometryHandler: (@Sendable (DocumentLiveGeometryObservation) -> Void)?
  private let temporalRecorder: DocumentTemporalRecorder?
  let metadataOnlyCapture: Bool
  private var configuration: DocumentCameraDiagnosticsConfiguration
  private let observationHandler: ObservationHandler
  private let focusHandler: FocusHandler
  private var qualityPolicy: DocumentCaptureQualityPolicy
  private let imageContext = CIContext(options: [.cacheIntermediates: false])
  private var regionDetector: DocumentRegionDetector
  private let liveContentAnalyzer = DocumentLiveContentAnalyzer()
  private var analysisCadence = DocumentAnalysisCadence()
  private var lastPreviewTime = CMTime.invalid
  private var previousMotionSamples: [UInt8]?
  private var stableFrameCount = 0
  private var sequence: UInt64 = 0
  private var lastFocusSequence: UInt64 = 0
  private var guideRegionBufferTopLeft: CGRect?
  private var geometryRevision: UInt64 = 0

  let now: @Sendable () -> Date

  init(
    now: @escaping @Sendable () -> Date,
    configuration: DocumentCameraDiagnosticsConfiguration,
    observationHandler: @escaping ObservationHandler,
    focusHandler: @escaping FocusHandler,
    temporalRecorder: DocumentTemporalRecorder? = nil,
    geometryHandler: (@Sendable (DocumentLiveGeometryObservation) -> Void)? = nil,
    tiltGuidanceHandler: @escaping @Sendable (DocumentTiltPresentation) -> Void = { _ in }
  ) {
    self.now = now
    tiltGuidanceTransport = .init(recorder: temporalRecorder, handler: tiltGuidanceHandler)
    self.geometryHandler = geometryHandler
    self.temporalRecorder = temporalRecorder
    self.metadataOnlyCapture = configuration.isMetadataOnly
    self.configuration = configuration
    qualityPolicy = DocumentCaptureQualityPolicy(tuning: configuration.tuning)
    regionDetector = DocumentRegionDetector(adaptive: configuration.includesAdaptiveCapture)
    self.observationHandler = observationHandler
    self.focusHandler = focusHandler
  }

  func reset() {
    ingressQueue.async { [self] in
      analysisCadence.reset()
      analysisQueue.async { [self] in
        lastPreviewTime = .invalid
        previousMotionSamples = nil
        stableFrameCount = 0
        sequence = 0
        lastFocusSequence = 0
        regionDetector.reset()
        tiltGuidanceTransport.endActive(reason: .sessionStopped)
        geometryHistory.reset(.sessionReset)
      }
    }
  }

  func updateGuideRegion(
    _ region: DocumentCameraGuideRegion?, geometryRevision: UInt64,
    resetReason: DocumentLiveGeometryObservation.ResetReason = .geometryRevisionChanged
  ) {
    ingressQueue.async { [self] in
      analysisCadence.reset()
      analysisQueue.async { [self] in
        guideRegionBufferTopLeft = region?.normalizedTopLeftRect
        self.geometryRevision = geometryRevision
        tiltGuidanceTransport.endActive(
          reason: resetReason == .clockChanged ? .clockChanged : .geometryChanged)
        geometryHistory.reset(resetReason)
        previousMotionSamples = nil
        stableFrameCount = 0
        lastFocusSequence = sequence
        lastPreviewTime = .invalid
        regionDetector.updateGuideRegion(bufferTopLeft: guideRegionBufferTopLeft)
      }
    }
  }

  func captureOutput(
    _ _: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    // Raw ingress precedes all Vision work. Only one quality buffer can be
    // retained while analysis runs; excess frames still reach the archive.
    retainTemporal(sampleBuffer, connection: connection, geometry: nil)
    // Live barcode capture with no analysis requested keeps the journal frames only.
    guard !metadataOnlyCapture else { return }
    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard analysisCadence.isDue(time), let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
      analysisSlot.wait(timeout: .now()) == .success
    else { return }
    guard
      let ownedPixels = analysisCadence.copyIfDue(
        time, copy: { DocumentAnalysisPixelCopy.copy(pixels) })
    else {
      analysisSlot.signal()
      return
    }
    let frame = AnalysisFrame(
      pixels: ownedPixels,
      time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), observedAt: now())
    analysisQueue.async { [self] in
      defer { analysisSlot.signal() }
      analyzeFrame(frame.pixels, presentationTime: frame.time, observedAt: frame.observedAt)
    }
  }

  /// One bounded app-owned buffer, read only by the serial analysis queue.
  private final class AnalysisFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let time: CMTime
    let observedAt: Date
    init(pixels: CVPixelBuffer, time: CMTime, observedAt: Date) {
      self.pixels = pixels
      self.time = time
      self.observedAt = observedAt
    }
  }

  func updateConfiguration(
    _ value: DocumentCameraDiagnosticsConfiguration, completion: @escaping @Sendable () -> Void
  ) {
    ingressQueue.async { [self] in
      analysisCadence.reset()
      analysisQueue.async { [self] in
        configuration = value
        tiltGuidanceTransport.endActive(reason: .configurationChanged)
        geometryHistory.reset(.configurationChanged)
        qualityPolicy = DocumentCaptureQualityPolicy(tuning: value.tuning)
        regionDetector = DocumentRegionDetector(adaptive: value.includesAdaptiveCapture)
        regionDetector.updateGuideRegion(bufferTopLeft: guideRegionBufferTopLeft)
        previousMotionSamples = nil
        stableFrameCount = 0
        completion()
      }
    }
  }

  func analyzeFrame(
    _ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, observedAt: Date
  ) {
    let document = analyzeGeometry(
      pixelBuffer, presentationTime: presentationTime, observedAt: observedAt)
    let luma =
      measurementRegion(for: document).map {
        DocumentLumaAnalyzer.analyze(pixelBuffer, normalizedRegion: $0)
      } ?? .empty
    let motion = motion(from: luma.motionSamples)
    previousMotionSamples = luma.motionSamples
    let liveContent =
      configuration.includesLiveContentAnalysis
      ? liveContentAnalyzer.analyze(
        pixelBuffer,
        regionOfInterest: regionDetector.guideRegionVision,
        target: configuration.liveContentTarget
      )
      : .empty

    var metrics = makeMetrics(document: document, luma: luma, motion: motion)
    if configuration.includesAdaptiveCapture {
      metrics.documentFitFillRatio = regionDetector.aspectFitFillRatio(for: document)
    }
    let assessment = qualityPolicy.assess(
      metrics: metrics,
      previousStableFrameCount: stableFrameCount
    )
    stableFrameCount = assessment.stableFrameCount
    sequence &+= 1

    updateFocusIfNeeded(document: document)

    let previewData = makePreviewIfDue(from: pixelBuffer, at: presentationTime)
    observationHandler(
      DocumentCaptureQualityObservation(
        sequence: sequence,
        geometryRevision: geometryRevision,
        timestamp: observedAt,
        metrics: metrics,
        assessment: assessment,
        previewJPEGData: previewData,
        liveContent: liveContent,
        documentBounds: document?.bufferTopLeftBounds
      )
    )
  }

  private func analyzeGeometry(
    _ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, observedAt: Date
  ) -> DetectedDocumentRegion? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    if let timestamp = DocumentCaptureClockTimestamp(avCapturePhotoTimestamp: presentationTime) {
      let needsReset = geometryHistory.prepare(timestamp: timestamp, width: width, height: height)
      if needsReset {
        tiltGuidanceTransport.endActive(reason: .trackerReset)
        regionDetector.reset()
      }
    } else {
      tiltGuidanceTransport.endActive(reason: .clockChanged)
      geometryHistory.reset(.clockDiscontinuity)
      regionDetector.reset()
    }
    updateGeometryAnalysisMode()
    let document = regionDetector.locate(in: pixelBuffer)
    if let geometry = temporalGeometry(document, time: presentationTime) {
      let packet = geometryHistory.packet(
        geometry: geometry,
        analysis: .init(
          width: width, height: height, sequence: sequence &+ 1,
          revision: geometryRevision, observedAt: observedAt),
        availability: regionDetector.availability,
        tracking: (regionDetector.transition, regionDetector.trackingOutcome),
        requestRevision: regionDetector.requestRevision, requestFacts: regionDetector.requestFacts,
        analysisMode: geometryAnalysisMode)
      temporalRecorder?.observeGeometry(geometry, liveGeometry: packet)
      tiltGuidanceTransport.consume(packet, hostSeconds: DocumentTemporalRecorder.hostNow())
      geometryHandler?(packet)
    }
    return document
  }

  func captureOutput(
    _ _: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
    from _: AVCaptureConnection
  ) {
    temporalRecorder?.dropped(sampleBuffer)
  }

  private func retainTemporal(
    _ sample: CMSampleBuffer, connection: AVCaptureConnection,
    geometry: DocumentTemporalGeometry?
  ) {
    let rotation: Double
    if #available(iOS 17.0, macOS 14.0, *) {
      rotation = Double(connection.videoRotationAngle)
    } else {
      rotation = 0
    }
    temporalRecorder?.append(
      sample, geometry: geometry,
      rotationDegrees: rotation, mirrored: connection.isVideoMirrored)
  }

  private func temporalGeometry(
    _ document: DetectedDocumentRegion?, time: CMTime
  ) -> DocumentTemporalGeometry? {
    guard let timestamp = DocumentCaptureClockTimestamp(avCapturePhotoTimestamp: time)
    else { return nil }
    let quadrilateral = document.map { document in
      let points = document.corners.map {
        DocumentNormalizedPoint(x: Double($0.x), y: Double(1 - $0.y))
      }
      return DocumentQuadrilateral(
        topLeft: points[0], topRight: points[1],
        bottomRight: points[2], bottomLeft: points[3])
    }
    return DocumentTemporalGeometry(
      quadrilateral: quadrilateral, observationTimestamp: timestamp,
      coordinateSpace: "normalized_delivered_video_buffer_top_left",
      status: document == nil ? "analyzed_no_accepted_rectangle" : "observed",
      confidence: document?.observation.confidence, method: regionDetector.observationMethod)
  }
}

extension DocumentFrameAnalyzer {
  /// Analysis-queue transition only; native release never waits for this queued cleanup.
  func updateGeometryAnalysisMode() {
    let desired: DocumentLiveGeometryObservation.AnalysisMode =
      tiltGuidanceTransport.usesFreshDetections ? .freshDetection : .trackingAssisted
    guard desired != geometryAnalysisMode else { return }
    geometryAnalysisMode = desired
    regionDetector.updateAnalysisMode(desired)
    geometryHistory.reset(.analysisModeChanged)
    previousMotionSamples = nil
    stableFrameCount = 0
  }

  private func measurementRegion(for document: DetectedDocumentRegion?) -> CGRect? {
    configuration.includesAdaptiveCapture ? document?.bufferTopLeftBounds : guideRegionBufferTopLeft
  }

  private func updateFocusIfNeeded(document: DetectedDocumentRegion?) {
    guard !configuration.includesAdaptiveCapture, let document,
      sequence - lastFocusSequence >= 5
    else { return }
    lastFocusSequence = sequence
    focusHandler(CGPoint(x: document.center.x, y: 1 - document.center.y))
  }

  private func makeMetrics(
    document: DetectedDocumentRegion?,
    luma: DocumentLumaAnalysis,
    motion: Double?
  ) -> DocumentCaptureQualityMetrics {
    DocumentCaptureQualityMetrics(
      documentFillRatio: document?.fillRatio,
      documentGuideFillRatio: regionDetector.guideFillRatio(for: document),
      documentInsideGuide: regionDetector.isInsideGuide(document),
      guideCenterX: guideRegionBufferTopLeft.map { Double($0.midX) },
      guideCenterY: guideRegionBufferTopLeft.map { Double($0.midY) },
      guideWidth: guideRegionBufferTopLeft.map { Double($0.width) },
      guideHeight: guideRegionBufferTopLeft.map { Double($0.height) },
      documentAspectRatio: document?.aspectRatio,
      sharpness: luma.sharpness,
      motion: motion,
      clippedHighlightRatio: luma.clippedHighlightRatio,
      meanLuminance: luma.meanLuminance,
      documentCenterX: document.map { Double($0.center.x) },
      documentCenterY: document.map { Double(1 - $0.center.y) }
    )
  }

  private func motion(from samples: [UInt8]) -> Double? {
    guard
      let previousMotionSamples,
      previousMotionSamples.count == samples.count,
      !samples.isEmpty
    else {
      return nil
    }
    let difference = zip(samples, previousMotionSamples).reduce(0) {
      $0 + abs(Int($1.0) - Int($1.1))
    }
    return Double(difference) / Double(samples.count * 255)
  }

  private func makePreviewIfDue(
    from pixelBuffer: CVPixelBuffer,
    at presentationTime: CMTime
  ) -> Data? {
    guard
      configuration.includesPreviewFrames,
      let guideRegionVision = regionDetector.guideRegionVision
    else { return nil }
    let isThrottled =
      lastPreviewTime.isValid
      && CMTimeGetSeconds(presentationTime - lastPreviewTime)
        < configuration.previewFrameIntervalSeconds
    if isThrottled {
      return nil
    }
    lastPreviewTime = presentationTime

    let input = CIImage(cvPixelBuffer: pixelBuffer)
    let guideImage = CGRect(
      x: input.extent.minX + guideRegionVision.minX * input.extent.width,
      y: input.extent.minY + guideRegionVision.minY * input.extent.height,
      width: guideRegionVision.width * input.extent.width,
      height: guideRegionVision.height * input.extent.height
    ).integral.intersection(input.extent)
    guard !guideImage.isEmpty else { return nil }
    let cropped = input.cropped(to: guideImage)
      .transformed(
        by: CGAffineTransform(translationX: -guideImage.minX, y: -guideImage.minY)
      )
    let longestEdge = max(guideImage.width, guideImage.height)
    let scale = min(1, 960 / longestEdge)
    let output = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return imageContext.jpegRepresentation(
      of: output,
      colorSpace: CGColorSpaceCreateDeviceRGB(),
      options: [:]
    )
  }
}

extension DocumentFrameAnalyzer: AVCaptureVideoDataOutputSampleBufferDelegate {}
