import UIKit

struct DocumentFlowDisplayItem {
    let title: String
    let text: String
    let image: UIImage?
    let identifier: String
}

struct DocumentFlowScreen {
    let title: String
    let heading: String
    let message: String
    let scope: String
    let preview: UIView?
    let previewLabel: String
    let items: [DocumentFlowDisplayItem]
    let actionSurface: UIView
    var captureSurface: UIView? = nil
}

/// Renders supplied state and emits visibility facts. Camera and workflow ownership stay outside.
@MainActor final class DocumentFlowRenderer: NativePageContainer {
    private let emit: (DocumentFlowIntent) -> Void
    private var screen: DocumentFlowScreen
    private let headingLabel = UILabel()
    private let messageLabel = UILabel()
    private let media = UIStackView()
    private let observations = UIStackView()
    private let scopeLabel = UILabel()
    private let captureRegion = UIView()
    private var mountedCaptureSurface: UIView?
    private var mountedPreview: UIView?
    private var previewHeight: NSLayoutConstraint?

    init(screen: DocumentFlowScreen, emit: @escaping (DocumentFlowIntent) -> Void) {
        self.screen = screen
        self.emit = emit
        super.init(nibName: nil, bundle: nil)
        pageSpacing = KenshikiDesign.pageSpacing
        contentSpacing = KenshikiDesign.gapSpacing
        contentMaximum = KenshikiDesign.contentMax
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        headingLabel.numberOfLines = 0; messageLabel.numberOfLines = 0; scopeLabel.numberOfLines = 0
        headingLabel.font = KenshikiIOSDesign.font(.title)
        headingLabel.accessibilityTraits.insert(.header)
        headingLabel.accessibilityIdentifier = "document.heading"
        messageLabel.font = KenshikiIOSDesign.font(.body)
        messageLabel.accessibilityIdentifier = "document.message"
        scopeLabel.font = KenshikiIOSDesign.font(.caption)
        scopeLabel.accessibilityIdentifier = "document.scope"
        for label in [headingLabel, messageLabel, scopeLabel] {
            label.textColor = KenshikiIOSDesign.color(.text)
            label.adjustsFontForContentSizeCategory = true
        }
        media.axis = .vertical; observations.axis = .vertical
        observations.spacing = KenshikiDesign.gapSpacing
        content.addArrangedSubview(headingLabel); content.addArrangedSubview(messageLabel)
        content.addArrangedSubview(media); content.addArrangedSubview(observations); content.addArrangedSubview(scopeLabel)
        captureRegion.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captureRegion)
        NSLayoutConstraint.activate([
            captureRegion.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            captureRegion.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            captureRegion.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            captureRegion.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        renderPreparedState(screen)
    }

    func apply(_ screen: DocumentFlowScreen) {
        self.screen = screen
        guard isViewLoaded else { return }
        renderPreparedState(screen)
    }

    private func renderPreparedState(_ screen: DocumentFlowScreen) {
        title = screen.title
        headingLabel.text = screen.heading; messageLabel.text = screen.message; scopeLabel.text = screen.scope
        captureRegion.isHidden = screen.captureSurface == nil
        content.superview?.isHidden = screen.captureSurface != nil
        primaryRegion.isHidden = screen.captureSurface != nil
        if mountedCaptureSurface !== screen.captureSurface {
            mountedCaptureSurface?.removeFromSuperview()
            mountedCaptureSurface = screen.captureSurface
            if let surface = screen.captureSurface {
                surface.translatesAutoresizingMaskIntoConstraints = false
                captureRegion.addSubview(surface)
                NSLayoutConstraint.activate([
                    surface.leadingAnchor.constraint(equalTo: captureRegion.leadingAnchor),
                    surface.trailingAnchor.constraint(equalTo: captureRegion.trailingAnchor),
                    surface.topAnchor.constraint(equalTo: captureRegion.topAnchor),
                    surface.bottomAnchor.constraint(equalTo: captureRegion.bottomAnchor)
                ])
            }
        }
        if mountedPreview !== screen.preview {
            previewHeight?.isActive = false
            mountedPreview?.removeFromSuperview()
            mountedPreview = screen.preview
            if let preview = screen.preview {
                media.addArrangedSubview(preview)
                previewHeight = preview.heightAnchor.constraint(equalTo: preview.widthAnchor,
                    multiplier: KenshikiDesign.documentPreviewHeight / KenshikiDesign.documentPreviewWidth)
                previewHeight?.isActive = true
            }
        }
        if let preview = screen.preview {
            preview.accessibilityLabel = screen.previewLabel
            preview.accessibilityIdentifier = "document.preview"
            preview.isAccessibilityElement = true
        }
        observations.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in screen.items {
            let heading = label(item.title, identifier: item.identifier + ".title")
            heading.accessibilityTraits.insert(.header)
            observations.addArrangedSubview(heading)
            if let image = item.image {
                let media = UIImageView(image: image)
                media.contentMode = .scaleAspectFit
                media.heightAnchor.constraint(equalToConstant: KenshikiDesign.passportMediaHeight).isActive = true
                media.isAccessibilityElement = true
                media.accessibilityLabel = item.title
                media.accessibilityIdentifier = item.identifier + ".image"
                observations.addArrangedSubview(media)
            }
            observations.addArrangedSubview(label(item.text, identifier: item.identifier + ".text"))
        }
        if screen.actionSurface.superview !== primaryRegion {
            primaryRegion.arrangedSubviews.forEach { $0.removeFromSuperview() }
            primaryRegion.addArrangedSubview(screen.actionSurface)
        }
        view.accessibilityIdentifier = "document.page"
    }

    private func label(_ text: String, identifier: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = KenshikiIOSDesign.font(.body)
        label.textColor = KenshikiIOSDesign.color(.text)
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = identifier
        return label
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        emit(.visible)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        emit(.hidden)
    }
}
