import Foundation

public struct DocumentCaptureQualityMetrics: Codable, Equatable, Sendable {
  /// Adaptive area relative to the largest aspect-preserving fit; legacy area remains below.
  public var documentFitFillRatio: Double?
  public let documentFillRatio: Double?
  public let documentGuideFillRatio: Double?
  public let documentInsideGuide: Bool?
  public let guideCenterX: Double?
  public let guideCenterY: Double?
  public let guideWidth: Double?
  public let guideHeight: Double?
  public let documentAspectRatio: Double?
  public let sharpness: Double
  public let motion: Double?
  public let clippedHighlightRatio: Double
  public let meanLuminance: Double
  public let documentCenterX: Double?
  public let documentCenterY: Double?

  private enum CodingKeys: String, CodingKey {
    case documentFitFillRatio
    case documentFillRatio
    case documentGuideFillRatio
    case documentInsideGuide = "isDocumentInsideGuide"
    case guideCenterX
    case guideCenterY
    case guideWidth
    case guideHeight
    case documentAspectRatio
    case sharpness
    case motion
    case clippedHighlightRatio
    case meanLuminance
    case documentCenterX
    case documentCenterY
  }
}

public struct DocumentCaptureQualityAssessment: Codable, Equatable, Sendable {
  public enum BlockingReason: String, Codable, Equatable, Sendable {
    case documentNotFound
    case guideUnavailable
    case alignWithGuide
    case moveCloser
    case moveFartherAway
    case tooDark
    case tooBright
    case glare
    case holdSteady
    case softFocus
    case stabilizing
    case cameraAdjusting
  }

  public let ready: Bool
  public let blockingReasons: [BlockingReason]
  public let stableFrameCount: Int

  private enum CodingKeys: String, CodingKey {
    case ready = "isReady"
    case blockingReasons
    case stableFrameCount
  }
}

/// Privacy-safe live content evidence from the fixed guide region. Recognized
/// strings and barcode payloads never cross the analysis queue.
public struct DocumentLiveContentMetrics: Codable, Equatable, Sendable {
  public let recognizedTextLineCount: Int
  public let recognizedCharacterCount: Int
  public let decodedPDF417Count: Int
  public let decodedPDF417CharacterCount: Int
  /// Nil means MRZ analysis was not performed; one means a single checksum-readable candidate.
  public let mrzCandidateCount: Int?

  public init(
    recognizedTextLineCount: Int,
    recognizedCharacterCount: Int,
    decodedPDF417Count: Int,
    decodedPDF417CharacterCount: Int,
    mrzCandidateCount: Int? = nil
  ) {
    self.recognizedTextLineCount = recognizedTextLineCount
    self.recognizedCharacterCount = recognizedCharacterCount
    self.decodedPDF417Count = decodedPDF417Count
    self.decodedPDF417CharacterCount = decodedPDF417CharacterCount
    self.mrzCandidateCount = mrzCandidateCount
  }

  public static let empty = Self(
    recognizedTextLineCount: 0,
    recognizedCharacterCount: 0,
    decodedPDF417Count: 0,
    decodedPDF417CharacterCount: 0
  )
}

/// Advisory analysis copied immediately before an operator-initiated photo
/// request. This deliberately excludes preview image bytes and document
/// content. It records what the current quality hypothesis reported without
/// granting that hypothesis authority over the shutter.
public struct DocumentCaptureObservationSnapshot: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let geometryRevision: UInt64
  public let observedAt: Date
  public let metrics: DocumentCaptureQualityMetrics
  public let assessment: DocumentCaptureQualityAssessment
  public let liveContent: DocumentLiveContentMetrics
  public let cameraControl: DocumentCameraControlSnapshot?
  public let documentBounds: CGRect?

  init(observation: DocumentCaptureQualityObservation) {
    sequence = observation.sequence
    geometryRevision = observation.geometryRevision
    observedAt = observation.timestamp
    metrics = observation.metrics
    assessment = observation.assessment
    liveContent = observation.liveContent
    cameraControl = observation.cameraControl
    documentBounds = observation.documentBounds
  }
}

/// One copied, immutable result from the camera's serial frame-analysis queue.
/// `previewJPEGData` is present only when explicitly enabled and must be treated
/// as sensitive document imagery. It is never written to ordinary telemetry.
public struct DocumentCaptureQualityObservation: Equatable, Sendable {
  public let sequence: UInt64
  public let geometryRevision: UInt64
  public let timestamp: Date
  public let metrics: DocumentCaptureQualityMetrics
  public let assessment: DocumentCaptureQualityAssessment
  public let previewJPEGData: Data?
  public let liveContent: DocumentLiveContentMetrics
  public let cameraControl: DocumentCameraControlSnapshot?
  public let documentBounds: CGRect?

  public init(
    sequence: UInt64,
    geometryRevision: UInt64,
    timestamp: Date,
    metrics: DocumentCaptureQualityMetrics,
    assessment: DocumentCaptureQualityAssessment,
    previewJPEGData: Data? = nil,
    liveContent: DocumentLiveContentMetrics = .empty,
    cameraControl: DocumentCameraControlSnapshot? = nil,
    documentBounds: CGRect? = nil
  ) {
    self.sequence = sequence
    self.geometryRevision = geometryRevision
    self.timestamp = timestamp
    self.metrics = metrics
    self.assessment = assessment
    self.previewJPEGData = previewJPEGData
    self.liveContent = liveContent
    self.cameraControl = cameraControl
    self.documentBounds = documentBounds
  }
}

public struct DocumentCaptureObservationIdentity: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let geometryRevision: UInt64
  public let observedAt: Date

  public init(observation: DocumentCaptureQualityObservation) {
    sequence = observation.sequence
    geometryRevision = observation.geometryRevision
    observedAt = observation.timestamp
  }

  func matches(_ observation: DocumentCaptureQualityObservation) -> Bool {
    sequence == observation.sequence
      && geometryRevision == observation.geometryRevision
      && observedAt == observation.timestamp
  }
}

/// Shared freshness rule for binding a live analysis observation to a photo
/// request. This is a measurement-validity constraint, not a quality verdict.
public enum DocumentCaptureObservationFreshness {
  public static let maximumAgeMilliseconds = DocumentCaptureTuning.Timing
    .maximumShutterObservationAgeMilliseconds

  public static func ageMilliseconds(
    of observation: DocumentCaptureQualityObservation,
    at referenceDate: Date
  ) -> Int {
    Int((referenceDate.timeIntervalSince(observation.timestamp) * 1_000).rounded())
  }

  public static func fresh(
    _ observation: DocumentCaptureQualityObservation,
    at referenceDate: Date
  ) -> Bool {
    let age = ageMilliseconds(of: observation, at: referenceDate)
    return (0...maximumAgeMilliseconds).contains(age)
  }
}

public struct DocumentCameraDiagnosticsConfiguration: Equatable, Sendable {
  public let tuning: DocumentCaptureTuningOverrides
  public let livePDF417: Bool
  public let includesAdaptiveCapture: Bool
  public let includesPreviewFrames: Bool
  public let includesLiveContentAnalysis: Bool
  public let liveContentTarget: DocumentLiveContentTarget
  public let previewFrameIntervalSeconds: Double

  public init(
    livePDF417: Bool = false,
    includesAdaptiveCapture: Bool = false,
    includesPreviewFrames: Bool = false,
    includesLiveContentAnalysis: Bool = false,
    liveContentTarget: DocumentLiveContentTarget = .documentText,
    previewFrameIntervalSeconds: Double = DocumentCaptureDefaults.previewFrameIntervalSeconds,
    tuning: DocumentCaptureTuningOverrides = .init()
  ) {
    self.livePDF417 = livePDF417
    self.tuning = tuning
    self.includesAdaptiveCapture = includesAdaptiveCapture
    self.includesPreviewFrames = includesPreviewFrames
    self.includesLiveContentAnalysis = includesLiveContentAnalysis
    self.liveContentTarget = liveContentTarget
    self.previewFrameIntervalSeconds = max(previewFrameIntervalSeconds, 0.5)
  }

  public static let qualityOnly = Self()
  public static let usbPreview = Self(includesPreviewFrames: true)

  /// Live barcode capture with no frame analysis requested keeps journal frames only.
  var isMetadataOnly: Bool {
    livePDF417 && !includesAdaptiveCapture && !includesLiveContentAnalysis
  }
}

@MainActor
public protocol DocumentCameraQualityProviding: AnyObject {
  var qualityObservations: AsyncStream<DocumentCaptureQualityObservation> { get }
}

struct DocumentCaptureQualityPolicy: Sendable {
  private typealias Tuning = DocumentCaptureTuning.Quality
  let requiredStableFrameCount: Int
  let tuning: DocumentCaptureTuningOverrides

  init(requiredStableFrameCount: Int? = nil, tuning: DocumentCaptureTuningOverrides = .init()) {
    self.tuning = tuning
    self.requiredStableFrameCount = requiredStableFrameCount ?? tuning.qualityObservations
  }

  func assess(
    metrics: DocumentCaptureQualityMetrics,
    previousStableFrameCount: Int
  ) -> DocumentCaptureQualityAssessment {
    var reasons: [DocumentCaptureQualityAssessment.BlockingReason] = []

    guard metrics.documentFillRatio != nil else {
      return assessment(reasons: [.documentNotFound], previousStableFrameCount: 0)
    }
    guard let guideFill = metrics.documentFitFillRatio ?? metrics.documentGuideFillRatio,
      let isInsideGuide = metrics.documentInsideGuide
    else {
      return assessment(reasons: [.guideUnavailable], previousStableFrameCount: 0)
    }
    if !isInsideGuide { reasons.append(.alignWithGuide) }
    if guideFill < tuning.minimumGuideFill { reasons.append(.moveCloser) }
    if guideFill > Tuning.maximumGuideFill { reasons.append(.moveFartherAway) }
    if metrics.meanLuminance < tuning.minimumMeanLuminance { reasons.append(.tooDark) }
    if metrics.meanLuminance > tuning.maximumMeanLuminance { reasons.append(.tooBright) }
    if metrics.clippedHighlightRatio > tuning.maximumClippedHighlightRatio {
      reasons.append(.glare)
    }
    let hasMotionProblem =
      metrics.motion.map {
        $0 > Tuning.maximumMotion
          || ($0 > tuning.maximumStableMotion
            && metrics.sharpness < Tuning.minimumSharpnessDuringMotion)
      } ?? false
    if hasMotionProblem {
      reasons.append(.holdSteady)
    }
    if metrics.sharpness < tuning.minimumSharpness { reasons.append(.softFocus) }

    return assessment(reasons: reasons, previousStableFrameCount: previousStableFrameCount)
  }

  private func assessment(
    reasons: [DocumentCaptureQualityAssessment.BlockingReason],
    previousStableFrameCount: Int
  ) -> DocumentCaptureQualityAssessment {
    guard reasons.isEmpty else {
      return DocumentCaptureQualityAssessment(
        ready: false,
        blockingReasons: reasons,
        stableFrameCount: 0
      )
    }

    let stableFrameCount = min(previousStableFrameCount + 1, requiredStableFrameCount)
    let ready = stableFrameCount >= requiredStableFrameCount
    return DocumentCaptureQualityAssessment(
      ready: ready,
      blockingReasons: ready ? [] : [.stabilizing],
      stableFrameCount: stableFrameCount
    )
  }
}
