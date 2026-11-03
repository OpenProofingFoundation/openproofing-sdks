#if os(iOS)
  import CoreImage
  import CryptoKit
  import UIKit

  /// Owns frame-bound admission and bounded asynchronous analysis. The camera view renders its outputs.
  @MainActor
  public final class SelfieCaptureCoordinator {
    public let admissionPolicy: SelfieAdmissionPolicy
    public let depthPolicy: SelfieDepthPolicy
    public let captureWindowPolicy: SelfieCaptureWindowPolicy?
    public var onReadiness: ((SelfieAdmissionGate.Readiness) -> Void)?
    public var onCapture: ((Data, SelfieAdmissionReceipt) -> Void)?
    public var onFailure: ((SelfieCameraFailure) -> Void)?
    // Native session binds motion at each delivery, while its frame is still recent.
    var onWindowCandidate: ((Data, SelfieAdmissionReceipt) -> Void)?
    var onWindowCompleted: (() -> Void)?
    var onWindowReset: (() -> Void)?
    private struct Window {
      let token = UUID()
      let startedAt: TimeInterval
      let anchorID: UUID
      let trigger: SelfieAdmissionReceipt.Trigger
      var lastTimestamp: TimeInterval?
      var count = 0
      var encodedBytes = 0
      var pixels = 0
    }
    private var window: Window?
    enum State: Equatable {
      case stopped
      case running(UUID)
      case rendering(UUID)
      case completed
    }
    private var state = State.stopped
    private var runningID: UUID? {
      if case .running(let id) = state { return id }
      return nil
    }
    private let analyze: @Sendable (SelfieFrameInput) async -> SelfieFrameAnalysis
    private let render: @Sendable (SelfieFrameInput) async -> CGImage?
    private let clock: @MainActor () -> TimeInterval
    private var measuredReadySince: TimeInterval?
    private var gate = SelfieAdmissionGate()
    // Admission generation changes when expression/guide/quality becomes invalid.
    // Lifecycle UUID instead identifies the session and an already-admitted render.
    private var epoch = UUID()
    private var sequence: UInt64 = 0
    private var guideRevision: UInt64 = 0
    private var guideOval = CGRect.zero
    private var guideViewport = CGSize.zero
    private var guideOrientation = UIInterfaceOrientation.unknown
    private var currentFrameTimestamp = TimeInterval.zero
    private var watchdogTask: Task<Void, Never>?
    private var lastFrameAt: TimeInterval?
    private var lastDepthAt: TimeInterval?
    private var analysisStartedAt: TimeInterval?
    private var renderStartedAt: TimeInterval?
    private let timeouts: SelfieCaptureTimeouts
    /// A timed-out noncooperative worker retains its slot until it actually returns.
    var isQuiescent: Bool { analysisTask == nil && renderTask == nil }
    private var analysisTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var pending: Candidate?
    private var measured: (Candidate, SelfieAdmissionReceipt)?

    public init(
      policy: SelfieAdmissionPolicy,
      depthPolicy: SelfieDepthPolicy = .engineeringV1,
      timeouts: SelfieCaptureTimeouts = .operationalV1,
      captureWindow: SelfieCaptureWindowPolicy? = nil,
      analyze: @escaping @Sendable (SelfieFrameInput) async -> SelfieFrameAnalysis,
      render: (@Sendable (SelfieFrameInput) async -> CGImage?)? = nil,
      clock: @escaping @MainActor () -> TimeInterval
    ) {
      admissionPolicy = policy
      self.depthPolicy = depthPolicy
      self.timeouts = timeouts
      captureWindowPolicy = captureWindow
      self.analyze = analyze
      self.render = render ?? { input in
        await Task.detached(priority: .userInitiated) {
          let raster = CIImage(cvPixelBuffer: input.buffer).oriented(input.orientation)
          return CIContext().createCGImage(raster, from: raster.extent)
        }.value
      }
      self.clock = clock
    }

    @discardableResult
    public func start(after timestamp: TimeInterval) -> Bool {
      guard state != .completed, admissionPolicy.configurationValid, depthPolicy.isValid, timeouts.isValid,
        captureWindowPolicy?.isValid ?? true else { return false }
      guard state == .stopped else { return false }
      stop()
      gate = SelfieAdmissionGate(
        policy: SelfieAdmissionPolicy(
          requiredTrackedFrames: admissionPolicy.requiredTrackedFrames,
          maximumFrameAge: admissionPolicy.maximumFrameAge,
          blinkFreshness: admissionPolicy.blinkFreshness,
          eyeClosedThreshold: admissionPolicy.eyeClosedThreshold,
          steadyHold: 0))
      gate.start(at: timestamp)
      state = .running(UUID())
      lastFrameAt = clock()
      lastDepthAt = clock()
      watchdogTask = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          guard let self else { return }
          self.checkTimeouts()
        }
      }
      return true
    }

    public func stop() {
      watchdogTask?.cancel()
      watchdogTask = nil
      lastFrameAt = nil
      lastDepthAt = nil
      if state != .completed { state = .stopped }
      invalidateCandidates()
      discardWindow()
      gate.stop()
      publish(refusal: .sessionNotRunning)
    }

    public func updateGuide(oval: CGRect, viewport: CGSize, orientation: UIInterfaceOrientation) {
      guard oval != guideOval || viewport != guideViewport || orientation != guideOrientation else {
        return
      }
      guideOval = oval
      guideViewport = viewport
      guideOrientation = orientation
      guideRevision += 1
      discardWindow()
      invalidateCandidates()
      if runningID != nil { publish(refusal: .captureQualityUnavailable) }
    }

    private func publish(refusal: SelfieAdmissionGate.Refusal) {
      publish(
        .init(
          trackingObserved: gate.trackingObserved, captureReady: false,
          blinkPhase: gate.currentBlinkPhase, refusal: refusal))
    }

    private func publish(_ readiness: SelfieAdmissionGate.Readiness) { onReadiness?(readiness) }

    private struct Candidate {
      let frame: SelfieCaptureFrame
      let gate: SelfieAdmissionGate
      let receivedAt: TimeInterval
      let epoch: UUID
      let sequence: UInt64
      let guideRevision: UInt64
      let orientation: CGImagePropertyOrientation
      let transform: CGAffineTransform
      let viewport: CGSize
      let oval: CGRect
      let anchorPoint: CGPoint
    }

    public func observe(_ frame: SelfieCaptureFrame, now: TimeInterval) {
      guard let sessionID = runningID else { return }
      if let window, frame.observation.anchorID != window.anchorID { discardWindow() }
      if finishWindowAtDeadline() { return }
      lastFrameAt = clock()
      currentFrameTimestamp = now
      if let depth = frame.input.depth,
        depth.imageTimestamp == frame.observation.timestamp,
        depthPolicy.fresh(depthTimestamp: depth.depthTimestamp, imageTimestamp: now)
      {
        lastDepthAt = clock()
      }
      if let (previous, receipt) = measured {
        let observedNow = max(now, previous.frame.observation.timestamp + clock() - previous.receivedAt)
        let imageStale = observedNow - previous.frame.observation.timestamp > admissionPolicy.maximumFrameAge
        let depthFresh = receipt.depthEvidence.map {
          depthPolicy.fresh(depthTimestamp: $0.depthTimestamp, imageTimestamp: observedNow)
        } ?? false
        if imageStale || !depthFresh {
          measured = nil
          measuredReadySince = nil
          publish(refusal: imageStale ? .frameStale : .depthStale)
        }
      }
      guard runningID == sessionID else { return }
      let readiness = gate.observe(frame.observation, now: now)
      var snapshot = gate
      let expression = snapshot.admit(
        frameTimestamp: frame.observation.timestamp, now: now, trigger: .manual)
      guard case .admit = expression else {
        invalidateCandidates()
        publish(readiness)
        return
      }
      // Colour-only callbacks still update expression/continuity, but never replace the
      // newest depth-bearing candidate. Its image and gate snapshot remain paired with it.
      guard let depth = frame.input.depth else {
        if measured == nil { publish(refusal: .depthUnavailable) }
        return
      }
      guard depth.imageTimestamp == frame.observation.timestamp,
        depthPolicy.fresh(depthTimestamp: depth.depthTimestamp, imageTimestamp: now)
      else {
        rejectMeasurement(.depthStale)
        return
      }
      if measured == nil { publish(refusal: .captureQualityUnavailable) }
      guard runningID == sessionID else { return }
      let candidate = Candidate(
        frame: frame, gate: snapshot,
        receivedAt: clock(), epoch: epoch, sequence: sequence,
        guideRevision: guideRevision, orientation: frame.input.orientation,
        transform: frame.displayTransform, viewport: guideViewport, oval: guideOval,
        anchorPoint: frame.anchorPoint)
      sequence += 1
      pending = candidate
      analyzePending()
    }

    private func invalidateCandidates() {
      epoch = UUID()
      pending = nil
      measured = nil
      measuredReadySince = nil
    }

    private func analyzePending() {
      guard runningID != nil, analysisTask == nil, let candidate = pending else {
        return
      }
      pending = nil
      let input = candidate.frame.input
      let analyze = self.analyze
      analysisStartedAt = clock()
      analysisTask = Task { [weak self] in
        let result = await analyze(input)
        guard let self else { return }
        self.analysisTask = nil
        self.analysisStartedAt = nil
        self.complete(candidate, result: result)
        self.analyzePending()
      }
    }

    private func rejectMeasurement(_ reason: SelfieAdmissionGate.Refusal) {
      invalidateCandidates()
      publish(refusal: reason)
    }

    private func complete(_ candidate: Candidate, result: SelfieFrameAnalysis) {
      guard let sessionID = runningID, candidate.epoch == epoch,
        candidate.guideRevision == guideRevision
      else { return }
      if let failure = result.failure {
        fail(failure)
        return
      }
      let now = max(
        candidate.frame.observation.timestamp + clock() - candidate.receivedAt,
        currentFrameTimestamp)
      var snapshot = candidate.gate
      guard
        case .admit(var receipt) = snapshot.admit(
          frameTimestamp: candidate.frame.observation.timestamp, now: now, trigger: .manual)
      else {
        measured = nil
        measuredReadySince = nil
        publish(refusal: .frameStale)
        return
      }
      guard result.faceCount == 1, let box = result.faceBox, let quality = result.quality,
        quality.isFinite, (0...1).contains(quality)
      else {
        rejectMeasurement(
          result.faceCount > 1 ? .multipleFacesObserved : .captureQualityUnavailable)
        return
      }
      guard var depth = result.depthEvidence, let source = candidate.frame.input.depth,
        depth.measurement.policy == depthPolicy,
        depth.imageTimestamp == candidate.frame.observation.timestamp,
        depth.depthTimestamp == source.depthTimestamp,
        depth.orientation == candidate.orientation.rawValue
      else {
        rejectMeasurement(.depthUnavailable)
        return
      }
      guard depthPolicy.fresh(depthTimestamp: depth.depthTimestamp, imageTimestamp: now) else {
        rejectMeasurement(.depthStale)
        return
      }
      depth.ageAtAdmission = now - depth.imageTimestamp + depth.imageTimestamp - depth.depthTimestamp
      switch depth.assessment {
      case .flat: rejectMeasurement(.depthFlat); return
      case .insufficientData: rejectMeasurement(.depthInsufficient); return
      case .live: break
      }
      let inside = SelfieGuideGeometry.contains(
        face: box, orientation: candidate.orientation.rawValue,
        displayTransform: candidate.transform, viewport: candidate.viewport, oval: candidate.oval)
      guard !admissionPolicy.requiresGuideContainment || inside else {
        rejectMeasurement(.outsideGuide)
        return
      }
      guard admissionPolicy.minimumCaptureQuality.map({ quality >= $0 }) ?? true else {
        rejectMeasurement(.captureQualityBelowMinimum)
        return
      }
      snapshot.measure(quality: quality, insideGuide: inside)
      guard
        case .admit(let measuredReceipt) = snapshot.admit(
          frameTimestamp: candidate.frame.observation.timestamp, now: now, trigger: .manual)
      else { return }
      receipt = measuredReceipt
      receipt.effectivePolicy = admissionPolicy
      receipt.captureQualityEnforced = admissionPolicy.minimumCaptureQuality != nil
      receipt.guideContainmentEnforced = admissionPolicy.requiresGuideContainment
      receipt.frameEvidence = SelfieFrameEvidence(
        sessionID: sessionID, sequence: candidate.sequence,
        guideRevision: candidate.guideRevision,
        pixelWidth: CVPixelBufferGetWidth(candidate.frame.input.buffer),
        pixelHeight: CVPixelBufferGetHeight(candidate.frame.input.buffer),
        orientation: candidate.orientation.rawValue, qualityRevision: result.revision,
        analysisDuration: result.elapsed,
        frameAgeAtAdmission: now - candidate.frame.observation.timestamp)
      receipt.depthEvidence = depth
      guard
        SelfieGuideGeometry.matchesAnchor(
          face: box, orientation: candidate.orientation.rawValue,
          displayTransform: candidate.transform, viewport: candidate.viewport,
          anchor: candidate.anchorPoint)
      else {
        rejectMeasurement(.noFaceObserved)
        return
      }
      if let previous = measured?.0,
        candidate.frame.observation.timestamp - previous.frame.observation.timestamp
          > admissionPolicy.maximumFrameAge
      {
        measuredReadySince = nil
      }
      if measuredReadySince == nil { measuredReadySince = candidate.frame.observation.timestamp }
      receipt.steadyHoldDuration =
        candidate.frame.observation.timestamp
        - (measuredReadySince ?? candidate.frame.observation.timestamp)
      measured = (candidate, receipt)
      guard renderTask == nil else {
        publish(refusal: .captureInProgress)
        return
      }
      publish(
        SelfieAdmissionGate.Readiness(
          trackingObserved: true, captureReady: true,
          blinkPhase: .reopened, refusal: nil))
      if let window {
        receipt.trigger = window.trigger
        capture(candidate: candidate, receipt: receipt)
      } else if receipt.steadyHoldDuration >= admissionPolicy.steadyHold {
        receipt.trigger = .automatic
        capture(candidate: candidate, receipt: receipt)
      }
    }

    public func shutterTapped() {
      guard let (candidate, receipt) = measured else { return }
      capture(candidate: candidate, receipt: receipt)
    }

    private func capture(candidate: Candidate, receipt: SelfieAdmissionReceipt) {
      guard renderTask == nil, let sessionID = runningID, candidate.epoch == epoch,
        candidate.guideRevision == guideRevision
      else { return }
      var snapshot = candidate.gate
      var receipt = receipt
      let now = max(
        candidate.frame.observation.timestamp + clock() - candidate.receivedAt,
        currentFrameTimestamp)
      guard
        case .admit = snapshot.admit(
          frameTimestamp: candidate.frame.observation.timestamp, now: now, trigger: receipt.trigger),
        receipt.admissionValid
      else {
        measured = nil
        measuredReadySince = nil
        publish(refusal: .frameStale)
        return
      }
      receipt.blinkAge = now - receipt.blinkCompletedAt
      let frameAge = now - receipt.frameTimestamp
      receipt.frameEvidence?.frameAgeAtAdmission = frameAge
      if var depth = receipt.depthEvidence {
        depth.ageAtAdmission = frameAge + receipt.frameTimestamp - depth.depthTimestamp
        receipt.depthEvidence = depth
      }
      guard receipt.depthEvidence?.assessment == .live else {
        rejectMeasurement(.depthStale)
        return
      }
      guard receipt.admissionValid else {
        rejectMeasurement(.frameStale)
        return
      }
      if let policy = captureWindowPolicy {
        if finishWindowAtDeadline() { return }
        if window == nil {
          window = Window(startedAt: clock(), anchorID: receipt.anchorID, trigger: receipt.trigger)
        }
        if let last = window?.lastTimestamp,
          receipt.frameTimestamp - last < policy.minimumInterval { return }
        let pixels = CVPixelBufferGetWidth(candidate.frame.input.buffer) * CVPixelBufferGetHeight(candidate.frame.input.buffer)
        guard let current = window, pixels <= SelfieCaptureWindowPolicy.resourceBounds.pixels - current.pixels else {
          fail(.init(reason: .captureWindowResourceLimit))
          return
        }
        window?.lastTimestamp = receipt.frameTimestamp
      } else {
        state = .rendering(sessionID)
      }
      let windowToken = window?.token
      pending = nil
      measured = nil
      publish(refusal: .captureInProgress)
      guard captureWindowPolicy == nil ? state == .rendering(sessionID)
        : (runningID == sessionID && window?.token == windowToken) else { return }
      let input = candidate.frame.input
      let render = self.render
      renderStartedAt = clock()
      renderTask = Task { [weak self] in
        let image = await render(input)
        guard let self else { return }
        self.renderTask = nil
        self.renderStartedAt = nil
        if let windowToken {
          guard self.runningID == sessionID, self.window?.token == windowToken else { return }
          if self.finishWindowAtDeadline() { return }
        } else {
          guard self.state == .rendering(sessionID) else { return }
        }
        guard let image else {
          self.fail(.init(reason: .renderingFailed))
          return
        }
        if windowToken != nil {
          let swapsDimensions = candidate.orientation == .left || candidate.orientation == .right
          let width = CVPixelBufferGetWidth(input.buffer)
          let height = CVPixelBufferGetHeight(input.buffer)
          guard image.width == (swapsDimensions ? height : width),
            image.height == (swapsDimensions ? width : height) else {
            self.fail(.init(reason: .renderingFailed))
            return
          }
        }
        guard let bytes = UIImage(cgImage: image).pngData() else {
          self.fail(.init(reason: .renderingFailed))
          return
        }
        receipt.depthEvidence?.imageSHA256 = SHA256.hash(data: bytes)
          .map { String(format: "%02x", $0) }.joined()
        if let windowToken {
          self.retainWindowCandidate(bytes, receipt: receipt, token: windowToken)
          return
        }
        self.watchdogTask?.cancel()
        self.watchdogTask = nil
        self.state = .completed
        self.gate.stop()
        self.invalidateCandidates()
        self.onCapture?(bytes, receipt)
      }
    }
    private func discardWindow() {
      window = nil
      onWindowReset?()
    }

    private func retainWindowCandidate(_ bytes: Data, receipt: SelfieAdmissionReceipt, token: UUID) {
      guard var current = window, current.token == token, let policy = captureWindowPolicy else { return }
      guard bytes.count <= SelfieCaptureWindowPolicy.resourceBounds.encodedBytes - current.encodedBytes else {
        fail(.init(reason: .captureWindowResourceLimit))
        return
      }
      current.count += 1
      current.encodedBytes += bytes.count
      current.pixels += (receipt.frameEvidence?.pixelWidth ?? 0) * (receipt.frameEvidence?.pixelHeight ?? 0)
      window = current
      onWindowCandidate?(bytes, receipt)
      // Public observers can synchronously withdraw consent or stop/restart the camera.
      guard window?.token == token, runningID != nil else { return }
      if current.count >= policy.maximumCandidates { finishWindow() }
    }

    @discardableResult
    private func finishWindowAtDeadline() -> Bool {
      guard let window, let policy = captureWindowPolicy,
        clock() - window.startedAt >= policy.duration else { return false }
      if window.count == 0 { fail(.init(reason: .captureWindowEmpty)) }
      else { finishWindow() }
      return true
    }

    private func finishWindow() {
      guard runningID != nil, window != nil else { return }
      watchdogTask?.cancel()
      watchdogTask = nil
      state = .completed
      gate.stop()
      invalidateCandidates()
      // Retained receipts describe admission time; do not revalidate old frame freshness here.
      window = nil
      onWindowCompleted?()
    }

    /// Called by the monotonic watchdog; internal for deterministic deadline tests.
    func checkTimeouts() {
      if finishWindowAtDeadline() { return }
      switch state {
      case .running:
        if let started = renderStartedAt, clock() - started >= timeouts.rendering {
          fail(.init(reason: .renderingTimedOut))
        } else if let started = analysisStartedAt, clock() - started >= timeouts.analysis {
          fail(.init(reason: .analysisTimedOut))
        } else if let started = lastFrameAt, clock() - started >= timeouts.frameDelivery {
          fail(.init(reason: .noFrames))
        } else if let started = lastDepthAt, clock() - started >= timeouts.frameDelivery {
          fail(.init(reason: .depthUnavailable))
        }
      case .rendering:
        if let started = renderStartedAt, clock() - started >= timeouts.rendering {
          fail(.init(reason: .renderingTimedOut))
        }
      case .stopped, .completed: break
      }
    }

    private func fail(_ failure: SelfieCameraFailure) {
      guard state != .stopped, state != .completed else { return }
      stop()
      onFailure?(failure)
    }
  }
#endif
