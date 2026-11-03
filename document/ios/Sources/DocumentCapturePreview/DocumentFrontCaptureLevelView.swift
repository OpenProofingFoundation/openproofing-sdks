#if os(iOS)
  import UIKit

  /// Draws supplied geometry only; freshness and gravity projection are outside the renderer.
  @MainActor final class DocumentFrontCaptureLevelView: UIView {
    private let style: DocumentFrontCaptureStyle
    private var state = DocumentLevelState.unavailable

    init(style: DocumentFrontCaptureStyle) {
      self.style = style
      super.init(frame: .zero)
      backgroundColor = .clear
      isOpaque = false
      isAccessibilityElement = true
      accessibilityIdentifier = "document.front.level"
      accessibilityTraits = .updatesFrequently
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    func apply(_ state: DocumentLevelState, label: String, value: String) {
      self.state = state
      accessibilityLabel = label
      accessibilityValue = value
      setNeedsDisplay()
    }

    override func draw(_: CGRect) {
      let center = CGPoint(x: bounds.midX, y: bounds.midY)
      let layout = style.layout
      let colors = style.colors
      let dial = circle(center: center, diameter: layout.levelDiameter - layout.borderWidth)
      colors.levelBackground.setFill(); dial.fill()
      colors.levelLine.setStroke(); dial.lineWidth = layout.borderWidth; dial.stroke()
      let crosshair = UIBezierPath()
      crosshair.move(to: CGPoint(x: center.x, y: center.y - layout.levelCrosshairLength / 2))
      crosshair.addLine(to: CGPoint(x: center.x, y: center.y + layout.levelCrosshairLength / 2))
      crosshair.move(to: CGPoint(x: center.x - layout.levelCrosshairLength / 2, y: center.y))
      crosshair.addLine(to: CGPoint(x: center.x + layout.levelCrosshairLength / 2, y: center.y))
      crosshair.lineWidth = layout.borderWidth; crosshair.stroke()
      let inner = circle(center: center, diameter: layout.levelInnerDiameter)
      inner.lineWidth = layout.borderWidth; inner.stroke()
      if let offset = state.offset {
        let bubble = circle(center: CGPoint(
          x: center.x + offset.width * layout.levelTravel,
          y: center.y + offset.height * layout.levelTravel), diameter: layout.levelBubbleDiameter)
        bubbleColor.setFill(); bubble.fill()
        colors.levelLine.setStroke(); bubble.lineWidth = layout.borderWidth; bubble.stroke()
      } else {
        let unavailable = UIBezierPath()
        unavailable.move(to: CGPoint(x: center.x - layout.levelBubbleDiameter / 2, y: center.y))
        unavailable.addLine(to: CGPoint(x: center.x + layout.levelBubbleDiameter / 2, y: center.y))
        unavailable.lineWidth = layout.borderWidth; unavailable.stroke()
      }
    }

    private var bubbleColor: UIColor {
      switch state.tone {
      case .unavailable: style.colors.levelLine
      case .centered: style.colors.levelGood
      case .warning: style.colors.levelWarning
      case .tilted: style.colors.levelTilted
      }
    }

    private func circle(center: CGPoint, diameter: CGFloat) -> UIBezierPath {
      UIBezierPath(ovalIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
        width: diameter, height: diameter))
    }
  }
#endif
