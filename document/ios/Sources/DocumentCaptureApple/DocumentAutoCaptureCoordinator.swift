import Foundation
import DocumentSDK

struct DocumentAutoCaptureContentPolicy: Equatable, Sendable {
  private typealias Tuning = DocumentCaptureTuning.Readability
  func hasUsableSignal(
    for side: DocumentSide,
    metrics: DocumentLiveContentMetrics,
    target: DocumentLiveContentTarget? = nil
  ) -> Bool {
    if let target {
      switch target {
      case .passportMRZ, .passportCardMRZ: return metrics.mrzCandidateCount == 1
      case .licensePDF417:
        return metrics.decodedPDF417Count == 1
          && metrics.decodedPDF417CharacterCount >= Tuning.minimumPDF417Characters
      case .documentText: break
      }
    }
    return switch side {
    case .front:
      metrics.recognizedTextLineCount >= Tuning.minimumTextLines
        && metrics.recognizedCharacterCount >= Tuning.minimumTextCharacters
        && metrics.decodedPDF417Count == 0
    case .back:
      metrics.decodedPDF417Count > 0
        && metrics.decodedPDF417CharacterCount >= Tuning.minimumPDF417Characters
    }
  }
}

/// Observation-driven auto-capture policy adapted from the bounded temporal
/// confirmation patterns in YesWeScan and OpenScanner. It owns no camera or UI.
public struct DocumentAutoCaptureCoordinator: Equatable, Sendable {
  public enum Decision: Equatable, Sendable {
    case observing
    case trigger(attempt: Int)
    case exhausted
  }

  public let requireQualityReadiness: Bool
  public let requiresContentSignal: Bool
  public let contentTarget: DocumentLiveContentTarget?
  public let maximumAttemptsPerSide: Int
  public let frontRequiredConsecutiveObservations: Int
  public let backRequiredConsecutiveObservations: Int
  public let maxConfirmationIntervalMilliseconds: Int

  private var activeSide: DocumentSide?
  private var geometryRevision: UInt64?
  private var lastSequence: UInt64?
  private var consecutivePositiveObservations = 0
  private var attempts = 0
  private var captureInFlight = false
  private var sideAccepted = false
  private let contentPolicy = DocumentAutoCaptureContentPolicy()
  private var lastPositiveObservationTimestamp: Date?

  public init(
    requireQualityReadiness: Bool = false,
    requiresContentSignal: Bool = true,
    contentTarget: DocumentLiveContentTarget? = nil,
    maximumAttemptsPerSide: Int = DocumentCaptureTuning.AutoCapture.defaultMaximumAttemptsPerSide,
    frontRequiredConsecutiveObservations: Int = DocumentCaptureTuning.AutoCapture
      .frontRequiredObservations,
    backRequiredConsecutiveObservations: Int = DocumentCaptureTuning.AutoCapture
      .backRequiredObservations,
    maxConfirmationIntervalMilliseconds: Int = DocumentCaptureTuning.AutoCapture
      .maximumConfirmationIntervalMilliseconds
  ) {
    self.requireQualityReadiness = requireQualityReadiness
    self.requiresContentSignal = requiresContentSignal
    self.contentTarget = contentTarget
    self.maximumAttemptsPerSide = max(maximumAttemptsPerSide, 1)
    self.frontRequiredConsecutiveObservations = max(frontRequiredConsecutiveObservations, 1)
    self.backRequiredConsecutiveObservations = max(backRequiredConsecutiveObservations, 1)
    self.maxConfirmationIntervalMilliseconds = max(
      maxConfirmationIntervalMilliseconds,
      1
    )
  }

  public mutating func begin(side: DocumentSide) {
    activeSide = side
    geometryRevision = nil
    lastSequence = nil
    consecutivePositiveObservations = 0
    lastPositiveObservationTimestamp = nil
    attempts = 0
    captureInFlight = false
    sideAccepted = false
    lastPositiveObservationTimestamp = nil
  }

  public mutating func observe(
    side: DocumentSide,
    observation: DocumentCaptureQualityObservation
  ) -> Decision {
    guard activeSide == side, !captureInFlight, !sideAccepted else { return .observing }
    guard attempts < maximumAttemptsPerSide else { return .exhausted }

    if geometryRevision != observation.geometryRevision {
      geometryRevision = observation.geometryRevision
      lastSequence = nil
      consecutivePositiveObservations = 0
      lastPositiveObservationTimestamp = nil
    }

    guard lastSequence.map({ observation.sequence == $0 + 1 }) ?? true else {
      lastSequence = observation.sequence
      consecutivePositiveObservations = 0
      lastPositiveObservationTimestamp = nil
      return .observing
    }
    lastSequence = observation.sequence

    let qualityReady =
      !requireQualityReadiness
      || (observation.assessment.ready && observation.cameraControl?.settled == true)
    let contentReady =
      !requiresContentSignal
      || contentPolicy.hasUsableSignal(
        for: side, metrics: observation.liveContent, target: contentTarget)
    guard qualityReady && contentReady else {
      consecutivePositiveObservations = 0
      lastPositiveObservationTimestamp = nil
      return .observing
    }

    if let lastPositiveObservationTimestamp {
      let elapsedMilliseconds = Int(
        (observation.timestamp.timeIntervalSince(lastPositiveObservationTimestamp) * 1_000)
          .rounded()
      )
      if !(1...maxConfirmationIntervalMilliseconds).contains(
        elapsedMilliseconds
      ) {
        consecutivePositiveObservations = 0
      }
    }
    lastPositiveObservationTimestamp = observation.timestamp
    consecutivePositiveObservations += 1
    let requiredCount =
      side == .front
      ? frontRequiredConsecutiveObservations
      : backRequiredConsecutiveObservations
    guard consecutivePositiveObservations >= requiredCount else { return .observing }

    attempts += 1
    captureInFlight = true
    consecutivePositiveObservations = 0
    lastPositiveObservationTimestamp = nil
    return .trigger(attempt: attempts)
  }

  public mutating func captureCompleted(usable: Bool) -> Decision {
    guard captureInFlight else { return .observing }
    captureInFlight = false
    sideAccepted = usable
    lastSequence = nil
    consecutivePositiveObservations = 0
    if usable { return .observing }
    return attempts >= maximumAttemptsPerSide ? .exhausted : .observing
  }
}
