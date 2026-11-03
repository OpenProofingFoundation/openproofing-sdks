import Foundation
import Testing

@testable import DocumentCaptureApple

@Test func inheritedZoomRampHasBoundedFailureWithoutIssuingFocusOrInferringCompletion() {
  let rig = AdaptiveRig()
  rig.device.ramping = true
  var last: DocumentCaptureQualityObservation?
  for index in 0...80 { last = rig.frame(index) }
  #expect(last?.assessment.ready == false)
  #expect(last?.cameraControl?.adaptiveFailureReason == "nativeAdjustmentTimedOut")
  #expect(rig.device.focusPoints.isEmpty)
  #expect(rig.device.zooms.isEmpty)
}

@Test func controllerResetCannotLoseAnActiveNativeRampDeadline() {
  let rig = AdaptiveRig()
  rig.bounds = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
  #expect(rig.frame(0) == nil)
  rig.device.ramping = true
  rig.controller.reset()
  var last: DocumentCaptureQualityObservation?
  for index in 1...80 { last = rig.frame(index) }
  #expect(last?.cameraControl?.adaptiveFailureReason == "nativeAdjustmentTimedOut")
  #expect(last?.assessment.ready == false)
  #expect(rig.device.zooms.count == 1)
  #expect(rig.device.focusPoints.isEmpty)
}

@Test func inheritedRampEndingRequiresFreshFocusBeforeReadiness() {
  let rig = AdaptiveRig()
  rig.device.ramping = true
  for index in 0...3 { #expect(rig.frame(index)?.assessment.ready == false) }
  rig.device.ramping = false
  #expect(rig.frame(4) == nil)
  #expect(rig.device.focusPoints.count == 1)
  rig.device.focusMode = 0
  var last: DocumentCaptureQualityObservation?
  for index in 5...16 { last = rig.frame(index) }
  #expect(last?.cameraControl?.adaptiveFailureReason == nil)
  #expect(last?.assessment.ready == true)
}

@Test func lateRampCompletionCannotClearTerminalFailureWithoutExplicitReset() {
  let rig = AdaptiveRig()
  rig.device.ramping = true
  for index in 0...80 { _ = rig.frame(index) }
  rig.device.ramping = false
  #expect(rig.frame(81)?.cameraControl?.adaptiveFailureReason == "nativeAdjustmentTimedOut")
  #expect(rig.device.focusPoints.isEmpty)
  rig.controller.reset()
  #expect(rig.frame(82) == nil)
  #expect(rig.device.focusPoints.count == 1)
  rig.device.focusMode = 0
  var last: DocumentCaptureQualityObservation?
  for index in 83...95 { last = rig.frame(index) }
  #expect(last?.assessment.ready == true)
}

@Test func newOpticalIdentityWithInheritedRampTimesOutEvenWithoutDocument() {
  let rig = AdaptiveRig()
  rig.device.identity = "new-device"
  rig.device.ramping = true
  var last: DocumentCaptureQualityObservation?
  for index in 0...80 { last = rig.frame(index, detected: false) }
  #expect(last?.cameraControl?.adaptiveFailureReason == "nativeAdjustmentTimedOut")
  #expect(rig.device.commandAttempts == 0)
  #expect(last?.assessment.ready == false)
}
