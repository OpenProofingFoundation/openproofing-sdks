import CryptoKit
import PassportSDK
import PassportNFC
import PassportMRZCapture
import PassportMRZPreview
import UIKit

/// Composition only: native effects, localized presentation and explicit issuer trust provisioning.
@MainActor final class PassportFlowHost: NSObject {
    let controller: PassportFlowController
    var onAccepted: ((AcceptedPassportPortrait) -> Void)?
    var onClose: (() -> Void)?
    var journeyMode = false
    var restoredMRZDate: Date?
    var evidenceStatusKey: String? { didSet { if oldValue != evidenceStatusKey { render() } } }
    private var detailsExpanded = false
    private var failureDetails: UINavigationController?
    private let native: PassportNativeEffects
    private let actions = UIStackView()
    private var buttons: [String: UIButton] = [:]
    private var renderer: PassportFlowRenderer?
    private var manual = false
    private var draft = PassportManualAccessFields(documentNumber: "", birthDateYYMMDD: "", expiryDateYYMMDD: "")
    private var previewImage: UIImage?
    private var imageAttempt: UUID?
    private var lastPhase: PassportFlowController.Phase?
    private var foreground = true
    private var visible = false

    override convenience init() { self.init(effects: nil) }

    init(effects: PassportFlowEffects?) {
        let native = PassportNativeEffects()
        self.native = native
        controller = PassportFlowController(effects: effects ?? native.effects)
        super.init()
        actions.axis = .vertical
        actions.spacing = KenshikiDesign.compactSpacing
        native.onPreview = { [weak self] in self?.render() }
        controller.onChange = { [weak self] in self?.render() }
        controller.onAccepted = { [weak self] value in self?.onAccepted?(value) }
        controller.onClose = { [weak self] in self?.onClose?() }
        if let url = PassportBundledTrust.url(in: .main) {
            controller.supplyTrustAnchors(url)
        }
    }

    func makeRenderer() -> PassportFlowRenderer {
        let page = PassportFlowRenderer(screen: screen(), emit: { [weak self] in self?.send($0) })
        renderer = page
        return page
    }
    func setBackgrounded(_ value: Bool) {
        foreground = !value
        if value {
            manual = false
            draft = .init(documentNumber: "", birthDateYYMMDD: "", expiryDateYYMMDD: "")
            previewImage = nil
        }
        controller.setBackgrounded(value)
    }
    func withdraw() {
        visible = false
        manual = false
        draft = .init(documentNumber: "", birthDateYYMMDD: "", expiryDateYYMMDD: "")
        previewImage = nil
        controller.send(.hidden)
    }

    private func send(_ intent: PassportViewIntent) {
        switch intent {
        case .visible:
            visible = true
            controller.send(.visible)
            render()
        case .hidden:
            withdraw()
        case .edit(let field, let value):
            switch field {
            case .document: draft = .init(documentNumber: value, birthDateYYMMDD: draft.birthDateYYMMDD, expiryDateYYMMDD: draft.expiryDateYYMMDD)
            case .birth: draft = .init(documentNumber: draft.documentNumber, birthDateYYMMDD: value, expiryDateYYMMDD: draft.expiryDateYYMMDD)
            case .expiry: draft = .init(documentNumber: draft.documentNumber, birthDateYYMMDD: draft.birthDateYYMMDD, expiryDateYYMMDD: value)
            }
        case .action(let action):
            renderer?.dismissKeyboard()
            switch action {
            case .start:
                manual = false
                controller.send(.startMRZ)
            case .manual:
                guard controller.canEnterManualAccessKey else { return }
                manual = true
                controller.send(.restart)
            case .confirm:
                if controller.accessFields != draft { controller.send(.manualKey(draft)) }
                controller.send(.confirmKey)
                manual = false
                if journeyMode { controller.send(.scan) }
                render()
            case .scan: controller.send(.scan)
            case .cancelScan: controller.send(.cancelScan)
            case .cancel, .restart:
                manual = false
                draft = .init(documentNumber: "", birthDateYYMMDD: "", expiryDateYYMMDD: "")
                if journeyMode, action == .cancel { controller.send(.cancel) }
                else {
                    controller.send(.restart)
                    if journeyMode { controller.send(.startMRZ) }
                }
            case .retry:
                if controller.phase == .mrzSaveFailure {
                    controller.send(.retryMRZSave)
                    return
                }
                if controller.phase == .saveFailure {
                    controller.send(.retrySave)
                    return
                }
                controller.send(.retryRead)
                if journeyMode {
                    if controller.phase == .start { controller.send(.startMRZ) }
                    else { controller.send(.scan) }
                }
            case .usePortrait: controller.send(.usePortrait)
            case .details:
                if controller.serverRejection != nil { presentFailureDetails(); return }
                detailsExpanded.toggle()
                render()
            }
        }
    }

    private func render() {
        if controller.phase == .confirm, let fields = controller.accessFields { draft = fields }
        if controller.phase != .result {
            detailsExpanded = false
            previewImage = nil
            imageAttempt = nil
        } else if imageAttempt != controller.attemptID {
            previewImage = controller.result?.portrait.flatMap { UIImage(data: $0) }
            imageAttempt = controller.attemptID
        }
        renderer?.apply(screen())
        if controller.phase != .failure || controller.serverRejection == nil {
            failureDetails?.dismiss(animated: false)
            failureDetails = nil
        }
        if lastPhase != controller.phase {
            lastPhase = controller.phase
            guard visible, foreground, renderer?.viewIfLoaded?.window != nil else { return }
            UIAccessibility.post(notification: .layoutChanged, argument: renderer?.headingElement)
        }
    }

    private func screen() -> PassportFlowScreen {
        let phase = controller.phase
        let heading: String
        var message: String
        var prepared: [PassportPreparedAction] = []
        var sections: [PassportResultSection] = []
        switch phase {
        case .start:
            heading = manual ? "passport.confirm.title" : "passport.start.title"
            message = copy(manual ? "passport.confirm.body" : "passport.start.body")
            if manual {
                prepared = [action(journeyMode ? "journey.readChip" : "passport.confirm", .confirm), action("passport.cancel", .cancel, primary: false)]
            } else {
                prepared = [action("passport.start", .start), action("passport.manual", .manual, primary: false)]
            }
        case .mrz:
            heading = "passport.mrz.title"
            message = copy("passport.mrz.body")
            prepared = [action("passport.manual", .manual), action("passport.cancel", .cancel, primary: false)]
        case .savingMRZ:
            heading = "passport.mrz.saving"
            message = copy("passport.mrz.saving")
            prepared = [action("passport.cancel", .cancel, primary: false)]
        case .mrzSaveFailure:
            heading = "passport.failure.title"
            message = copy("passport.mrz.saveFailed")
            prepared = [action("journey.saved.retry", .retry), action("passport.cancel", .cancel, primary: false)]
        case .confirm:
            heading = "passport.confirm.title"
            message = copy("passport.confirm.body")
            prepared = [action(journeyMode ? "journey.readChip" : "passport.confirm", .confirm), action("passport.cancel", .cancel, primary: false)]
        case .ready:
            heading = "passport.ready.title"
            message = copy("passport.ready.body")
            sections = [accessSection()]
            prepared = [action(journeyMode ? "journey.readChip" : "passport.scan", .scan), action("passport.cancel", .cancel, primary: false)]
        case .scanning:
            heading = "passport.scanning.title"
            switch controller.serverStage {
            case .preparing: message = copy("passport.server.preparing")
            case .verifying: message = copy("passport.server.verifying")
            default: message = PassportNFCText.localized().message(controller.event ?? .presenting)
            }
            prepared = [action("passport.cancelScan", .cancelScan, primary: false)]
        case .saving:
            heading = "journey.saved.saving"
            message = copy("journey.saved.saving")
        case .saveFailure:
            heading = "passport.failure.title"
            message = copy("journey.saved.failed")
            prepared = [action("journey.saved.retry", .retry), action("passport.cancel", .cancel, primary: false)]
        case .result:
            heading = "passport.result.verified"
            message = copy(journeyMode ? "journey.passportReady.body" : "passport.result.body")
            if let result = controller.result {
                sections = !journeyMode || detailsExpanded ? resultSections(result) : []
                if let server = controller.resultServerVerification {
                    sections.insert(.init(heading: copy("passport.server.title"), rows:
                        PassportServerPresentation.rows(server, historical: false,
                            includeProvenance: !journeyMode || detailsExpanded)), at: 0)
                }
                if controller.hasPortrait {
                    prepared.append(action(journeyMode ? "journey.continueSelfie" : "passport.use", .usePortrait))
                    if previewImage == nil { message = copy("passport.result.previewUnavailable") }
                } else { message = copy("passport.result.noPortrait") }
            }
            if journeyMode { prepared.append(action(detailsExpanded ? "journey.hideDetails" : "journey.viewDetails", .details, primary: false)) }
            prepared.append(action("passport.restart", .restart, primary: false))
        case .failure:
            heading = "passport.failure.title"
            message = copy(failureKey())
            prepared = controller.failure == .correspondence
                ? [action("passport.restart", .restart)] : [action("passport.retry", .retry)]
            if controller.serverRejection != nil { prepared.append(action("journey.viewDetails", .details, primary: false)) }
            if controller.canEnterManualAccessKey { prepared.append(action("passport.manual", .manual, primary: false)) }
            prepared.append(action("passport.cancel", .cancel, primary: false))
        }
        if let restoredMRZDate {
            message += "\n" + copy("journey.saved.mrzProvenance") + " " + restoredMRZDate.formatted(date: .abbreviated, time: .shortened)
        }
        reconcile(prepared)
        let inputs = [
            PassportInput(identifier: "passport.field.document", label: copy("passport.field.document"), value: draft.documentNumber, keyboard: .asciiCapable),
            PassportInput(identifier: "passport.field.birth", label: copy("passport.field.birth"), value: draft.birthDateYYMMDD, keyboard: .numberPad),
            PassportInput(identifier: "passport.field.expiry", label: copy("passport.field.expiry"), value: draft.expiryDateYYMMDD, keyboard: .numberPad)
        ]
        return PassportFlowScreen(title: copy(journeyMode ? "journey.progress.passport" : "capability.passport.title"), heading: copy(heading),
            message: message, scope: copy(journeyMode ? "journey.saved.scope" : "passport.scope") + (evidenceStatusKey.map { "\n" + copy($0) } ?? ""), fields: inputs,
            fieldsHidden: !(manual || phase == .confirm), preview: phase == .mrz ? native.preview : nil,
            image: previewImage, imageLabel: copy("passport.result.portrait"),
            mediaHidden: phase != .mrz && previewImage == nil, sections: sections, actionSurface: actions)
    }

    private func presentFailureDetails() {
        guard let rejection = controller.serverRejection, controller.phase == .failure,
              let renderer, renderer.viewIfLoaded?.window != nil,
              renderer.presentedViewController == nil else { return }
        let paragraphs = PassportServerPresentation.rows(rejection).flatMap { row in
            [ReferenceParagraph(text: row.label, role: .caption, identifier: row.identifier + ".label"),
             ReferenceParagraph(text: row.value, role: .body, identifier: row.identifier)]
        }
        let page = ReferenceRenderer(screen: ReferenceScreen(title: copy("passport.server.title"),
            heading: copy("passport.server.failed"), paragraphs: paragraphs, primaryActions: []), emit: { _ in
                // Failed server facts are read-only; retry belongs to the acquisition page.
            })
        let close = UIBarButtonItem(title: copy("journey.details.close"), primaryAction: UIAction { [weak self] _ in
            self?.failureDetails?.dismiss(animated: false)
            self?.failureDetails = nil
        })
        close.accessibilityIdentifier = "journey.details.close"
        page.navigationItem.rightBarButtonItem = close
        page.view.accessibilityViewIsModal = true
        let sheet = UINavigationController(rootViewController: page)
        sheet.modalPresentationStyle = .pageSheet
        sheet.sheetPresentationController?.detents = [.large()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        failureDetails = sheet
        renderer.present(sheet, animated: false) { [weak page] in
            UIAccessibility.post(notification: .screenChanged,
                argument: page?.accessibilityElement(identifier: "workflow.step"))
        }
    }

    private func accessSection() -> PassportResultSection {
        let fields = controller.accessFields ?? draft
        return .init(heading: copy("passport.confirm.title"), rows: [
            row("passport.field.document", fields.documentNumber),
            row("passport.field.birth", fields.birthDateYYMMDD),
            row("passport.field.expiry", fields.expiryDateYYMMDD)
        ])
    }
    func resultSections(_ result: PassportReadObservation) -> [PassportResultSection] {
        Self.resultSections(SavedPassportNFC(result))
    }
    private func row(_ key: String, _ value: String) -> PassportResultRow { Self.row(key, value) }

    static func resultSections(_ result: SavedPassportNFC) -> [PassportResultSection] {
        var identity = [
            row("passport.field.document", result.documentNumber),
            row("passport.result.given", names(result.givenNames)),
            row("passport.result.surname", names(result.surname)),
            row("passport.result.nationality", result.nationality),
            row("passport.result.issuer", result.issuingState),
            row("passport.result.birth", date(result.birthDateYYMMDD)),
            row("passport.result.expiry", date(result.expiryDateYYMMDD)),
            row("passport.result.sex", result.sex)
        ]
        for (key, value) in [("passport.result.issueDate", result.dateOfIssue), ("passport.result.authority", result.issuingAuthority), ("passport.result.birthplace", result.placeOfBirth)] {
            if let value, !value.isEmpty { identity.append(row(key, value)) }
        }
        let proof = [
            row("passport.result.face", KenshikiCopy.text("passport.result.notCompared")),
            row("passport.result.chain", protocolText(result.countrySigningChain)),
            row("passport.result.signature", protocolText(result.documentSignature)),
            row("passport.result.hashes", protocolText(result.dataGroupHashes)),
            row("passport.result.pace", protocolText(result.pace)),
            row("passport.result.bac", protocolText(result.basicAccessControl)),
            row("passport.result.aa", protocolText(result.activeAuthentication)),
            row("passport.result.ca", protocolText(result.chipAuthentication)),
            row("passport.result.groupCount", String(result.dataGroups.count + (result.dg2 == nil ? 0 : 1))),
            row("passport.result.sod", SHA256.hash(data: result.securityObject).map { String(format: "%02x", $0) }.joined()),
            row("passport.result.dg2", result.dg2Digest ?? KenshikiCopy.text("passport.result.notPerformed"))
        ]
        return [.init(heading: KenshikiCopy.text("passport.result.details"), rows: identity), .init(heading: KenshikiCopy.text("passport.result.proof"), rows: proof)]
    }
    private static func protocolText(_ state: PassportProtocolObservation) -> String {
        switch state {
        case .succeeded: KenshikiCopy.text("passport.result.passed")
        case .notPerformed: KenshikiCopy.text("passport.result.notPerformed")
        case .failed: KenshikiCopy.text("passport.result.failed")
        }
    }
    private static func names(_ value: String) -> String { value.replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces) }
    private static func date(_ value: String) -> String {
        // Keep the MRZ's two-digit year; never guess the holder's birth century.
        guard value.count == 6 else { return value }
        return [String(value.prefix(2)), String(value.dropFirst(2).prefix(2)), String(value.suffix(2))].joined(separator: "/")
    }
    private static func row(_ key: String, _ value: String) -> PassportResultRow {
        .init(label: KenshikiCopy.text(key), value: value, identifier: key)
    }
    private func failureKey() -> String {
        switch controller.failure {
        case .server(.configuration): "passport.server.failure.configuration"
        case .server(.credentials), .server(.registration), .server(.unauthorized): "passport.server.failure.registration"
        case .server(.expired): "passport.server.failure.expired"
        case .server(.unsupportedChip): "passport.server.failure.unsupportedChip"
        case .server(.rejected), .server(.invalidResponse): "passport.server.failure.rejected"
        case .server(.chipAuthenticationUnavailable), .server(.unavailable), .server(.timedOut): "passport.server.failure.unavailable"
        case .invalidAccessKey: "passport.failure.key"
        case .camera: "passport.failure.camera"
        case .trustAnchorsRequired: "passport.trust.required"
        case .unavailable, .read(.unsupported): "passport.failure.unsupported"
        case .interrupted: "passport.failure.interrupted"
        case .correspondence:
            switch controller.correspondenceMismatchedFields.first {
            case .documentNumber, .birthDate, .expiryDate: "passport.failure.correspondence.key"
            case .surname: "passport.failure.correspondence.surname"
            case .givenNames: "passport.failure.correspondence.givenNames"
            case nil: "passport.failure.correspondence"
            }
        case .unverifiedEvidence, .read(.dataIntegrityFailure), .read(.activeAuthenticationFailed), .read(.chipAuthenticationFailed): "passport.failure.integrity"
        case .read(.trustAnchorNotFound), .read(.trustAnchorsUnavailable): "passport.failure.trust"
        case .read(.connectionLost), .read(.multipleTags), .read(.invalidTag): "passport.failure.connection"
        default: "passport.failure.read"
        }
    }
    private func action(_ key: String, _ intent: PassportViewAction, primary: Bool = true) -> PassportPreparedAction {
        .init(identifier: key, title: copy(key), intent: intent, primary: primary)
    }
    private func reconcile(_ prepared: [PassportPreparedAction]) {
        let retained = Set(prepared.map(\.identifier))
        for (key, button) in buttons where !retained.contains(key) { button.removeFromSuperview(); buttons.removeValue(forKey: key) }
        for (index, action) in prepared.enumerated() {
            let existing = buttons[action.identifier]
            let button = existing ?? UIButton(type: .system)
            var config = action.primary ? KenshikiIOSDesign.primaryConfiguration() : KenshikiIOSDesign.secondaryConfiguration()
            if action.intent == .details { config = KenshikiIOSDesign.tertiaryConfiguration() }
            config.title = action.title
            config.buttonSize = .large
            config.titleLineBreakMode = .byWordWrapping
            button.configuration = config
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.accessibilityIdentifier = action.identifier
            button.accessibilityHint = copy("accessibility.actionHint")
            if existing == nil {
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: KenshikiDesign.minimumTargetIOS).isActive = true
                button.addAction(UIAction { [weak self] _ in self?.send(.action(action.intent)) }, for: .touchUpInside)
                buttons[action.identifier] = button
            }
            if actions.arrangedSubviews.indices.contains(index), actions.arrangedSubviews[index] === button { continue }
            actions.insertArrangedSubview(button, at: index)
        }
        actions.accessibilityElements = actions.arrangedSubviews
    }
    private func copy(_ key: String) -> String { KenshikiCopy.text(key) }

}

private struct PassportPreparedAction {
    let identifier: String
    let title: String
    let intent: PassportViewAction
    let primary: Bool
}

@MainActor final class PassportNativeEffects {
    var preview: UIView?
    var onPreview: (() -> Void)?
    private var camera: NativeMRZSession?
    private var registration: PassportPulseRegistration?
    private var server: PassportServerCeremony?
    private let makeMRZSession: @MainActor () -> NativeMRZSession
    init(makeMRZSession: @escaping @MainActor () -> NativeMRZSession = {
        NativeMRZSession(notificationsCenter: .default)
    }) { self.makeMRZSession = makeMRZSession }
    private func serverCeremony() -> PassportServerCeremony {
        if let server { return server }
        var ports = PassportServerCeremony.Ports(client: { [weak self] in
            guard let self else { throw CancellationError() }
            if self.registration == nil { self.registration = try PassportPulseRegistration.live(in: .main) }
            guard let registration = self.registration else { throw PassportServerFailure.configuration }
            return try await registration.client(diagnostic: { PassportServerDiagnostic.service($0).record(observer: { _ in
                // The app has no additional observer; persistent finite OSLog recording still runs.
            }) })
        }, read: { key, trust, nonce, terminal, event in
            let text = PassportNFCText.localized()
            return try await PassportChipReader(trustAnchorsURL: trust).read(accessKey: key,
                challenge: nonce.activeAuthenticationChallenge, chipAuthenticationTerminal: terminal,
                displayMessage: { text.message($0) },
                onEvent: { value in Task { @MainActor in event(value) } })
        })
        ports.recoverDeadKey = { [weak self] error in
            guard let registration = self?.registration else { throw PassportServerFailure.configuration }
            return try await registration.recoverDeadKey(after: error, diagnostic: { PassportServerDiagnostic.service($0).record(observer: { _ in
                // Persistent finite OSLog recording remains active after key recovery.
            }) })
        }
        let value = PassportServerCeremony(ports: ports)
        server = value
        return value
    }
    var effects: PassportFlowEffects {
        PassportFlowEffects(serverRead: { [weak self] key, trust, event, stage, admit in
                guard let self else { throw CancellationError() }
                return try await self.serverCeremony().read(key: key, trust: trust, event: event, stage: stage, admit: admit)
            }, available: PassportChipReader.availability == .available,
            startCamera: { [weak self] candidates, failed in
                guard let self else { throw CancellationError() }
                let session = self.makeMRZSession()
                self.camera = session
                // Pulse publishes continuous OCR candidates; the controller owns complete-read
                // validation and explicit confirmation before NFC, independently of preview geometry.
                session.onFrame = { frame in candidates(frame.candidates) }
                session.onState = { state in if case .failed = state { failed() } }
                self.preview = NativeMRZPreviewView(captureSession: session)
                self.onPreview?()
                try await session.start(consent: .permitted)
            }, stopCamera: { [weak self] in
                guard let self else { return }
                let retired = self.camera
                self.camera = nil
                self.preview = nil
                retired?.onReady = nil
                retired?.onFrame = nil
                retired?.onState = nil
                await retired?.stop()
            }, read: { key, trust, event in
                // Production always selects serverRead. A missing server path must never downgrade.
                throw PassportServerFailure.configuration
            })
    }
}

struct PassportNFCText: Sendable {
    let present: String
    let authenticating: String
    let reading: String
    let active: String
    let finishing: String
    let verifying: String
    let complete: String
    let failed: String
    @MainActor static func localized() -> Self {
        Self(present: KenshikiCopy.text("passport.nfc.present"), authenticating: KenshikiCopy.text("passport.nfc.authenticatingPrefix"),
             reading: KenshikiCopy.text("passport.nfc.readingPrefix"), active: KenshikiCopy.text("passport.nfc.active"),
             finishing: KenshikiCopy.text("passport.nfc.finishing"), verifying: KenshikiCopy.text("passport.nfc.verifying"), complete: KenshikiCopy.text("passport.nfc.complete"), failed: KenshikiCopy.text("passport.failure.read"))
    }
    func message(_ event: PassportReadEvent) -> String {
        switch event {
        case .presenting: present
        case .authenticating(let progress): authenticating + " — " + percentage(progress)
        case .reading(let group, let progress): reading + " " + group + " — " + percentage(progress)
        case .activeAuthentication: active
        case .transportFinishing, .transportComplete: complete + " — " + percentage(100)
        case .passiveAuthentication: verifying
        case .failure: failed
        }
    }
    private func percentage(_ progress: Int) -> String {
        (Double(min(100, max(0, progress))) / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// The reference application provisions issuer trust at build time. The SDK still receives an explicit URL.
enum PassportBundledTrust {
    private struct Policy: Decodable { let sha256: String; let maxBytes: Int }
    static func url(in bundle: Bundle) -> URL? {
        guard let manifest = bundle.url(forResource: "PassportTrust", withExtension: "json"),
              let source = bundle.url(forResource: "PassportCSCA", withExtension: "pem"),
              let encoded = try? Data(contentsOf: manifest), encoded.count < 16_384,
              let policy = try? JSONDecoder().decode(Policy.self, from: encoded),
              policy.maxBytes > 0, policy.maxBytes <= 4_194_304,
              let handle = try? FileHandle(forReadingFrom: source) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: policy.maxBytes + 1), bytes.count <= policy.maxBytes,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == policy.sha256 else { return nil }
        // OpenSSL in the preserved reader owns X.509 parsing and verification, including legacy
        // issuer certificates that Apple's Security parser cannot represent.
        return source
    }
}
