#if os(iOS)
  import Combine
  import Foundation
  @_spi(CaptureTestFixture) import CaptureEvidenceCustody
  import XCTest
  @testable import DocumentCapture
  @testable import DocumentCaptureApple

  @MainActor
  final class CaptureGeometrySubscriptionTests: XCTestCase {
    func testOldGenerationAndOldSubscriptionCannotChangeReplacement() {
      let engine = makeSession()
      let oldSubscription = engine.geometryObservationID
      engine.stopGeometryObservation()
      engine.cameraGeneration += 1
      let value = packet()
      engine.receiveGeometry(value, generation: engine.cameraGeneration - 1)
      XCTAssertNil(engine.latestGeometry)
      engine.receiveGeometry(value, generation: engine.cameraGeneration)
      engine.finishGeometryObservation(subscriptionID: oldSubscription)
      XCTAssertEqual(engine.latestGeometry, value)
      engine.finishGeometryObservation(subscriptionID: engine.geometryObservationID)
      XCTAssertNil(engine.latestGeometry)
    }

    func testCameraStreamIsCapturedBeforeDeferredTaskStarts() async throws {
      let engine = makeSession()
      let camera = DocumentCamera(now: Date.init, notifications: NotificationCenter())
      engine.observeGeometry(from: camera, generation: engine.cameraGeneration)
      let subscription = try XCTUnwrap(engine.geometryTask)
      // MainActor has not yielded: the subscription task has not entered its loop.
      // Stop replaces the camera's stream. The old, synchronously captured stream must finish.
      camera.stop()
      let finished = expectation(description: "Original camera stream finished")
      let waiter = Task {
        await subscription.value
        finished.fulfill()
      }
      await fulfillment(of: [finished], timeout: 1)
      engine.stopGeometryObservation()
      await waiter.value
      XCTAssertNil(engine.latestGeometry)
    }

    func testActualStreamFinishClearsConsumedGeometry() async throws {
      let engine = makeSession()
      let pair = AsyncStream.makeStream(
        of: DocumentLiveGeometryObservation.self,
        bufferingPolicy: .bufferingNewest(1))
      let consumed = expectation(description: "Geometry consumed from stream")
      let observation = engine.$latestGeometry.compactMap { $0 }.prefix(1)
        .sink { _ in consumed.fulfill() }
      defer {
        observation.cancel()
        engine.stopGeometryObservation()
      }
      engine.observeGeometry(pair.stream, generation: engine.cameraGeneration)
      let subscription = try XCTUnwrap(engine.geometryTask)
      let value = packet()
      pair.continuation.yield(value)
      await fulfillment(of: [consumed], timeout: 1)
      XCTAssertEqual(engine.latestGeometry, value)
      pair.continuation.finish()
      await subscription.value
      XCTAssertNil(engine.latestGeometry)
      XCTAssertNil(engine.geometryTask)
    }

    func testCanceledActualSubscriptionCannotFinishReplacement() async throws {
      let engine = makeSession()
      let old = AsyncStream.makeStream(
        of: DocumentLiveGeometryObservation.self,
        bufferingPolicy: .bufferingNewest(1))
      let replacement = AsyncStream.makeStream(
        of: DocumentLiveGeometryObservation.self,
        bufferingPolicy: .bufferingNewest(1))
      engine.observeGeometry(old.stream, generation: engine.cameraGeneration)
      let canceled = try XCTUnwrap(engine.geometryTask)
      engine.observeGeometry(replacement.stream, generation: engine.cameraGeneration)
      let current = try XCTUnwrap(engine.geometryTask)
      let consumed = expectation(description: "Replacement consumed its value")
      let observation = engine.$latestGeometry.compactMap { $0 }.prefix(1)
        .sink { _ in consumed.fulfill() }
      defer {
        observation.cancel()
        engine.stopGeometryObservation()
      }
      let value = packet()
      replacement.continuation.yield(value)
      old.continuation.finish()
      await fulfillment(of: [consumed], timeout: 1)
      await canceled.value
      XCTAssertEqual(engine.latestGeometry, value)
      XCTAssertNotNil(engine.geometryTask)
      replacement.continuation.finish()
      await current.value
      XCTAssertNil(engine.latestGeometry)
    }

    private func packet(width: Int = 1320) -> DocumentLiveGeometryObservation {
      let timestamp = DocumentCaptureClockTimestamp(
        value: 1, timescale: 30, flags: 1, epoch: 0, clock: .captureSessionSynchronizationClock)
      let geometry = DocumentTemporalGeometry(
        quadrilateral: .init(
          topLeft: .init(x: 0.1, y: 0.2), topRight: .init(x: 0.9, y: 0.2),
          bottomRight: .init(x: 0.9, y: 0.8), bottomLeft: .init(x: 0.1, y: 0.8)),
        observationTimestamp: timestamp,
        coordinateSpace: "normalized_delivered_video_buffer_top_left",
        status: "observed", confidence: 0.8, method: "VNDetectRectanglesRequest")
      return DocumentLiveGeometryObservation(
        schemaVersion: 1, observedAt: Date(timeIntervalSince1970: 123), geometry: geometry,
        pixelWidth: width, pixelHeight: 1760, analysisSequence: 1, geometryRevision: 0,
        availability: .observed, requestRevision: 1,
        tracker: .init(
          transition: .initialDetection, trackingOutcome: .notAttempted,
          precedingAnalysisTimestamp: nil, resetReasons: [.sessionStarted]))
    }
    private func makeSession() -> CaptureSession {
      let id = UUID().uuidString
      return CaptureSession(
        configuration: .init(
          notifications: NotificationCenter(),
          custody: try! .init(applicationID: "synthetic.capture-sdk.fixture",
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(id),
            keychainService: "synthetic." + id, keychainAccount: id, accessGroup: "TEST.capture-sdk.fixture"),
          signing: try! .testing(applicationID: "synthetic.capture-sdk.fixture", installationID: "synthetic-installation"),
          clock: .init(now: Date.init, uptime: { ProcessInfo.processInfo.systemUptime }),
          consent: .permitted)).withFixtureCustody()
    }
  }
#endif
