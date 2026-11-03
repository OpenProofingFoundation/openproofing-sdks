import AVFoundation
import Foundation
import DocumentSDK

/// One decoded PDF417 code with its corners in metadata-output space.
struct LivePDF417MetadataRead: Equatable {
  let payload: String?
  let corners: [CGPoint]
}

/// The same metadata-output path used by Pulse iOS. Payloads remain local.
final class LivePDF417MetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
  /// The published guide in metadata-output space, read on the session queue.
  let guideRegion: () -> CGRect?
  let onPayload: (String?) -> Void
  init(guideRegion: @escaping () -> CGRect?, onPayload: @escaping (String?) -> Void) {
    self.guideRegion = guideRegion
    self.onPayload = onPayload
  }
  func metadataOutput(
    _ _: AVCaptureMetadataOutput,
    didOutput objects: [AVMetadataObject], from _: AVCaptureConnection
  ) {
    let codes = objects.compactMap { $0 as? AVMetadataMachineReadableCodeObject }
      .filter { $0.type == .pdf417 }
    receive(codes.map { LivePDF417MetadataRead(payload: $0.stringValue, corners: $0.corners) })
  }

  /// A code outside the published guide is refused before its payload is considered.
  func receive(_ reads: [LivePDF417MetadataRead]) {
    let guide = guideRegion()
    receive(
      reads.map {
        LivePDF417GuideContainment.contains(corners: $0.corners, in: guide) ? $0.payload : nil
      })
  }

  /// Validate the entire decoded payload before it can trigger a retained photo.
  /// Nil also clears a previous candidate when a read is absent or ambiguous.
  func receive(_ payloads: [String?]) {
    guard payloads.count == 1, let value = payloads[0],
      AAMVAPDF417Parser.parse(value).status == .readable
    else {
      onPayload(nil)
      return
    }
    onPayload(value)
  }
}

extension AVFoundationCameraSessionController {
  func configurePDF417Output() throws {
    let output = state.metadataOutput
    guard state.captureSession.canAddOutput(output) else {
      throw PhotoCaptureError.configurationFailed("pdf417_output_unavailable")
    }
    state.captureSession.addOutput(output)
    guard output.availableMetadataObjectTypes.contains(.pdf417) else {
      throw PhotoCaptureError.configurationFailed("pdf417_unsupported")
    }
    let delegate = LivePDF417MetadataDelegate(
      guideRegion: { [weak self] in self?.livePDF417GuideRegion }
    ) { [weak self] payload in
      self?.receiveLivePDF417Read(payload)
    }
    state.pdf417Delegate = delegate
    output.setMetadataObjectsDelegate(delegate, queue: sessionQueue)
    output.metadataObjectTypes = [.pdf417]
  }

  /// Session queue only. The guide the preview published, in metadata-output space.
  var livePDF417GuideRegion: CGRect? {
    #if os(iOS)
      state.captureDeviceGuideRegion?.normalizedTopLeftRect
    #else
      nil
    #endif
  }

  /// Session queue only. Every read refreshes the admission candidate; the shutter handler
  /// runs only after the required identical counted reads are confirmed.
  func receiveLivePDF417Read(_ payload: String?) {
    state.pdf417Candidate = nil
    let observedAt = now()
    guard let payload, state.captureAdmissionEnabled,
      state.captureSession.isRunning, state.processors.isEmpty
    else {
      _ = state.pdf417Confirmation.observe(nil, at: observedAt)
      return
    }
    state.pdf417Candidate = (payload, observedAt)
    guard state.pdf417Confirmation.observe(payload, at: observedAt) else { return }
    pdf417Handler(payload)
  }
}

extension DocumentCamera {
  public func setLivePDF417Handler(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
    guard let controller = sessionController as? AVFoundationCameraSessionController else { return }
    let epoch = generation
    controller.sessionQueue.async {
      controller.pdf417Handler = { [weak self] payload in
        Task { @MainActor in
          guard let self, self.generation == epoch, self.isRunning else { return }
          handler(payload)
        }
      }
    }
  }
}
