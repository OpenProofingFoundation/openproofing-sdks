import DocumentSDK
import CryptoKit
import UIKit
import XCTest
@testable import KenshikiReference

@MainActor final class DocumentFlowHostLifecycleTests: XCTestCase {
    func testRetainedFrontButtonCannotConsumeBackStepButBackButtonCan() async throws {
        var cameras: [CaptureCamera] = []
        let factory = NativeDocumentFlowFactory()
        let digest: @MainActor @Sendable (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let ports = DocumentFlowPorts(makeCamera: {
            let camera = CaptureCamera(); cameras.append(camera); return camera
        }, prepare: { source in
            DocumentFlowPrepared(sourceSHA256: source.sha256, data: source.data, sha256: source.sha256,
                pixelWidth: source.pixelWidth, pixelHeight: source.pixelHeight, derivation: Data([1]))
        }, extract: { source in
            DocumentFlowReading(sourceSHA256: source.sha256, recognizedText: [], pdf417Payloads: [])
        }, portraits: { _ in [] }, sha256: digest)
        let controller = DocumentFlowController(ports: ports)
        let host = DocumentFlowHost(controller: controller, factory: factory)
        let renderer = host.makeRenderer()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = renderer
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.setForeground(true)
        controller.send(.visible)
        controller.send(.start)
        await controller.waitUntilSettled()
        let retainedFrontButton = try XCTUnwrap(factory.frontIntent)
        retainedFrontButton(.capture)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        for _ in 0..<3 {
            retainedFrontButton(.capture)
            await controller.waitUntilSettled()
        }
        XCTAssertEqual(controller.phase, .back)
        XCTAssertNil(controller.back)
        XCTAssertEqual(cameras.count, 2)
        XCTAssertEqual(cameras[0].captures, [.front])
        XCTAssertTrue(cameras[1].captures.isEmpty)
        XCTAssertEqual(cameras[0].stops, 1)
        let backButton = try XCTUnwrap(button(in: renderer.view, identifier: "document.live.capture"))
        backButton.sendActions(for: .touchUpInside)
        await controller.waitUntilSettled()
        XCTAssertEqual(cameras[0].captures, [.front])
        XCTAssertEqual(cameras[1].captures, [.back])
        XCTAssertEqual(cameras[1].stops, 1)
        XCTAssertEqual(controller.phase, .review)
    }

    private func button(in view: UIView, identifier: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        return view.subviews.lazy.compactMap { self.button(in: $0, identifier: identifier) }.first
    }

    @MainActor private final class CaptureCamera: DocumentFlowCamera {
        var captures: [DocumentSide] = []
        var stops = 0
        func start() async throws {}
        func stop() async throws { stops += 1 }
        func capture(side: DocumentSide) async throws -> DocumentFlowSource {
            captures.append(side)
            let bytes = Data(side == .front ? [1] : [2])
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return DocumentFlowSource(side: side, data: bytes, sha256: digest, pixelWidth: 100, pixelHeight: 60)
        }
    }

    func testOwnedPermissionSheetKeepsStartAndDenialPublishesFailure() async {
        let fixture = Fixture(permissionPending: true)
        fixture.start()
        await fixture.waitForNativeStart()
        fixture.host.resignActive()
        XCTAssertEqual(fixture.controller.phase, .starting)
        fixture.camera.complete(.failure(StubFailure.denied))
        await fixture.controller.waitUntilSettled()
        XCTAssertEqual(fixture.controller.phase, .failure)
        XCTAssertEqual(fixture.controller.failure, .cameraStart)
        XCTAssertEqual(fixture.camera.stops, 1)
    }

    func testTrueBackgroundDuringOwnedPermissionSheetRevokesLateGrant() async {
        let fixture = Fixture(permissionPending: true)
        fixture.start()
        await fixture.waitForNativeStart()
        fixture.host.resignActive()
        fixture.host.setForeground(false)
        XCTAssertEqual(fixture.controller.phase, .intro)
        fixture.camera.complete(.success(()))
        await fixture.controller.waitUntilSettled()
        XCTAssertEqual(fixture.controller.phase, .intro)
        XCTAssertNil(fixture.controller.front)
        XCTAssertNil(fixture.controller.back)
        XCTAssertEqual(fixture.camera.stops, 1)
        fixture.controller.send(.start)
        await fixture.controller.waitUntilSettled()
        XCTAssertEqual(fixture.camera.starts, 1)
    }

    func testUnownedInactivityStillRevokesPendingStart() async {
        let fixture = Fixture(permissionPending: false)
        fixture.start()
        await fixture.waitForNativeStart()
        fixture.host.resignActive()
        fixture.camera.complete(.success(()))
        await fixture.controller.waitUntilSettled()
        XCTAssertEqual(fixture.controller.phase, .intro)
        XCTAssertEqual(fixture.camera.stops, 1)
    }

    private enum StubFailure: Error { case denied, unused }

    @MainActor private final class Camera: DocumentFlowCamera {
        var starts = 0
        var stops = 0
        private var continuation: CheckedContinuation<Void, Error>?
        func start() async throws {
            starts += 1
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func stop() async throws { stops += 1 }
        func capture(side _: DocumentSide) async throws -> DocumentFlowSource { throw StubFailure.unused }
        func complete(_ result: Result<Void, Error>) {
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }
    }

    @MainActor private final class Fixture {
        let camera: Camera
        let controller: DocumentFlowController
        let host: DocumentFlowHost
        init(permissionPending: Bool) {
            let camera = Camera()
            self.camera = camera
            let ports = DocumentFlowPorts(makeCamera: { camera },
                prepare: { _ in throw StubFailure.unused }, extract: { _ in throw StubFailure.unused },
                portraits: { _ in throw StubFailure.unused }, sha256: { _ in "unused" })
            let controller = DocumentFlowController(ports: ports)
            self.controller = controller
            host = DocumentFlowHost(controller: controller, permissionPromptPending: { permissionPending })
        }
        func start() {
            host.setForeground(true)
            controller.send(.visible)
            controller.send(.start)
        }
        func waitForNativeStart() async {
            for _ in 0..<100 where camera.starts == 0 { await Task.yield() }
            XCTAssertEqual(camera.starts, 1)
        }
    }
}
