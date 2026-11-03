import UIKit
import DocumentCaptureApple
import DocumentCapturePreview
import XCTest
@testable import KenshikiReference

@MainActor final class DocumentFlowRendererTests: XCTestCase {
    func testFactorySelectsBarcodeGuideAndMountsBackPreviewThenRestoresFrontSurface() throws {
        let factory = NativeDocumentFlowFactory()
        let driver = try XCTUnwrap(factory.ports.makeCamera() as? NativeDocumentFlowCamera)
        let front = try XCTUnwrap(factory.frontSurface(busy: false))
        let frontPreview = try XCTUnwrap(factory.preview)
        let actions = UIView()
        let renderer = DocumentFlowRenderer(screen: .init(title: "Unit", heading: "Front", message: "Unit", scope: "Unit",
            preview: nil, previewLabel: "Unit", items: [], actionSurface: actions, captureSurface: front), emit: { _ in })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = renderer
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        driver.selectedCameraChanged?(.back)
        let backPreview = try XCTUnwrap(factory.preview)
        XCTAssertFalse(frontPreview === backPreview)
        XCTAssertNil(factory.frontSurface(busy: false))
        guard case .pdf417 = backPreview.guideStyle else { return XCTFail("Back requires the PDF417 guide") }
        renderer.apply(.init(title: "Unit", heading: "Back", message: "Unit", scope: "Unit",
            preview: backPreview, previewLabel: "Unit", items: [], actionSurface: actions))
        window.layoutIfNeeded()
        XCTAssertNil(front.superview)
        XCTAssertNotNil(backPreview.window)
        XCTAssertGreaterThan(backPreview.bounds.width, 0)
        XCTAssertGreaterThan(backPreview.bounds.height, 0)
        driver.selectedCameraChanged?(.front)
        let replacement = try XCTUnwrap(factory.frontSurface(busy: false))
        XCTAssertTrue(replacement.preview === factory.preview)
        guard case .document = replacement.preview.guideStyle else { return XCTFail("Front requires the document guide") }
    }

    func testSharedFrontControlsDispatchCaptureAndCancelInHostedApplication() throws {
        var intents: [DocumentFrontCaptureIntent] = []
        let camera = DocumentCamera(now: Date.init, notifications: .default)
        let surface = DocumentFrontCaptureView(preview: DocumentCameraPreviewView(previewProvider: camera),
            style: DocumentFrontCapturePresentation.style(), emit: { intents.append($0) })
        surface.apply(.init(heading: "Unit capture", instruction: "Unit positioning", status: "Unit ready",
            captureTitle: "Unit capture", cancelTitle: "Unit cancel", previewAccessibilityLabel: "Unit preview",
            levelAccessibilityLabel: "Unit level", levelAccessibilityValue: "Unit unavailable",
            level: .unavailable, captureEnabled: true, busy: false, showLevel: true))
        let screen = DocumentFlowScreen(title: "Unit", heading: "Unit", message: "Unit", scope: "Unit",
            preview: nil, previewLabel: "Unit preview", items: [], actionSurface: UIView(), captureSurface: surface)
        let renderer = DocumentFlowRenderer(screen: screen, emit: { _ in })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = renderer
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        let capture = try XCTUnwrap(button(in: surface, identifier: "document.front.capture"))
        let cancel = try XCTUnwrap(button(in: surface, identifier: "document.front.cancel"))
        XCTAssertTrue(capture.isEnabled)
        capture.sendActions(for: .touchUpInside)
        cancel.sendActions(for: .touchUpInside)
        XCTAssertEqual(intents, [.capture, .cancel])
    }

    func testFrontSurfaceRemainsMountedDuringGuidanceAndProcessingUpdates() {
        verifyStableAttachment(frontSurface: true)
    }

    func testBackPreviewRemainsMountedDuringGuidanceAndProcessingUpdates() {
        verifyStableAttachment(frontSurface: false)
    }

    private func verifyStableAttachment(frontSurface: Bool) {
        let live = AttachmentProbe(), actions = UIView()
        var screen = DocumentFlowScreen(title: "Unit", heading: "Capture", message: "Position card", scope: "Unit scope",
            preview: frontSurface ? nil : live, previewLabel: "Unit preview", items: [], actionSurface: actions,
            captureSurface: frontSurface ? live : nil)
        let renderer = DocumentFlowRenderer(screen: screen, emit: { _ in })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = renderer
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let parent = live.superview, attachments = live.attachments
        XCTAssertNotNil(live.window)
        for text in ["Camera adjusting", "Hold still", "Processing"] {
            screen = DocumentFlowScreen(title: screen.title, heading: text, message: text, scope: screen.scope,
                preview: screen.preview, previewLabel: screen.previewLabel, items: [], actionSurface: actions,
                captureSurface: screen.captureSurface)
            renderer.apply(screen)
            window.layoutIfNeeded()
            XCTAssertTrue(live.superview === parent)
            XCTAssertEqual(live.attachments, attachments)
            XCTAssertNotNil(live.window)
        }
        window.isHidden = true
        window.rootViewController = nil
    }

    private final class AttachmentProbe: UIView {
        var attachments = 0
        override func didMoveToWindow() { super.didMoveToWindow(); attachments += 1 }
    }

    private func button(in view: UIView, identifier: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        return view.subviews.lazy.compactMap { self.button(in: $0, identifier: identifier) }.first
    }
}
