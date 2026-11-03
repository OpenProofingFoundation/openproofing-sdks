import Foundation

/// Ported from DocumentCameraHardware and AVFoundationDocumentCapturePolicy at identity SDK
/// 0a1d0a0; virtual-first policy restored in 245e086. See Gates/extraction-sources.json.
/// Camera selection is acquisition policy, not a document or identity decision.
enum MRZCameraLens: String, Sendable {
  case wide, ultraWide, telephoto, dualWide, triple
}

struct MRZCameraCandidate: Equatable, Sendable {
  let identifier: String
  let lens: MRZCameraLens
  let maximumPhotoWidth: Int
  let maximumPhotoHeight: Int

  var maximumPhotoPixelCount: Int64 {
    Int64(maximumPhotoWidth) * Int64(maximumPhotoHeight)
  }
}

enum MRZCameraSelection {
  /// Preserve the established virtual-device order. Focus distance is never subject distance.
  static func select(from candidates: [MRZCameraCandidate]) -> MRZCameraCandidate? {
    for lens in [MRZCameraLens.dualWide, .triple, .wide, .ultraWide, .telephoto] {
      guard let selected = candidates.filter({ $0.lens == lens }).sorted(by: {
        if $0.maximumPhotoPixelCount != $1.maximumPhotoPixelCount {
          return $0.maximumPhotoPixelCount > $1.maximumPhotoPixelCount
        }
        return $0.identifier < $1.identifier
      }).first else { continue }
      return selected
    }
    return nil
  }

  /// Same native switch-over baseline and clamp as the donor; no distance or zoom heuristic.
  static func baselineZoom(minimum: Double, maximum: Double, firstSwitchOver: Double?) -> Double {
    min(maximum, max(minimum, firstSwitchOver ?? 1))
  }
}

#if os(iOS)
  @preconcurrency import AVFoundation

  extension MRZCameraSelection {
    /// Called only on the driver's serial queue. Device identifiers are internal tie breakers.
    static func device() -> AVCaptureDevice? {
      let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInDualWideCamera, .builtInTripleCamera, .builtInWideAngleCamera,
          .builtInUltraWideCamera, .builtInTelephotoCamera],
        mediaType: .video, position: .back).devices
      let candidates = devices.map { device in
        let dimensions = device.formats.flatMap(\.supportedMaxPhotoDimensions).max {
          Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        } ?? CMVideoDimensions(width: 0, height: 0)
        return MRZCameraCandidate(identifier: device.uniqueID, lens: lens(for: device.deviceType),
          maximumPhotoWidth: Int(dimensions.width), maximumPhotoHeight: Int(dimensions.height))
      }
      guard let selected = select(from: candidates) else { return nil }
      return devices.first { $0.uniqueID == selected.identifier }
    }

    /// The donor's device-only configuration. Photo-output policy is outside MRZ capture.
    static func configure(_ device: AVCaptureDevice) throws {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      device.cancelVideoZoomRamp()
      if device.isVirtualDevice {
        if device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
          device.setPrimaryConstituentDeviceSwitchingBehavior(
            .auto, restrictedSwitchingBehaviorConditions: [])
        }
        device.videoZoomFactor = CGFloat(baselineZoom(
          minimum: Double(device.minAvailableVideoZoomFactor),
          maximum: Double(device.maxAvailableVideoZoomFactor),
          firstSwitchOver: device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue))
      }
      if device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusMode = .continuousAutoFocus
      }
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
    }

    static func lens(for type: AVCaptureDevice.DeviceType) -> MRZCameraLens {
      switch type {
      case .builtInDualWideCamera: .dualWide
      case .builtInTripleCamera: .triple
      case .builtInUltraWideCamera: .ultraWide
      case .builtInTelephotoCamera: .telephoto
      default: .wide
      }
    }
  }
#endif
