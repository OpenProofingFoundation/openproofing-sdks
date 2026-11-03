#if os(iOS)
  import XCTest
  @_spi(Preview) @testable import PassportMRZCapture

  @MainActor
  final class NativeMRZSessionTests: XCTestCase {
    func testReadinessRequiresCurrentGuideAndResetsAfterLayoutAndStop() async throws {
      var publish: (@MainActor @Sendable (MRZOCRFrame) -> Void)?
      var revision: UUID?
      let session = NativeMRZSession(effects: .init(
        previewSession: nil, authorize: { true }, start: { frame, _ in publish = frame },
        stop: {}, updateGuideRegion: { _, value in revision = value }))
      var ready: [String] = []
      session.onReady = { ready.append($0.documentNumber) }
      let lines = [["P<UTOSPECIMEN<<SYNTHETIC<<<<<<<<<<<<<<<<<<<<"],
                   ["X1234567<7UTO8506151F3201015<<<<<<<<<<<<<<08"]]
      func send(_ time: Double, _ token: UUID?) {
        publish?(.init(candidates: lines, timestamp: time, policy: .engineeringV1,
          rowBounds: [CGRect(x: 0.2, y: 0.55, width: 0.6, height: 0.1),
                      CGRect(x: 0.2, y: 0.35, width: 0.6, height: 0.1)],
          guideRevision: token))
      }
      try await session.start(consent: .permitted)
      for time in [1.0, 1.25, 1.5] { send(time, nil) }
      XCTAssertTrue(ready.isEmpty)
      session.updateGuideRegion(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
      let old = revision
      send(2, old)
      send(2.25, old)
      session.updateGuideRegion(CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
      send(2.5, old)
      XCTAssertTrue(ready.isEmpty)
      for time in [3.0, 3.25, 3.5] { send(time, revision) }
      XCTAssertEqual(ready, ["X1234567"])
      await session.stop()
      send(4, revision)
      try await session.start(consent: .permitted)
      send(5, revision)
      XCTAssertEqual(ready.count, 1)
      send(5.25, revision)
      send(5.5, revision)
      XCTAssertEqual(ready.count, 2)
      await session.stop()
    }

    func testRotationDropsCompletionsFromPreviousPreviewOrientation() async throws {
      var publish: (@MainActor @Sendable (MRZOCRFrame) -> Void)?
      var orientations: [MRZCaptureOrientation] = []
      let session = NativeMRZSession(
        effects: .init(
          previewSession: nil, authorize: { true }, start: { frame, _ in publish = frame },
          stop: {},
          updateOrientation: { orientations.append($0) }))
      var received: [MRZOCRFrame] = []
      session.onFrame = { received.append($0) }
      try await session.start(consent: .permitted)
      session.updateOrientation(.landscapeLeft)
      publish?(
        .init(
          candidates: [["stale"]], timestamp: 1, policy: .engineeringV1,
          orientation: .portrait))
      publish?(
        .init(
          candidates: [["current"]], timestamp: 2, policy: .engineeringV1,
          orientation: .landscapeLeft))
      XCTAssertEqual(orientations, [.landscapeLeft])
      XCTAssertEqual(received.map(\.candidates), [[["current"]]])
      await session.stop()
    }

    func testRestartWaitsForStopToDrain() async throws {
      var resume: CheckedContinuation<Void, Never>?
      let entered = expectation(description: "stop")
      var suspend = true
      let session = NativeMRZSession(
        effects: .init(
          previewSession: nil, authorize: { true },
          start: { _, _ in },
          stop: {
            if suspend {
              await withCheckedContinuation {
                resume = $0
                entered.fulfill()
              }
            }
          }))
      try await session.start(consent: .permitted)
      let stopping = Task { await session.stop() }
      await fulfillment(of: [entered], timeout: 2)
      do {
        try await session.start(consent: .permitted)
        XCTFail("Restart overlapped camera teardown")
      } catch MRZCameraFailure.busy {}
      suspend = false
      resume?.resume()
      await stopping.value
      try await session.start(consent: .permitted)
      XCTAssertEqual(session.state, .running)
      await session.stop()
    }

    func testStopDuringPermissionNeverStartsCamera() async throws {
      var resume: CheckedContinuation<Bool, Never>?
      let entered = expectation(description: "permission")
      let session = NativeMRZSession(
        effects: .init(
          previewSession: nil,
          authorize: {
            await withCheckedContinuation {
              resume = $0
              entered.fulfill()
            }
          }, start: { _, _ in XCTFail("Late permission reopened camera") }, stop: {}))
      let task = Task { try await session.start(consent: .permitted) }
      await fulfillment(of: [entered], timeout: 2)
      await session.stop()
      resume?.resume(returning: true)
      do {
        try await task.value
        XCTFail("Stopped permission published")
      } catch MRZCameraFailure.cancelled {}
      XCTAssertEqual(session.state, .stopped)
    }

    func testConsentAndOSPermissionAreSeparateGates() async throws {
      var authorizations = 0
      let session = NativeMRZSession(
        effects: .init(
          previewSession: nil,
          authorize: {
            authorizations += 1
            return false
          }, start: { _, _ in XCTFail("Denied acquisition started") }, stop: {}))
      do {
        try await session.start(consent: .withheld)
        XCTFail("Consent bypassed")
      } catch MRZCameraFailure.consentRequired {}
      XCTAssertEqual(authorizations, 0)
      do {
        try await session.start(consent: .permitted)
        XCTFail("Permission bypassed")
      } catch MRZCameraFailure.cameraPermissionDenied {}
      XCTAssertEqual(authorizations, 1)
    }

    func testLateFrameCannotCrossStopOrReplacementGeneration() async throws {
      var publishers: [@MainActor @Sendable (MRZOCRFrame) -> Void] = []
      let session = NativeMRZSession(
        effects: .init(
          previewSession: nil, authorize: { true },
          start: { frame, _ in publishers.append(frame) }, stop: {}))
      var received: [MRZOCRFrame] = []
      session.onFrame = { received.append($0) }
      try await session.start(consent: .permitted)
      let frame = MRZOCRFrame(
        candidates: [["row", "alternative"]], timestamp: 1, policy: .engineeringV1)
      publishers[0](frame)
      await session.stop()
      publishers[0](frame)
      try await session.start(consent: .permitted)
      publishers[0](frame)
      publishers[1](frame)
      XCTAssertEqual(received.count, 2)
      XCTAssertEqual(received.first?.candidates, [["row", "alternative"]])
      await session.stop()
    }
  }
#endif
