import AVFoundation
import Foundation
import DocumentSDK
import ImageIO

/// Maps platform-neutral document-capture choices to AVFoundation policy.
/// Every method is called by the serial capture-session owner.
struct AVFoundationDocumentCapturePolicy {
  struct SelectedCamera {
    let device: AVCaptureDevice
    let hardwareSelection: DocumentCameraHardwareSelection
  }

  let configuration: DocumentCaptureConfiguration
  private let selectionPolicy = DocumentCameraSelectionPolicy()

  func selectCamera(choice: DocumentCameraDeviceChoice = .automatic) -> SelectedCamera? {
    let devices = AVCaptureDevice.DiscoverySession(
      deviceTypes: discoveryDeviceTypes,
      mediaType: .video,
      position: .back
    ).devices
    let candidates = devices.map { device in
      DocumentCameraCandidate(
        identifier: device.uniqueID,
        capability: capability(for: device)
      )
    }
    if choice != .automatic {
      let requestedLens: DocumentCameraCapability.Lens
      switch choice {
      case .wide, .automatic: requestedLens = .wide
      case .ultraWide: requestedLens = .ultraWide
      case .telephoto: requestedLens = .telephoto
      }
      guard let candidate = candidates.first(where: { $0.capability.lens == requestedLens }),
        let device = devices.first(where: { $0.uniqueID == candidate.identifier })
      else { return nil }
      return SelectedCamera(
        device: device,
        hardwareSelection: DocumentCameraHardwareSelection(
          selected: candidate.capability, discovered: candidates.map(\.capability),
          reason: .explicitlyRequested, targetWorkingDistanceMillimeters: nil))
    }
    guard
      let selection = selectionPolicy.select(from: candidates),
      let device = devices.first(where: { $0.uniqueID == selection.candidate.identifier })
    else {
      return nil
    }
    return SelectedCamera(device: device, hardwareSelection: selection.report)
  }

  func configure(
    device: AVCaptureDevice,
    photoOutput: AVCapturePhotoOutput
  ) throws {
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }

      #if os(iOS)
        device.cancelVideoZoomRamp()
        if device.isVirtualDevice {
          if device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
            device.setPrimaryConstituentDeviceSwitchingBehavior(
              .auto, restrictedSwitchingBehaviorConditions: [])
          }
          let baseline = device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1
          device.videoZoomFactor = CGFloat(
            min(
              Double(device.maxAvailableVideoZoomFactor),
              max(Double(device.minAvailableVideoZoomFactor), baseline)))
        }
      #endif
      if device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusMode = .continuousAutoFocus
      }
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
    } catch {
      throw PhotoCaptureError.configurationFailed(String(describing: error))
    }

    try configurePhotoOutput(device: device, photoOutput: photoOutput)
  }

  func configurePhotoOutput(device: AVCaptureDevice, photoOutput: AVCapturePhotoOutput) throws {
    guard
      let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(
        by: { area(of: $0) < area(of: $1) }), dimensions.width > 0, dimensions.height > 0
    else { throw PhotoCaptureError.configurationFailed("photo_dimensions_unsupported") }
    photoOutput.maxPhotoQualityPrioritization = requestedQualityPrioritization
    if photoOutput.maxPhotoDimensions.width != dimensions.width
      || photoOutput.maxPhotoDimensions.height != dimensions.height {
      photoOutput.maxPhotoDimensions = dimensions
    }
  }

  func availableChoices() -> [DocumentCameraDeviceChoice] {
    DocumentCameraDeviceChoice.allCases.filter { selectCamera(choice: $0) != nil }
  }

  func makePhotoSettings(
    photoOutput: AVCapturePhotoOutput,
    locationAssertion: CaptureLocationAssertion? = nil
  ) -> AVCapturePhotoSettings {
    let codec: AVVideoCodecType
    switch configuration.encoding {
    case .heicWithJPEGFallback:
      codec = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
    case .jpeg:
      codec = .jpeg
    }

    let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
    settings.photoQualityPrioritization = requestedQualityPrioritization
    settings.flashMode = .off
    #if os(iOS)
      switch configuration.distortionCorrection {
      case .disabled:
        settings.isAutoContentAwareDistortionCorrectionEnabled = false
      case .systemDefault:
        break
      }
    #endif

    let maximumDimensions = photoOutput.maxPhotoDimensions
    if maximumDimensions.width > 0, maximumDimensions.height > 0 {
      settings.maxPhotoDimensions = maximumDimensions
    }

    // A location is written before encoding so the retained original's digest
    // covers it. Only the documented GPS keys are set: Apple raises an
    // exception for any key outside `CGImageProperties`, and merging leaves the
    // platform's own automatically written metadata in place.
    #if !os(macOS)
      if let locationAssertion,
        let gps = CaptureLocationGPSMetadata.gpsDictionary(for: locationAssertion) {
        var metadata = settings.metadata
        metadata[kCGImagePropertyGPSDictionary as String] = gps
        settings.metadata = metadata
      }
    #endif
    return settings
  }

  private func area(of dimensions: CMVideoDimensions) -> Int64 {
    Int64(dimensions.width) * Int64(dimensions.height)
  }

  /// A photo setting may not exceed the output's `maxPhotoQualityPrioritization`,
  /// so both use the mandatory geometry policy.
  private var requestedQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization {
    .balanced
  }

  private var discoveryDeviceTypes: [AVCaptureDevice.DeviceType] {
    #if os(iOS)
      [
        .builtInDualWideCamera, .builtInTripleCamera, .builtInWideAngleCamera,
        .builtInUltraWideCamera, .builtInTelephotoCamera
      ]
    #else
      [.builtInWideAngleCamera]
    #endif
  }

  private func capability(for device: AVCaptureDevice) -> DocumentCameraCapability {
    let maximumDimensions =
      device.formats
      .flatMap(\.supportedMaxPhotoDimensions)
      .max(by: { area(of: $0) < area(of: $1) })
      ?? CMVideoDimensions(width: 0, height: 0)
    let minimumFocusDistance = device.minimumFocusDistance

    return DocumentCameraCapability(
      lens: lens(for: device.deviceType),
      localizedName: device.localizedName,
      minimumFocusDistanceMillimeters: minimumFocusDistance > 0 ? minimumFocusDistance : nil,
      maximumPhotoWidth: Int(maximumDimensions.width),
      maximumPhotoHeight: Int(maximumDimensions.height),
      videoFieldOfViewDegrees: videoFieldOfView(for: device),
      lensAperture: lensAperture(for: device),
      supportsContinuousAutoFocus: device.isFocusModeSupported(.continuousAutoFocus),
      supportsFocusPointOfInterest: device.isFocusPointOfInterestSupported
    )
  }

  private func lens(for deviceType: AVCaptureDevice.DeviceType) -> DocumentCameraCapability.Lens {
    #if os(iOS)
      switch deviceType {
      case .builtInDualWideCamera:
        .dualWide
      case .builtInTripleCamera:
        .triple
      case .builtInUltraWideCamera:
        .ultraWide
      case .builtInTelephotoCamera:
        .telephoto
      default:
        .wide
      }
    #else
      .wide
    #endif
  }

  private func videoFieldOfView(for device: AVCaptureDevice) -> Float {
    #if os(iOS)
      device.activeFormat.videoFieldOfView
    #else
      0
    #endif
  }

  private func lensAperture(for device: AVCaptureDevice) -> Float {
    #if os(iOS)
      device.lensAperture
    #else
      0
    #endif
  }
}
