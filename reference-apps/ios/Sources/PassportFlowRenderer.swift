import UIKit

enum PassportViewAction {
    case start, manual, confirm, scan, cancel, cancelScan, restart, retry, usePortrait, details
}
enum PassportField: Int, CaseIterable { case document, birth, expiry }
enum PassportViewIntent {
    case action(PassportViewAction)
    case edit(PassportField, String)
    case visible, hidden
}
struct PassportInput {
    let identifier: String
    let label: String
    let value: String
    let keyboard: UIKeyboardType
}
struct PassportResultRow {
    let label: String
    let value: String
    let identifier: String
}
struct PassportResultSection {
    let heading: String
    let rows: [PassportResultRow]
}
struct PassportFlowScreen {
    let title: String
    let heading: String
    let message: String
    let scope: String
    let fields: [PassportInput]
    let fieldsHidden: Bool
    let preview: UIView?
    let image: UIImage?
    let imageLabel: String
    let mediaHidden: Bool
    let sections: [PassportResultSection]
    let actionSurface: UIView
}

/// Native rendering only: prepared copy, fields, media and sections; raw input goes to the host.
@MainActor final class PassportFlowRenderer: NativePageContainer {
    private let heading = UILabel()
    private let message = UILabel()
    private let scope = UILabel()
    private let media = UIView()
    private let form = UIStackView()
    private let details = UIStackView()
    private var inputs: [UITextField] = []
    private var fieldLabels: [UILabel] = []
    private var screen: PassportFlowScreen
    private let emit: (PassportViewIntent) -> Void
    var headingElement: UIView { heading }

    init(screen: PassportFlowScreen, emit: @escaping (PassportViewIntent) -> Void) {
        self.screen = screen
        self.emit = emit
        super.init(nibName: nil, bundle: nil)
        pageSpacing = KenshikiDesign.pageSpacing
        contentSpacing = KenshikiDesign.gapSpacing
        contentMaximum = KenshikiDesign.contentMax
        navigationItem.largeTitleDisplayMode = .never
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        super.loadView()
        heading.font = KenshikiIOSDesign.font(.title)
        heading.accessibilityTraits.insert(.header)
        heading.accessibilityIdentifier = "passport.heading"
        message.font = KenshikiIOSDesign.font(.body)
        message.accessibilityIdentifier = "passport.message"
        scope.font = KenshikiIOSDesign.font(.caption)
        scope.accessibilityIdentifier = "passport.scope"
        for label in [heading, message, scope] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.textColor = KenshikiIOSDesign.color(.text)
        }
        form.axis = .vertical
        form.spacing = KenshikiDesign.compactSpacing
        for field in PassportField.allCases {
            let label = UILabel()
            label.font = KenshikiIOSDesign.font(.caption)
            label.textColor = KenshikiIOSDesign.color(.secondary)
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            let input = UITextField()
            input.borderStyle = .roundedRect
            input.font = KenshikiIOSDesign.font(.body)
            input.adjustsFontForContentSizeCategory = true
            input.autocorrectionType = .no
            input.spellCheckingType = .no
            input.autocapitalizationType = .allCharacters
            input.textContentType = .none
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: KenshikiDesign.minimumTargetIOS).isActive = true
            input.addAction(UIAction { [emit, weak input] _ in emit(.edit(field, input?.text ?? "")) }, for: .editingChanged)
            form.addArrangedSubview(label)
            form.addArrangedSubview(input)
            fieldLabels.append(label)
            inputs.append(input)
        }
        media.heightAnchor.constraint(equalToConstant: KenshikiDesign.passportMediaHeight).isActive = true
        media.clipsToBounds = true
        media.layer.cornerRadius = KenshikiDesign.cardRadius
        details.axis = .vertical
        details.spacing = KenshikiDesign.gapSpacing
        for child in [heading, message, media, form, details, scope] { content.addArrangedSubview(child) }
        primaryRegion.addArrangedSubview(screen.actionSurface)
        view.accessibilityIdentifier = "passport.page"
        renderPreparedState(screen)
    }
    func apply(_ screen: PassportFlowScreen) {
        self.screen = screen
        guard isViewLoaded else { return }
        renderPreparedState(screen)
    }
    private func renderPreparedState(_ screen: PassportFlowScreen) {
        title = screen.title
        heading.text = screen.heading
        message.text = screen.message
        scope.text = screen.scope
        for (index, field) in screen.fields.enumerated() {
            fieldLabels[index].text = field.label
            inputs[index].text = field.value
            inputs[index].accessibilityIdentifier = field.identifier
            inputs[index].accessibilityLabel = field.label
            inputs[index].keyboardType = field.keyboard
        }
        form.isHidden = screen.fieldsHidden
        media.subviews.forEach { $0.removeFromSuperview() }
        if let preview = screen.preview {
            media.addSubview(preview)
            preview.frame = media.bounds
            preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            preview.isAccessibilityElement = false
        }
        if let image = screen.image {
            let picture = UIImageView(image: image)
            picture.contentMode = .scaleAspectFit
            picture.frame = media.bounds
            picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            picture.isAccessibilityElement = true
            picture.accessibilityLabel = screen.imageLabel
            picture.accessibilityIdentifier = "passport.portrait"
            media.addSubview(picture)
        }
        media.isHidden = screen.mediaHidden
        details.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for section in screen.sections {
            let group = UIStackView()
            group.axis = .vertical
            group.spacing = KenshikiDesign.compactSpacing
            group.isLayoutMarginsRelativeArrangement = true
            group.directionalLayoutMargins = NSDirectionalEdgeInsets(top: KenshikiDesign.gapSpacing, leading: KenshikiDesign.gapSpacing, bottom: KenshikiDesign.gapSpacing, trailing: KenshikiDesign.gapSpacing)
            group.backgroundColor = KenshikiIOSDesign.color(.surface)
            group.layer.cornerRadius = KenshikiDesign.cardRadius
            let title = preparedLabel(section.heading, role: .action)
            title.accessibilityTraits.insert(.header)
            group.addArrangedSubview(title)
            for row in section.rows {
                group.addArrangedSubview(preparedLabel(row.label, role: .caption))
                let value = preparedLabel(row.value, role: .body)
                value.accessibilityIdentifier = row.identifier
                group.addArrangedSubview(value)
            }
            details.addArrangedSubview(group)
        }
    }
    private func preparedLabel(_ value: String, role: KenshikiIOSTextRole) -> UILabel {
        let label = UILabel()
        label.text = value
        label.font = KenshikiIOSDesign.font(role)
        label.textColor = KenshikiIOSDesign.color(.text)
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.adjustsFontForContentSizeCategory = true
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
    func dismissKeyboard() { view.endEditing(true) }
}
