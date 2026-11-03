import CoreML
import Vision

/// Shared Vision configuration for retained and live document analysis.
/// Physical devices retain the platform's default algorithms and compute selection.
enum DocumentVisionRequests {
  static func configurePDF417(_ request: VNDetectBarcodesRequest) throws {
    #if targetEnvironment(simulator)
      // On the iOS 26.5 simulator, default barcode inference fails to initialize.
      // Revisions 3/4 with explicit CPU selection finish but miss positive controls;
      // revision 2 on its supported CPU decodes the same payloads exactly.
      request.revision = VNDetectBarcodesRequestRevision2
      try selectSupportedCPU(for: request)
    #endif
    // Changing the revision resets symbologies. Apply the PDF417 scope last.
    request.symbologies = [.pdf417]
  }

  static func configureFaces(_ request: VNDetectFaceRectanglesRequest) throws {
    #if targetEnvironment(simulator)
      // Default simulator inference fails here too; the current face revision
      // works with explicit CPU selection, including the positive face fixture.
      try selectSupportedCPU(for: request)
    #endif
  }

  #if targetEnvironment(simulator)
    private static func selectSupportedCPU(for request: VNRequest) throws {
      for (stage, devices) in try request.supportedComputeStageDevices {
        if let cpu = devices.first(where: {
          if case .cpu = $0 { return true }
          return false
        }) {
          request.setComputeDevice(cpu, for: stage)
        }
      }
    }
  #endif
}
