#if os(iOS)
  import Foundation
  import DocumentSDK
  import XCTest

  @testable import DocumentCapture
  @testable import DocumentCaptureApple

  @MainActor
  final class PassportCardCaptureAdmissionTests: XCTestCase {
    func testBackCanCaptureWithoutLiveMRZButStillRequiresQualityAndSettledCamera() {
      var coordinator = CaptureSession.makeCoordinator(profile: .passportCardBack, tuning: .init())
      coordinator.begin(side: .back)
      XCTAssertEqual(coordinator.contentTarget, .passportCardMRZ)
      XCTAssertEqual(
        coordinator.observe(
          side: .back,
          observation: observation(sequence: 1, ready: false, settled: true)), .observing)
      XCTAssertEqual(
        coordinator.observe(
          side: .back,
          observation: observation(sequence: 2, ready: true, settled: false)), .observing)
      XCTAssertEqual(
        coordinator.observe(
          side: .back,
          observation: observation(sequence: 3, ready: true, settled: true)), .trigger(attempt: 1))
    }

    private func observation(sequence: UInt64, ready: Bool, settled: Bool)
      -> DocumentCaptureQualityObservation
    {
      DocumentCaptureQualityObservation(
        sequence: sequence, geometryRevision: 1,
        timestamp: Date(timeIntervalSince1970: Double(sequence) / 5),
        metrics: DocumentCaptureQualityMetrics(
          documentFillRatio: nil,
          documentGuideFillRatio: nil, documentInsideGuide: nil,
          guideCenterX: nil, guideCenterY: nil, guideWidth: nil, guideHeight: nil,
          documentAspectRatio: nil, sharpness: 0, motion: nil,
          clippedHighlightRatio: 0, meanLuminance: 0.5,
          documentCenterX: nil, documentCenterY: nil),
        assessment: DocumentCaptureQualityAssessment(
          ready: ready,
          blockingReasons: ready ? [] : [.softFocus], stableFrameCount: ready ? 3 : 0),
        liveContent: .empty,
        cameraControl: DocumentCameraControlSnapshot(
          sampledAt: Date(), zoomFactor: 1,
          adjustingFocus: !settled, adjustingExposure: false,
          rampingZoom: false, settled: settled))
    }
  }

#endif
