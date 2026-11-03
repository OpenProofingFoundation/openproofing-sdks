#if os(iOS)
  public enum DocumentFrontCaptureIntent: Equatable, Sendable { case capture, cancel }

  /// Fully prepared content and availability. Navigation and capture authority stay with the host.
  public struct DocumentFrontCaptureState: Equatable, Sendable {
    public let heading: String
    public let instruction: String
    public let status: String
    public let captureTitle: String
    public let cancelTitle: String
    public let previewAccessibilityLabel: String
    public let levelAccessibilityLabel: String
    public let levelAccessibilityValue: String
    public let level: DocumentLevelState
    public let captureEnabled: Bool
    public let busy: Bool
    public let showLevel: Bool

    public init(
      heading: String, instruction: String, status: String, captureTitle: String, cancelTitle: String,
      previewAccessibilityLabel: String, levelAccessibilityLabel: String, levelAccessibilityValue: String,
      level: DocumentLevelState, captureEnabled: Bool, busy: Bool, showLevel: Bool
    ) {
      self.heading = heading; self.instruction = instruction; self.status = status
      self.captureTitle = captureTitle; self.cancelTitle = cancelTitle
      self.previewAccessibilityLabel = previewAccessibilityLabel
      self.levelAccessibilityLabel = levelAccessibilityLabel
      self.levelAccessibilityValue = levelAccessibilityValue; self.level = level
      self.captureEnabled = captureEnabled; self.busy = busy; self.showLevel = showLevel
    }
  }
#endif
