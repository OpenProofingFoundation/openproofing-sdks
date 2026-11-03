#if os(iOS)
  import UIKit

  /// Hosts supply native design tokens. This optional surface has no product branding or copy.
  @MainActor public struct DocumentFrontCaptureStyle {
    public struct Fonts {
      public let heading: UIFont
      public let body: UIFont
      public let status: UIFont
      public let action: UIFont
      public init(heading: UIFont, body: UIFont, status: UIFont, action: UIFont) {
        self.heading = heading; self.body = body; self.status = status; self.action = action
      }
    }

    public struct Colors {
      public let background: UIColor
      public let text: UIColor
      public let secondaryText: UIColor
      public let previewBackground: UIColor
      public let previewBorder: UIColor
      public let levelBackground: UIColor
      public let levelLine: UIColor
      public let levelGood: UIColor
      public let levelWarning: UIColor
      public let levelTilted: UIColor
      public let captureBackground: UIColor
      public let captureForeground: UIColor
      public let cancelForeground: UIColor
      public init(
        background: UIColor, text: UIColor, secondaryText: UIColor,
        previewBackground: UIColor, previewBorder: UIColor, levelBackground: UIColor,
        levelLine: UIColor, levelGood: UIColor, levelWarning: UIColor, levelTilted: UIColor,
        captureBackground: UIColor, captureForeground: UIColor, cancelForeground: UIColor
      ) {
        self.background = background; self.text = text; self.secondaryText = secondaryText
        self.previewBackground = previewBackground; self.previewBorder = previewBorder
        self.levelBackground = levelBackground; self.levelLine = levelLine
        self.levelGood = levelGood; self.levelWarning = levelWarning; self.levelTilted = levelTilted
        self.captureBackground = captureBackground; self.captureForeground = captureForeground
        self.cancelForeground = cancelForeground
      }
    }

    public struct Layout {
      public let insets: NSDirectionalEdgeInsets
      public let sectionSpacing: CGFloat
      public let guidanceSpacing: CGFloat
      public let previewAspectRatio: CGFloat
      public let previewCornerRadius: CGFloat
      public let borderWidth: CGFloat
      public let levelDiameter: CGFloat
      public let levelTravel: CGFloat
      public let levelInnerDiameter: CGFloat
      public let levelBubbleDiameter: CGFloat
      public let levelCrosshairLength: CGFloat
      public let controlHeight: CGFloat
      public let controlCornerRadius: CGFloat
      public let statusMinimumHeight: CGFloat
      public init(
        insets: NSDirectionalEdgeInsets, sectionSpacing: CGFloat, guidanceSpacing: CGFloat,
        previewAspectRatio: CGFloat, previewCornerRadius: CGFloat, borderWidth: CGFloat,
        levelDiameter: CGFloat, levelTravel: CGFloat, levelInnerDiameter: CGFloat,
        levelBubbleDiameter: CGFloat, levelCrosshairLength: CGFloat,
        controlHeight: CGFloat, controlCornerRadius: CGFloat, statusMinimumHeight: CGFloat
      ) {
        self.insets = insets; self.sectionSpacing = sectionSpacing; self.guidanceSpacing = guidanceSpacing
        self.previewAspectRatio = previewAspectRatio; self.previewCornerRadius = previewCornerRadius
        self.borderWidth = borderWidth; self.levelDiameter = levelDiameter; self.levelTravel = levelTravel
        self.levelInnerDiameter = levelInnerDiameter; self.levelBubbleDiameter = levelBubbleDiameter
        self.levelCrosshairLength = levelCrosshairLength; self.controlHeight = controlHeight
        self.controlCornerRadius = controlCornerRadius; self.statusMinimumHeight = statusMinimumHeight
      }
    }

    public let fonts: Fonts
    public let colors: Colors
    public let layout: Layout
    public init(fonts: Fonts, colors: Colors, layout: Layout) {
      self.fonts = fonts; self.colors = colors; self.layout = layout
    }
  }
#endif
