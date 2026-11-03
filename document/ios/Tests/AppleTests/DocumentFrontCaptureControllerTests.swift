import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

@MainActor
struct DocumentFrontCaptureControllerTests {
  @Test(.timeLimit(.minutes(1))) func actualQualityStreamCanRetireAndRestartItsHandler() async {
    let pair = AsyncStream<DocumentCaptureQualityObservation>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let delivery = DocumentFrontQualityDelivery(stream: pair.stream)
    let first = FrontQualityDeliveryProbe(), second = FrontQualityDeliveryProbe()
    delivery.observe { first.receive($0) }
    let initial = observation(1, at: 100.1)
    pair.continuation.yield(initial)
    #expect(await first.next() == initial)
    delivery.endObservation()
    delivery.observe { second.receive($0) }
    let restarted = observation(2, at: 100.2)
    pair.continuation.yield(restarted)
    #expect(await second.next() == restarted)
    #expect(first.received == [initial])
    #expect(second.received == [restarted])
    delivery.endObservation()
    pair.continuation.finish()
  }

  @Test(.timeLimit(.minutes(1))) func actualQualityStreamConsumerDoesNotRetainItsDeliveryOwner() async {
    let pair = AsyncStream<DocumentCaptureQualityObservation>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let termination = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    pair.continuation.onTermination = { reason in
      if case .cancelled = reason { termination.continuation.yield(true) }
      else { termination.continuation.yield(false) }
      termination.continuation.finish()
    }
    var delivery: DocumentFrontQualityDelivery? = DocumentFrontQualityDelivery(stream: pair.stream)
    let probe = FrontQualityDeliveryProbe()
    probe.deliveryOwner = delivery
    delivery?.observe { probe.receive($0) }
    let value = observation(1, at: 100.1)
    pair.continuation.yield(value)
    #expect(await probe.next() == value)
    delivery = nil
    var completion = termination.stream.makeAsyncIterator()
    #expect(await completion.next() == true)
    #expect(probe.deliveryOwner == nil)
    if case .terminated = pair.continuation.yield(value) {} else {
      Issue.record("Releasing the delivery must cancel its actual waiting stream iterator")
    }
  }

  @Test func manualAvailabilityUsesFreshGuideSnapshotWithoutQualityReadiness() async throws {
    let fixture = FrontCaptureFixture()
    try await fixture.controller.start()
    #expect(!fixture.controller.manualCaptureAvailable)
    fixture.clock.set(100.2)
    fixture.driver.handlers[0](observation(1, at: 100.1, ready: false, guideAvailable: false))
    #expect(!fixture.controller.manualCaptureAvailable)
    fixture.driver.handlers[0](observation(2, at: 100.2, ready: false))
    #expect(fixture.controller.manualCaptureAvailable)
    fixture.clock.set(102)
    #expect(!fixture.controller.manualCaptureAvailable)
    try await fixture.controller.stop()
    #expect(!fixture.controller.manualCaptureAvailable)
  }

  @Test func freshSettledFrontObservationsTriggerOnceWithoutContentSignal() async throws {
    let fixture = FrontCaptureFixture()
    var triggers: [DocumentCaptureObservationIdentity] = []
    fixture.controller.onAutomaticCapture = { triggers.append($0) }
    try await fixture.controller.start()
    fixture.clock.set(100.3)
    fixture.driver.handlers[0](observation(1, at: 99.9))
    fixture.driver.handlers[0](observation(2, at: 100.4))
    #expect(fixture.controller.latestQuality == nil)
    fixture.driver.handlers[0](observation(3, at: 100.1, settled: false))
    fixture.driver.handlers[0](observation(4, at: 100.2))
    let trigger = observation(5, at: 100.3)
    fixture.driver.handlers[0](trigger)
    fixture.driver.handlers[0](observation(6, at: 100.3))
    #expect(triggers == [DocumentCaptureObservationIdentity(observation: trigger)])
    #expect(!fixture.controller.automaticCaptureAvailable)
    #expect(fixture.driver.requests.isEmpty)
    try await fixture.controller.stop()
  }

  @Test func automaticRequestPreservesExactIdentityAndLeavesCameraForHost() async throws {
    let fixture = FrontCaptureFixture()
    try await fixture.controller.start()
    let identity = DocumentCaptureObservationIdentity(observation: observation(9, at: 100.1))
    let photo = try await fixture.controller.capture(observationIdentity: identity)
    #expect(fixture.driver.requests.count == 1)
    #expect(fixture.driver.requests[0].side == .front)
    #expect(fixture.driver.requests[0].qualityGate == .qualityDrivenAutoCapture)
    #expect(fixture.driver.requests[0].requiredObservationIdentity == identity)
    #expect(photo.data == Data([1]))
    #expect(fixture.controller.running)
    #expect(!fixture.controller.capturing)
    #expect(fixture.driver.stops == 0)
    #expect(fixture.driver.observationEnds == 1)
    #expect(fixture.motion.stops == 1)
    await expectError(.cameraNotReady) { _ = try await fixture.controller.capture() }
    try await fixture.controller.stop()
  }

  @Test func manualAndAutomaticRequestsCannotRaceIntoTwoCaptures() async throws {
    let fixture = FrontCaptureFixture()
    fixture.driver.holdCapture = true
    try await fixture.controller.start()
    let first = Task { try await fixture.controller.capture() }
    await fixture.driver.waitForCapture()
    let identity = DocumentCaptureObservationIdentity(observation: observation(2, at: 100.2))
    await expectError(.cameraNotReady) {
      _ = try await fixture.controller.capture(observationIdentity: identity)
    }
    #expect(fixture.driver.requests.count == 1)
    #expect(fixture.driver.requests[0].qualityGate == .operatorInitiatedAdvisory)
    #expect(fixture.driver.requests[0].requiredObservationIdentity == nil)
    fixture.driver.finishCapture()
    _ = try await first.value
    try await fixture.controller.stop()
  }

  @Test func restartRejectsRetiredQualityCallbacksAndRearmsFreshGeneration() async throws {
    let fixture = FrontCaptureFixture()
    var triggers: [DocumentCaptureObservationIdentity] = []
    fixture.controller.onAutomaticCapture = { triggers.append($0) }
    try await fixture.controller.start()
    let retired = fixture.driver.handlers[0]
    try await fixture.controller.stop()
    fixture.clock.set(100.3)
    try await fixture.controller.start()
    fixture.clock.set(100.6)
    retired(observation(1, at: 100.4))
    retired(observation(2, at: 100.5))
    #expect(fixture.controller.latestQuality == nil)
    #expect(triggers.isEmpty)
    fixture.driver.handlers[1](observation(3, at: 100.4))
    fixture.driver.handlers[1](observation(4, at: 100.5))
    #expect(triggers.count == 1)
    #expect(fixture.driver.starts == 2)
    try await fixture.controller.stop()
  }

  @Test func adaptiveFailureDisablesAutomaticCaptureWithoutRetryLoop() async throws {
    let fixture = FrontCaptureFixture()
    var triggers = 0
    fixture.controller.onAutomaticCapture = { _ in triggers += 1 }
    try await fixture.controller.start()
    fixture.clock.set(100.3)
    fixture.driver.handlers[0](observation(1, at: 100.1, failure: "focus_failed"))
    fixture.driver.handlers[0](observation(2, at: 100.2))
    fixture.driver.handlers[0](observation(3, at: 100.3))
    #expect(!fixture.controller.automaticCaptureAvailable)
    #expect(triggers == 0)
    #expect(fixture.driver.requests.isEmpty)
    try await fixture.controller.stop()
  }

  @Test func stopFencesAnInFlightCaptureCompletionAndClearsMotion() async throws {
    let fixture = FrontCaptureFixture()
    fixture.driver.holdCapture = true
    try await fixture.controller.start()
    let pending = Task { try await fixture.controller.capture() }
    await fixture.driver.waitForCapture()
    try await fixture.controller.stop()
    fixture.driver.finishCapture()
    do {
      _ = try await pending.value
      Issue.record("Retired capture must not return a current result")
    } catch is CancellationError {
      #expect(!fixture.controller.running)
      #expect(!fixture.controller.capturing)
      #expect(fixture.controller.latestMotion == nil)
      #expect(fixture.controller.latestQuality == nil)
    }
  }

  @Test func stopDuringStartupCannotPublishAReplacementRunningState() async throws {
    let fixture = FrontCaptureFixture()
    fixture.driver.holdStart = true
    let pending = Task { try await fixture.controller.start() }
    await fixture.driver.waitForStart()
    try await fixture.controller.stop()
    fixture.driver.finishStart()
    do {
      try await pending.value
      Issue.record("Retired startup must not publish running state")
    } catch is CancellationError {
      #expect(!fixture.controller.running)
      #expect(!fixture.controller.automaticCaptureAvailable)
      #expect(fixture.driver.handlers.isEmpty)
    }
  }

  @Test func failedRetirementPreventsRestartUntilExplicitStopSucceeds() async throws {
    let fixture = FrontCaptureFixture()
    try await fixture.controller.start()
    fixture.driver.stopFails = true
    await expectError(.cameraNotReady) { try await fixture.controller.stop() }
    await expectError(.cameraNotReady) { try await fixture.controller.start() }
    #expect(fixture.driver.starts == 1)
    #expect(!fixture.controller.running)
    fixture.driver.stopFails = false
    try await fixture.controller.stop()
    try await fixture.controller.start()
    #expect(fixture.driver.starts == 2)
    try await fixture.controller.stop()
  }

  @Test func rawMotionCallbacksAreRetainedBeforeTheLevelMainActorTurn() async throws {
    let fixture = FrontCaptureFixture()
    try await fixture.controller.start()
    let sample = DocumentTemporalMotionSample(bootTimeSeconds: ProcessInfo.processInfo.systemUptime,
      attitude: .init(x: 0, y: 0, z: 0, w: 1), rotationRate: .init(x: 0.1, y: 0.2, z: 0.3),
      gravity: .init(x: 0, y: 0, z: -1), userAcceleration: .init(x: 0, y: 0, z: 0),
      referenceFrame: "xArbitraryZVertical_rotation_radians_per_second_acceleration_g")
    fixture.motion.handlers[0](sample, nil)
    #expect(fixture.controller.latestMotion == nil)
    let photo = try await fixture.controller.capture()
    let evidence = try #require(photo.motionEvidence)
    #expect(evidence.samples == [sample])
    #expect(evidence.binding.sessionID == fixture.controller.camera.sessionID.rawValue.uuidString)
    #expect(evidence.binding.attemptID == fixture.driver.requests[0].attemptID.uuidString)
    #expect(evidence.binding.stillSHA256 == photo.fidelity.sha256)
    #expect(evidence.binding.stillTimestamp == photo.captureTimestamp)
    #expect(evidence.binding.stillHostTimeSeconds == nil)
    #expect(photo.temporalEvidence == nil)
    try evidence.requireValid()
    await Task.yield()
    #expect(fixture.controller.latestMotion == nil)
    try await fixture.controller.stop()
  }

  @Test func failedCaptureRestartsTheSameMotionCollectorAndRetainsFreshUnavailability() async throws {
    let fixture = FrontCaptureFixture()
    fixture.motion.unavailable = true
    try await fixture.controller.start()
    fixture.driver.captureFails = true
    await expectError(.cameraNotReady) { _ = try await fixture.controller.capture() }
    #expect(fixture.motion.starts == 2)
    #expect(fixture.motion.stops == 1)
    #expect(fixture.driver.starts == 1)
    fixture.driver.captureFails = false
    let photo = try await fixture.controller.capture()
    let evidence = try #require(photo.motionEvidence)
    #expect(evidence.samples.isEmpty)
    #expect(evidence.issues.map(\.code) == [.deviceMotionUnavailable])
    #expect(evidence.status == .unavailable)
    #expect(evidence.binding.attemptID == fixture.driver.requests.last?.attemptID.uuidString)
    #expect(fixture.motion.starts == 2)
    #expect(fixture.driver.requests.count == 2)
    #expect(fixture.driver.requests[0].attemptID != fixture.driver.requests[1].attemptID)
    try evidence.requireValid()
    try await fixture.controller.stop()
  }

  private func observation(_ sequence: UInt64, at timestamp: Double,
                           settled: Bool = true, failure: String? = nil, ready: Bool = true,
                           guideAvailable: Bool = true)
    -> DocumentCaptureQualityObservation {
    DocumentCaptureQualityObservation(sequence: sequence, geometryRevision: 1,
      timestamp: Date(timeIntervalSince1970: timestamp),
      metrics: .init(documentFillRatio: 0.8, documentGuideFillRatio: 0.8,
        documentInsideGuide: true, guideCenterX: 0.5, guideCenterY: 0.5,
        guideWidth: guideAvailable ? 0.8 : nil, guideHeight: guideAvailable ? 0.5 : nil,
        documentAspectRatio: 1.586,
        sharpness: 1, motion: 0, clippedHighlightRatio: 0, meanLuminance: 0.5,
        documentCenterX: 0.5, documentCenterY: 0.5),
      assessment: .init(ready: ready, blockingReasons: ready ? [] : [.holdSteady], stableFrameCount: 3),
      liveContent: .empty,
      cameraControl: .init(adaptiveFailureReason: failure,
        sampledAt: Date(timeIntervalSince1970: timestamp), zoomFactor: 1,
        adjustingFocus: false, adjustingExposure: false, rampingZoom: false, settled: settled))
  }
}

@MainActor
private final class FrontQualityDeliveryProbe {
  weak var deliveryOwner: DocumentFrontQualityDelivery?
  private var pending: CheckedContinuation<DocumentCaptureQualityObservation, Never>?
  private var queued: [DocumentCaptureQualityObservation] = []
  private(set) var received: [DocumentCaptureQualityObservation] = []

  func receive(_ value: DocumentCaptureQualityObservation) {
    received.append(value)
    if let pending {
      self.pending = nil
      pending.resume(returning: value)
    } else { queued.append(value) }
  }

  func next() async -> DocumentCaptureQualityObservation {
    if !queued.isEmpty { return queued.removeFirst() }
    return await withCheckedContinuation { pending = $0 }
  }
}

private final class FrontCaptureClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 100)
  func now() -> Date { lock.withLock { value } }
  func set(_ time: Double) { lock.withLock { value = Date(timeIntervalSince1970: time) } }
}

@MainActor
private final class FrontCaptureMotionProbe: DocumentLevelMotionCollecting {
  var handlers: [@Sendable (DocumentTemporalMotionSample?, String?) -> Void] = []
  var starts = 0
  var unavailable = false
  var stops = 0
  func startLevelMotion(
    handler _: @escaping @MainActor @Sendable (DocumentTemporalMotionSample?) -> Void
  ) {}
  func startRecordingMotion(handler: @escaping @Sendable (DocumentTemporalMotionSample?, String?) -> Void) {
    starts += 1
    handlers.append(handler)
    if unavailable { handler(nil, "device_motion_unavailable") }
  }
  func stopLevelMotion() { stops += 1 }
}

@MainActor
private final class FrontCaptureDriverProbe {
  var sessionID = CaptureSessionID()
  var starts = 0
  var stops = 0
  var observationEnds = 0
  var holdStart = false
  var stopFails = false
  var holdCapture = false
  var captureFails = false
  var requests: [DocumentCaptureRequest] = []
  var handlers: [@MainActor (DocumentCaptureQualityObservation) -> Void] = []
  private var waitingForCapture: CheckedContinuation<Void, Never>?
  private var pendingCapture: CheckedContinuation<Void, Never>?
  private var waitingForStart: CheckedContinuation<Void, Never>?
  private var pendingStart: CheckedContinuation<Void, Never>?

  var operations: DocumentFrontCaptureOperations {
    .init(start: {
      self.starts += 1
      self.waitingForStart?.resume()
      self.waitingForStart = nil
      if self.holdStart { await withCheckedContinuation { self.pendingStart = $0 } }
    }, stop: {
      self.stops += 1
      if self.stopFails { throw PhotoCaptureError.cameraNotReady }
    }, capture: { request in
      self.requests.append(request)
      self.waitingForCapture?.resume()
      self.waitingForCapture = nil
      if self.holdCapture { await withCheckedContinuation { self.pendingCapture = $0 } }
      if self.captureFails { throw PhotoCaptureError.cameraNotReady }
      return self.photo(request: request)
    }, observe: { self.handlers.append($0) }, endObservation: { self.observationEnds += 1 })
  }

  func waitForCapture() async {
    if !requests.isEmpty { return }
    await withCheckedContinuation { waitingForCapture = $0 }
  }

  func finishCapture() { pendingCapture?.resume(); pendingCapture = nil }

  func waitForStart() async {
    if starts > 0 { return }
    await withCheckedContinuation { waitingForStart = $0 }
  }

  func finishStart() { pendingStart?.resume(); pendingStart = nil }

  private func photo(request: DocumentCaptureRequest) -> CapturedDocumentPhoto {
    let nativeRequest = CameraPhotoCaptureRequest(sessionID: sessionID, side: request.side,
      qualityGate: request.qualityGate, requiredObservationIdentity: request.requiredObservationIdentity,
      attemptID: request.attemptID, userRequestedAt: Date(timeIntervalSince1970: 100))
    let admission = DocumentCaptureAdmissionSnapshot(request: nativeRequest,
      admittedAt: Date(timeIntervalSince1970: 100), photoSettingsUniqueID: 1, observation: nil)
    return CapturedDocumentPhoto(sessionID: sessionID, side: .front,
      requestedAt: Date(timeIntervalSince1970: 100),
      captureTimestamp: .init(value: 1, timescale: 1, flags: 1, epoch: 0,
        clock: .captureSessionSynchronizationClock),
      processedAt: Date(timeIntervalSince1970: 100), data: Data([1]),
      fidelity: .init(pixelWidth: 32, pixelHeight: 16, fileByteCount: 1,
        uniformTypeIdentifier: "public.heic", orientation: 1, cameraModel: nil,
        lensModel: nil, exposureTimeSeconds: nil, fNumber: nil, isoSpeed: nil,
        sha256: String(repeating: "a", count: 64), optical: nil), admission: admission)
  }
}

@MainActor
private final class FrontCaptureFixture {
  let clock = FrontCaptureClock()
  let driver = FrontCaptureDriverProbe()
  let motion = FrontCaptureMotionProbe()
  let controller: DocumentFrontCaptureController

  init() {
    let clock = clock
    let camera = makeCamera(permissionState: .authorized, controller: StubCameraSessionController())
    driver.sessionID = camera.sessionID
    controller = DocumentFrontCaptureController(
      camera: camera,
      now: { clock.now() }, operations: driver.operations,
      motion: DocumentLevelMotionSource(collector: motion, onSample: { _ in }))
  }
}
