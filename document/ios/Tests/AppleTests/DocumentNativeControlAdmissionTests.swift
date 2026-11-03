import AVFoundation
import Foundation
import Testing

@testable import DocumentCaptureApple

@Test func shutterRejectsNativeFocusPointDriftAfterAcceptedObservation() {
  let admitted = settledControls()
  var current = admitted
  #expect(DocumentNativeControlAdmission.matches(admitted: admitted, current: current))
  current.focusPointX = 0.7
  #expect(!DocumentNativeControlAdmission.matches(admitted: admitted, current: current))
}

@Test func shutterRejectsDifferentOpticsAndTerminalFailure() {
  let admitted = settledControls()
  var current = admitted
  current.opticalIdentity = "replacement-camera"
  #expect(!DocumentNativeControlAdmission.matches(admitted: admitted, current: current))
  var failed = admitted
  failed.adaptiveFailureReason = "focusAttemptsExhausted"
  #expect(!DocumentNativeControlAdmission.matches(admitted: failed, current: admitted))
}

@Test func shutterRejectsMissingNativeReadbackAndOngoingAdjustment() {
  let admitted = settledControls()
  var missing = admitted
  missing.focusPointY = nil
  #expect(!DocumentNativeControlAdmission.matches(admitted: admitted, current: missing))
  let adjusting = settledControls(adjusting: true)
  #expect(!DocumentNativeControlAdmission.matches(admitted: admitted, current: adjusting))
}

private func settledControls(adjusting: Bool = false) -> DocumentCameraControlSnapshot {
  var value = DocumentCameraControlSnapshot(
    sampledAt: Date(), zoomFactor: 2, adjustingFocus: adjusting,
    adjustingExposure: false, rampingZoom: false, settled: true)
  value.opticalIdentity = "logical-camera|wide|format1"
  value.focusModeRawValue = AVCaptureDevice.FocusMode.locked.rawValue
  value.focusPointX = 0.5
  value.focusPointY = 0.5
  return value
}
