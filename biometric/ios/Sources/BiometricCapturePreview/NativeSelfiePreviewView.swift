#if os(iOS)
  import ARKit
  @_spi(Preview) import BiometricCapture

  /// Optional rendering surface; lifecycle and frame admission remain owned by NativeSelfieSession.
  @MainActor
  public final class NativeSelfiePreviewView: ARSCNView {
    public init(captureSession: NativeSelfieSession) {
      super.init(frame: .zero, options: nil)
      session = captureSession.previewSession
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
  }
#endif
