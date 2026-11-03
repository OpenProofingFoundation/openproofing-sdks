import UIKit

/// Platform layout only. This container has no knowledge of SDK workflow states or events.
@MainActor class NativePageContainer: UIViewController {
    let content = UIStackView()
    let primaryRegion = UIStackView()
    var pageSpacing: CGFloat = 0
    var contentSpacing: CGFloat = 0
    var contentMaximum: CGFloat = 0

    override func loadView() {
        let root = UIView()
        root.backgroundColor = KenshikiIOSDesign.color(.background)
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        root.addSubview(scroll)
        content.axis = .vertical
        content.spacing = contentSpacing
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        primaryRegion.axis = .vertical
        primaryRegion.spacing = contentSpacing
        primaryRegion.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(primaryRegion)
        let preferredWidth = content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -pageSpacing * 2)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            scroll.bottomAnchor.constraint(equalTo: primaryRegion.topAnchor, constant: -pageSpacing),
            content.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.leadingAnchor, constant: pageSpacing),
            content.trailingAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.trailingAnchor, constant: -pageSpacing),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: pageSpacing),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -pageSpacing),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: contentMaximum),
            preferredWidth,
            primaryRegion.centerXAnchor.constraint(equalTo: root.safeAreaLayoutGuide.centerXAnchor),
            primaryRegion.widthAnchor.constraint(equalTo: content.widthAnchor),
            primaryRegion.bottomAnchor.constraint(equalTo: root.keyboardLayoutGuide.topAnchor, constant: -pageSpacing)
        ])
        view = root
    }
}

/// Native view reconciliation only; a supplied live view stays mounted across label updates.
@MainActor final class StableMediaSurface: UIView {
    var onLayout: ((CGSize) -> Void)?
    private var mountedPreview: UIView?
    private let imageView = UIImageView()

    func apply(preview: UIView?, image: UIImage?, previewLabel: String, imageLabel: String,
               previewIdentifier: String, imageIdentifier: String, overlay: CALayer) {
        if mountedPreview !== preview {
            mountedPreview?.removeFromSuperview()
            mountedPreview = preview
            if let preview {
                preview.frame = bounds
                preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                preview.accessibilityLabel = previewLabel
                preview.accessibilityIdentifier = previewIdentifier
                preview.isAccessibilityElement = false
                addSubview(preview)
            }
        }
        if preview != nil {
            if overlay.superlayer !== layer { layer.addSublayer(overlay) }
        } else { overlay.removeFromSuperlayer() }
        if let image {
            imageView.image = image
            imageView.contentMode = .scaleAspectFit
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.isAccessibilityElement = true
            imageView.accessibilityLabel = imageLabel
            imageView.accessibilityIdentifier = imageIdentifier
            if imageView.superview !== self {
                imageView.frame = bounds
                addSubview(imageView)
            }
        } else {
            imageView.image = nil
            imageView.removeFromSuperview()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }
}

/// Reserves the tallest supplied localized alternative at the actual width and font size.
@MainActor final class VariantHeightLabel: UILabel {
    var variants: [String] = [] { didSet { if oldValue != variants { setNeedsLayout() } } }
    private lazy var minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 0)

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, let font else { return }
        let height = variants.map { text in
            (text as NSString).boundingRect(with: CGSize(width: bounds.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
        }.max() ?? 0
        minimumHeight.isActive = true
        let reserved = ceil(height)
        if minimumHeight.constant != reserved { minimumHeight.constant = reserved }
    }
}

/// Keeps a wrapped, dynamically sized title inside its native button surface.
@MainActor final class MultilineActionButton: UIButton {
    private lazy var titleMinimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 0)

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let titleLabel, let configuration else { return }
        let insets = configuration.contentInsets
        let width = bounds.width - insets.leading - insets.trailing
        guard width > 0 else { return }
        let textHeight = titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = ceil(textHeight + insets.top + insets.bottom)
        titleMinimumHeight.isActive = true
        if titleMinimumHeight.constant != height { titleMinimumHeight.constant = height }
    }
}
