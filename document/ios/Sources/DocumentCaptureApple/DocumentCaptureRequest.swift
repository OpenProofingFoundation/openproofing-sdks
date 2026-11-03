import Foundation
import DocumentSDK

/// Declares whether the caller requires the provisional live-quality policy to
/// authorize a still request. The advisory case exists for controlled capture
/// calibration; it is not a document-validation or assurance decision.
public enum DocumentCaptureQualityGate: String, Codable, Equatable, Sendable {
  case required
  case livePDF417AutoCapture
  case operatorInitiatedAdvisory
  case contentDrivenAutoCapture
  case qualityDrivenAutoCapture
}

public struct DocumentCaptureRequest: Equatable, Sendable {
  public let side: DocumentSide
  public let qualityGate: DocumentCaptureQualityGate
  public let requiredObservationIdentity: DocumentCaptureObservationIdentity?
  public let attemptID: UUID
  /// Live metadata candidate; the native controller must independently bind this value.
  public let livePDF417Candidate: String?
  /// Optional host-supplied location to bind to this capture.
  ///
  /// Nil, the default, writes no location and requests no permissionState. The
  /// SDK never reads device location itself: a host that wants one owns the
  /// permission prompt, its usage description, and its privacy declaration.
  public let locationAssertion: CaptureLocationAssertion?

  public init(
    side: DocumentSide,
    qualityGate: DocumentCaptureQualityGate = .required,
    requiredObservationIdentity: DocumentCaptureObservationIdentity? = nil,
    attemptID: UUID = UUID(),
    livePDF417Candidate: String? = nil,
    locationAssertion: CaptureLocationAssertion? = nil
  ) {
    self.side = side
    self.qualityGate = qualityGate
    self.requiredObservationIdentity = requiredObservationIdentity
    self.attemptID = attemptID
    self.livePDF417Candidate = livePDF417Candidate
    self.locationAssertion = locationAssertion
  }
}

struct CameraPhotoCaptureRequest: Equatable, Sendable {
  let sessionID: CaptureSessionID
  let side: DocumentSide
  let qualityGate: DocumentCaptureQualityGate
  let requiredObservationIdentity: DocumentCaptureObservationIdentity?
  let attemptID: UUID
  let userRequestedAt: Date
  let livePDF417Candidate: String?
  let locationAssertion: CaptureLocationAssertion?

  init(
    sessionID: CaptureSessionID,
    side: DocumentSide,
    qualityGate: DocumentCaptureQualityGate,
    requiredObservationIdentity: DocumentCaptureObservationIdentity? = nil,
    attemptID: UUID,
    userRequestedAt: Date,
    livePDF417Candidate: String? = nil,
    locationAssertion: CaptureLocationAssertion? = nil
  ) {
    self.sessionID = sessionID
    self.side = side
    self.qualityGate = qualityGate
    self.requiredObservationIdentity = requiredObservationIdentity
    self.attemptID = attemptID
    self.userRequestedAt = userRequestedAt
    self.livePDF417Candidate = livePDF417Candidate
    self.locationAssertion = locationAssertion
  }
}

/// What the serial camera owner observed and admitted immediately before it
/// submitted one AVCapturePhoto request. `admittedAt` is request time, not the
/// sensor exposure time.
public struct DocumentCaptureAdmissionSnapshot: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let attemptID: UUID
  public let sessionID: CaptureSessionID
  public let side: DocumentSide
  public let qualityGate: DocumentCaptureQualityGate
  public let userRequestedAt: Date
  public let admittedAt: Date
  public let queueLatencyMilliseconds: Int
  public let photoSettingsUniqueID: Int64
  public let observationAgeMilliseconds: Int?
  public let observation: DocumentCaptureObservationSnapshot?
  public let nativeCaptureDeviceGuideRegion: DocumentCameraGuideRegion?
  public let captureOrientation: DocumentCameraOrientation?
  /// Native readback at admission, not an assertion of the still's exclusive sensor.
  public let nativeCamera: DocumentCameraNativeSnapshot?

  init(
    request: CameraPhotoCaptureRequest,
    admittedAt: Date,
    photoSettingsUniqueID: Int64,
    observation: DocumentCaptureQualityObservation?,
    nativeCaptureDeviceGuideRegion: DocumentCameraGuideRegion? = nil,
    captureOrientation: DocumentCameraOrientation? = nil,
    nativeCamera: DocumentCameraNativeSnapshot? = nil
  ) {
    schemaVersion = 4
    attemptID = request.attemptID
    sessionID = request.sessionID
    side = request.side
    qualityGate = request.qualityGate
    userRequestedAt = request.userRequestedAt
    self.admittedAt = admittedAt
    queueLatencyMilliseconds = Self.milliseconds(from: request.userRequestedAt, to: admittedAt)
    self.photoSettingsUniqueID = photoSettingsUniqueID
    observationAgeMilliseconds = observation.map {
      DocumentCaptureObservationFreshness.ageMilliseconds(of: $0, at: admittedAt)
    }
    self.observation = observation.map(DocumentCaptureObservationSnapshot.init(observation:))
    self.nativeCaptureDeviceGuideRegion = nativeCaptureDeviceGuideRegion
    self.captureOrientation = captureOrientation
    self.nativeCamera = nativeCamera
  }

  private static func milliseconds(from start: Date, to end: Date) -> Int {
    max(Int((end.timeIntervalSince(start) * 1_000).rounded()), 0)
  }
}

struct DocumentCaptureAdmissionPolicy: Sendable {
  private let contentPolicy = DocumentAutoCaptureContentPolicy()

  struct Context: Sendable {
    let isConfigured: Bool
    let isRunning: Bool
    let isCaptureInFlight: Bool
    let isGuideAvailable: Bool
    let currentGeometryRevision: UInt64?
    let observation: DocumentCaptureQualityObservation?
    let side: DocumentSide
    let qualityGate: DocumentCaptureQualityGate
    let requiredObservationIdentity: DocumentCaptureObservationIdentity?
    let admissionTime: Date

    init(
      isConfigured: Bool,
      isRunning: Bool,
      isCaptureInFlight: Bool,
      isGuideAvailable: Bool,
      currentGeometryRevision: UInt64?,
      observation: DocumentCaptureQualityObservation?,
      side: DocumentSide = .front,
      qualityGate: DocumentCaptureQualityGate,
      requiredObservationIdentity: DocumentCaptureObservationIdentity? = nil,
      admissionTime: Date
    ) {
      self.isConfigured = isConfigured
      self.isRunning = isRunning
      self.isCaptureInFlight = isCaptureInFlight
      self.isGuideAvailable = isGuideAvailable
      self.currentGeometryRevision = currentGeometryRevision
      self.observation = observation
      self.side = side
      self.qualityGate = qualityGate
      self.requiredObservationIdentity = requiredObservationIdentity
      self.admissionTime = admissionTime
    }
  }

  func failure(in context: Context) -> PhotoCaptureError? {
    guard context.isConfigured, context.isRunning, !context.isCaptureInFlight else {
      return .cameraNotReady
    }
    if context.qualityGate == .livePDF417AutoCapture {
      return context.side == .back ? nil : .captureObservationUnavailable
    }
    guard context.isGuideAvailable else {
      return .captureGuideUnavailable
    }

    guard let observation = context.observation else {
      return .captureObservationUnavailable
    }
    guard observation.geometryRevision == context.currentGeometryRevision else {
      return .captureObservationUnavailable
    }
    guard DocumentCaptureObservationFreshness.fresh(observation, at: context.admissionTime) else {
      return .captureObservationUnavailable
    }

    return qualityFailure(in: context, observation: observation)
  }

  private func qualityFailure(in context: Context, observation: DocumentCaptureQualityObservation)
    -> PhotoCaptureError? {
    switch context.qualityGate {
    case .required:
      guard observation.assessment.ready else {
        return .captureQualityNotReady
      }
    case .qualityDrivenAutoCapture:
      guard let identity = context.requiredObservationIdentity, identity.matches(observation),
        observation.assessment.ready, observation.cameraControl?.settled == true
      else { return .captureQualityNotReady }
    case .livePDF417AutoCapture:
      return .captureObservationUnavailable // handled before document observations
    case .operatorInitiatedAdvisory:
      break
    case .contentDrivenAutoCapture:
      guard
        let requiredIdentity = context.requiredObservationIdentity,
        requiredIdentity.matches(observation),
        contentPolicy.hasUsableSignal(for: context.side, metrics: observation.liveContent)
      else {
        return .captureObservationUnavailable
      }
    }
    return nil
  }
}
