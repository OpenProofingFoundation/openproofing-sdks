#if os(iOS)
  import AVFoundation
  @_spi(Preview) import PassportMRZCapture
  import UIKit

  /// Camera preview with the shared MRZ band. Hosts own controls, instructions, readiness
  /// feedback and confirmation. OCR examines the full frame; automatic capture requires
  /// the complete MRZ rows to remain inside this band.
  @MainActor
  public final class NativeMRZPreviewView: UIView {
    public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private let captureSession: NativeMRZSession
    private let guide: MRZPreviewGuide
    private let veil = CAShapeLayer()
    private var runningObservation: NSKeyValueObservation?

    /// Current view-local band, available to a host that places instructional text beside it.
    public var guideFrame: CGRect { guide.frame(in: bounds) }

    public init(captureSession: NativeMRZSession, guide: MRZPreviewGuide = .documentBand) {
      self.captureSession = captureSession
      self.guide = guide
      super.init(frame: .zero)
      guard let preview = layer as? AVCaptureVideoPreviewLayer else { return }
      preview.session = captureSession.previewSession
      preview.videoGravity = .resizeAspectFill
      clipsToBounds = true
      veil.fillRule = .evenOdd
      veil.fillColor = UIColor.black.withAlphaComponent(min(1, max(0, guide.veilOpacity))).cgColor
      layer.addSublayer(veil)
      // The view can mount before the camera graph has a connection. Reapply orientation when
      // that graph starts, including after a stop/retry, without replacing the host's callbacks.
      runningObservation = captureSession.previewSession?.observe(\.isRunning, options: [.new]) {
        [weak self] _, _ in
        Task { @MainActor in self?.setNeedsLayout() }
      }
    }

    public override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil { captureSession.updateGuideRegion(nil) }
      setNeedsLayout()
    }

    public override func layoutSubviews() {
      super.layoutSubviews()
      // Use this preview's scene, not a process-global device orientation. Rotation lock can
      // make the interface and device differ, and capture must agree with what is displayed.
      // https://developer.apple.com/documentation/uikit/uiwindowscene/interfaceorientation
      if let interfaceOrientation = window?.windowScene?.interfaceOrientation,
        let orientation = Self.captureOrientation(interfaceOrientation)
      {
        if let connection = (layer as? AVCaptureVideoPreviewLayer)?.connection,
          connection.isVideoRotationAngleSupported(orientation.videoRotationDegrees)
        {
          connection.videoRotationAngle = orientation.videoRotationDegrees
        }
        captureSession.updateOrientation(orientation)
      }
      if window != nil, bounds.width > 0, bounds.height > 0,
        let preview = layer as? AVCaptureVideoPreviewLayer, preview.connection != nil {
        captureSession.updateGuideRegion(preview.metadataOutputRectConverted(fromLayerRect: guideFrame))
      } else {
        captureSession.updateGuideRegion(nil)
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      veil.frame = bounds
      let path = CGMutablePath()
      path.addRect(bounds)
      path.addRoundedRect(
        in: guideFrame, cornerWidth: guide.cornerRadius,
        cornerHeight: guide.cornerRadius)
      veil.path = path
      CATransaction.commit()
    }

    static func captureOrientation(_ orientation: UIInterfaceOrientation) -> MRZCaptureOrientation?
    {
      switch orientation {
      case .portrait: .portrait
      case .portraitUpsideDown: .portraitUpsideDown
      case .landscapeLeft: .landscapeLeft
      case .landscapeRight: .landscapeRight
      default: nil
      }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
  }
#endif
