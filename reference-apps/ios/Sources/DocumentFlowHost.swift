import CryptoKit
import DocumentSDK
import DocumentCaptureApple
import DocumentCapturePreview
import UIKit

/// App composition of public optical SDK APIs and explicitly named local capture custody.
@MainActor final class DocumentFlowHost {
    let controller: DocumentFlowController
    private let factory: NativeDocumentFlowFactory?
    private let permissionPromptPending: () -> Bool
    private let actions = UIStackView()
    private var renderer: DocumentFlowRenderer?
    private var presentationTask: Task<Void, Never>?
    private var deletionConfirmation: UIAlertController?
    #if DEBUG
    private let diagnostics = try? DocumentFlowDiagnostics.live()
    #endif

    convenience init() {
        let factory = NativeDocumentFlowFactory()
        self.init(controller: DocumentFlowController(ports: factory.ports, persistence: DocumentFlowSQLiteStore()), factory: factory,
            permissionPromptPending: { factory.authorizationPending })
        factory.created = { [weak self] in self?.connectFrontPresentation() }
    }

    init(controller: DocumentFlowController, factory: NativeDocumentFlowFactory? = nil,
         permissionPromptPending: @escaping () -> Bool = { false }) {
        self.controller = controller
        self.factory = factory
        self.permissionPromptPending = permissionPromptPending
        actions.axis = .vertical
        actions.spacing = KenshikiDesign.gapSpacing
        controller.changed = { [weak self] in
            guard let self else { return }
            #if DEBUG
            self.diagnostics?.record(phase: self.controller.phase, persistence: self.controller.persistenceState,
                failure: self.controller.failure, hasFront: self.controller.front != nil, hasBack: self.controller.back != nil)
            #endif
            self.render()
        }
        factory?.frontIntent = { [weak self] intent in
            switch intent {
            case .capture: self?.controller.send(.frontCapture)
            case .cancel: self?.controller.send(.reset)
            }
        }
    }

    func makeRenderer() -> DocumentFlowRenderer {
        let renderer = DocumentFlowRenderer(screen: screen(), emit: { [weak self] intent in
            if case .hidden = intent { self?.withdraw() }
            else { self?.controller.send(intent) }
        })
        self.renderer = renderer
        return renderer
    }

    func resignActive() {
        // An owned system permission sheet temporarily makes the app inactive.
        // True backgrounding and page withdrawal always revoke the pending start.
        guard !permissionPromptPending() else { return }
        setForeground(false)
    }

    func setForeground(_ foreground: Bool) {
        if !foreground {
            dismissDeletionConfirmation()
            presentationTask?.cancel(); presentationTask = nil
            factory?.invalidatePendingAuthorization()
        }
        controller.setForeground(foreground)
    }
    func withdraw() {
        dismissDeletionConfirmation()
        presentationTask?.cancel(); presentationTask = nil
        factory?.invalidatePendingAuthorization()
        controller.send(.hidden)
    }

    private func render() {
        if !canConfirmDeletion { dismissDeletionConfirmation() }
        renderer?.apply(screen())
    }

    private func connectFrontPresentation() {
        presentationTask?.cancel()
        render()
        presentationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.refreshFrontPresentation() == true else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func refreshFrontPresentation() -> Bool {
        guard factory?.camera != nil else { return false }
        if controller.phase == .front || controller.processingSide == .front {
            _ = factory?.frontSurface(busy: controller.phase == .processing)
        }
        return true
    }

    private func screen() -> DocumentFlowScreen {
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let heading: String
        let message: String
        var items: [DocumentFlowDisplayItem] = []
        var preview: UIView?
        var captureSurface: UIView?
        switch controller.phase {
        case .intro:
            heading = "document.live.title"
            message = "document.live.intro"
            add("document.live.start", .start)
            if controller.supportsPersistence { add("document.saved.open", .reopen) }
        case .starting:
            heading = "document.live.title"
            message = "document.live.starting"
            add(controller.supportsPersistence ? "document.saved.reset" : "document.live.reset", .reset)
        case .front:
            heading = "workflow.step.document.front"
            message = "document.live.align"
            captureSurface = factory?.frontSurface(busy: false)
        case .back:
            heading = "document.saved.scanBack"
            message = "document.back.instruction"
            preview = factory?.preview
            add("document.live.capture", .capture)
            add(controller.supportsPersistence ? "document.saved.reset" : "document.live.reset", .reset)
        case .processing:
            heading = "document.live.processing"
            message = controller.persistenceState == .saving ? "document.saved.saving" : "document.live.processing.body"
            if controller.processingSide == .front {
                captureSurface = factory?.frontSurface(busy: true)
            } else {
                preview = factory?.preview
                add(controller.supportsPersistence ? "document.saved.reset" : "document.live.reset", .reset)
            }
        case .restoring, .deleting:
            heading = "document.live.title"
            message = controller.phase == .restoring ? "document.saved.restoring" : "document.saved.deleting"
            add("document.saved.reset", .reset)
        case .review:
            heading = "workflow.step.document.review"
            switch controller.persistenceState {
            case .saved: message = "document.saved.review"
            case .restored: message = "document.saved.restored"
            default: message = "document.live.review"
            }
            if let front = controller.front { items += display(front, prefix: "document.front") }
            if let back = controller.back { items += display(back, prefix: "document.back") }
            add("document.live.retakeFront", .retakeFront)
            add(controller.back == nil ? "document.saved.scanBack" : "document.live.retakeBack", .retakeBack)
            if controller.supportsPersistence { add("document.saved.delete", .deleteSaved) }
            add(controller.supportsPersistence ? "document.saved.reset" : "document.live.reset", .reset)
        case .failure:
            heading = "document.live.failure"
            switch controller.failure {
            case .cameraStart: message = "document.live.failure.camera"
            case .sourceBinding: message = "document.live.failure.source"
            case .preparation: message = "document.live.failure.preparation"
            case .storageSave: message = "document.saved.failure.save"
            case .storageRead: message = "document.saved.failure.read"
            case .storageDelete: message = "document.saved.failure.delete"
            case .noSavedCapture: message = "document.saved.missing"
            default: message = "document.live.failure.processing"
            }
            if controller.failure == .storageSave { add("document.saved.retrySave", .retrySave) }
            if controller.supportsPersistence {
                add("document.saved.open", .reopen)
                if canConfirmDeletion {
                    add("document.saved.delete", .deleteSaved)
                }
            }
            add(controller.supportsPersistence ? "document.saved.reset" : "document.live.reset", .reset)
        }
        return DocumentFlowScreen(title: copy("capability.document.title"), heading: copy(heading), message: copy(message),
            scope: copy(controller.supportsPersistence ? "document.saved.scope" : "document.live.scope"), preview: preview, previewLabel: copy("document.live.preview"),
            items: items, actionSurface: actions, captureSurface: captureSurface)
    }

    private func display(_ observation: DocumentFlowObservation, prefix: String) -> [DocumentFlowDisplayItem] {
        var items = [DocumentFlowDisplayItem(title: copy(prefix + ".original"), text: "",
            image: UIImage(data: observation.source.data), identifier: prefix + ".original")]
        if let prepared = observation.prepared {
            items.append(DocumentFlowDisplayItem(title: copy(prefix + ".prepared"), text: "",
                image: UIImage(data: prepared.data), identifier: prefix + ".prepared"))
        }
        items += [DocumentFlowDisplayItem(title: copy("document.live.text"), text: observation.reading.recognizedText.joined(separator: "\n"),
            image: nil, identifier: prefix + ".text"),
            DocumentFlowDisplayItem(title: copy("document.live.barcode"), text: observation.reading.pdf417Payloads.joined(separator: "\n"),
            image: nil, identifier: prefix + ".barcode")]
        let fields = observation.reading.structuredPDF417Results.flatMap { result in
            result.fields.sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value }
        }.joined(separator: "\n")
        items.append(DocumentFlowDisplayItem(title: copy("document.live.fields"), text: fields,
            image: nil, identifier: prefix + ".fields"))
        if observation.source.side == .front {
            if observation.portraits.isEmpty {
                items.append(DocumentFlowDisplayItem(title: copy("document.live.portrait"), text: copy("document.live.portrait.empty"), image: nil, identifier: "document.portrait.empty"))
            } else {
                for (index, portrait) in observation.portraits.enumerated() {
                    items.append(DocumentFlowDisplayItem(title: copy("document.live.portrait"), text: copy("document.live.portrait.scope"),
                        image: UIImage(data: portrait.data), identifier: "document.portrait." + String(index)))
                }
            }
        }
        return items
    }

    private func add(_ key: String, _ intent: DocumentFlowIntent) {
        let button = MultilineActionButton(type: .system)
        var configuration = KenshikiIOSDesign.primaryConfiguration()
        configuration.title = copy(key)
        configuration.titleLineBreakMode = .byWordWrapping
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        if case .reset = intent { button.accessibilityIdentifier = "document.live.reset" }
        else { button.accessibilityIdentifier = key }
        button.accessibilityHint = copy("accessibility.actionHint")
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: KenshikiDesign.minimumTargetIOS).isActive = true
        button.addAction(UIAction { [weak self] _ in
            if case .deleteSaved = intent { self?.confirmDeletion() }
            else { self?.controller.send(intent) }
        }, for: .touchUpInside)
        actions.addArrangedSubview(button)
    }

    private var canConfirmDeletion: Bool {
        guard controller.supportsPersistence else { return false }
        switch controller.phase {
        case .review: return true
        case .failure:
            switch controller.failure {
            case .storageRead, .sourceBinding, .storageDelete: return true
            default: return false
            }
        default: return false
        }
    }

    private func confirmDeletion() {
        guard canConfirmDeletion, let renderer, renderer.viewIfLoaded?.window != nil,
              renderer.presentedViewController == nil else { return }
        let confirmation = UIAlertController(title: copy("document.saved.delete.title"),
            message: copy("document.saved.delete.body"), preferredStyle: .alert)
        confirmation.addAction(UIAlertAction(title: copy("document.saved.delete.cancel"), style: .cancel) { [weak self, weak confirmation] _ in
            guard let self, let confirmation, self.deletionConfirmation === confirmation else { return }
            self.deletionConfirmation = nil
        })
        confirmation.addAction(UIAlertAction(title: copy("document.saved.delete"), style: .destructive) { [weak self, weak confirmation] _ in
            guard let self, let confirmation, self.deletionConfirmation === confirmation, self.canConfirmDeletion else { return }
            self.deletionConfirmation = nil
            self.controller.send(.deleteSaved)
        })
        deletionConfirmation = confirmation
        renderer.present(confirmation, animated: true)
    }

    private func dismissDeletionConfirmation() {
        let confirmation = deletionConfirmation
        deletionConfirmation = nil
        confirmation?.dismiss(animated: false)
    }

    private func copy(_ key: String) -> String { KenshikiCopy.text(key) }
}

@MainActor final class NativeDocumentFlowFactory {
    var created: (() -> Void)?
    private(set) var camera: NativeDocumentFlowCamera?
    private var pendingPhoto: CapturedDocumentPhoto?
    private(set) var preview: DocumentCameraPreviewView?
    private var surface: DocumentFrontCaptureView?
    var frontIntent: ((DocumentFrontCaptureIntent) -> Void)?
    var authorizationPending: Bool { camera?.authorizationPending == true }

    func invalidatePendingAuthorization() { camera?.invalidatePendingAuthorization() }

    func frontSurface(busy: Bool) -> DocumentFrontCaptureView? {
        guard let camera, let surface else { return nil }
        surface.apply(DocumentFrontCapturePresentation.state(front: camera.front, busy: busy,
            uptime: ProcessInfo.processInfo.systemUptime))
        return surface
    }

    private func configurePreview(driver: NativeDocumentFlowCamera, side: DocumentSide) {
        guard camera === driver else { return }
        let preview = DocumentCameraPreviewView(previewProvider: driver.camera)
        self.preview = preview
        if side == .back {
            preview.guideStyle = .pdf417
            surface = nil
        } else {
            surface = DocumentFrontCaptureView(preview: preview, style: DocumentFrontCapturePresentation.style(),
                emit: { [weak self] in self?.frontIntent?($0) })
        }
        created?()
    }

    var ports: DocumentFlowPorts {
        DocumentFlowPorts(makeCamera: { [self] in
            let driver = NativeDocumentFlowCamera()
            driver.captured = { [weak self] in self?.pendingPhoto = $0 }
            driver.stopping = { [weak self, weak driver] in
                self?.pendingPhoto = nil
                if self?.camera === driver {
                    self?.camera = nil; self?.preview = nil; self?.surface = nil
                }
            }
            camera = driver
            driver.selectedCameraChanged = { [weak self, weak driver] side in
                guard let self, let driver, self.camera === driver else { return }
                self.configurePreview(driver: driver, side: side)
            }
            configurePreview(driver: driver, side: .front)
            return driver
        }, prepare: { [self] source in
            guard let photo = pendingPhoto, photo.side == source.side, photo.data == source.data,
                  photo.fidelity.sha256 == source.sha256 else { throw DocumentFlowFailure.sourceBinding }
            pendingPhoto = nil
            let prepared = try await AppleDocumentImagePreparer().prepare(photo)
            try Task.checkCancellation()
            return DocumentFlowPrepared(sourceSHA256: prepared.derivative.derivation.sourceSHA256,
                data: prepared.derivative.data, sha256: prepared.derivative.derivation.outputSHA256,
                pixelWidth: prepared.derivative.derivation.outputPixelWidth,
                pixelHeight: prepared.derivative.derivation.outputPixelHeight,
                derivation: try JSONEncoder().encode(prepared.derivative.derivation))
        }, extract: { source in
            let extraction = try await ArtifactExtraction.extractAsync(original: source.data)
            try Task.checkCancellation()
            guard extraction.fidelity.sha256 == source.sha256 else { throw DocumentFlowFailure.sourceBinding }
            return DocumentFlowReading(sourceSHA256: extraction.fidelity.sha256, recognizedText: extraction.recognizedText,
                pdf417Payloads: extraction.pdf417Payloads, parsedPDF417: extraction.parsedPDF417 ?? [], licenseFront: extraction.licenseFront)
        }, portraits: { prepared in
            let derivation = try JSONDecoder().decode(DocumentImageDerivation.self, from: prepared.derivation)
            guard derivation.outputSHA256 == prepared.sha256,
                  derivation.sourceSHA256 == prepared.sourceSHA256,
                  derivation.outputPixelWidth == prepared.pixelWidth,
                  derivation.outputPixelHeight == prepared.pixelHeight,
                  derivation.supported else { throw DocumentFlowFailure.sourceBinding }
            let result = try await ApplePortraitExtractor().extract(data: prepared.data, derivation: derivation)
            try Task.checkCancellation()
            guard result.metadata.sourceSHA256 == prepared.sha256 else { throw DocumentFlowFailure.sourceBinding }
            return result.candidates.map { DocumentFlowPortrait(sourceSHA256: $0.metadata.sourceSHA256, data: $0.data,
                sha256: $0.metadata.outputSHA256, geometry: $0.metadata.geometry) }
        }, sha256: { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
    }
}

#if DEBUG
/// Bounded phase codes only: no images, OCR, barcode payloads, source IDs or error descriptions.
@MainActor final class DocumentFlowDiagnostics {
    struct Entry: Codable, Equatable {
        let sequence: UInt64
        let phase: String
        let persistence: String
        let failure: String?
        let hasFront: Bool
        let hasBack: Bool
    }
    private(set) var entries: [Entry] = []
    private var sequence: UInt64 = 0
    private let write: (Data) throws -> Void

    init(write: @escaping (Data) throws -> Void) { self.write = write }

    static func live() throws -> DocumentFlowDiagnostics {
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).resolvingSymlinksInPath()
            .appendingPathComponent("KenshikiDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(values)
        let destination = directory.appendingPathComponent("document-flow.json")
        return DocumentFlowDiagnostics { try $0.write(to: destination, options: [.atomic, .completeFileProtection]) }
    }

    func record(phase: DocumentFlowPhase, persistence: DocumentFlowPersistenceState,
                failure: DocumentFlowFailure?, hasFront: Bool, hasBack: Bool) {
        sequence += 1
        entries.append(.init(sequence: sequence, phase: String(describing: phase),
            persistence: String(describing: persistence), failure: failure.map { String(describing: $0) },
            hasFront: hasFront, hasBack: hasBack))
        if entries.count > 64 { entries.removeFirst(entries.count - 64) }
        try? write(JSONEncoder().encode(entries))
    }
}
#endif
