#if os(iOS)
  import Combine
  import Foundation
  import DocumentCaptureApple

  @MainActor
  public final class CaptureSessionTiltState: ObservableObject {
    /// Current instruction eligibility, distinct from retained measurement evidence.
    public enum Guidance: Equatable, Sendable {
      case idle, starting, finishing
      case movement(DocumentTiltPresentation, restartingBaseline: Bool)
      case retry(DocumentTiltReason?)
      case unavailable(DocumentTiltReason?)
      case readyForPhoto
    }

    public enum Outcome: Equatable, Sendable { case completed, skipped, incomplete }

    struct Attempt {
      let runID: UUID
      var restartingBaseline = false
    }
    struct Result {
      let runID: UUID?
      let outcome: Outcome
      var reason: DocumentTiltReason?
    }
    enum AfterRelease {
      case automaticCapture, manualCapture, awaitRetry, retry, unavailable
    }
    struct Release {
      let id: UUID
      let runID: UUID?
      var result: Result
      var next: AfterRelease
    }
    /// One operational owner. In particular, receiving baseline evidence does not turn preparing
    /// into measuring: only the matching successful native begin acknowledgment can do that.
    enum Lifecycle {
      case inactive(Result?)
      case waiting
      case preparing(Attempt)
      case measuring(Attempt)
      case releasing(Release)
      case retryable(Result)
      case released(Result)
      case unavailable(Result)
    }

    @Published var lifecycle: Lifecycle = .inactive(nil)
    /// Latest accepted evidence can remain available after the instruction has been withdrawn.
    @Published public internal(set) var presentation: DocumentTiltPresentation?
    var requestedForFront = false
    var budgetWatchID: UUID?
    var observationID = UUID()
    var observationTask: Task<Void, Never>?
    var startTask: Task<Void, Never>?
    var controlTask: Task<Void, Never>?

    var attempt: Attempt? {
      switch lifecycle {
      case .preparing(let attempt), .measuring(let attempt): attempt
      default: nil
      }
    }
    var result: Result? {
      switch lifecycle {
      case .inactive(let result): result
      case .releasing(let release): release.result
      case .retryable(let result), .released(let result), .unavailable(let result): result
      default: nil
      }
    }
    public var outcome: Outcome? { result?.outcome }
    public var outcomePresent: Bool { outcome != nil }
    public var active: Bool { attempt != nil }
    public var releasing: Bool {
      if case .releasing = lifecycle { return true }
      return false
    }
    public var needsRetry: Bool {
      switch lifecycle {
      case .retryable: true
      case .releasing(let release): release.next == .awaitRetry || release.next == .retry
      default: false
      }
    }
    public var skipped: Bool { outcome == .skipped }
    public var reason: DocumentTiltReason? { result?.reason }
    public var runID: UUID? { attempt?.runID }
    public var releasedForSession: Bool {
      switch lifecycle {
      case .inactive, .released: true
      default: false
      }
    }
  }

  @MainActor
  struct CaptureSessionTiltActions {
    typealias Begin = @MainActor (DocumentCamera, UUID) async throws -> DocumentTiltPresentation
    typealias End = @MainActor (DocumentCamera, UUID, DocumentTiltReason) async -> Void
    var begin: Begin
    init(configuration: DocumentTiltConfiguration) {
      begin = { camera, id in
        try await camera.beginTiltGuidance(runID: id, configuration: configuration)
      }
    }
    var end: End = { camera, id, reason in
      await camera.endTiltGuidance(runID: id, reason: reason)
    }
  }

  extension CaptureSession {
    /// Hosts observe both the session and tiltGuidance. Evidence alone never authorizes a prompt.
    public var tiltCaptureGuidance: CaptureSessionTiltState.Guidance {
      guard phase == .capturing, originalState == .idle,
        tiltGuidance.requestedForFront, profile.twoSided, !profile.backSide
      else { return .idle }
      if startup != nil { return .starting }
      guard ready else { return .idle }
      switch tiltGuidance.lifecycle {
      case .waiting, .preparing: return .starting
      case .measuring(let attempt):
        guard let value = tiltGuidance.presentation, value.runID == attempt.runID,
          !value.phase.terminal
        else { return .starting }
        return .movement(value, restartingBaseline: attempt.restartingBaseline)
      case .releasing(let release):
        return release.next == .retry ? .starting : .finishing
      case .retryable(let result): return .retry(result.reason)
      case .unavailable(let result): return .unavailable(result.reason)
      case .released(let result): return result.outcome == .completed ? .readyForPhoto : .idle
      case .inactive: return .idle
      }
    }

    var tiltDefersAutomaticCapture: Bool {
      tiltGuidance.requestedForFront && profile.twoSided && !profile.backSide
        && !tiltGuidance.releasedForSession
    }

    func resetTiltForCameraStart(recordingOnly: Bool) {
      stopTiltObservation(preserveOutcome: false)
      if !recordingOnly, tiltGuidance.requestedForFront, profile.twoSided, !profile.backSide {
        tiltGuidance.lifecycle = .waiting
      }
    }

    func startTiltIfRequested(
      camera activeCamera: DocumentCamera, generation: Int, restartingBaseline: Bool = false
    ) {
      guard tiltDefersAutomaticCapture, generation == cameraGeneration,
        case .waiting = tiltGuidance.lifecycle
      else { return }
      tiltGuidance.presentation = nil
      disarmAutomaticCapture()
      let runID = UUID()
      guard admitTiltBudget(runID: runID, generation: generation) else { return }
      tiltGuidance.lifecycle = .preparing(
        .init(runID: runID, restartingBaseline: restartingBaseline))
      observeTilt(camera: activeCamera, generation: generation)
      tiltGuidance.startTask = Task { [weak self] in
        await self?.activateTilt(camera: activeCamera, runID: runID, generation: generation)
      }
    }

    private func activateTilt(
      camera activeCamera: DocumentCamera, runID: UUID, generation: Int
    ) async {
      guard !Task.isCancelled, tiltGuidance.runID == runID, generation == cameraGeneration else {
        return
      }
      do {
        let value = try await tiltActions.begin(activeCamera, runID)
        guard !Task.isCancelled, generation == cameraGeneration,
          case .preparing(let attempt) = tiltGuidance.lifecycle, attempt.runID == runID
        else { return }
        // Accept the acknowledgment without replacing a newer stream receipt.
        receiveTilt(value, generation: generation)
        if case .preparing(let current) = tiltGuidance.lifecycle, current.runID == runID {
          tiltGuidance.lifecycle = .measuring(current)
        }
      } catch {
        guard tiltGuidance.runID == runID, generation == cameraGeneration else { return }
        failTilt(.observationUnavailable)
      }
    }

    func receiveTilt(_ value: DocumentTiltPresentation, generation: Int) {
      guard value.valid, generation == cameraGeneration else { return }
      if refineTiltFailure(value) { return }
      guard var attempt = tiltGuidance.attempt, attempt.runID == value.runID,
        phase == .capturing,
        tiltGuidance.presentation.map({ value.revision >= $0.revision }) ?? true
      else { return }
      let previous = tiltGuidance.presentation
      if value.phase != .baseline {
        attempt.restartingBaseline = false
      } else if let previous, previous.runID == value.runID,
        previous.phase != .baseline, !previous.phase.terminal
      {
        attempt.restartingBaseline = true
      }
      let preparing: Bool
      if case .preparing = tiltGuidance.lifecycle { preparing = true } else { preparing = false }
      tiltGuidance.presentation = value
      tiltGuidance.lifecycle = preparing ? .preparing(attempt) : .measuring(attempt)
      switch value.phase {
      case .readyForStill: releaseTilt(reason: .completed, captureNow: false)
      case .skipped: skipTiltGuidance()
      case .cancelled, .evidenceLimit: failTilt(value.reason ?? .cancelled)
      default: break
      }
    }

    public func skipTiltGuidance() {
      guard !presenceGatesCapture else {
        issue = .documentPresenceRequired
        return
      }
      releaseTilt(reason: .userSkipped, captureNow: false)
    }

    func releaseTilt(reason: DocumentTiltReason, captureNow: Bool) {
      let previous = tiltGuidance.result
      let result: CaptureSessionTiltState.Result
      let next: CaptureSessionTiltState.AfterRelease
      let runID = tiltGuidance.runID ?? previous?.runID
      if captureNow {
        if let previous, [.completed, .skipped].contains(previous.outcome) {
          result = previous
        } else {
          result = .init(runID: runID, outcome: .incomplete, reason: .userCaptureNow)
        }
        next = .manualCapture
      } else {
        switch reason {
        case .completed:
          result = .init(runID: runID, outcome: .completed, reason: nil)
          next = .automaticCapture
        case .userSkipped:
          result = .init(runID: runID, outcome: .skipped, reason: .userSkipped)
          next = .automaticCapture
        case .recordingBudget:
          result = .init(runID: runID, outcome: .incomplete, reason: .recordingBudget)
          next = presenceGatesCapture ? .unavailable : .automaticCapture
        default:
          result = .init(runID: runID, outcome: .incomplete, reason: reason)
          next = .awaitRetry
        }
      }
      if captureNow || [.completed, .userSkipped, .recordingBudget].contains(reason) {
        clearTiltBudgetWatch()
      }
      beginTiltRelease(result: result, reason: reason, next: next)
    }

    private func beginTiltRelease(
      result: CaptureSessionTiltState.Result, reason: DocumentTiltReason,
      next: CaptureSessionTiltState.AfterRelease
    ) {
      if case .releasing(var release) = tiltGuidance.lifecycle {
        // A queued manual shutter wins over subsequent optional guidance actions.
        guard release.next != .manualCapture else { return }
        release.result = result
        release.next = next
        tiltGuidance.lifecycle = .releasing(release)
        return
      }
      let activeCamera = camera
      let generation = cameraGeneration
      let release = CaptureSessionTiltState.Release(
        id: UUID(), runID: tiltGuidance.runID, result: result, next: next)
      tiltGuidance.lifecycle = .releasing(release)
      tiltGuidance.controlTask = Task { [weak self] in
        guard let self else { return }
        if let runID = release.runID { await self.tiltActions.end(activeCamera, runID, reason) }
        guard !Task.isCancelled, generation == self.cameraGeneration,
          case .releasing(let current) = self.tiltGuidance.lifecycle, current.id == release.id
        else { return }
        self.tiltGuidance.controlTask = nil
        self.tiltGuidance.startTask?.cancel()
        self.tiltGuidance.startTask = nil
        self.completeTiltRelease(current, camera: activeCamera, generation: generation)
      }
    }

    func stopTiltObservation(preserveOutcome: Bool = true) {
      clearTiltBudgetWatch()
      let result = preserveOutcome ? tiltGuidance.result : nil
      tiltGuidance.lifecycle = .inactive(result)
      tiltGuidance.observationID = UUID()
      tiltGuidance.observationTask?.cancel()
      tiltGuidance.startTask?.cancel()
      tiltGuidance.controlTask?.cancel()
      tiltGuidance.observationTask = nil
      tiltGuidance.startTask = nil
      tiltGuidance.controlTask = nil
      if result == nil { tiltGuidance.presentation = nil }
    }

    public func retryTiltGuidance() {
      guard !erasing, !nativeControlsBusy, phase == .capturing, ready,
        !busy, operation == nil
      else { return }
      switch tiltGuidance.lifecycle {
      case .releasing(var release) where release.next == .awaitRetry:
        release.next = .retry
        tiltGuidance.lifecycle = .releasing(release)
      case .retryable:
        tiltGuidance.lifecycle = .waiting
        startTiltIfRequested(camera: camera, generation: cameraGeneration)
      default: return
      }
      disarmAutomaticCapture()
    }

    private func failTilt(_ reason: DocumentTiltReason) {
      let result = CaptureSessionTiltState.Result(
        runID: tiltGuidance.runID, outcome: .incomplete, reason: reason)
      disarmAutomaticCapture()
      beginTiltRelease(result: result, reason: .cancelled, next: recoveryAfterTiltFailure(reason))
    }

    /// Automatic lens selection and preview rotation invalidate the old measurement, not the
    /// holder's request to scan. End that run, then reacquire from a fresh baseline using the same
    /// recording and its remaining reserve. Native source fences and evidence remain unchanged.
    private func recoveryAfterTiltFailure(_ reason: DocumentTiltReason?)
      -> CaptureSessionTiltState.AfterRelease
    {
      reason == .geometryChanged && phase == .capturing && ready && !erasing && !nativeControlsBusy
        ? .retry : .awaitRetry
    }

    private func completeTiltRelease(
      _ release: CaptureSessionTiltState.Release, camera activeCamera: DocumentCamera,
      generation: Int
    ) {
      switch release.next {
      case .retry:
        tiltGuidance.lifecycle = .waiting
        guard phase == .capturing, ready else { return }
        startTiltIfRequested(
          camera: activeCamera, generation: generation,
          restartingBaseline: release.result.reason == .geometryChanged)
      case .awaitRetry:
        tiltGuidance.lifecycle = .retryable(release.result)
        disarmAutomaticCapture()
      case .unavailable:
        tiltGuidance.lifecycle = .unavailable(release.result)
        disarmAutomaticCapture()
      case .manualCapture, .automaticCapture:
        // Presence enforcement remains independent of optional practice/observe release choices.
        guard !presenceGatesCapture || release.result.outcome == .completed else {
          tiltGuidance.lifecycle = .unavailable(release.result)
          disarmAutomaticCapture()
          return
        }
        tiltGuidance.lifecycle = .released(release.result)
        guard phase == .capturing, ready else { return }
        if release.next == .manualCapture {
          capture(observation: nil)
        } else {
          prepareAutomaticCapture()
        }
      }
    }

    private func observeTilt(camera activeCamera: DocumentCamera, generation: Int) {
      guard tiltGuidance.observationTask == nil else { return }
      let observations = activeCamera.tiltGuidanceUpdates
      let observationID = UUID()
      tiltGuidance.observationID = observationID
      // Keep one stream consumer across retries; cancelling it terminates this camera stream.
      tiltGuidance.observationTask = Task { [weak self] in
        for await value in observations {
          guard !Task.isCancelled, let self else { return }
          self.receiveTilt(value, generation: generation)
        }
        guard !Task.isCancelled, let self, generation == self.cameraGeneration,
          self.tiltGuidance.observationID == observationID
        else { return }
        self.tiltGuidance.observationTask = nil
        guard self.tiltGuidance.runID != nil else { return }
        self.failTilt(.observationSilence)
      }
    }

    /// A begin error can precede the native terminal receipt. Refine the matching failure only.
    private func refineTiltFailure(_ value: DocumentTiltPresentation) -> Bool {
      guard tiltGuidance.needsRetry, tiltGuidance.result?.runID == value.runID,
        value.phase == .cancelled || value.phase == .evidenceLimit,
        tiltGuidance.presentation.map({ value.revision > $0.revision }) ?? true
      else { return false }
      switch tiltGuidance.lifecycle {
      case .retryable(var result):
        result.reason = value.reason
        if recoveryAfterTiltFailure(value.reason) == .retry {
          beginTiltRelease(result: result, reason: .cancelled, next: .retry)
        } else {
          tiltGuidance.lifecycle = .retryable(result)
        }
      case .releasing(var release):
        release.result.reason = value.reason
        if release.next == .awaitRetry {
          release.next = recoveryAfterTiltFailure(value.reason)
        }
        tiltGuidance.lifecycle = .releasing(release)
      default: return false
      }
      tiltGuidance.presentation = value
      return true
    }
  }
#endif
