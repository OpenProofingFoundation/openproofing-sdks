#if os(iOS)
  // Adapted from Apple's AVCam CameraPreview.swift ownership pattern.
  // Source and modification record: References/sources/apple-avcam-preview.md
  // Apple sample terms: ThirdPartyNotices/Apple-AVCam.txt
  import DocumentCaptureApple
  import AVFoundation
  import UIKit
  import os

  /// The three colours the framing guide uses.
  ///
  /// The SDK owns WHEN each one shows — that is the capture state machine's
  /// business — and the host owns what they look like, the same division the
  /// status components keep. Defaults are the system colours, so a host that
  /// says nothing gets exactly what it got before.
  ///
  /// These sit on live video, so a host passing design tokens should pass the
  /// variant meant for a dark surface, not the one that follows the system.
  public struct DocumentGuideColors: Sendable {
    public var seeking: UIColor
    public var ready: UIColor
    public var failed: UIColor

    public init(seeking: UIColor = .white, ready: UIColor = .systemGreen, failed: UIColor = .systemRed) {
      self.seeking = seeking
      self.ready = ready
      self.failed = failed
    }
  }

  /// PDF417 preserves pulse-ios's 2:1 barcode viewport, expanded to the screen. It is
  /// guidance only; capture admission remains owned by the camera session.
  public enum DocumentCameraGuideStyle: Sendable { case document, pdf417 }

  /// The PDF417 guide's look when the host sets none.
  ///
  /// ATTRIBUTION. A presentation default, not a measurement: the corner radius the native PDF417
  /// scanner port shipped with on 2026-09-24. The host owns the look and replaces it by setting
  /// `DocumentCameraPreviewView.pdf417GuideCornerRadius`.
  struct DocumentPDF417GuideDefaults: Sendable {
    let cornerRadius: CGFloat
    static let ported20260924 = Self()
    private init() { cornerRadius = 16 }
  }

  @MainActor
  public final class DocumentCameraPreviewView: UIView {
    private let previewProvider: any DocumentCameraPreviewProviding
    private let suppliedPreviewLayer: AVCaptureVideoPreviewLayer?
    private let guideLayout = DocumentID1GuideLayout()
    private let guideLayer = CAShapeLayer()
    private let veilLayer = CAShapeLayer()
    public var guideStyle: DocumentCameraGuideStyle = .document {
      didSet { setNeedsLayout() }
    }
    public var pdf417GuideCornerRadius: CGFloat = DocumentPDF417GuideDefaults.ported20260924.cornerRadius {
      didSet { setNeedsLayout() }
    }
    public var pdf417VeilColor: UIColor = UIColor.black.withAlphaComponent(0.5) {
      didSet { veilLayer.fillColor = pdf417VeilColor.cgColor }
    }
    private var authority = DocumentPreviewGeometryAuthority()
    private var appliedOrientation: DocumentCameraOrientation? { authority.orientation }
    private var guideFrame: CGRect?
    /// Brackets while seeking, a closed rectangle once the document is held.
    private var guideIsClosed = false
    /// Set by the host. Re-renders the current state so a change applies at once.
    public var guideColors = DocumentGuideColors() {
      didSet { renderCaptureFeedback(lastFeedback) }
    }
    private var lastFeedback: DocumentCaptureFeedback = .seeking
    private var lastGeometryDiagnostic: DocumentCameraPreviewGeometryDiagnostic?
    private var previewObservation: NSKeyValueObservation?
    private let previewStopPending = OSAllocatedUnfairLock(initialState: false)

    // UIKit requires overriding this class property.
    // swiftlint:disable:next static_over_final_class
    public override class var layerClass: AnyClass {
      AVCaptureVideoPreviewLayer.self
    }

    private var previewLayer: AVCaptureVideoPreviewLayer {
      if let suppliedPreviewLayer { return suppliedPreviewLayer }
      guard let layer = layer as? AVCaptureVideoPreviewLayer else {
        preconditionFailure("invalid_preview_layer_type")
      }
      return layer
    }

    public convenience init(previewProvider: any DocumentCameraPreviewProviding) {
      self.init(previewProvider: previewProvider, previewLayer: nil)
    }

    init(
      previewProvider: any DocumentCameraPreviewProviding, previewLayer: AVCaptureVideoPreviewLayer?
    ) {
      self.previewProvider = previewProvider
      suppliedPreviewLayer = previewLayer
      super.init(frame: .zero)
      self.previewLayer.videoGravity = .resizeAspectFill
      observePreviewReadiness()
      previewProvider.attachPreview(to: self.previewLayer)
      configureGuideLayer()
      previewProvider.setCaptureFeedbackHandler { [weak self] feedback in
        self?.renderCaptureFeedback(feedback)
      }
      previewProvider.setPreviewGeometryInvalidationHandler { [weak self] generation in
        guard let self, authority.invalidate(for: generation) else { return }
        lastGeometryDiagnostic = nil
        refreshGeometry()
      }
    }

    public override func layoutSubviews() {
      super.layoutSubviews()
      refreshGeometry()
    }

    public override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil else {
        publishGuide(nil)
        return
      }
      refreshGeometry()
    }

    public override func safeAreaInsetsDidChange() {
      super.safeAreaInsetsDidChange()
      setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      nil
    }

    private func refreshGeometry() {
      updateGuideLayer()
      authority.beginRefresh()
      let stopped = previewStopPending.withLock { pending in
        let stopped = pending
        pending = false
        return stopped
      }
      if stopped { publishGuide(nil) }
      guard window != nil, updateOrientationIfNeeded() else {
        publishGuide(nil)
        return
      }
      updateGuideRegionIfPossible()
    }

    private func observePreviewReadiness() {
      // AVFoundation documents `isPreviewing` as the observable rendering boundary.
      // Observe before attachment: attaching to an already-running session can start rendering.
      let pendingStop = previewStopPending
      previewObservation = previewLayer.observe(\.isPreviewing, options: [.old, .new]) {
        [weak self] _, change in
        if change.oldValue == true && change.newValue == false {
          pendingStop.withLock { $0 = true }
        }
        Task { @MainActor [weak self] in
          // Every refresh consumes the stop before admitting geometry. A layout that overtakes
          // this callback therefore cannot have its new guide revoked by an already-consumed stop.
          self?.refreshGeometry()
        }
      }
    }

    private func configureGuideLayer() {
      guideLayer.fillColor = UIColor.clear.cgColor
      guideLayer.strokeColor = UIColor.white.cgColor
      guideLayer.lineWidth = 3
      guideLayer.lineCap = .round
      guideLayer.lineJoin = .round
      guideLayer.shadowColor = UIColor.black.cgColor
      guideLayer.shadowOpacity = 0.45
      guideLayer.shadowRadius = 2
      guideLayer.shadowOffset = .zero
      veilLayer.fillColor = pdf417VeilColor.cgColor
      veilLayer.fillRule = .evenOdd
      veilLayer.isHidden = true
      layer.addSublayer(veilLayer)
      layer.addSublayer(guideLayer)
    }

    /// SHAPE CARRIES THE STATE, not colour alone.
    ///
    /// This used to paint `.seeking` the same red as `.failed`, so the resting
    /// state of the scanner — what a person sees for most of the time the
    /// camera is open, while doing exactly the right thing — was drawn as an
    /// error. Nothing had gone wrong; it was still looking.
    ///
    /// The frame now opens and closes instead. Seeking shows four corner
    /// brackets, which read as "line it up here"; locking on closes them into a
    /// continuous rectangle. That survives greyscale, which matters because the
    /// old signal was red against green — the one pair roughly one man in
    /// twelve cannot separate, and colour was the ONLY thing that changed
    /// (WCAG 1.4.1).
    ///
    /// Red is now reserved for `.failed`, so it means what red means.
    private func renderCaptureFeedback(_ feedback: DocumentCaptureFeedback) {
      lastFeedback = feedback
      let color: UIColor
      let closed: Bool
      switch feedback {
      case .seeking: color = guideColors.seeking; closed = false
      case .failed: color = guideColors.failed; closed = false
      case .ready, .capturing, .stored, .accepted: color = guideColors.ready; closed = true
      }
      guideIsClosed = closed
      // The one moment worth motion is the frame closing, so this transition is
      // NOT wrapped in setDisableActions — unlike the geometry updates below,
      // which must not animate because they follow the camera's own layout.
      guideLayer.strokeColor = color.cgColor
      updateGuidePath(animated: true)
    }

    /// Four corner brackets, or the closed rectangle they become.
    ///
    /// The corner run is a fraction of the shorter side so the brackets keep
    /// their proportion on any guide size, and `closed` draws the same path
    /// with the runs extended to meet. Both paths have the same point count and
    /// the same start point, so Core Animation can interpolate between them —
    /// which is what makes the frame appear to snap shut rather than cross-fade.
    private static func guidePath(in rect: CGRect, closed: Bool) -> CGPath {
      let path = UIBezierPath()
      let run = closed ? min(rect.width, rect.height) / 2 : min(rect.width, rect.height) * 0.18
      let corners: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: rect.minX, y: rect.minY + run), CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX + run, y: rect.minY)),
        (CGPoint(x: rect.maxX - run, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + run)),
        (CGPoint(x: rect.maxX, y: rect.maxY - run), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - run, y: rect.maxY)),
        (CGPoint(x: rect.minX + run, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY - run)),
      ]
      for (start, corner, end) in corners {
        path.move(to: start)
        path.addLine(to: corner)
        path.addLine(to: end)
      }
      return path.cgPath
    }

    private func updateGuidePath(animated: Bool) {
      guard let frame = guideFrame else { return }
      let localFrame = frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
      let path = guideStyle == .pdf417
        ? UIBezierPath(roundedRect: localFrame, cornerRadius: pdf417GuideCornerRadius).cgPath
        : Self.guidePath(in: localFrame, closed: guideIsClosed)
      if animated && !UIAccessibility.isReduceMotionEnabled && guideStyle == .document {
        let morph = CABasicAnimation(keyPath: "path")
        morph.fromValue = guideLayer.path
        morph.toValue = path
        morph.duration = 0.2
        morph.timingFunction = CAMediaTimingFunction(name: .easeOut)
        guideLayer.add(morph, forKey: "path")
        guideLayer.path = path
      } else {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guideLayer.path = path
        CATransaction.commit()
      }
    }

    private func updateGuideLayer() {
      let nextFrame: CGRect?
      if guideStyle == .pdf417 {
        // Keep pulse-ios's 2:1 barcode shape, but use the available width
        // rather than capping larger phones at 320 points. Leave a 16-point
        // screen margin and room inside the guide for barcode quiet zones.
        let width = min(bounds.width - 32, (bounds.height - 32) * 2)
        nextFrame = width > 0 && width.isFinite
          ? CGRect(x: bounds.midX - width / 2, y: bounds.midY - width / 4,
                   width: width, height: width / 2)
          : nil
      } else {
        nextFrame = guideLayout.guideFrame(in: bounds)
      }
      guideFrame = nextFrame

      CATransaction.begin()
      CATransaction.setDisableActions(true)
      guideLayer.frame = bounds
      veilLayer.frame = bounds
      veilLayer.isHidden = guideStyle != .pdf417
      if guideStyle == .pdf417, let nextFrame {
        let veil = UIBezierPath(rect: bounds)
        veil.append(UIBezierPath(roundedRect: nextFrame, cornerRadius: pdf417GuideCornerRadius))
        veilLayer.path = veil.cgPath
      } else {
        veilLayer.path = nil
      }
      CATransaction.commit()
      // Geometry follows the camera's own layout, so it never animates.
      updateGuidePath(animated: false)
    }

    private func updateOrientationIfNeeded() -> Bool {
      guard
        authority.sourceGeneration != nil,
        let interfaceOrientation = window?.windowScene?.interfaceOrientation,
        let orientation = DocumentCameraOrientation(interfaceOrientation)
      else {
        reportGeometry(.guideUnavailable, orientation: nil)
        return false
      }
      guard let connection = previewLayer.connection else {
        reportGeometry(.connectionUnavailable, orientation: orientation)
        return false
      }
      guard apply(orientation, to: connection) else {
        reportGeometry(.rotationUnsupported, orientation: orientation)
        return false
      }
      authority.acceptRotation(orientation)
      return true
    }

    private func apply(
      _ orientation: DocumentCameraOrientation,
      to connection: AVCaptureConnection
    ) -> Bool {
      if #available(iOS 17.0, *) {
        let angle = orientation.videoRotationAngle
        if connection.isVideoRotationAngleSupported(angle) {
          connection.videoRotationAngle = angle
          return connection.videoRotationAngle == angle
        }
      } else if connection.isVideoOrientationSupported {
        connection.videoOrientation = orientation.legacyVideoOrientation
        return connection.videoOrientation == orientation.legacyVideoOrientation
      }
      return false
    }

    private func updateGuideRegionIfPossible() {
      guard
        let guideFrame = localGuideFrame,
        window != nil,
        previewLayer.isPreviewing,
        authority.canPublishGuide,
        bounds.width > 0,
        bounds.height > 0
      else {
        reportGeometry(.guideUnavailable, orientation: appliedOrientation)
        publishGuide(nil)
        return
      }
      let metadataRegion = previewLayer.metadataOutputRectConverted(fromLayerRect: guideFrame)
      let layerRoundTrip = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRegion)
      guard
        previewLayer.isPreviewing,
        metadataRegion.width > 0,
        metadataRegion.height > 0,
        CGRect(x: 0, y: 0, width: 1, height: 1).contains(metadataRegion),
        approximatelyEqual(layerRoundTrip, guideFrame, tolerance: 1)
      else {
        let rejectedRegion = DocumentCameraGuideRegion(
          minX: metadataRegion.minX,
          minY: metadataRegion.minY,
          width: metadataRegion.width,
          height: metadataRegion.height
        )
        reportGeometry(
          .guideRejected,
          orientation: appliedOrientation,
          nativeRegion: rejectedRegion
        )
        publishGuide(nil)
        return
      }

      let acceptedRegion = DocumentCameraGuideRegion(
        minX: metadataRegion.minX,
        minY: metadataRegion.minY,
        width: metadataRegion.width,
        height: metadataRegion.height
      )
      reportGeometry(
        .guideAccepted,
        orientation: appliedOrientation,
        nativeRegion: acceptedRegion
      )
      publishGuide(acceptedRegion)
    }

    private func publishGuide(_ region: DocumentCameraGuideRegion?) {
      guard let generation = authority.sourceGeneration else { return }
      let canPublish =
        authority.canPublishGuide && window != nil && previewLayer.isPreviewing
        && previewStopPending.withLock { !$0 }
      previewProvider.updatePreviewGeometry(
        orientation: appliedOrientation ?? .portrait,
        region: canPublish ? region : nil,
        sourceGeneration: generation
      )
    }

    private func approximatelyEqual(_ first: CGRect, _ second: CGRect, tolerance: CGFloat) -> Bool {
      abs(first.minX - second.minX) <= tolerance
        && abs(first.minY - second.minY) <= tolerance
        && abs(first.width - second.width) <= tolerance
        && abs(first.height - second.height) <= tolerance
    }

    private func reportGeometry(
      _ status: DocumentCameraPreviewGeometryDiagnostic.Status,
      orientation: DocumentCameraOrientation?,
      nativeRegion: DocumentCameraGuideRegion? = nil
    ) {
      let guideFrame = localGuideFrame
      let diagnostic = DocumentCameraPreviewGeometryDiagnostic(
        status: status,
        orientation: orientation,
        previewWidth: Double(bounds.width),
        previewHeight: Double(bounds.height),
        guideMinX: guideFrame.map { Double($0.minX) },
        guideMinY: guideFrame.map { Double($0.minY) },
        guideWidth: guideFrame.map { Double($0.width) },
        guideHeight: guideFrame.map { Double($0.height) },
        nativeRegion: nativeRegion
      )
      guard diagnostic != lastGeometryDiagnostic else { return }
      lastGeometryDiagnostic = diagnostic
      previewProvider.recordPreviewGeometry(diagnostic)
    }

    private var localGuideFrame: CGRect? {
      guideFrame
    }
  }

#endif
