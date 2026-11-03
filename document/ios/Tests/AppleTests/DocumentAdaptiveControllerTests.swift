import Foundation
import Testing

@testable import DocumentCaptureApple

@Test func missingDocumentDoesNotTouchCameraOrReplenishFocusBudget() {
  let rig = AdaptiveRig()
  for index in 0..<100 { _ = rig.frame(index, detected: false, soft: true) }
  #expect(rig.device.focusPoints.isEmpty)
  #expect(rig.device.zooms.isEmpty)
  for index in 100..<140 { _ = rig.frame(index, soft: true) }
  #expect(rig.device.focusPoints.count == 3)
  for index in 140..<150 { _ = rig.frame(index, detected: false, soft: true) }
  for index in 150..<180 { _ = rig.frame(index, soft: true) }
  #expect(rig.device.focusPoints.count == 3)
}

@Test func nativeFocusCompletionCanSettleWithoutAnotherModeCommand() {
  let rig = AdaptiveRig()
  #expect(rig.frame(0) == nil)
  #expect(rig.device.focusPoints.count == 1)
  rig.device.adjustingFocus = true
  for index in 1...20 {
    #expect(rig.frame(index)?.assessment.ready == false)
  }
  #expect(rig.device.focusPoints.count == 1)
  rig.device.adjustingFocus = false
  rig.device.focusMode = 0
  var last: DocumentCaptureQualityObservation?
  for index in 21...30 { last = rig.frame(index) }
  #expect(last?.assessment.ready == true)
  #expect(rig.device.focusPoints.count == 1)
  #expect(rig.device.snapshotCount == 32)
}

@Test func zoomWaitsForCompletionAndReacquiresOnlyPostZoomTarget() {
  let rig = AdaptiveRig()
  rig.bounds = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
  #expect(rig.frame(0) == nil)
  #expect(rig.device.zooms.count == 1)
  #expect(rig.device.focusPoints.isEmpty)
  rig.device.ramping = true
  for index in 1...20 { _ = rig.frame(index) }
  #expect(rig.device.zooms.count == 1)
  #expect(rig.device.focusPoints.isEmpty)
  rig.device.ramping = false
  rig.bounds = CGRect(x: 0.18, y: 0.18, width: 0.64, height: 0.64)
  #expect(rig.frame(21) == nil)
  #expect(rig.device.focusPoints == [CGPoint(x: 0.5, y: 0.5)])
}

@Test func explicitResetGetsNewBoundedAcquisitionAndUnsupportedFocusDoesNotCount() {
  let rig = AdaptiveRig()
  rig.device.supportsFocus = false
  #expect(rig.frame(0) != nil)
  #expect(rig.device.focusPoints.isEmpty)
  rig.device.supportsFocus = true
  rig.controller.reset()
  for index in 1...40 { _ = rig.frame(index, soft: true) }
  #expect(rig.device.focusPoints.count == 3)
  rig.point = CGPoint(x: 0.6, y: 0.5)
  rig.controller.reset()
  #expect(rig.frame(41, soft: true) == nil)
  #expect(rig.device.focusPoints.last == rig.point)
  #expect(rig.device.focusPoints.count == 4)
}

@Test func framingRespectsNativeMinimumWithoutCroppingForIt() {
  let guide = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
  let fits = DocumentAdaptiveFramingPolicy.coordinatedZoom(
    current: 1.5, maximum: 2, minimum: 1.5,
    document: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), guide: guide)
  #expect(fits.zoom > 1)
  #expect(!fits.needsReposition)
  let conflict = DocumentAdaptiveFramingPolicy.coordinatedZoom(
    current: 2, maximum: 2, minimum: 2,
    document: CGRect(x: 0.09, y: 0.1, width: 0.82, height: 0.8), guide: guide)
  #expect(conflict.needsReposition)
  #expect(conflict.zoom == 2)
}

@Test func outsideGuideTargetCanDriveZoomOutButCannotBecomeReady() {
  let rig = AdaptiveRig()
  rig.device.zoomFactor = 2
  rig.bounds = CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96)
  #expect(rig.frame(0) == nil)
  #expect(rig.device.zooms.first.map { $0 < 2 } == true)
  #expect(rig.device.focusPoints.isEmpty)
}

@Test func nativeCommandFailuresAreThrottledBoundedAndNeverReady() {
  for failingZoom in [false, true] {
    let rig = AdaptiveRig()
    rig.device.failCommands = true
    if failingZoom { rig.bounds = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4) }
    for index in 0..<100 {
      #expect(rig.frame(index)?.assessment.ready == false)
      if index < 3 { #expect(rig.device.commandAttempts == 1) }
    }
    #expect(rig.device.commandAttempts == 3)
    #expect(rig.device.focusPoints.isEmpty)
    #expect(rig.device.zooms.isEmpty)
  }
}

@Test func exposureAdjustmentDoesNotPreventTargetFocusRequest() {
  let rig = AdaptiveRig()
  rig.device.adjustingExposure = true
  #expect(rig.frame(0) == nil)
  #expect(rig.device.focusPoints.count == 1)
  rig.device.focusMode = 0
  for index in 1...20 { #expect(rig.frame(index)?.assessment.ready == false) }
  rig.device.adjustingExposure = false
  var last: DocumentCaptureQualityObservation?
  for index in 21...30 { last = rig.frame(index) }
  #expect(last?.assessment.ready == true)
}

@Test func idleNonlockedFocusRetriesThenReportsTerminalFailure() {
  let rig = AdaptiveRig()
  for index in 0...40 { _ = rig.frame(index) }
  #expect(rig.device.focusPoints.count == 3)
  let stopped = rig.frame(41)
  #expect(stopped?.cameraControl?.adaptiveFailureReason == "focusAttemptsExhausted")
  #expect(stopped?.assessment.ready == false)
  rig.device.focusMode = 0
  #expect(rig.frame(42)?.assessment.ready == false)
}

@Test func nativePointDriftReacquiresWithoutWaitingForBlur() {
  let rig = AdaptiveRig()
  _ = rig.frame(0)
  rig.device.focusMode = 0
  rig.device.focusPoint = CGPoint(x: 0.4, y: 0.4)
  for index in 1...8 { _ = rig.frame(index) }
  #expect(rig.device.focusPoints.count == 2)
  #expect(rig.device.focusPoint == rig.point)
  rig.device.focusMode = 0
  var last: DocumentCaptureQualityObservation?
  for index in 9...16 { last = rig.frame(index) }
  #expect(last?.assessment.ready == true)
}

@Test func acceptedNativePointNeedNotMatchRequestedFloatingPointBits() {
  let rig = AdaptiveRig()
  rig.device.pointOffset = 0.000001
  _ = rig.frame(0)
  rig.device.focusMode = 0
  var last: DocumentCaptureQualityObservation?
  for index in 1...12 { last = rig.frame(index) }
  #expect(rig.device.focusPoints.count == 1)
  #expect(last?.assessment.ready == true)
}

@Test func nativeAdjustmentDeadlineNeverInfersSuccess() {
  for zoom in [false, true] {
    let rig = AdaptiveRig()
    if zoom { rig.bounds = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4) }
    _ = rig.frame(0)
    rig.device.ramping = zoom
    rig.device.adjustingFocus = !zoom
    var last: DocumentCaptureQualityObservation?
    for index in 1...50 { last = rig.frame(index) }
    #expect(last?.assessment.ready == false)
    #expect(last?.cameraControl?.adaptiveFailureReason == "nativeAdjustmentTimedOut")
    #expect(rig.device.commandAttempts == 1)
  }
}

@Test func lockedModeWithPendingFocusAdjustmentStillTimesOut() {
  let rig = AdaptiveRig()
  _ = rig.frame(0)
  rig.device.focusMode = 0
  rig.device.adjustingFocus = true
  var last: DocumentCaptureQualityObservation?
  for index in 1...50 { last = rig.frame(index) }
  #expect(last?.assessment.ready == false)
  #expect(last?.cameraControl?.adaptiveFailureReason == "nativeAdjustmentTimedOut")
  #expect(rig.device.commandAttempts == 1)
}

@Test func completedFocusDoesNotTimeOutContinuousExposureAdjustment() {
  let rig = AdaptiveRig()
  _ = rig.frame(0)
  rig.device.focusMode = 0
  rig.device.adjustingExposure = true
  for index in 1...60 {
    let value = rig.frame(index)
    #expect(value?.assessment.ready == false)
    #expect(value?.cameraControl?.adaptiveFailureReason == nil)
  }
  rig.device.adjustingExposure = false
  var last: DocumentCaptureQualityObservation?
  for index in 61...70 { last = rig.frame(index) }
  #expect(last?.assessment.ready == true)
  #expect(rig.device.commandAttempts == 1)
}

@Test func completedZoomDoesNotTimeOutLaterUnrelatedNativeAdjustments() {
  let rig = AdaptiveRig()
  rig.device.zoomFactor = 1.1349
  rig.bounds = CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96)
  #expect(rig.frame(0) == nil)
  #expect(rig.device.zooms.count == 1)
  rig.device.ramping = true
  _ = rig.frame(1, detected: false)
  rig.device.ramping = false
  _ = rig.frame(2, detected: false)
  for index in 3...60 {
    rig.device.adjustingFocus = index.isMultiple(of: 2)
    rig.device.adjustingExposure = true
    let value = rig.frame(index, detected: false)
    #expect(value?.assessment.ready == false)
    #expect(value?.cameraControl?.adaptiveFailureReason == nil)
  }
  #expect(rig.device.focusPoints.isEmpty)
  // A subsequent acquisition has a new focus deadline, independent of the old zoom.
  rig.device.adjustingFocus = false
  rig.device.adjustingExposure = false
  rig.bounds = CGRect(x: 0.18, y: 0.18, width: 0.64, height: 0.64)
  #expect(rig.frame(61) == nil)
  rig.device.focusMode = 0
  var last: DocumentCaptureQualityObservation?
  for index in 62...70 { last = rig.frame(index) }
  #expect(last?.assessment.ready == true)
}

@Test func opticalIdentityChangeInvalidatesAcceptanceAndRequiresNewAcquisition() {
  let rig = AdaptiveRig()
  rig.device.identity = "wide"
  #expect(rig.frame(0)?.assessment.ready == false)
  for index in 1...4 { _ = rig.frame(index) }
  rig.device.focusMode = 0
  var last: DocumentCaptureQualityObservation?
  for index in 5...12 { last = rig.frame(index) }
  #expect(last?.assessment.ready == true)
  rig.device.identity = "ultrawide"
  #expect(rig.frame(13)?.assessment.ready == false)
  for index in 14...18 { _ = rig.frame(index) }
  #expect(rig.device.focusPoints.count == 2)
}

@Test func measuredFramingCanReachReadinessWithoutNominalDocumentSize() {
  let rig = AdaptiveRig()
  _ = rig.frame(0)
  #expect(rig.device.zooms.isEmpty)
  rig.device.focusMode = 0
  var last: DocumentCaptureQualityObservation?
  for index in 1...12 { last = rig.frame(index) }
  #expect(last?.assessment.ready == true)
}

final class AdaptiveRig {
  var date = Date(timeIntervalSince1970: 100)
  let device = AdaptiveFakeDevice()
  lazy var controller = DocumentAdaptiveCameraController(now: { [weak self] in
    self?.date ?? .distantPast
  })
  var bounds = CGRect(x: 0.18, y: 0.18, width: 0.64, height: 0.64)
  var point = CGPoint(x: 0.5, y: 0.5)

  func frame(_ index: Int, detected: Bool = true, soft: Bool = false)
    -> DocumentCaptureQualityObservation? {
    date = Date(timeIntervalSince1970: 100 + Double(index) * 0.2)
    let inside = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8).contains(bounds)
    let observation = DocumentCaptureQualityObservation(
      sequence: UInt64(index), geometryRevision: 1, timestamp: date,
      metrics: .init(
        documentFillRatio: detected ? 0.4 : nil, documentGuideFillRatio: 0.64,
        documentInsideGuide: inside, guideCenterX: 0.5, guideCenterY: 0.5,
        guideWidth: 0.8, guideHeight: 0.8, documentAspectRatio: 1,
        sharpness: soft ? 0.01 : 0.1, motion: 0.01,
        clippedHighlightRatio: 0, meanLuminance: 0.5, documentCenterX: 0.5, documentCenterY: 0.5),
      assessment: .init(
        ready: detected && !soft && inside,
        blockingReasons: !detected
          ? [.documentNotFound] : (soft ? [.softFocus] : [.alignWithGuide]),
        stableFrameCount: 4), documentBounds: detected ? bounds : nil)
    return controller.process(
      observation, device: device, nativePoint: point)
  }
}

final class AdaptiveFakeDevice: DocumentAdaptiveDevice {
  let maximumZoom = 2.0
  var zoomFactor = 1.0
  var focusMode = 2
  var pointOffset = 0.0
  var identity: String?
  var focusPoint = CGPoint(x: 0.5, y: 0.5)
  var adjustingExposure = false
  var adjustingFocus = false
  var ramping = false
  var supportsFocus = true
  var failCommands = false
  var commandAttempts = 0
  enum CommandError: Error { case unavailable }
  var focusPoints: [CGPoint] = []
  var zooms: [Double] = []
  var snapshotCount = 0

  func snapshot(at date: Date) -> DocumentCameraControlSnapshot {
    snapshotCount += 1
    var value = DocumentCameraControlSnapshot(
      sampledAt: date, zoomFactor: zoomFactor, adjustingFocus: adjustingFocus,
      adjustingExposure: adjustingExposure, rampingZoom: ramping, settled: false)
    value.opticalIdentity = identity
    value.focusModeRawValue = focusMode
    value.focusPointX = Double(focusPoint.x)
    value.focusPointY = Double(focusPoint.y)
    return value
  }
  func focus(at point: CGPoint) throws -> Bool {
    guard supportsFocus else { return false }
    commandAttempts += 1
    if failCommands { throw CommandError.unavailable }
    focusMode = 1
    focusPoint = CGPoint(x: point.x + pointOffset, y: point.y + pointOffset)
    focusPoints.append(point)
    return true
  }
  func zoom(to factor: Double) throws {
    commandAttempts += 1
    if failCommands { throw CommandError.unavailable }
    zooms.append(factor)
    zoomFactor = factor
  }
}

@Test func documentInsideVisibleGuideCanSettleAtMinimumZoom() {
  let rig = AdaptiveRig()
  rig.bounds = CGRect(x: 0.11, y: 0.18, width: 0.64, height: 0.64)
  _ = rig.frame(1)
  rig.device.focusMode = 0
  var last: DocumentCaptureQualityObservation?
  for index in 2...12 { last = rig.frame(index) }
  #expect(rig.device.zooms.isEmpty)
  #expect(last?.assessment.ready == true)
  #expect(last?.cameraControl?.settled == true)
}
