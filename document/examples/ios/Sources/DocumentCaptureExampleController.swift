import DocumentCaptureApple
import DocumentCapturePreview
import DocumentSDK
import KenshikiDesign
import UIKit

/// Independent optical sample. All media stays in memory; no identity verification is composed.
@MainActor
final class DocumentCaptureExampleController: UIViewController {
  private let camera = DocumentCamera(now: Date.init, notifications: .default,
    diagnostics: .init(includesAdaptiveCapture: true))
  private lazy var preview = DocumentCameraPreviewView(previewProvider: camera)
  private let status = UILabel()
  private let action = UIButton(type: .system)
  private let result = UITextView()
  private var operation: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var active = false
  private var side: DocumentSide = .front
  private var front: PreparedDocumentCandidate?
  private var back: PreparedDocumentCandidate?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = KenshikiCopy.capabilityDocumentTitle.localized()
    view.backgroundColor = .systemBackground
    status.font = .preferredFont(forTextStyle: .headline)
    status.adjustsFontForContentSizeCategory = true
    status.numberOfLines = 0
    status.accessibilityTraits = .updatesFrequently
    action.isEnabled = false
    action.setTitle(KenshikiCopy.workflowActionAdvance.localized(), for: .normal)
    action.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    action.titleLabel?.adjustsFontForContentSizeCategory = true
    action.addTarget(self, action: #selector(capture), for: .touchUpInside)
    result.isEditable = false
    result.font = .preferredFont(forTextStyle: .body)
    result.adjustsFontForContentSizeCategory = true
    let stack = UIStackView(arrangedSubviews: [status, preview, action, result])
    stack.axis = .vertical
    stack.spacing = KenshikiDesign.gapSpacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: KenshikiDesign.pageSpacing),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -KenshikiDesign.pageSpacing),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: KenshikiDesign.compactSpacing),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -KenshikiDesign.compactSpacing),
      preview.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5),
      action.heightAnchor.constraint(greaterThanOrEqualToConstant: KenshikiDesign.minimumTargetIOS),
    ])
    status.text = KenshikiCopy.workflowStepDocumentFront.localized()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    resumeCapture()
  }

  func resumeCapture() {
    guard isViewLoaded, view.window != nil, !active else { return }
    active = true
    status.text = KenshikiCopy.workflowStepDocumentFront.localized()
    generation &+= 1
    let selected = generation
    operation = Task { [weak self] in
      guard let self else { return }
      do {
        try await camera.start()
        try Task.checkCancellation()
        guard generation == selected else { return }
        action.isEnabled = true
      } catch {
        guard generation == selected else { return }
        status.text = KenshikiCopy.workflowReasonPermissionDenied.localized()
        action.isEnabled = false
      }
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    suspendCapture()
  }

  func suspendCapture() {
    active = false
    action.isEnabled = false
    generation &+= 1
    operation?.cancel()
    operation = nil
    camera.stop()
    front = nil
    back = nil
    result.text = nil
    side = .front
  }

  @objc private func capture() {
    operation?.cancel()
    action.isEnabled = false
    let selected = generation
    let selectedSide = side
    operation = Task { [weak self] in
      guard let self else { return }
      defer { if generation == selected { action.isEnabled = true } }
      do {
        let original = try await camera.capture(side: selectedSide)
        let prepared = try await AppleDocumentImagePreparer().prepare(original)
        let extracted = try await ArtifactExtraction.extractAsync(original: original.data)
        var portraitCount = 0
        if selectedSide == .front {
          let portraits = try await ApplePortraitExtractor().extract(
            data: prepared.derivative.data, derivation: prepared.derivative.derivation)
          portraitCount = portraits.candidates.count
        }
        try Task.checkCancellation()
        guard generation == selected else { return }
        if selectedSide == .front {
          front = prepared
          side = .back
          status.text = KenshikiCopy.workflowStepDocumentBack.localized()
        } else {
          back = prepared
          side = .front
          status.text = KenshikiCopy.workflowStepDocumentReview.localized()
        }
        let fields: [String: Any] = [
          "side": selectedSide.rawValue,
          "sourceSHA256": original.fidelity.sha256,
          "derivativeSHA256": prepared.derivative.derivation.outputSHA256,
          "recognizedText": extracted.recognizedText,
          "pdf417": extracted.pdf417Payloads,
          "barcodeFields": (extracted.parsedPDF417 ?? []).map(\.fields),
          "portraitCandidateCount": portraitCount,
        ]
        let bytes = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        result.text = String(decoding: bytes, as: UTF8.self)
      } catch is CancellationError {
        return
      } catch {
        guard generation == selected else { return }
        status.text = KenshikiCopy.workflowReasonInvalidInput.localized()
      }
    }
  }
}
