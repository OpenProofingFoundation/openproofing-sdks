#if os(iOS)
  import ImageIO
  import UIKit
  import XCTest
  @_spi(Preview) @testable import PassportMRZCapture
  @testable import PassportMRZPreview

  @MainActor
  final class NativeMRZPreviewTests: XCTestCase {
    func testGuideLeavesMRZBandClearAndDimsSurroundingPreviewAfterResize() throws {
      let session = NativeMRZSession(
        effects: .init(
          previewSession: nil, authorize: { true }, start: { _, _ in }, stop: {}))
      let preview = NativeMRZPreviewView(captureSession: session)
      for size in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393)] {
        preview.frame = CGRect(origin: .zero, size: size)
        preview.layoutIfNeeded()
        XCTAssertEqual(preview.guideFrame.width, size.width - 48)
        XCTAssertEqual(preview.guideFrame.height, 110)
        XCTAssertEqual(preview.guideFrame.midY, size.height / 2)
        let veil = try XCTUnwrap(preview.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let path = try XCTUnwrap(veil.path)
        XCTAssertEqual(veil.fillRule, .evenOdd)
        XCTAssertTrue(path.contains(CGPoint(x: 1, y: 1), using: .evenOdd))
        XCTAssertFalse(
          path.contains(CGPoint(x: size.width / 2, y: size.height / 2), using: .evenOdd))
        XCTAssertEqual(try XCTUnwrap(veil.fillColor).alpha, 0.65, accuracy: 0.001)
      }
    }

    func testRemovingPreviewImmediatelyWithdrawsGuideAndResetsReadiness() async throws {
      var publish: (@MainActor @Sendable (MRZOCRFrame) -> Void)?
      var revision: UUID?
      var activeGuide: CGRect?
      let session = NativeMRZSession(effects: .init(
        previewSession: nil, authorize: { true }, start: { frame, _ in publish = frame }, stop: {},
        updateGuideRegion: { region, token in activeGuide = region; revision = token }))
      var accepted = 0
      session.onReady = { _ in accepted += 1 }
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
      let host = UIViewController()
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer { window.isHidden = true }
      let preview = NativeMRZPreviewView(captureSession: session)
      preview.frame = host.view.bounds
      host.view.addSubview(preview)
      preview.layoutIfNeeded()
      XCTAssertNotNil(preview.window)
      try await session.start(consent: .permitted)
      preview.layoutIfNeeded()
      session.updateOrientation(.landscapeRight)
      let guide = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
      session.updateGuideRegion(guide)
      let lines = [["P<UTOSPECIMEN<<SYNTHETIC<<<<<<<<<<<<<<<<<<<<"],
                   ["X1234567<7UTO8506151F3201015<<<<<<<<<<<<<<08"]]
      func send(_ timestamp: Double, token: UUID?) {
        publish?(.init(candidates: lines, timestamp: timestamp, policy: .engineeringV1,
          orientation: .landscapeRight,
          rowBounds: [CGRect(x: 0.15, y: 0.6, width: 0.7, height: 0.08),
                      CGRect(x: 0.15, y: 0.45, width: 0.7, height: 0.08)], guideRevision: token))
      }
      let retired = revision
      send(1, token: retired)
      send(1.25, token: retired)
      XCTAssertEqual(accepted, 0)
      preview.removeFromSuperview()
      // No layoutIfNeeded call: removal itself must withdraw the geometry.
      XCTAssertNil(preview.window)
      XCTAssertNil(activeGuide)
      XCTAssertNotEqual(revision, retired)
      send(1.5, token: retired)
      for time in [2.0, 2.25, 2.5] { send(time, token: revision) }
      XCTAssertEqual(accepted, 0)
      host.view.addSubview(preview)
      session.updateGuideRegion(guide)
      send(3, token: revision)
      send(3.25, token: revision)
      XCTAssertEqual(accepted, 0)
      send(3.5, token: revision)
      XCTAssertEqual(accepted, 1)
      await session.stop()
    }

    func testEverySupportedInterfaceOrientationAgreesBetweenPreviewAndOCR() {
      let cases: [(UIInterfaceOrientation, Double, CGImagePropertyOrientation)] = [
        (.portrait, 90, .right), (.portraitUpsideDown, 270, .left),
        (.landscapeLeft, 180, .down), (.landscapeRight, 0, .up),
      ]
      for (interface, degrees, image) in cases {
        let orientation = NativeMRZPreviewView.captureOrientation(interface)
        XCTAssertEqual(orientation?.videoRotationDegrees, degrees)
        XCTAssertEqual(orientation?.imageOrientation, image)
      }
      XCTAssertNil(NativeMRZPreviewView.captureOrientation(.unknown))
    }
  }
#endif
