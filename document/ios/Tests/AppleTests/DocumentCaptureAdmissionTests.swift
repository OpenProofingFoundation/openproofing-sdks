import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

// swift-format and SwiftLint intentionally disagree on multiline collection commas.
// swiftlint:disable trailing_comma

@Test
func requiredGateAdmitsOnlyReadyQuality() {
  let policy = DocumentCaptureAdmissionPolicy()

  #expect(
    policy.failure(
      in: .init(
        isConfigured: true,
        isRunning: true,
        isCaptureInFlight: false,
        isGuideAvailable: true,
        currentGeometryRevision: 7,
        observation: observation(ready: true, geometryRevision: 7),
        qualityGate: .required,
        admissionTime: admissionTime()
      )) == nil
  )
  #expect(
    policy.failure(
      in: .init(
        isConfigured: true,
        isRunning: true,
        isCaptureInFlight: false,
        isGuideAvailable: true,
        currentGeometryRevision: 7,
        observation: observation(ready: false, geometryRevision: 7),
        qualityGate: .required,
        admissionTime: admissionTime()
      )) == .captureQualityNotReady
  )
}

@Test
func operatorInitiatedAdvisorySkipsOnlyQualityPredicate() {
  let policy = DocumentCaptureAdmissionPolicy()

  #expect(
    policy.failure(
      in: .init(
        isConfigured: true,
        isRunning: true,
        isCaptureInFlight: false,
        isGuideAvailable: true,
        currentGeometryRevision: 7,
        observation: observation(ready: false, geometryRevision: 7),
        qualityGate: .operatorInitiatedAdvisory,
        admissionTime: admissionTime()
      )) == nil
  )
  #expect(
    policy.failure(
      in: .init(
        isConfigured: true,
        isRunning: true,
        isCaptureInFlight: false,
        isGuideAvailable: true,
        currentGeometryRevision: 7,
        observation: nil,
        qualityGate: .operatorInitiatedAdvisory,
        admissionTime: admissionTime()
      )) == .captureObservationUnavailable
  )
}

@Test
func contentDrivenGateRequiresTheExactTriggerObservation() {
  let policy = DocumentCaptureAdmissionPolicy()
  let current = observation(ready: false, geometryRevision: 7)
  let matchingIdentity = DocumentCaptureObservationIdentity(observation: current)

  #expect(
    policy.failure(
      in: .init(
        isConfigured: true,
        isRunning: true,
        isCaptureInFlight: false,
        isGuideAvailable: true,
        currentGeometryRevision: 7,
        observation: current,
        qualityGate: .contentDrivenAutoCapture,
        requiredObservationIdentity: matchingIdentity,
        admissionTime: admissionTime()
      )) == nil
  )

  for identity in [
    nil,
    DocumentCaptureObservationIdentity(
      observation: observation(ready: false, geometryRevision: 7, sequence: 8)
    ),
    DocumentCaptureObservationIdentity(
      observation: observation(ready: false, geometryRevision: 8)
    ),
  ] {
    #expect(
      policy.failure(
        in: .init(
          isConfigured: true,
          isRunning: true,
          isCaptureInFlight: false,
          isGuideAvailable: true,
          currentGeometryRevision: 7,
          observation: current,
          qualityGate: .contentDrivenAutoCapture,
          requiredObservationIdentity: identity,
          admissionTime: admissionTime()
        )) == .captureObservationUnavailable
    )
  }
}

@Test
func contentDrivenGateRevalidatesContentOnTheSessionAuthority() {
  let policy = DocumentCaptureAdmissionPolicy()
  let empty = observation(
    ready: false,
    geometryRevision: 7,
    liveContent: .empty
  )

  #expect(
    policy.failure(
      in: .init(
        isConfigured: true,
        isRunning: true,
        isCaptureInFlight: false,
        isGuideAvailable: true,
        currentGeometryRevision: 7,
        observation: empty,
        qualityGate: .contentDrivenAutoCapture,
        requiredObservationIdentity: DocumentCaptureObservationIdentity(observation: empty),
        admissionTime: admissionTime()
      )) == .captureObservationUnavailable
  )
}

@Test
func allGateModesAdmitValidObservation() {
  let policy = DocumentCaptureAdmissionPolicy()
  let current = observation(ready: true, geometryRevision: 7)

  for gate in allGateModes {
    #expect(
      policy.failure(
        in: .init(
          isConfigured: true,
          isRunning: true,
          isCaptureInFlight: false,
          isGuideAvailable: true,
          currentGeometryRevision: 7,
          observation: current,
          qualityGate: gate,
          requiredObservationIdentity: DocumentCaptureObservationIdentity(observation: current),
          admissionTime: admissionTime()
        )) == nil
    )
  }
}

@Test
func allGateModesPreserveLifecycleAndConcurrencyGuards() {
  let policy = DocumentCaptureAdmissionPolicy()
  let current = observation(ready: true, geometryRevision: 7)
  let lifecycleFailures = [
    (configured: false, running: true, inFlight: false),
    (configured: true, running: false, inFlight: false),
    (configured: true, running: true, inFlight: true),
  ]

  for gate in allGateModes {
    for failure in lifecycleFailures {
      #expect(
        policy.failure(
          in: .init(
            isConfigured: failure.configured,
            isRunning: failure.running,
            isCaptureInFlight: failure.inFlight,
            isGuideAvailable: true,
            currentGeometryRevision: 7,
            observation: current,
            qualityGate: gate,
            requiredObservationIdentity: DocumentCaptureObservationIdentity(observation: current),
            admissionTime: admissionTime()
          )) == .cameraNotReady
      )
    }
  }
}

@Test
func allGateModesPreserveGuideAndGeometryGuards() {
  let policy = DocumentCaptureAdmissionPolicy()
  let current = observation(ready: true, geometryRevision: 7)

  for gate in allGateModes {
    #expect(
      policy.failure(
        in: .init(
          isConfigured: true,
          isRunning: true,
          isCaptureInFlight: false,
          isGuideAvailable: false,
          currentGeometryRevision: 7,
          observation: current,
          qualityGate: gate,
          requiredObservationIdentity: DocumentCaptureObservationIdentity(observation: current),
          admissionTime: admissionTime()
        )) == .captureGuideUnavailable
    )
    #expect(
      policy.failure(
        in: .init(
          isConfigured: true,
          isRunning: true,
          isCaptureInFlight: false,
          isGuideAvailable: true,
          currentGeometryRevision: 8,
          observation: current,
          qualityGate: gate,
          requiredObservationIdentity: DocumentCaptureObservationIdentity(observation: current),
          admissionTime: admissionTime()
        )) == .captureObservationUnavailable
    )
  }
}

@Test
func allGateModesRejectMissingStaleAndFutureObservations() {
  let policy = DocumentCaptureAdmissionPolicy()
  let staleObservation = observation(
    ready: true,
    geometryRevision: 7,
    timestamp: Date(timeIntervalSince1970: 99.849)
  )
  let futureObservation = observation(
    ready: true,
    geometryRevision: 7,
    timestamp: Date(timeIntervalSince1970: 100.101)
  )

  for gate in allGateModes {
    for unavailableObservation in [nil, staleObservation, futureObservation] {
      #expect(
        policy.failure(
          in: .init(
            isConfigured: true,
            isRunning: true,
            isCaptureInFlight: false,
            isGuideAvailable: true,
            currentGeometryRevision: 7,
            observation: unavailableObservation,
            qualityGate: gate,
            requiredObservationIdentity: unavailableObservation.map(
              DocumentCaptureObservationIdentity.init),
            admissionTime: admissionTime()
          )) == .captureObservationUnavailable
      )
    }
  }
}

@Test
func admissionSnapshotBindsAttemptAndExcludesPreviewBytes() throws {
  let sessionID = CaptureSessionID()
  let attemptID = UUID()
  let userRequestedAt = Date(timeIntervalSince1970: 100)
  let admittedAt = Date(timeIntervalSince1970: 100.125)
  let currentObservation = observation(
    ready: false,
    geometryRevision: 7,
    timestamp: Date(timeIntervalSince1970: 100.025),
    previewJPEGData: Data([0xDE, 0xAD, 0xBE, 0xEF])
  )
  let request = CameraPhotoCaptureRequest(
    sessionID: sessionID,
    side: .back,
    qualityGate: .operatorInitiatedAdvisory,
    attemptID: attemptID,
    userRequestedAt: userRequestedAt
  )

  let snapshot = DocumentCaptureAdmissionSnapshot(
    request: request,
    admittedAt: admittedAt,
    photoSettingsUniqueID: 42,
    observation: currentObservation
  )

  #expect(snapshot.attemptID == attemptID)
  #expect(snapshot.schemaVersion == 4)
  #expect(snapshot.qualityGate == .operatorInitiatedAdvisory)
  #expect(snapshot.queueLatencyMilliseconds == 125)
  #expect(snapshot.observationAgeMilliseconds == 100)
  #expect(snapshot.observation?.sequence == currentObservation.sequence)
  #expect(snapshot.observation?.assessment == currentObservation.assessment)
  #expect(snapshot.observation?.liveContent == currentObservation.liveContent)

  let encoded = try JSONEncoder().encode(snapshot)
  let encodedJSON = try #require(String(data: encoded, encoding: .utf8))
  #expect(!encodedJSON.contains(Data([0xDE, 0xAD, 0xBE, 0xEF]).base64EncodedString()))
}

private func admissionTime() -> Date {
  Date(timeIntervalSince1970: 100.1)
}

private let allGateModes: [DocumentCaptureQualityGate] = [
  .required,
  .operatorInitiatedAdvisory,
  .contentDrivenAutoCapture,
  .qualityDrivenAutoCapture,
]

private func observation(
  ready: Bool,
  geometryRevision: UInt64,
  sequence: UInt64 = 9,
  timestamp: Date = Date(timeIntervalSince1970: 100),
  previewJPEGData: Data? = nil,
  liveContent: DocumentLiveContentMetrics = DocumentLiveContentMetrics(
    recognizedTextLineCount: 8,
    recognizedCharacterCount: 80,
    decodedPDF417Count: 0,
    decodedPDF417CharacterCount: 0
  )
) -> DocumentCaptureQualityObservation {
  DocumentCaptureQualityObservation(
    sequence: sequence,
    geometryRevision: geometryRevision,
    timestamp: timestamp,
    metrics: DocumentCaptureQualityMetrics(
      documentFillRatio: 0.4,
      documentGuideFillRatio: 0.7,
      documentInsideGuide: true,
      guideCenterX: 0.5,
      guideCenterY: 0.5,
      guideWidth: 0.6,
      guideHeight: 0.38,
      documentAspectRatio: 1.586,
      sharpness: 0.08,
      motion: 0.1,
      clippedHighlightRatio: 0.01,
      meanLuminance: 0.55,
      documentCenterX: 0.5,
      documentCenterY: 0.5
    ),
    assessment: DocumentCaptureQualityAssessment(
      ready: ready,
      blockingReasons: ready ? [] : [.holdSteady],
      stableFrameCount: ready ? 4 : 0
    ),
    previewJPEGData: previewJPEGData,
    liveContent: liveContent,
    cameraControl: DocumentCameraControlSnapshot(
      sampledAt: timestamp,
      zoomFactor: 1,
      adjustingFocus: false,
      adjustingExposure: false,
      rampingZoom: false,
      settled: true
    )
  )
}

// swiftlint:enable trailing_comma
