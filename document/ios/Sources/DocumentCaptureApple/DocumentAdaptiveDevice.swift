import Foundation

/// Narrow, synchronous interface used only on the camera owner's serial queue.
/// Tests exercise the production controller through this boundary.
protocol DocumentAdaptiveDevice {
  var minimumZoom: Double { get }
  var maximumZoom: Double { get }
  func snapshot(at date: Date) -> DocumentCameraControlSnapshot
  func focus(at point: CGPoint) throws -> Bool
  func zoom(to factor: Double) throws
}

extension DocumentAdaptiveDevice {
  var minimumZoom: Double { 1 }
}

#if os(iOS)
  import AVFoundation

  private enum AdaptiveDeviceError: Error { case invalidZoom }

  struct AVFoundationAdaptiveDevice: DocumentAdaptiveDevice {
    let device: AVCaptureDevice
    var minimumZoom: Double { Double(device.minAvailableVideoZoomFactor) }
    var maximumZoom: Double { Double(device.maxAvailableVideoZoomFactor) }

    func snapshot(at date: Date) -> DocumentCameraControlSnapshot {
      var value = DocumentCameraControlSnapshot(
        sampledAt: date, zoomFactor: Double(device.videoZoomFactor),
        adjustingFocus: device.isAdjustingFocus,
        adjustingExposure: device.isAdjustingExposure,
        rampingZoom: device.isRampingVideoZoom, settled: false)
      value.focusModeRawValue = device.focusMode.rawValue
      value.focusPointX = Double(device.focusPointOfInterest.x)
      value.focusPointY = Double(device.focusPointOfInterest.y)
      value.lensPosition = Double(device.lensPosition)
      let primary = device.activePrimaryConstituent?.uniqueID ?? device.uniqueID
      value.opticalIdentity = "\(device.uniqueID)|\(primary)|\(ObjectIdentifier(device.activeFormat))"
      return value
    }

    func focus(at point: CGPoint) throws -> Bool {
      // WeScan's point AF/AE primitive, under the existing serial ownership.
      guard point.x.isFinite, point.y.isFinite,
        (0...1).contains(point.x), (0...1).contains(point.y),
        device.isFocusPointOfInterestSupported,
        device.isFocusModeSupported(.autoFocus)
      else { return false }
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
      device.isFaceDrivenAutoFocusEnabled = false
      device.focusPointOfInterest = point
      device.focusMode = .autoFocus
      if device.isExposurePointOfInterestSupported,
        device.isExposureModeSupported(.continuousAutoExposure) {
        device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
        device.isFaceDrivenAutoExposureEnabled = false
        device.exposurePointOfInterest = point
        device.exposureMode = .continuousAutoExposure
      }
      return true
    }

    func zoom(to factor: Double) throws {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      guard factor.isFinite,
        (minimumZoom...maximumZoom).contains(factor)
      else { throw AdaptiveDeviceError.invalidZoom }
      device.ramp(toVideoZoomFactor: CGFloat(factor), withRate: 1)
    }
  }
#endif
