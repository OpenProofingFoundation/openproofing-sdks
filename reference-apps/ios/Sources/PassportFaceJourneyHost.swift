import UIKit

/// Native composition and prepared copy for one journey; SDK mechanisms remain independently owned.
@MainActor final class PassportFaceJourneyHost: NSObject, UIAdaptivePresentationControllerDelegate {
    let controller: PassportFaceJourneyController
    #if DEBUG
    private(set) var diagnosticsPersistence: FaceWorkflowPersistence?
    #endif
    let navigation = UINavigationController()
    private let makePassport: () -> PassportFlowHost
    private let makeCapture: () -> BiometricCaptureHost
    private var passport: PassportFlowHost?
    private var capture: BiometricCaptureHost?
    private var displayedSession: UUID?
    private var displayedCapture: PassportFaceJourneyController.CaptureToken?
    private var reportCopied = false
    private let writeClipboard: (String) -> Void
    private var navigationWasHome = false
    private var navigationWasDeleting = false
    private var navigationPage: PassportFaceJourneyController.HomePage?
    private var lastHomePage: PassportFaceJourneyController.HomePage?
    private var lastPhase: PassportFaceJourneyController.Phase?
    private var passportRetirement: Task<Void, Never>?
    private var retirementID: UUID?
    private var pendingMount: Task<Void, Never>?
    private var detailsPage: ReferenceRenderer?
    private var detailsNavigation: UINavigationController?
    private lazy var page = ReferenceRenderer(screen: screen(), emit: { [weak self] event in
        if case .journey(let intent) = event { self?.controller.send(intent) }
    })

    override convenience init() {
        #if DEBUG
        let storageDiagnostics: StorageHealthDiagnostics?
        do { storageDiagnostics = try StorageHealthDiagnostics.live() }
        catch { storageDiagnostics = nil }
        #endif
        let provider = PassportCaptureStoreProvider {
            try await MainActor.run {
                #if DEBUG
                do {
                    return try PassportCaptureStore.live(observeTrustedRoot: {
                        storageDiagnostics?.observeTrustedRoot(canonicalizationRequired: $0)
                    })
                } catch {
                    storageDiagnostics?.record(stage: .constructing, error: error)
                    throw error
                }
                #else
                return try PassportCaptureStore.live()
                #endif
            }
        }
        let comparisonPersistence = provider.comparisonEffects
        let persistence: PassportCapturePersistence
        #if DEBUG
        let effects = provider.effects
        persistence = PassportCapturePersistence(load: effects.load, save: effects.save,
            delete: {
                try await FaceInferenceScheduler.shared.run {
                    try await provider.effects.delete()
                    try DebugComparisonDiagnostics.eraseExports()
                }
            }, loadMRZ: effects.loadMRZ)
        #else
        persistence = provider.effects
        #endif
        let trust = PassportBundledTrust.url(in: .main).flatMap { try? Data(contentsOf: $0) }
            .map(SavedPassportCapture.digest)
        let sensors = WorkflowSensorHost()
        let evidence = WorkflowEvidenceRecorder(sensors: sensors.port, persistence: comparisonPersistence)
        self.init(controller: PassportFaceJourneyController(comparison: FaceComparisonHost.makeController(persistence: comparisonPersistence),
                  persistence: persistence, trustBundleSHA256: trust, evidence: evidence, comparisonPersistence: comparisonPersistence),
                  makePassport: { PassportFlowHost() }, makeCapture: { BiometricCaptureHost() })
        #if DEBUG
        diagnosticsPersistence = comparisonPersistence
        controller.onStorageHealthChange = { [storageDiagnostics] stage, error in
            storageDiagnostics?.record(stage: stage, error: error)
        }
        #endif
    }

    init(controller: PassportFaceJourneyController, makePassport: @escaping () -> PassportFlowHost,
         makeCapture: @escaping () -> BiometricCaptureHost,
         writeClipboard: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }) {
        self.controller = controller
        self.writeClipboard = writeClipboard
        self.makePassport = makePassport
        self.makeCapture = makeCapture
        super.init()
        controller.onChange = { [weak self] in self?.reportCopied = false; self?.render() }
        controller.onEvidenceChange = { [weak self] in self?.render() }
        controller.onCopyReport = { [weak self] text in
            guard let self else { return }
            self.writeClipboard(text)
            self.reportCopied = true
            self.render()
            UIAccessibility.post(notification: .announcement, argument: self.copy("comparison.export.copied"))
        }
        controller.onWithdraw = { [weak self] in self?.withdrawAcquisition() }
        render()
    }

    func setForeground(_ active: Bool) { capture?.setForeground(active) }
    func backgrounded() { controller.interrupt() }

    private func withdrawAcquisition() {
        pendingMount?.cancel()
        pendingMount = nil
        let oldCapture = capture
        capture = nil
        displayedCapture = nil
        oldCapture?.onAccepted = nil
        oldCapture?.onClose = nil
        oldCapture?.controller.send(.cancel)
        let oldPassport = passport
        passport = nil
        displayedSession = nil
        oldPassport?.onAccepted = nil
        oldPassport?.onClose = nil
        oldPassport?.withdraw()
        if let oldPassport {
            let prior = passportRetirement
            let id = UUID()
            retirementID = id
            passportRetirement = Task { [weak self] in
                await prior?.value
                await oldPassport.controller.waitForRetirement()
                guard let self, self.retirementID == id else { return }
                self.passportRetirement = nil
            }
        }
    }

    private func render() {
        let evidenceKey: String?
        switch controller.evidenceStatus {
        case .idle?: evidenceKey = "journey.evidence.idle"
        case .recording?: evidenceKey = "journey.evidence.recording"
        case .failed?: evidenceKey = "journey.evidence.failed"
        case nil: evidenceKey = nil
        }
        passport?.evidenceStatusKey = evidenceKey
        capture?.evidenceStatusKey = evidenceKey
        switch controller.phase {
        case .passport: showPassport()
        case .selfie: showSelfie()
        case .introduction, .comparing, .result, .interrupted:
            page.apply(screen())
            mount(page)
            prepareHomeNavigation()
            if lastPhase != controller.phase || lastHomePage != controller.homePage {
                UIAccessibility.post(notification: .screenChanged, argument: page.accessibilityElement(identifier: "workflow.step"))
            }
        }
        prepareDetailsPresentation()
        lastPhase = controller.phase
        lastHomePage = controller.homePage
    }

    private func showPassport() {
        let session = controller.sessionID
        guard displayedSession != session else { return }
        displayedSession = session
        if let prior = passportRetirement {
            page.apply(screen())
            mount(page)
            pendingMount = Task { [weak self] in
                await prior.value
                guard let self, !Task.isCancelled, self.controller.phase == .passport,
                      self.controller.sessionID == session else { return }
                self.pendingMount = nil
                self.installPassport(session: session)
            }
            return
        }
        installPassport(session: session)
    }

    private func installPassport(session: UUID) {
        guard controller.phase == .passport, controller.sessionID == session else { return }
        let host = makePassport()
        guard controller.phase == .passport, controller.sessionID == session else {
            host.withdraw()
            return
        }
        passport = host
        if let mrz = controller.restoredMRZ {
            do { try host.controller.restoreMRZ(mrz); host.restoredMRZDate = mrz.capturedAt }
            catch { controller.interrupt(); return }
        }
        host.journeyMode = true
        host.controller.scanAfterMRZCommit = true
        if controller.recordsEvidence {
            host.controller.persistMRZ = { [weak self, weak host] value in
                guard let self, let host, self.passport === host else { throw CancellationError() }
                try await self.controller.checkpointMRZ(value, session: session)
            }
        }
        if controller.recordsEvidence {
            host.controller.beforeAction = { [weak self, weak host] code in
                guard let self, let host, self.passport === host, self.controller.sessionID == session else { throw CancellationError() }
                try await self.controller.recordAction(code)
            }
        }
        host.controller.persistCompletedRead = { [weak self, weak host] value in
            guard let self, let host, self.passport === host else { throw CancellationError() }
            try await self.controller.checkpointPassport(value, session: session)
        }
        host.onAccepted = { [weak self, weak host] value in
            guard let self, let host, self.passport === host else { return }
            self.controller.acceptPassport(value, session: session)
        }
        host.onClose = { [weak self, weak host] in
            guard let self, let host, self.passport === host, self.controller.sessionID == session else { return }
            self.controller.send(.cancel)
        }
        host.controller.send(.beginJourney)
        let renderer = host.makeRenderer()
        let cancel = UIBarButtonItem(title: copy("journey.cancel"), primaryAction: UIAction { [weak self] _ in
            self?.controller.send(.cancel)
        })
        cancel.accessibilityIdentifier = "journey.cancel"
        renderer.navigationItem.leftBarButtonItem = cancel
        mount(renderer)
    }

    private func showSelfie() {
        guard let token = controller.captureToken, displayedCapture != token else { return }
        displayedCapture = token
        let host = makeCapture()
        guard controller.phase == .selfie, controller.captureToken == token else {
            host.controller.send(.cancel)
            return
        }
        capture = host
        if controller.recordsEvidence {
            host.controller.beforeAction = { [weak self, weak host] code in
                guard let self, let host, self.capture === host else { throw CancellationError() }
                try await self.controller.recordAction(code)
            }
        }
        host.controller.persistSelectedSelfie = { [weak self, weak host] value in
            guard let self, let host, self.capture === host else { throw CancellationError() }
            try await self.controller.checkpointSelfie(value.capture, token: token, selection: value.selection)
        }
        host.controller.persistCapturedSelfie = { [weak self, weak host] value in
            guard let self, let host, self.capture === host else { throw CancellationError() }
            try await self.controller.checkpointSelfie(value, token: token)
        }
        host.titleKey = "journey.progress.selfie"
        host.useSelfieKey = "comparison.compare"
        host.scopeKey = "comparison.scope"
        host.onAccepted = { [weak self, weak host] value in
            guard let self, let host, self.capture === host else { return }
            self.capture = nil
            self.controller.acceptSelfie(value, token: token)
        }
        host.onClose = { [weak self] in self?.controller.cancelCapture(token) }
        // Continue to selfie is the explicit acquisition admission. Visibility is still required.
        host.controller.send(.allowWhenVisible)
        mount(host.makeRenderer())
    }

    private func mount(_ renderer: UIViewController) {
        guard navigation.topViewController !== renderer else { return }
        navigation.setViewControllers([renderer], animated: false)
    }

    private func prepareHomeNavigation() {
        if controller.phase == .result || controller.phase == .comparing {
            page.navigationItem.leftBarButtonItem = nil
            page.navigationItem.rightBarButtonItem = resultMenu()
            navigationWasHome = false
            navigationPage = nil
            return
        }
        let home = controller.phase == .introduction || controller.phase == .interrupted
        let deleting = controller.storageState == .deleting
        guard navigationPage != controller.homePage || navigationWasHome != home || navigationWasDeleting != deleting else { return }
        navigationPage = controller.homePage
        navigationWasHome = home
        navigationWasDeleting = deleting
        page.navigationItem.leftBarButtonItem = nil
        page.navigationItem.rightBarButtonItem = nil
        if home {
            if controller.homePage == .overview {
                page.navigationItem.rightBarButtonItem = navigationAction("journey.developer", .developerTools,
                    symbol: KenshikiIOSPrimitives.developerSymbol)
            } else if !deleting {
                page.navigationItem.leftBarButtonItem = navigationAction("navigation.back", .homeBack)
            }
        }
    }

    private func navigationAction(_ key: String, _ intent: PassportFaceJourneyIntent, symbol: String? = nil) -> UIBarButtonItem {
        let invoke = UIAction { [weak self] _ in self?.controller.send(intent) }
        let item: UIBarButtonItem
        if let symbol { item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: invoke) }
        else { item = UIBarButtonItem(title: copy(key), primaryAction: invoke) }
        item.accessibilityLabel = copy(key)
        item.accessibilityIdentifier = key
        item.accessibilityHint = copy("accessibility.actionHint")
        return item
    }

    private func screen() -> ReferenceScreen {
        if (controller.phase == .introduction || controller.phase == .interrupted), controller.homePage != .overview {
            return homeDestinationScreen()
        }
        var heading = "journey.title"
        var title = "journey.title"
        var paragraphs: [ReferenceParagraph] = []
        var actions: [ReferenceAction] = []
        var contentActions: [ReferenceAction] = []
        switch controller.phase {
        case .introduction:
            title = "journey.home"
            paragraphs = [paragraph("journey.introduction", .body),
                paragraph("journey.overview.scan", .body), paragraph("journey.overview.chip", .body),
                paragraph("journey.overview.selfie", .body), paragraph("journey.scope", .caption)]
            actions = [action("journey.begin", .begin)]
            contentActions = [contentAction("journey.saved.open", .savedWork)]
        case .passport:
            title = "journey.progress.passport"
            heading = "passport.nfc.finishing"
            paragraphs = [paragraph("passport.nfc.finishing", .body)]
            actions = [action("journey.cancel", .cancel)]
        case .selfie: title = "journey.progress.selfie"
        case .comparing:
            title = "journey.progress.result"
            heading = "comparison.processing"
            paragraphs = FaceComparisonPresentation.paragraphs(phase: controller.comparisonPhase,
                visual: controller.visualPhase, durationMilliseconds: controller.comparisonDurationMilliseconds,
                expanded: false, input: controller.inputTelemetry,
                auraTelemetry: controller.auraTelemetry, visualDurationMilliseconds: controller.visualDurationMilliseconds,
                waitingForAura: controller.visualWaitingForComparison, partial: controller.visualPartialResult)
            actions = [action("journey.cancel", .cancel)]
            contentActions = [contentAction("journey.viewDetails", .details)]
        case .result:
            title = "journey.progress.result"
            heading = "journey.result.title"
            paragraphs.append(paragraph("journey.passportPassed", .body))
            if controller.passportServerVerification != nil {
                paragraphs.append(paragraph(controller.restoredPassport == nil ? "passport.server.verified" : "passport.server.historical", .body))
            }
            paragraphs += FaceComparisonPresentation.summary(phase: controller.comparisonPhase)
            actions = [action("journey.done", .done)]
            contentActions = [contentAction("journey.viewDetails", .details)]
        case .interrupted:
            heading = "journey.interrupted.title"
            paragraphs = [paragraph("journey.interrupted.body", .body)]
            title = "journey.home"
            actions = [action("journey.beginAgain", .begin)]
            contentActions = [contentAction("journey.saved.open", .savedWork)]
        }
        if let restored = controller.restoredPassport {
            paragraphs.insert(ReferenceParagraph(
                text: copy("journey.saved.reused") + " " + restored.capturedAt.formatted(date: .abbreviated, time: .shortened),
                role: .caption, identifier: "journey.saved.provenance"), at: 0)
        }
        if controller.phase == .introduction || controller.phase == .interrupted {
            switch controller.storageState {
            case .failed:
                paragraphs.append(paragraph("journey.storage.unavailable", .caption))
                actions = [action("journey.saved.retry", .retryStorage)]
            case .deleteFailed:
                paragraphs.append(paragraph("journey.saved.deleteFailed", .caption))
                actions = [action("journey.saved.retryDelete", .retryStorage)]
            case .deleting:
                paragraphs.append(paragraph("journey.saved.deleting", .caption))
                actions = []
            case .loading, .saving:
                actions = actions.map { item in
                    ReferenceAction(identifier: item.identifier, title: item.title, hint: item.hint,
                        enabled: false, event: item.event, configuration: item.configuration)
                }
            case .disabled, .ready: break
            }
        } else if controller.storageState == .failed {
            paragraphs.append(paragraph("journey.saved.failed", .caption))
        }
        return ReferenceScreen(title: copy(title), heading: copy(heading), paragraphs: paragraphs,
            primaryActions: actions, contentActions: contentActions)
    }

    private func resultMenu() -> UIBarButtonItem {
        var entries: [UIMenuElement] = []
        if controller.phase == .result {
            entries.append(menuAction("journey.retake", .retake))
            if controller.canRetryComparison { entries.append(menuAction("journey.saved.rerun", .retryComparison)) }
        }
        entries.append(menuAction("journey.viewDetails", .details))
        let menu = UIMenu(children: entries)
        let item = UIBarButtonItem(image: UIImage(systemName: KenshikiIOSPrimitives.developerSymbol), menu: menu)
        item.accessibilityLabel = copy("journey.result.menu")
        item.accessibilityIdentifier = "journey.result.menu"
        item.accessibilityHint = copy("accessibility.actionHint")
        return item
    }

    private func menuAction(_ key: String, _ intent: PassportFaceJourneyIntent) -> UIAction {
        let session = controller.sessionID
        let item = UIAction(title: copy(key), identifier: UIAction.Identifier(key)) { [weak self] _ in
            guard let self, self.controller.sessionID == session else { return }
            self.controller.send(intent)
        }
        return item
    }

    private func prepareDetailsPresentation() {
        guard controller.detailsExpanded, controller.phase == .result || controller.phase == .comparing else {
            if let presented = detailsNavigation {
                detailsNavigation = nil
                detailsPage = nil
                presented.dismiss(animated: false) { [weak self] in self?.focusResultDetails() }
            }
            return
        }
        if let detailsPage {
            detailsPage.apply(detailsScreen())
            return
        }
        let renderer = ReferenceRenderer(screen: detailsScreen(), emit: { [weak self] event in
            if case .journey(let intent) = event { self?.controller.send(intent) }
        })
        renderer.navigationItem.rightBarButtonItem = navigationAction("journey.details.close", .details)
        let sheet = UINavigationController(rootViewController: renderer)
        sheet.modalPresentationStyle = .pageSheet
        sheet.sheetPresentationController?.detents = [.large()]
        sheet.sheetPresentationController?.prefersGrabberVisible = true
        sheet.presentationController?.delegate = self
        renderer.view.accessibilityViewIsModal = true
        detailsPage = renderer
        detailsNavigation = sheet
        navigation.present(sheet, animated: false) { [weak renderer] in
            UIAccessibility.post(notification: .screenChanged,
                argument: renderer?.accessibilityElement(identifier: "workflow.step"))
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === detailsNavigation else { return }
        detailsNavigation = nil
        detailsPage = nil
        if controller.detailsExpanded { controller.send(.details) }
        focusResultDetails()
    }

    private func focusResultDetails() {
        guard navigation.topViewController === page, controller.phase == .result || controller.phase == .comparing else { return }
        UIAccessibility.post(notification: .screenChanged,
            argument: page.accessibilityElement(identifier: "journey.viewDetails") ?? page.accessibilityElement(identifier: "workflow.step"))
    }

    private func detailsScreen() -> ReferenceScreen {
        var paragraphs = FaceComparisonPresentation.paragraphs(phase: controller.comparisonPhase,
            visual: controller.visualPhase, durationMilliseconds: controller.comparisonDurationMilliseconds,
            expanded: true, input: controller.inputTelemetry, auraTelemetry: controller.auraTelemetry,
            visualDurationMilliseconds: controller.visualDurationMilliseconds,
            waitingForAura: controller.visualWaitingForComparison, partial: controller.visualPartialResult,
            includeCaptureMotionSource: false)
        if let server = controller.passportServerVerification {
            paragraphs.append(paragraph("passport.server.title", .action))
            for row in PassportServerPresentation.rows(server, historical: controller.restoredPassport != nil) {
                paragraphs.append(ReferenceParagraph(text: row.label, role: .caption, identifier: row.identifier + ".label"))
                paragraphs.append(ReferenceParagraph(text: row.value, role: .body, identifier: row.identifier))
            }
        }
        paragraphs.append(paragraph("telemetry.motion.title", .action))
        paragraphs.append(paragraph("telemetry.motion.scope", .caption))
        if let projection = controller.workflowMotion {
            paragraphs += FaceComparisonPresentation.telemetry(FaceComparisonTelemetry.motionFields(projection))
        } else {
            let motionKey: String
            switch controller.motionProjectionState {
            case .loading: motionKey = "telemetry.motion.loading"
            case .failed: motionKey = "telemetry.motion.failed"
            case .idle, .ready: motionKey = "telemetry.motion.unavailable"
            }
            paragraphs.append(paragraph(motionKey, .body))
        }
        let saved = controller.reference.map { SavedPassportNFC($0.read) } ?? controller.restoredPassport?.nfc
        for (index, section) in (saved.map(PassportFlowHost.resultSections) ?? []).enumerated() {
            paragraphs.append(ReferenceParagraph(text: section.heading, role: .action, identifier: "journey.details.heading.\(index)"))
            for row in section.rows where row.identifier != "passport.result.face" {
                paragraphs.append(ReferenceParagraph(text: row.label, role: .caption, identifier: "\(row.identifier).label"))
                paragraphs.append(ReferenceParagraph(text: row.value, role: .body, identifier: row.identifier))
            }
        }
        if let status = controller.evidenceStatus {
            switch status {
            case .idle: paragraphs.append(paragraph("journey.evidence.idle", .caption))
            case .recording: paragraphs.append(paragraph("journey.evidence.recording", .caption))
            case .failed: paragraphs.append(paragraph("journey.evidence.failed", .caption))
            }
        }
        var tools: [ReferenceAction] = []
        if controller.canExportReport {
            tools.append(ReferenceAction(identifier: "comparison.export.copy",
                title: copy(reportCopied ? "comparison.export.copied" : "comparison.export.copy"),
                hint: copy("comparison.export.hint"), enabled: true, event: .journey(.copyReport),
                configuration: KenshikiIOSDesign.tertiaryConfiguration()))
        }
        return ReferenceScreen(title: copy("journey.result.details"), heading: copy("journey.result.details"),
            paragraphs: paragraphs, primaryActions: [], contentActions: tools,
            image: controller.referencePortrait.flatMap { UIImage(data: $0) }, imageLabel: copy("passport.result.portrait"))
    }

    private func homeDestinationScreen() -> ReferenceScreen {
        var heading = "journey.saved.open"
        var paragraphs: [ReferenceParagraph] = []
        var actions: [ReferenceAction] = []
        var links: [ReferenceAction] = []
        switch controller.homePage {
        case .overview: break
        case .savedWork:
            paragraphs = [paragraph("journey.saved.description", .body)]
            switch controller.storageState {
            case .ready:
                if let saved = controller.savedPassport {
                    paragraphs.append(ReferenceParagraph(text: copy("journey.saved.available") + " " +
                        saved.capturedAt.formatted(date: .abbreviated, time: .shortened),
                        role: .caption, identifier: "journey.saved.available"))
                }
                if controller.canUseSavedPassport { links.append(contentAction("journey.saved.use", .useSavedPassport)) }
                if controller.savedComparisonID != nil { links.append(contentAction("journey.saved.comparison", .resumeComparison)) }
                if controller.savedMRZ != nil { links.append(contentAction("journey.saved.mrz", .useSavedMRZ)) }
                if !controller.hasSavedWork { paragraphs.append(paragraph("journey.saved.empty", .body)) }
            case .loading: paragraphs.append(paragraph("journey.saved.loading", .caption))
            case .saving: paragraphs.append(paragraph("journey.saved.saving", .caption))
            case .deleting: paragraphs.append(paragraph("journey.saved.deleting", .caption))
            case .failed:
                paragraphs.append(paragraph("journey.saved.failed", .body))
                actions = [action("journey.saved.retry", .retryStorage)]
            case .deleteFailed:
                paragraphs.append(paragraph("journey.saved.deleteFailed", .body))
                actions = [action("journey.saved.retryDelete", .retryStorage)]
            case .disabled: paragraphs.append(paragraph("journey.saved.empty", .body))
            }
            if (controller.hasSavedWork || controller.storageState == .failed), controller.storageState != .deleting {
                links.append(contentAction("journey.saved.manageDelete", .reviewDeletion))
            }
        case .developerTools:
            heading = "journey.developer"
            paragraphs = [paragraph("journey.developer.description", .body)]
            if let status = controller.evidenceStatus {
                switch status {
                case .idle: paragraphs.append(paragraph("journey.evidence.idle", .caption))
                case .recording: paragraphs.append(paragraph("journey.evidence.recording", .caption))
                case .failed: paragraphs.append(paragraph("journey.evidence.failed", .caption))
                }
            }
            links = [contentAction("journey.examples", .examples)]
        case .deletionConfirmation:
            heading = "journey.saved.deleteTitle"
            paragraphs = [paragraph("journey.saved.deleteExplanation", .body)]
            if controller.storageState == .deleting {
                paragraphs.append(paragraph("journey.saved.deleting", .caption))
            } else {
                actions = [action("journey.saved.delete", .deleteSavedPassport),
                    action("journey.saved.keep", .homeBack, primary: false)]
            }
        }
        return ReferenceScreen(title: copy("journey.home"), heading: copy(heading), paragraphs: paragraphs,
            primaryActions: actions, contentActions: links)
    }

    private func contentAction(_ key: String, _ intent: PassportFaceJourneyIntent) -> ReferenceAction {
        ReferenceAction(identifier: key, title: copy(key), hint: copy("accessibility.actionHint"), enabled: true,
            event: .journey(intent), configuration: KenshikiIOSDesign.tertiaryConfiguration())
    }

    private func paragraph(_ key: String, _ role: KenshikiIOSTextRole) -> ReferenceParagraph {
        ReferenceParagraph(text: copy(key), role: role, identifier: key)
    }
    private func action(_ key: String, _ intent: PassportFaceJourneyIntent, primary: Bool = true) -> ReferenceAction {
        ReferenceAction(identifier: key, title: copy(key), hint: copy("accessibility.actionHint"), enabled: true, event: .journey(intent),
            configuration: primary ? KenshikiIOSDesign.primaryConfiguration() : KenshikiIOSDesign.secondaryConfiguration())
    }
    private func copy(_ key: String) -> String { KenshikiCopy.text(key) }
}
