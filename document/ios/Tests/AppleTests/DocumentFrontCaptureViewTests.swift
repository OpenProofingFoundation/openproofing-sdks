#if os(iOS)
  import AVFoundation
  import DocumentCaptureApple
  import DocumentCapturePreview
  import UIKit
  import XCTest

  @MainActor final class DocumentFrontCaptureViewTests: XCTestCase {
    func testApplyingContentPreservesTheExactNativePreviewAndAttachment() throws {
      let provider = FrontPreviewProvider()
      let preview = DocumentCameraPreviewView(previewProvider: provider)
      let view = DocumentFrontCaptureView(preview: preview, style: style(), emit: { _ in })
      let viewport = try XCTUnwrap(preview.superview)
      for index in 0..<4 {
        view.apply(state(status: "Observation \(index)", busy: index.isMultiple(of: 2)))
        view.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        view.layoutIfNeeded()
        XCTAssertTrue(view.preview === preview)
        XCTAssertTrue(preview.superview === viewport)
      }
      XCTAssertEqual(provider.attachments, 1, "Rendering content must not reattach or replace the native camera preview")
      XCTAssertEqual(provider.feedbackSubscriptions, 1)
    }

    func testWrappingStatusCannotMoveTheLevelAndTheViewportKeepsItsAspect() throws {
      let view = DocumentFrontCaptureView(
        preview: DocumentCameraPreviewView(previewProvider: FrontPreviewProvider()), style: style(), emit: { _ in })
      view.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
      view.apply(state(status: "Hold steady"))
      view.layoutIfNeeded()
      let level = try XCTUnwrap(find("document.front.level", in: view))
      let status = try XCTUnwrap(find("document.front.status", in: view) as? UILabel)
      let initialCenter = level.convert(CGPoint(x: level.bounds.midX, y: level.bounds.midY), to: view)
      let initialStatusHeight = status.bounds.height
      view.apply(state(status: String(repeating: "Keep the whole document in the camera frame. ", count: 12)))
      view.layoutIfNeeded()
      let changedCenter = level.convert(CGPoint(x: level.bounds.midX, y: level.bounds.midY), to: view)
      XCTAssertEqual(initialCenter.x, changedCenter.x, accuracy: 0.001)
      XCTAssertEqual(initialCenter.y, changedCenter.y, accuracy: 0.001)
      XCTAssertGreaterThan(status.bounds.height, initialStatusHeight)
      XCTAssertEqual(view.preview.bounds.width / view.preview.bounds.height, 340 / 234.97, accuracy: 0.001)
      let scroll = try XCTUnwrap(view.subviews.first as? UIScrollView)
      XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height,
        "Long localized guidance must scroll instead of clipping the actions")
    }

    func testPreparedAccessibilityAvailabilityAndIntentsStayHostOwned() throws {
      var intents: [DocumentFrontCaptureIntent] = []
      let view = DocumentFrontCaptureView(
        preview: DocumentCameraPreviewView(previewProvider: FrontPreviewProvider()),
        style: style(), emit: { intents.append($0) })
      view.apply(state(status: "Ready", captureEnabled: false, busy: true))
      let capture = try XCTUnwrap(find("document.front.capture", in: view) as? UIButton)
      let cancel = try XCTUnwrap(find("document.front.cancel", in: view) as? UIButton)
      let heading = try XCTUnwrap(find("document.front.heading", in: view))
      let level = try XCTUnwrap(find("document.front.level", in: view))
      XCTAssertFalse(capture.isEnabled)
      XCTAssertTrue(cancel.isEnabled)
      XCTAssertTrue(heading.accessibilityTraits.contains(.header))
      XCTAssertEqual(level.accessibilityLabel, "Phone level")
      XCTAssertEqual(level.accessibilityValue, "Unavailable")
      XCTAssertEqual(view.preview.accessibilityLabel, "Front camera picture")
      XCTAssertTrue(intents.isEmpty, "Applying state never starts or cancels acquisition")
      view.apply(state(status: "Ready", captureEnabled: true,
        level: .init(offset: .init(width: 0.8, height: 0), tone: .tilted), levelValue: "Phone is tilted"))
      XCTAssertTrue(capture.isEnabled)
      XCTAssertEqual(capture.title(for: .normal), "Take photo")
      XCTAssertEqual(level.accessibilityValue, "Phone is tilted",
        "The spoken state must update independently of the bubble's colour")
      try dispatchRegisteredTouchUpInside(capture)
      try dispatchRegisteredTouchUpInside(cancel)
      XCTAssertEqual(intents, [.capture, .cancel])
    }

    func testLevelCanBeHiddenWithoutRecreatingPreviewOrStatus() throws {
      let view = DocumentFrontCaptureView(
        preview: DocumentCameraPreviewView(previewProvider: FrontPreviewProvider()), style: style(), emit: { _ in })
      view.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
      view.apply(state(status: "Ready"))
      view.layoutIfNeeded()
      let level = try XCTUnwrap(find("document.front.level", in: view))
      let status = try XCTUnwrap(find("document.front.status", in: view))
      view.apply(state(status: "Saved", showLevel: false))
      view.layoutIfNeeded()
      XCTAssertTrue(try XCTUnwrap(level.superview).isHidden)
      XCTAssertEqual(try XCTUnwrap(level.superview).bounds.height, 0)
      XCTAssertTrue(find("document.front.status", in: view) === status)
      XCTAssertFalse(status.isHidden)
    }

    func testSuppliedDynamicBorderRefreshesForAppearanceAndContrastWithoutReplacingPreview() throws {
      let border = UIColor { traits in
        if traits.accessibilityContrast == .high { return .yellow }
        return traits.userInterfaceStyle == .dark ? .red : .blue
      }
      let preview = DocumentCameraPreviewView(previewProvider: FrontPreviewProvider())
      let view = DocumentFrontCaptureView(preview: preview, style: style(border: border), emit: { _ in })
      view.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
      view.traitOverrides.userInterfaceStyle = .light
      view.updateTraitsIfNeeded()
      view.apply(state(status: "Ready"))
      view.layoutIfNeeded()
      let viewport = try XCTUnwrap(preview.superview)
      XCTAssertEqual(viewport.layer.borderColor, UIColor.blue.cgColor)
      view.traitOverrides.userInterfaceStyle = .dark
      view.updateTraitsIfNeeded()
      view.layoutIfNeeded()
      XCTAssertEqual(viewport.layer.borderColor, UIColor.red.cgColor)
      view.traitOverrides.accessibilityContrast = .high
      view.updateTraitsIfNeeded()
      view.layoutIfNeeded()
      XCTAssertEqual(viewport.layer.borderColor, UIColor.yellow.cgColor)
      XCTAssertTrue(view.preview === preview)
      XCTAssertTrue(preview.superview === viewport)
    }

    // SwiftPM runs this UIKit suite without UIApplicationMain. UIControl.sendActions
    // cannot dispatch in that host; exercise the actual registered target/selector instead.
    private func dispatchRegisteredTouchUpInside(_ button: UIButton) throws {
      XCTAssertEqual(button.allTargets.count, 1)
      let target = try XCTUnwrap(button.allTargets.first as? NSObject)
      let actions = try XCTUnwrap(button.actions(forTarget: target, forControlEvent: .touchUpInside))
      XCTAssertEqual(actions.count, 1)
      let action = try XCTUnwrap(actions.first)
      XCTAssertTrue(target.responds(to: NSSelectorFromString(action)))
      target.perform(NSSelectorFromString(action))
    }

    private func state(status: String, captureEnabled: Bool = true, busy: Bool = false,
      showLevel: Bool = true, level: DocumentLevelState = .unavailable,
      levelValue: String = "Unavailable") -> DocumentFrontCaptureState {
      .init(heading: "Document front", instruction: "Place the card inside the frame", status: status,
        captureTitle: "Take photo", cancelTitle: "Cancel", previewAccessibilityLabel: "Front camera picture",
        levelAccessibilityLabel: "Phone level", levelAccessibilityValue: levelValue,
        level: level, captureEnabled: captureEnabled, busy: busy, showLevel: showLevel)
    }

    private func style(border: UIColor = .gray) -> DocumentFrontCaptureStyle {
      .init(fonts: .init(heading: .preferredFont(forTextStyle: .title1), body: .preferredFont(forTextStyle: .body),
        status: .preferredFont(forTextStyle: .body), action: .preferredFont(forTextStyle: .headline)),
        colors: .init(background: .systemBackground, text: .label, secondaryText: .secondaryLabel,
          previewBackground: .black, previewBorder: border, levelBackground: .secondarySystemBackground,
          levelLine: .label, levelGood: .systemGreen, levelWarning: .systemOrange, levelTilted: .systemRed,
          captureBackground: .systemBlue, captureForeground: .white, cancelForeground: .systemBlue),
        layout: .init(insets: .init(top: 24, leading: 24, bottom: 24, trailing: 24),
          sectionSpacing: 20, guidanceSpacing: 12, previewAspectRatio: 340 / 234.97,
          previewCornerRadius: 20, borderWidth: 1, levelDiameter: 88, levelTravel: 32,
          levelInnerDiameter: 24, levelBubbleDiameter: 18, levelCrosshairLength: 76,
          controlHeight: 44, controlCornerRadius: 20, statusMinimumHeight: 24))
    }

    private func find(_ identifier: String, in view: UIView) -> UIView? {
      if view.accessibilityIdentifier == identifier { return view }
      for child in view.subviews {
        if let found = find(identifier, in: child) { return found }
      }
      return nil
    }
  }

  @MainActor private final class FrontPreviewProvider: DocumentCameraPreviewProviding {
    var attachments = 0
    var feedbackSubscriptions = 0
    func attachPreview(to _: AVCaptureVideoPreviewLayer) { attachments += 1 }
    func setCaptureFeedbackHandler(_ handler: @escaping @MainActor @Sendable (DocumentCaptureFeedback) -> Void) {
      feedbackSubscriptions += 1
      handler(.seeking)
    }
    func setPreviewGeometryInvalidationHandler(_: @escaping @MainActor @Sendable (UInt64) -> Void) {}
    func updatePreviewGeometry(orientation _: DocumentCameraOrientation, region _: DocumentCameraGuideRegion?,
      sourceGeneration _: UInt64) {}
    func updateCaptureOrientation(_: DocumentCameraOrientation) {}
    func updateDocumentGuideRegion(_: DocumentCameraGuideRegion?) {}
    func recordPreviewGeometry(_: DocumentCameraPreviewGeometryDiagnostic) {}
  }
#endif
