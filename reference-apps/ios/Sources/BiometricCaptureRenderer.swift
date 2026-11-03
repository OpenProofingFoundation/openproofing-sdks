import UIKit

enum BiometricCaptureViewIntent {
    case action(BiometricCaptureIntent)
    case viewport(CGSize, UIInterfaceOrientation)
}

struct BiometricCaptureScreen {
    let title: String
    let heading: String
    let message: String
    let scope: String
    let previewLabel: String
    let imageLabel: String
    let preview: UIView?
    let image: UIImage?
    let mediaHidden: Bool
    let actionSurface: UIView
    var messageVariants: [String] = []
}

/// Prepared-state renderer. It reports native visibility/layout facts and typed holder intents.
@MainActor final class BiometricCaptureRenderer: NativePageContainer {
    private let heading = UILabel()
    private let message = VariantHeightLabel()
    private let scope = UILabel()
    private let media = StableMediaSurface()
    private let guide = CAShapeLayer()
    var headingElement: UIView { heading }
    private let emit: (BiometricCaptureViewIntent) -> Void
    private var screen: BiometricCaptureScreen

    init(screen: BiometricCaptureScreen, emit: @escaping (BiometricCaptureViewIntent) -> Void) {
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
        for label in [heading, message, scope] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.textColor = KenshikiIOSDesign.color(.text)
        }
        heading.font = KenshikiIOSDesign.font(.title)
        heading.accessibilityTraits.insert(.header)
        heading.accessibilityIdentifier = "capture.heading"
        message.font = KenshikiIOSDesign.font(.body)
        message.accessibilityIdentifier = "capture.message"
        scope.font = KenshikiIOSDesign.font(.caption)
        let mediaAspect = media.heightAnchor.constraint(equalTo: media.widthAnchor)
        mediaAspect.priority = .defaultLow
        mediaAspect.isActive = true
        media.clipsToBounds = true
        media.onLayout = { [weak self] size in self?.publishViewport(size) }
        guide.fillColor = nil
        guide.strokeColor = KenshikiIOSDesign.color(.accent).cgColor
        guide.lineWidth = KenshikiDesign.borderWidth
        for child in [heading, media, message, scope] { content.addArrangedSubview(child) }
        primaryRegion.addArrangedSubview(screen.actionSurface)
        renderPreparedState(screen)
        view.accessibilityIdentifier = "capture.page"
    }

    func apply(_ screen: BiometricCaptureScreen) {
        self.screen = screen
        guard isViewLoaded else { return }
        renderPreparedState(screen)
    }

    private func renderPreparedState(_ screen: BiometricCaptureScreen) {
        title = screen.title
        heading.text = screen.heading
        message.text = screen.message
        message.variants = screen.messageVariants
        scope.text = screen.scope
        media.apply(preview: screen.preview, image: screen.image,
            previewLabel: screen.previewLabel, imageLabel: screen.imageLabel,
            previewIdentifier: "capture.preview", imageIdentifier: "capture.image", overlay: guide)
        media.isHidden = screen.mediaHidden
    }

    func applyGuide(_ oval: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guide.frame = media.bounds
        guide.path = UIBezierPath(ovalIn: oval).cgPath
        CATransaction.commit()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        emit(.action(.visible))
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        emit(.action(.hidden))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content.layoutIfNeeded()
        publishViewport(media.bounds.size)
    }

    private func publishViewport(_ size: CGSize) {
        emit(.viewport(size, view.window?.windowScene?.interfaceOrientation ?? .portrait))
    }
}
