#if os(iOS)
  import UIKit

  /// Reusable front surface adapted from SSA's fixed guidance row and Pulse's themed viewport.
  /// Applies prepared content and emits intents; the host owns acquisition, consent and lifecycle.
  @MainActor public final class DocumentFrontCaptureView: UIView {
    public let preview: DocumentCameraPreviewView
    private let emit: (DocumentFrontCaptureIntent) -> Void
    private let heading = UILabel()
    private let instruction = UILabel()
    private let status = UILabel()
    private let captureButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let progress = UIActivityIndicatorView()
    private let level: DocumentFrontCaptureLevelView
    private let levelRow = UIView()
    private let viewport = UIView()
    private let previewBorderColor: UIColor

    public init(
      preview: DocumentCameraPreviewView, style: DocumentFrontCaptureStyle,
      emit: @escaping (DocumentFrontCaptureIntent) -> Void
    ) {
      self.preview = preview; self.emit = emit
      level = DocumentFrontCaptureLevelView(style: style)
      previewBorderColor = style.colors.previewBorder
      super.init(frame: .zero)
      backgroundColor = style.colors.background
      configureLabels(style)
      configureControls(style)
      configureLayout(style)
      refreshBorderColor()
      registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
        (view: DocumentFrontCaptureView, _: UITraitCollection) in view.refreshBorderColor()
      }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    public func apply(_ state: DocumentFrontCaptureState) {
      heading.text = state.heading; instruction.text = state.instruction; status.text = state.status
      captureButton.setTitle(state.captureTitle, for: .normal)
      cancelButton.setTitle(state.cancelTitle, for: .normal)
      captureButton.isEnabled = state.captureEnabled
      preview.accessibilityLabel = state.previewAccessibilityLabel
      level.apply(state.level, label: state.levelAccessibilityLabel, value: state.levelAccessibilityValue)
      levelRow.isHidden = !state.showLevel
      if state.busy { progress.startAnimating() } else { progress.stopAnimating() }
      setNeedsLayout()
    }

    private func configureLabels(_ style: DocumentFrontCaptureStyle) {
      heading.font = style.fonts.heading; instruction.font = style.fonts.body; status.font = style.fonts.status
      heading.textColor = style.colors.text
      instruction.textColor = style.colors.secondaryText; status.textColor = style.colors.secondaryText
      heading.numberOfLines = 0; instruction.numberOfLines = 0; status.numberOfLines = 0
      heading.textAlignment = .center; instruction.textAlignment = .center; status.textAlignment = .center
      heading.adjustsFontForContentSizeCategory = true
      instruction.adjustsFontForContentSizeCategory = true; status.adjustsFontForContentSizeCategory = true
      heading.accessibilityTraits.insert(.header); status.accessibilityTraits.insert(.updatesFrequently)
      heading.accessibilityIdentifier = "document.front.heading"
      status.accessibilityIdentifier = "document.front.status"
      preview.isAccessibilityElement = true
      preview.accessibilityIdentifier = "document.front.preview"
    }

    private func configureControls(_ style: DocumentFrontCaptureStyle) {
      captureButton.titleLabel?.font = style.fonts.action; cancelButton.titleLabel?.font = style.fonts.action
      captureButton.titleLabel?.adjustsFontForContentSizeCategory = true
      cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
      captureButton.titleLabel?.numberOfLines = 0; cancelButton.titleLabel?.numberOfLines = 0
      captureButton.titleLabel?.textAlignment = .center; cancelButton.titleLabel?.textAlignment = .center
      captureButton.backgroundColor = style.colors.captureBackground
      captureButton.isEnabled = false
      captureButton.setTitleColor(style.colors.captureForeground, for: .normal)
      cancelButton.setTitleColor(style.colors.cancelForeground, for: .normal)
      captureButton.layer.cornerRadius = style.layout.controlCornerRadius
      captureButton.accessibilityIdentifier = "document.front.capture"
      cancelButton.accessibilityIdentifier = "document.front.cancel"
      captureButton.addTarget(self, action: #selector(captureRequested), for: .touchUpInside)
      cancelButton.addTarget(self, action: #selector(cancelRequested), for: .touchUpInside)
      progress.color = style.colors.captureForeground
      progress.isAccessibilityElement = false
      progress.hidesWhenStopped = true
    }

    private func configureLayout(_ style: DocumentFrontCaptureStyle) {
      let layout = style.layout
      let scroll = UIScrollView()
      let content = UIStackView()
      let guidance = UIStackView()
      scroll.translatesAutoresizingMaskIntoConstraints = false
      content.translatesAutoresizingMaskIntoConstraints = false
      content.axis = .vertical; content.spacing = layout.sectionSpacing
      content.isLayoutMarginsRelativeArrangement = true; content.directionalLayoutMargins = layout.insets
      guidance.axis = .vertical; guidance.spacing = layout.guidanceSpacing
      viewport.translatesAutoresizingMaskIntoConstraints = false
      viewport.backgroundColor = style.colors.previewBackground
      viewport.layer.cornerRadius = layout.previewCornerRadius; viewport.clipsToBounds = true
      viewport.layer.borderWidth = layout.borderWidth
      preview.translatesAutoresizingMaskIntoConstraints = false
      progress.translatesAutoresizingMaskIntoConstraints = false
      level.translatesAutoresizingMaskIntoConstraints = false
      addSubview(scroll); scroll.addSubview(content)
      viewport.addSubview(preview); viewport.addSubview(progress)
      levelRow.addSubview(level)
      guidance.addArrangedSubview(levelRow); guidance.addArrangedSubview(status)
      content.addArrangedSubview(heading); content.addArrangedSubview(instruction)
      content.addArrangedSubview(viewport); content.addArrangedSubview(guidance)
      content.addArrangedSubview(captureButton); content.addArrangedSubview(cancelButton)
      let levelRowHeight = levelRow.heightAnchor.constraint(equalToConstant: layout.levelDiameter)
      levelRowHeight.priority = .defaultHigh
      NSLayoutConstraint.activate([
        scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
        scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
        scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
        scroll.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
        content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
        content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        viewport.heightAnchor.constraint(equalTo: viewport.widthAnchor, multiplier: 1 / layout.previewAspectRatio),
        preview.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
        preview.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
        preview.topAnchor.constraint(equalTo: viewport.topAnchor),
        preview.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
        progress.centerXAnchor.constraint(equalTo: viewport.centerXAnchor),
        progress.centerYAnchor.constraint(equalTo: viewport.centerYAnchor),
        levelRowHeight,
        level.centerXAnchor.constraint(equalTo: levelRow.centerXAnchor),
        level.centerYAnchor.constraint(equalTo: levelRow.centerYAnchor),
        level.widthAnchor.constraint(equalToConstant: layout.levelDiameter),
        level.heightAnchor.constraint(equalToConstant: layout.levelDiameter),
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: layout.statusMinimumHeight),
        captureButton.heightAnchor.constraint(greaterThanOrEqualToConstant: layout.controlHeight),
        cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: layout.controlHeight),
      ])
    }

    private func refreshBorderColor() {
      viewport.layer.borderColor = previewBorderColor.resolvedColor(with: traitCollection).cgColor
    }

    @objc private func captureRequested() { emit(.capture) }
    @objc private func cancelRequested() { emit(.cancel) }
  }
#endif
