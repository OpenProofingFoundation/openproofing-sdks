import UIKit
import KenshikiPresentation

enum ReferenceEvent {
    case journey(PassportFaceJourneyIntent)
    case workflow(WorkflowEvent)
    case liveSelfie
    case discardSelfie
    case copyComparisonReport
    case comparisonTelemetry
    case passportReference
    case discardPassportReference
}

/// Native shell owns independent tab sessions; controllers own every workflow transition.
@main @MainActor final class ApplicationHost: UIResponder, UIApplicationDelegate, UINavigationControllerDelegate, UITabBarControllerDelegate {
    var window: UIWindow?
    private let tabs = UITabBarController()
    private var controllers: [Capability: WorkflowController] = [:]
    private var navigation: [Capability: UINavigationController] = [:]
    private var roots: [Capability: ReferenceRenderer] = [:]
    private let comparison: FaceComparisonController
    private var reportCopied = false
    private let writeClipboard: (String) -> Void
    private let makeCapture: () -> BiometricCaptureHost
    private var liveCapture: BiometricCaptureHost?
    private var passportFlow: PassportFlowHost?
    private var documentFlow: DocumentFlowHost?
    private var passportReference: AcceptedPassportPortrait?
    private var selectedCapability: Capability = .biometric
    private let startsInExamples: Bool
    private var journey: PassportFaceJourneyHost?
    #if DEBUG && !targetEnvironment(simulator)
    private var diagnosticsTask: Task<Void, Never>?
    private var diagnosticsStartupError: (any Error)?
    #endif

    override convenience init() {
        #if DEBUG
        let startsInExamples = !ProcessInfo.processInfo.arguments.contains("--reference-test-guided-journey")
        #else
        let startsInExamples = true
        #endif
        self.init(comparison: FaceComparisonHost.makeController(), makeCapture: { BiometricCaptureHost() }, startsInExamples: startsInExamples)
    }

    init(comparison: FaceComparisonController, makeCapture: @escaping () -> BiometricCaptureHost, startsInExamples: Bool = true,
         writeClipboard: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }) {
        self.comparison = comparison
        self.writeClipboard = writeClipboard
        self.makeCapture = makeCapture
        self.startsInExamples = startsInExamples
        super.init()
    }

    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reference-test-expanded-rtl-dark") {
            window?.overrideUserInterfaceStyle = .dark
            window?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            window?.semanticContentAttribute = .forceRightToLeft
        }
        #endif
        comparison.onChange = { [weak self] in self?.comparisonChanged() }
        tabs.delegate = self
        var pages: [UIViewController] = []
        for capability in Capability.allCases {
            let stack = UINavigationController()
            stack.delegate = self
            stack.tabBarItem = UITabBarItem(title: copy("navigation.tab.\(capability.rawValue)"), image: UIImage(systemName: symbol(capability)), selectedImage: nil)
            stack.tabBarItem.accessibilityIdentifier = "capability.\(capability.rawValue)"
            navigation[capability] = stack
            reset(capability)
            pages.append(stack)
        }
        tabs.setViewControllers(pages, animated: false)
        let journey = PassportFaceJourneyHost()
        journey.controller.onExamples = { [weak self] in self?.showExamples() }
        self.journey = journey
        window?.rootViewController = startsInExamples ? tabs : journey.navigation
        window?.makeKeyAndVisible()
        return true
    }

    func applicationWillTerminate(_: UIApplication) {
        documentFlow?.withdraw()
        stopDiagnostics()
        journey?.controller.send(.cancel)
        liveCapture?.controller.send(.cancel)
        comparison.clear()
        passportReference = nil
        passportFlow?.withdraw()
        for controller in controllers.values {
            controller.onStateChange = nil
            controller.send(.cancel)
        }
    }

    func applicationWillResignActive(_: UIApplication) {
        documentFlow?.resignActive()
        stopDiagnostics()
        journey?.setForeground(false)
        liveCapture?.setForeground(false)
        controllers[selectedCapability]?.send(.interrupt)
    }

    func applicationDidBecomeActive(_: UIApplication) {
        documentFlow?.setForeground(true)
        startDiagnostics()
        journey?.setForeground(true)
        liveCapture?.setForeground(true)
        passportFlow?.setBackgrounded(false)
    }
    func applicationDidEnterBackground(_: UIApplication) {
        documentFlow?.setForeground(false)
        stopDiagnostics()
        journey?.backgrounded()
        liveCapture?.backgrounded()
        passportFlow?.setBackgrounded(true)
        passportReference = nil
        refreshBiometricRoot()
        clearComparison()
    }

    private func startDiagnostics() {
        #if DEBUG && !targetEnvironment(simulator)
        stopDiagnostics()
        diagnosticsStartupError = nil
        do {
            guard let persistence = journey?.diagnosticsPersistence else { throw FaceWorkflowStorageFailure.unavailable }
            let service = try DebugComparisonDiagnostics.live(persistence: persistence)
            diagnosticsTask = Task { await service.run() }
        } catch { diagnosticsStartupError = error }
        #endif
    }

    private func stopDiagnostics() {
        #if DEBUG && !targetEnvironment(simulator)
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        #endif
    }

    func tabBarController(_: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if let next = navigation.first(where: { $0.value === viewController })?.key, next != selectedCapability {
            let previous = selectedCapability
            selectedCapability = next
            controllers[previous]?.send(.interrupt)
            if previous == .document { documentFlow?.withdraw() }
            if previous == .passport { passportFlow?.withdraw() }
            if previous == .biometric {
                liveCapture?.controller.send(.cancel)
                clearComparison()
            }
        }
        return true
    }

    func tabBarController(_: UITabBarController, didSelect viewController: UIViewController) {
        if let capability = navigation.first(where: { $0.value === viewController })?.key { selectedCapability = capability }
    }

    func navigationController(_ navigationController: UINavigationController, didShow _: UIViewController, animated _: Bool) {
        if navigationController === navigation[.biometric], navigationController.viewControllers.count == 1,
           let capture = liveCapture {
            liveCapture = nil
            capture.onClose = nil
            capture.controller.send(.cancel)
        }
    }

    private func send(_ event: ReferenceEvent, capability: Capability) {
        switch event {
        case .journey: break
        case .passportReference:
            selectPassport()
        case .discardPassportReference:
            liveCapture?.controller.send(.cancel)
            passportReference = nil
            comparison.clear()
            refreshBiometricRoot()
        case .liveSelfie:
            clearComparison()
            openLiveCapture()
        case .discardSelfie:
            clearComparison()
        case .copyComparisonReport:
            guard let report = comparison.reportForExport() else { return }
            writeClipboard(report)
            reportCopied = true
            refreshBiometricRoot()
            UIAccessibility.post(notification: .announcement, argument: copy("comparison.export.copied"))
        case .comparisonTelemetry:
            comparison.toggleTelemetry()
        case .workflow(.cancel):
            guard capability == .document else { return }
            clearComparison()
            reset(capability)
        case .workflow(let event):
            guard capability == .document else { return }
            clearComparison()
            controllers[capability]?.send(event)
        }
    }

    private func openLiveCapture() {
        guard liveCapture == nil, let selected = passportReference, let reference = selected.read.portrait,
              let stack = navigation[.biometric] else { selectPassport(); return }
        let attempt = comparison.beginCapture(referenceID: selected.attemptID, reference: reference)
        let controller = makeCapture()
        controller.useSelfieKey = "comparison.compare"
        controller.scopeKey = "comparison.scope"
        controller.onAccepted = { [weak self, weak stack, weak controller] selfie in
            guard let self, let controller, self.liveCapture === controller else { return }
            self.liveCapture = nil
            let started = self.comparison.acceptCapture(id: attempt, currentReferenceID: self.passportReference?.attemptID,
                selfie: selfie.capture.encodedPNG, selfieSHA256: selfie.capture.sha256,
                captureContext: FaceCaptureContext(capture: selfie.capture), selection: selfie.selection, preparedSelfie: selfie.preparedSelfie)
            stack?.popToRootViewController(animated: true)
            if started { UIAccessibility.post(notification: .announcement, argument: self.copy("comparison.processing")) }
        }
        controller.onClose = { [weak self, weak stack, weak controller] in
            guard let self, let controller, self.liveCapture === controller else { return }
            self.comparison.cancelCapture(id: attempt)
            self.liveCapture = nil
            stack?.popViewController(animated: true)
        }
        liveCapture = controller
        stack.pushViewController(controller.makeRenderer(), animated: true)
    }

    private func clearComparison() {
        comparison.clear()
        refreshBiometricRoot()
    }

    private func comparisonChanged() {
        reportCopied = false
        refreshBiometricRoot()
        guard selectedCapability == .biometric else { return }
        switch comparison.phase {
        case .completed, .failed:
            let root = roots[.biometric]
            root?.loadViewIfNeeded()
            UIAccessibility.post(notification: .screenChanged, argument: root?.accessibilityElement(identifier: "workflow.step"))
        case .idle, .processing: break
        }
    }

    private func refreshBiometricRoot() {
        // Keep the navigation root stable while selfie review is being popped.
        // Replacing the stack during that transition can restore an older processing page.
        roots[.biometric]?.apply(biometricScreen())
    }

    private func reset(_ capability: Capability) {
        controllers[capability]?.onStateChange = nil
        controllers[capability]?.send(.cancel)
        if capability == .document {
            if let documentFlow {
                documentFlow.controller.send(.reset)
                return
            }
            let host = DocumentFlowHost()
            documentFlow = host
            let root = host.makeRenderer()
            prepareExampleRoot(root)
            navigation[capability]?.setViewControllers([root], animated: false)
            return
        }
        if capability == .biometric {
            let root = biometricRenderer()
            root.navigationItem.backButtonDisplayMode = .minimal
            roots[capability] = root
            prepareExampleRoot(root)
            navigation[capability]?.setViewControllers([root], animated: false)
            return
        }
        if capability == .passport {
            let host = PassportFlowHost()
            host.onAccepted = { [weak self] reference in
                guard let self else { return }
                self.acceptPassportPortrait(reference)
            }
            passportFlow = host
            let root = host.makeRenderer()
            prepareExampleRoot(root)
            navigation[capability]?.setViewControllers([root], animated: false)
            return
        }
    }

    private func selectPassport() {
        liveCapture?.controller.send(.cancel)
        selectedCapability = .passport
        tabs.selectedViewController = navigation[.passport]
    }

    private func showExamples() {
        guard let journey, journey.navigation.presentedViewController == nil, tabs.presentingViewController == nil else { return }
        tabs.modalPresentationStyle = .fullScreen
        journey.navigation.present(tabs, animated: true)
    }

    private func prepareExampleRoot(_ root: UIViewController) {
        guard !startsInExamples else { return }
        let done = UIBarButtonItem(title: copy("journey.done"), primaryAction: UIAction { [weak self] _ in self?.closeExamples() })
        done.accessibilityIdentifier = "journey.closeExamples"
        root.navigationItem.leftBarButtonItem = done
    }

    private func closeExamples() {
        documentFlow?.withdraw()
        liveCapture?.controller.send(.cancel)
        comparison.clear()
        passportReference = nil
        passportFlow?.withdraw()
        for capability in Capability.allCases { reset(capability) }
        selectedCapability = .biometric
        tabs.selectedIndex = 0
        if window?.rootViewController === tabs { window?.rootViewController = journey?.navigation }
        else { tabs.dismiss(animated: true) }
    }

    func acceptPassportPortrait(_ reference: AcceptedPassportPortrait) {
        liveCapture?.controller.send(.cancel)
        comparison.clear()
        passportReference = reference
        refreshBiometricRoot()
        selectedCapability = .biometric
        tabs.selectedViewController = navigation[.biometric]
        reset(.passport)
    }

    private func biometricRenderer() -> ReferenceRenderer {
        ReferenceRenderer(screen: biometricScreen(), emit: { [weak self] in
            self?.send($0, capability: .biometric)
        })
    }

    /// Pure prepared-state mapping; this never injects or accepts biometric evidence.
    func biometricScreen() -> ReferenceScreen {
        let heading: String
        var paragraphs: [ReferenceParagraph] = []
        var actions: [ReferenceAction] = []
        func action(_ key: String, _ event: ReferenceEvent) -> ReferenceAction {
            ReferenceAction(identifier: key, title: copy(key), hint: copy("accessibility.actionHint"), enabled: true, event: event)
        }
        if comparison.phase == .idle {
            heading = passportReference == nil ? "comparison.reference.required" : "passport.reference.title"
            paragraphs.append(ReferenceParagraph(text: copy(passportReference == nil ? "passport.reference.empty" : "comparison.reference.ready"), role: .body, identifier: "passport.reference.status"))
            if passportReference != nil { actions.append(action("capture.live.start", .liveSelfie)) }
            actions.append(action("passport.reference.open", .passportReference))
            if passportReference != nil { actions.append(action("passport.reference.discard", .discardPassportReference)) }
        } else {
            heading = comparison.hasResult ? "journey.result.title" : "comparison.processing"
            paragraphs += FaceComparisonPresentation.paragraphs(phase: comparison.phase,
                visual: comparison.visualPhase, durationMilliseconds: comparison.durationMilliseconds,
                expanded: comparison.telemetryExpanded, input: comparison.inputTelemetry,
                auraTelemetry: comparison.auraTelemetry, visualDurationMilliseconds: comparison.visualDurationMilliseconds,
                waitingForAura: comparison.visualWaitingForComparison)
            if comparison.canExportReport {
                actions.append(ReferenceAction(identifier: "comparison.export.copy",
                    title: copy(reportCopied ? "comparison.export.copied" : "comparison.export.copy"),
                    hint: copy("comparison.export.hint"), enabled: true, event: .copyComparisonReport))
            }
            if comparison.hasResult {
                actions.append(action("capture.retake", .liveSelfie))
                actions.append(action("capture.discard", .discardSelfie))
            } else { actions.append(action("capture.cancel", .discardSelfie)) }
            actions.append(action(comparison.telemetryExpanded ? "comparison.telemetry.hide" : "comparison.telemetry.show",
                .comparisonTelemetry))
        }
        paragraphs.append(ReferenceParagraph(text: copy("comparison.scope"), role: .caption, identifier: "comparison.scope"))
        return ReferenceScreen(title: copy(Capability.biometric.titleKey), heading: copy(heading), paragraphs: paragraphs,
            primaryActions: actions, image: passportReference?.read.portrait.flatMap { UIImage(data: $0) }, imageLabel: copy("passport.result.portrait"))
    }

    private func screen(_ state: WorkflowState) -> ReferenceScreen {
        var paragraphs: [ReferenceParagraph] = []
        let heading: String
        if state.phase == .idle {
            heading = copy("capability.\(state.capability.rawValue).instructionTitle")
            paragraphs.append(ReferenceParagraph(text: copy("capability.\(state.capability.rawValue).intro"), role: .body, identifier: "workflow.introduction"))
            paragraphs.append(ReferenceParagraph(text: copy("workflow.overviewHeading"), role: .action, identifier: "workflow.overview"))
            for key in overview(state.capability) {
                paragraphs.append(ReferenceParagraph(text: copy(key), role: .body, identifier: key))
            }
        } else {
            heading = copy(state.stepKey)
            if ![.completed, .cancelled].contains(state.phase) {
                let progress = ["progress.step1", "progress.step2", "progress.step3"][state.step]
                paragraphs.append(ReferenceParagraph(text: copy(progress), role: .caption, identifier: "workflow.progress"))
            }
            paragraphs.append(ReferenceParagraph(text: copy(state.outcome?.messageKey ?? state.accessibilityStatusKey), role: .body, identifier: "workflow.message"))
        }
        paragraphs.append(ReferenceParagraph(text: copy("demo.disclosure"), role: .caption, identifier: "stub.notice"))
        var primary: [ReferenceAction] = []
        for action in state.actions where [.start, .advance, .retry, .restore].contains(action.id) {
            primary.append(ReferenceAction(identifier: "action.\(action.id.rawValue)", title: copy(action.labelKey), hint: copy("accessibility.actionHint"), enabled: action.enabled, event: .workflow(action.event)))
        }
        return ReferenceScreen(title: copy(state.capability.titleKey), heading: heading, paragraphs: paragraphs, primaryActions: primary)
    }

    private func renderer(_ state: WorkflowState) -> ReferenceRenderer {
        let renderer = ReferenceRenderer(screen: screen(state), emit: { [weak self] event in self?.send(event, capability: state.capability) })
        var items: [UIBarButtonItem] = []
        if state.actions.contains(where: { $0.id == .cancel }) {
            let cancel = UIBarButtonItem(image: UIImage(systemName: KenshikiIOSPrimitives.cancelSymbol), primaryAction: UIAction { [weak self] _ in self?.send(.workflow(.cancel), capability: state.capability) })
            cancel.accessibilityIdentifier = "action.cancel"
            cancel.accessibilityLabel = copy("workflow.action.cancel")
            cancel.accessibilityHint = copy("accessibility.actionHint")
            items.append(cancel)
        }
        #if DEBUG
        if state.actions.contains(where: { $0.id == .simulateFailure }) {
            let failure = UIAction(title: copy("workflow.action.simulateFailure"), identifier: UIAction.Identifier("action.simulateFailure")) { [weak self] _ in self?.send(.workflow(.simulateFailure), capability: state.capability) }
            let developer = UIBarButtonItem(image: UIImage(systemName: KenshikiIOSPrimitives.developerSymbol), menu: UIMenu(children: [failure]))
            developer.accessibilityIdentifier = "developer.menu"
            developer.accessibilityLabel = copy("developer.menu")
            items.append(developer)
        }
        #endif
        renderer.navigationItem.rightBarButtonItems = items
        return renderer
    }

    private func render(_ capability: Capability) {
        guard let state = controllers[capability]?.state, let stack = navigation[capability], let root = roots[capability] else { return }
        let prepared = renderer(state)
        stack.setViewControllers([root, prepared], animated: stack.viewControllers.count == 1)
        if capability == selectedCapability {
            prepared.loadViewIfNeeded()
            UIAccessibility.post(notification: .layoutChanged, argument: prepared.accessibilityElement(identifier: "workflow.step"))
            UIAccessibility.post(notification: .announcement, argument: copy(state.outcome?.messageKey ?? state.accessibilityStatusKey))
        }
    }

    private func copy(_ key: String) -> String { KenshikiCopy.text(key) }

    private func symbol(_ capability: Capability) -> String {
        switch capability {
        case .biometric: KenshikiIOSPrimitives.biometricSymbol
        case .document: KenshikiIOSPrimitives.documentSymbol
        case .passport: KenshikiIOSPrimitives.passportSymbol
        }
    }

    private func overview(_ capability: Capability) -> [String] {
        switch capability {
        case .biometric: []
        case .document: ["workflow.step.document.front", "workflow.step.document.back", "workflow.step.document.review"]
        case .passport: []
        }
    }
}

/// Shared localization and formatting for both live reference entry points.
@MainActor enum FaceComparisonPresentation {
    static func summary(phase: FaceComparisonController.Phase) -> [ReferenceParagraph] {
        var rows = [paragraph("comparison.aura.title", .action)]
        switch phase {
        case .idle: rows.append(paragraph("comparison.aura.ready", .body, identifier: "comparison.status"))
        case .processing: rows.append(paragraph("comparison.aura.processing", .body, identifier: "comparison.status"))
        case .completed(let score):
            rows.append(paragraph("comparison.score", .caption, identifier: "comparison.score.label"))
            rows.append(number(score, identifier: "comparison.score"))
            rows.append(paragraph("comparison.observation.summary", .caption, identifier: "comparison.status"))
        case .failed(let key): rows.append(paragraph(key, .body, identifier: "comparison.status"))
        }
        return rows
    }

    static func paragraphs(phase: FaceComparisonController.Phase, visual: FaceComparisonController.VisualPhase,
                           durationMilliseconds: Double?, expanded: Bool = false,
                           input: FaceInputTelemetry? = nil, auraTelemetry: [FaceTelemetryField] = [],
                           visualDurationMilliseconds: Double? = nil, waitingForAura: Bool = false,
                           partial: FaceVisualAssessmentCompletion? = nil,
                           includeCaptureMotionSource: Bool = true) -> [ReferenceParagraph] {
        var rows = [paragraph("comparison.aura.title", .action)]
        switch phase {
        case .idle: rows.append(paragraph("comparison.aura.ready", .body, identifier: "comparison.status"))
        case .processing: rows.append(paragraph("comparison.aura.processing", .body, identifier: "comparison.status"))
        case .completed(let score):
            rows.append(paragraph("comparison.score", .caption, identifier: "comparison.score.label"))
            rows.append(number(score, identifier: "comparison.score"))
            rows.append(paragraph("comparison.observation", .body, identifier: "comparison.status"))
        case .failed(let key): rows.append(paragraph(key, .body, identifier: "comparison.status"))
        }
        if let durationMilliseconds {
            rows.append(paragraph("comparison.duration", .caption, identifier: "comparison.aura.duration.label"))
            rows.append(number(durationMilliseconds, identifier: "comparison.aura.duration"))
        }
        if expanded {
            rows.append(paragraph("comparison.telemetry.title", .action))
            rows.append(paragraph("comparison.telemetry.scope", .caption))
            if let input { rows += telemetry(FaceComparisonTelemetry.fields(input, includeCaptureMotionSource: includeCaptureMotionSource)) }
            rows.append(paragraph("telemetry.aura.title", .action))
            rows += auraTelemetry.isEmpty ? [paragraph("telemetry.unavailable", .body, identifier: "telemetry.aura.unavailable")] : telemetry(auraTelemetry)

        }
        return rows
    }
    static func telemetry(_ fields: [FaceTelemetryField], prefix: String = "") -> [ReferenceParagraph] {
        var rows: [ReferenceParagraph] = []
        for (index, field) in fields.enumerated() {
            rows.append(diagnosticParagraph(field.key, .caption, identifier: "\(prefix)\(field.key).label.\(index)"))
            let identifier = "\(prefix)\(field.key).value.\(index)"
            switch field.value {
            case .text(let value): rows.append(ReferenceParagraph(text: value, role: .body, identifier: identifier))
            case .code(let key): rows.append(diagnosticParagraph(key, .body, identifier: identifier))
            case .number(let value): rows.append(number(value, identifier: identifier))
            case .range(let minimum, let maximum):
                if minimum.isFinite, maximum.isFinite, minimum <= maximum {
                    rows.append(ReferenceParagraph(text: number(minimum, identifier: identifier).text +
                        KenshikiCopy.text("telemetry.motion.range") + number(maximum, identifier: identifier).text,
                        role: .body, identifier: identifier))
                } else { rows.append(paragraph("telemetry.invalid", .body, identifier: identifier)) }
            case .integer(let value): rows.append(number(Double(value), identifier: identifier))
            case .unsigned(let value): rows.append(ReferenceParagraph(text: value.formatted(.number), role: .body, identifier: identifier))
            case .flag(let value): rows.append(paragraph(value ? "telemetry.yes" : "telemetry.no", .body, identifier: identifier))
            case .unavailable: rows.append(paragraph("telemetry.unavailable", .body, identifier: identifier))
            }
        }
        return rows
    }
    private static func diagnosticParagraph(_ key: String, _ role: KenshikiIOSTextRole,
                                            identifier: String? = nil) -> ReferenceParagraph {
        // Persisted diagnostics can outlive their producing app version. Unknown
        // dynamic keys are explicit unsupported data, not localization assertions.
        let text = KenshikiCopy(rawValue: key)?.localized() ?? KenshikiCopy.text("telemetry.unsupported")
        return ReferenceParagraph(text: text, role: role, identifier: identifier ?? key)
    }
    private static func paragraph(_ key: String, _ role: KenshikiIOSTextRole,
                                  identifier: String? = nil) -> ReferenceParagraph {
        ReferenceParagraph(text: KenshikiCopy.text(key), role: role, identifier: identifier ?? key)
    }
    private static func number(_ value: Double, identifier: String) -> ReferenceParagraph {
        guard value.isFinite else { return paragraph("telemetry.invalid", .body, identifier: identifier) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 17
        return ReferenceParagraph(text: formatter.string(from: NSNumber(value: value)) ?? value.formatted(),
            role: .body, identifier: identifier)
    }
}
