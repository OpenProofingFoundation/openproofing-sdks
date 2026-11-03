import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

@Test
func frontTriggersAfterConsecutiveReadableObservationsWithoutRectangleAuthority() {
  var coordinator = DocumentAutoCaptureCoordinator()
  coordinator.begin(side: .front)

  #expect(coordinator.observe(side: .front, observation: observation(sequence: 1)) == .observing)
  #expect(
    coordinator.observe(side: .front, observation: observation(sequence: 2))
      == .trigger(attempt: 1)
  )
}

@Test
func backTriggersFromPDF417AndNotFromFrontText() {
  var coordinator = DocumentAutoCaptureCoordinator()
  coordinator.begin(side: .back)

  #expect(coordinator.observe(side: .back, observation: observation(sequence: 1)) == .observing)
  #expect(
    coordinator.observe(
      side: .back,
      observation: observation(sequence: 2, pdf417Characters: 321)
    ) == .trigger(attempt: 1)
  )
}

@Test
func frontDoesNotTriggerFromThePDF417BackSide() {
  var coordinator = DocumentAutoCaptureCoordinator()
  coordinator.begin(side: .front)

  #expect(
    coordinator.observe(
      side: .front,
      observation: observation(sequence: 1, pdf417Characters: 321)
    ) == .observing
  )
  #expect(
    coordinator.observe(
      side: .front,
      observation: observation(sequence: 2, pdf417Characters: 321)
    ) == .observing
  )
}

@Test
func geometryAndSequenceDiscontinuitiesResetTemporalConfirmation() {
  var coordinator = DocumentAutoCaptureCoordinator()
  coordinator.begin(side: .front)

  #expect(coordinator.observe(side: .front, observation: observation(sequence: 1)) == .observing)
  #expect(coordinator.observe(side: .front, observation: observation(sequence: 3)) == .observing)
  #expect(coordinator.observe(side: .front, observation: observation(sequence: 4)) == .observing)
  #expect(
    coordinator.observe(side: .front, observation: observation(sequence: 5))
      == .trigger(attempt: 1)
  )

  coordinator.begin(side: .front)
  #expect(coordinator.observe(side: .front, observation: observation(sequence: 6)) == .observing)
  #expect(
    coordinator.observe(
      side: .front,
      observation: observation(sequence: 7, geometryRevision: 2)
    ) == .observing
  )
}

@Test
func failedCapturesRetryButStopAtBoundedAttemptCount() {
  var coordinator = DocumentAutoCaptureCoordinator(
    maximumAttemptsPerSide: 2,
    frontRequiredConsecutiveObservations: 1
  )
  coordinator.begin(side: .front)

  #expect(
    coordinator.observe(side: .front, observation: observation(sequence: 1))
      == .trigger(attempt: 1)
  )
  #expect(coordinator.captureCompleted(usable: false) == .observing)
  #expect(
    coordinator.observe(side: .front, observation: observation(sequence: 2))
      == .trigger(attempt: 2)
  )
  #expect(coordinator.captureCompleted(usable: false) == .exhausted)
  #expect(coordinator.observe(side: .front, observation: observation(sequence: 3)) == .exhausted)
}

@Test
func wrongSideAndInFlightObservationsCannotDuplicateCapture() {
  var coordinator = DocumentAutoCaptureCoordinator(frontRequiredConsecutiveObservations: 1)
  coordinator.begin(side: .front)

  #expect(coordinator.observe(side: .back, observation: observation(sequence: 1)) == .observing)
  #expect(
    coordinator.observe(side: .front, observation: observation(sequence: 1))
      == .trigger(attempt: 1)
  )
  #expect(coordinator.observe(side: .front, observation: observation(sequence: 2)) == .observing)
}

@Test
func adjacentSequencesSeparatedByAStallDoNotConfirmTheFront() {
  var coordinator = DocumentAutoCaptureCoordinator(
    maxConfirmationIntervalMilliseconds: 500
  )
  coordinator.begin(side: .front)

  #expect(
    coordinator.observe(
      side: .front,
      observation: observation(sequence: 1, timestamp: Date(timeIntervalSince1970: 1))
    ) == .observing
  )
  #expect(
    coordinator.observe(
      side: .front,
      observation: observation(sequence: 2, timestamp: Date(timeIntervalSince1970: 2))
    ) == .observing
  )
  #expect(
    coordinator.observe(
      side: .front,
      observation: observation(sequence: 3, timestamp: Date(timeIntervalSince1970: 2.2))
    ) == .trigger(attempt: 1)
  )
}

private func observation(
  sequence: UInt64,
  geometryRevision: UInt64 = 1,
  textLines: Int = 8,
  textCharacters: Int = 80,
  pdf417Characters: Int = 0,
  timestamp: Date? = nil
) -> DocumentCaptureQualityObservation {
  DocumentCaptureQualityObservation(
    sequence: sequence,
    geometryRevision: geometryRevision,
    timestamp: timestamp ?? Date(timeIntervalSince1970: Double(sequence) / 5),
    metrics: DocumentCaptureQualityMetrics(
      documentFillRatio: nil,
      documentGuideFillRatio: nil,
      documentInsideGuide: nil,
      guideCenterX: 0.5,
      guideCenterY: 0.5,
      guideWidth: 0.6,
      guideHeight: 0.38,
      documentAspectRatio: nil,
      sharpness: 0,
      motion: nil,
      clippedHighlightRatio: 0,
      meanLuminance: 0.5,
      documentCenterX: nil,
      documentCenterY: nil
    ),
    assessment: DocumentCaptureQualityAssessment(
      ready: false,
      blockingReasons: [.documentNotFound],
      stableFrameCount: 0
    ),
    liveContent: DocumentLiveContentMetrics(
      recognizedTextLineCount: textLines,
      recognizedCharacterCount: textCharacters,
      decodedPDF417Count: pdf417Characters > 0 ? 1 : 0,
      decodedPDF417CharacterCount: pdf417Characters
    )
  )
}
