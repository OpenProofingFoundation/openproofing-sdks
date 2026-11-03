#if os(iOS)
  import CoreGraphics

  /// Immutable AR adapter output. Analysis, admission and rendering retain this exact input.
  public struct SelfieCaptureFrame {
    let input: SelfieFrameInput
    let observation: SelfieAdmissionGate.Observation
    let displayTransform: CGAffineTransform
    let anchorPoint: CGPoint
    public init(
      input: SelfieFrameInput, observation: SelfieAdmissionGate.Observation,
      displayTransform: CGAffineTransform, anchorPoint: CGPoint
    ) {
      self.input = input
      self.observation = observation
      self.displayTransform = displayTransform
      self.anchorPoint = anchorPoint
    }
  }
#endif
