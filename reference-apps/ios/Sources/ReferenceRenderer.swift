import UIKit

@MainActor struct ReferenceAction {
    let identifier: String
    let title: String
    let hint: String
    let enabled: Bool
    let event: ReferenceEvent
    var configuration: UIButton.Configuration = KenshikiIOSDesign.primaryConfiguration()
}

struct ReferenceParagraph {
    let text: String
    let role: KenshikiIOSTextRole
    let identifier: String
}

struct ReferenceScreen {
    let title: String
    let heading: String
    let paragraphs: [ReferenceParagraph]
    let primaryActions: [ReferenceAction]
    var contentActions: [ReferenceAction] = []
    var image: UIImage? = nil
    var imageLabel: String? = nil
}

/// Rendering only: prepared copy and action placement come from the host.
@MainActor final class ReferenceRenderer: NativePageContainer {
    private var accessibilityElementsByIdentifier: [String: UIView] = [:]
    private var screen: ReferenceScreen
    private let emit: (ReferenceEvent) -> Void

    init(screen: ReferenceScreen, emit: @escaping (ReferenceEvent) -> Void) {
        self.screen = screen
        self.emit = emit
        super.init(nibName: nil, bundle: nil)
        title = screen.title
        navigationItem.largeTitleDisplayMode = .never
        pageSpacing = KenshikiDesign.pageSpacing
        contentSpacing = KenshikiDesign.gapSpacing
        contentMaximum = KenshikiDesign.contentMax
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        renderPreparedState(screen)
    }

    func apply(_ screen: ReferenceScreen) {
        self.screen = screen
        title = screen.title
        loadViewIfNeeded()
        renderPreparedState(screen)
    }

    private func renderPreparedState(_ screen: ReferenceScreen) {
        accessibilityElementsByIdentifier.removeAll()
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        primaryRegion.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let heading = label(screen.heading, role: .title, identifier: "workflow.step")
        heading.accessibilityTraits.insert(.header)
        content.addArrangedSubview(heading)
        if let image = screen.image {
            let portrait = UIImageView(image: image)
            portrait.contentMode = .scaleAspectFit
            portrait.heightAnchor.constraint(equalToConstant: KenshikiDesign.passportMediaHeight).isActive = true
            portrait.isAccessibilityElement = true
            portrait.accessibilityLabel = screen.imageLabel
            content.addArrangedSubview(portrait)
        }
        for paragraph in screen.paragraphs {
            content.addArrangedSubview(label(paragraph.text, role: paragraph.role, identifier: paragraph.identifier))
        }
        for action in screen.contentActions {
            content.addArrangedSubview(button(action, configuration: action.configuration))
        }
        for action in screen.primaryActions {
            primaryRegion.addArrangedSubview(button(action, configuration: action.configuration))
        }
        primaryRegion.accessibilityIdentifier = "page.primaryActions"
        view.accessibilityIdentifier = "page.instruction"
    }

    func accessibilityElement(identifier: String) -> UIView? { accessibilityElementsByIdentifier[identifier] }

    private func button(_ action: ReferenceAction, configuration: UIButton.Configuration) -> UIButton {
        let button = MultilineActionButton(type: .system)
        var prepared = configuration
        prepared.title = action.title
        prepared.buttonSize = .large
        prepared.titleLineBreakMode = .byWordWrapping
        button.configuration = prepared
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.accessibilityHint = action.hint
        button.accessibilityIdentifier = action.identifier
        button.isEnabled = action.enabled
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: KenshikiDesign.minimumTargetIOS).isActive = true
        button.addAction(UIAction { [emit] _ in emit(action.event) }, for: .touchUpInside)
        accessibilityElementsByIdentifier[action.identifier] = button
        return button
    }

    private func label(_ value: String, role: KenshikiIOSTextRole, identifier: String) -> UILabel {
        let label = UILabel()
        label.text = value
        label.numberOfLines = 0
        label.font = KenshikiIOSDesign.font(role)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = KenshikiIOSDesign.color(.text)
        label.accessibilityIdentifier = identifier
        accessibilityElementsByIdentifier[identifier] = label
        return label
    }
}
