import Foundation

/// Confined to the existing session owner's serial queue. No UI or camera ownership.
final class DocumentAdaptiveCameraController {
  private typealias Focus = DocumentCaptureTuning.Focus
  private typealias Controls = DocumentCaptureTuning.Controls
  private var lastPoint: CGPoint?
  private var acknowledgedPoint: CGPoint?
  private var failureCode: String?
  private var opticalIdentity: String?
  // Provisional failure deadline only; elapsed time never establishes completion.
  private var zoomDeadline: Date?
  private var focusDeadline: Date?
  private var lastChange = Date.distantPast
  private var readiness: DocumentAdaptiveReadinessPolicy
  private let tuning: DocumentCaptureTuningOverrides
  private var focusRequestCount = 0
  private var targetRequestCount = 0
  private var lastFocusRequest = Date.distantPast
  private var controlFailures = 0
  private var lastControlAttempt = Date.distantPast
  private var focusRequestIssued = false
  private let now: () -> Date

  init(tuning: DocumentCaptureTuningOverrides = .init(), now: @escaping () -> Date) {
    self.now = now
    self.tuning = tuning
    readiness = DocumentAdaptiveReadinessPolicy(tuning: tuning)
  }

  func reset() {
    lastPoint = nil
    acknowledgedPoint = nil
    failureCode = nil
    opticalIdentity = nil
    zoomDeadline = nil
    focusDeadline = nil
    lastChange = .distantPast
    readiness.reset()
    focusRequestCount = 0
    targetRequestCount = 0
    lastFocusRequest = .distantPast
    controlFailures = 0
    lastControlAttempt = .distantPast
    focusRequestIssued = false
  }

  /// Nil means a native command succeeded; discard the pre-command observation.
  func process(
    _ observation: DocumentCaptureQualityObservation,
    device: any DocumentAdaptiveDevice,
    nativePoint: CGPoint
  ) -> DocumentCaptureQualityObservation? {
    let date = now()
    let controls = device.snapshot(at: date)
    guard acceptsNativeState(controls, at: date) else {
      readiness.reset()
      return annotated(observation, controls: controls, ready: false)
    }
    let adjusting =
      controls.adjustingFocus || controls.adjustingExposure || controls.rampingZoom
    guard DocumentFocusRecoveryPolicy.permitsControl(observedAt: observation.timestamp, now: date),
      let bounds = observation.documentBounds,
      let width = observation.metrics.guideWidth, let height = observation.metrics.guideHeight,
      let centerX = observation.metrics.guideCenterX, let centerY = observation.metrics.guideCenterY
    else {
      readiness.reset()
      return annotated(observation, controls: controls, ready: false)
    }
    let guide = CGRect(
      x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    // Nominal document dimensions and aggregate MFD do not measure subject distance.
    // Only measured framing and the current native zoom limits constrain this plan.
    let plan = DocumentAdaptiveFramingPolicy.coordinatedZoom(
      current: controls.zoomFactor, maximum: device.maximumZoom,
      minimum: device.minimumZoom, document: bounds, guide: guide, tuning: tuning)

    // Exposure adjustment is telemetry, not a prerequisite for a focus command.
    // Only wait for a focus scan that this controller has already requested.
    if !controls.rampingZoom && (!controls.adjustingFocus || !focusRequestIssued),
      observation.timestamp.timeIntervalSince(lastChange) >= Controls.minimumCommandIntervalSeconds,
      date.timeIntervalSince(lastControlAttempt) >= Controls.minimumCommandIntervalSeconds,
      controlFailures < Controls.maximumConsecutiveFailures {
      do {
        if try applyChanges(
          plan, device: device, point: nativePoint,
          observation: observation, controls: controls) {
          lastChange = date
          readiness.reset()
          return nil
        }
      } catch {
        controlFailures += 1
        if controlFailures >= Controls.maximumConsecutiveFailures {
          failureCode = "nativeCommandFailed"
        }
        readiness.reset()
        return annotated(observation, controls: controls, ready: false)
      }
    }
    // AVCaptureFocusMode.autoFocus completes by transitioning to locked (raw value 0).
    // Returning from the setter is only request issuance, not focus completion.
    let completed = focusCompleted(controls)
    let ready = readiness.observe(
      observation,
      controlsAdjusting: adjusting || plan.needsReposition || !completed
        || controlFailures > 0 || failureCode != nil, changedAt: lastChange)
    return annotated(
      observation, controls: controls, ready: ready,
      reposition: plan.needsReposition)
  }

  private func applyChanges(
    _ plan: DocumentAdaptiveFramingPolicy.ZoomPlan, device: any DocumentAdaptiveDevice,
    point: CGPoint, observation: DocumentCaptureQualityObservation,
    controls: DocumentCameraControlSnapshot
  ) throws -> Bool {
    let date = controls.sampledAt
    if abs(plan.zoom - controls.zoomFactor) > DocumentCaptureTuning.Framing.minimumZoomChange {
      lastControlAttempt = date
      try device.zoom(to: plan.zoom)
      lastPoint = nil
      targetRequestCount = 0
      focusRequestIssued = false
      acknowledgedPoint = nil
      zoomDeadline = date.addingTimeInterval(Controls.adjustmentTimeoutSeconds)
      focusDeadline = nil
      controlFailures = 0
      return true
    }
    guard !plan.needsReposition else { return false }
    let moved =
      lastPoint.map { hypot($0.x - point.x, $0.y - point.y) > Focus.targetMovementThreshold }
      ?? true
    if moved {
      targetRequestCount = 0
      focusRequestIssued = false
    }
    let needsRecovery =
      !focusCompleted(controls)
      || DocumentFocusRecoveryPolicy.needsFocus(
        previous: lastPoint, target: point, sharpness: observation.metrics.sharpness,
        sinceLastRequest: date.timeIntervalSince(lastFocusRequest), tuning: tuning)
    if targetRequestCount >= Focus.maximumAttemptsPerTarget && needsRecovery,
      date.timeIntervalSince(lastFocusRequest) >= Focus.retryIntervalSeconds {
      failureCode = "focusAttemptsExhausted"
      return false
    }
    guard targetRequestCount < Focus.maximumAttemptsPerTarget,
      moved || date.timeIntervalSince(lastFocusRequest) >= Focus.retryIntervalSeconds,
      needsRecovery
    else { return false }
    return try requestFocus(at: point, device: device, date: date)
  }

  private func requestFocus(at point: CGPoint, device: any DocumentAdaptiveDevice, date: Date)
    throws -> Bool {
    lastPoint = point
    targetRequestCount += 1
    lastFocusRequest = date
    lastControlAttempt = date
    focusRequestIssued = try device.focus(at: point)
    guard focusRequestIssued else {
      failureCode = "focusUnsupported"
      return false
    }
    focusRequestCount += 1
    focusDeadline = date.addingTimeInterval(Controls.adjustmentTimeoutSeconds)
    // Save the native accepted target, not assumed bit-identical setter input.
    let accepted = device.snapshot(at: date)
    acknowledgedPoint = nativePoint(accepted)
    if let acknowledgedPoint,
      hypot(acknowledgedPoint.x - point.x, acknowledgedPoint.y - point.y)
        <= Focus.targetMovementThreshold {
      controlFailures = 0
    } else {
      acknowledgedPoint = nil
    }
    return focusRequestIssued
  }

  private func acceptsNativeState(_ controls: DocumentCameraControlSnapshot, at date: Date) -> Bool {
    if opticalIdentity != controls.opticalIdentity {
      reset()
      opticalIdentity = controls.opticalIdentity
      lastChange = date
      return false
    }
    // A controller reset does not cancel native device work. Bound any ramp
    // observed on entry too; otherwise an inherited ramp blocks focus forever.
    if controls.rampingZoom, zoomDeadline == nil {
      zoomDeadline = date.addingTimeInterval(Controls.adjustmentTimeoutSeconds)
    }
    // A stopped ramp retires its own deadline even if continuous AF/AE is moving.
    // Those independent controls cannot make an already completed zoom time out.
    if !controls.rampingZoom { zoomDeadline = nil }
    if !focusRequestIssued || (controls.focusModeRawValue == 0 && !controls.adjustingFocus) {
      focusDeadline = nil
    }
    if let deadline = zoomDeadline, date >= deadline {
      failureCode = "nativeAdjustmentTimedOut"
    }
    if let deadline = focusDeadline, date >= deadline {
      failureCode = "nativeAdjustmentTimedOut"
    }
    return failureCode == nil
  }

  private func nativePoint(_ controls: DocumentCameraControlSnapshot) -> CGPoint? {
    guard let pointX = controls.focusPointX, let pointY = controls.focusPointY,
      pointX.isFinite, pointY.isFinite, (0...1).contains(pointX), (0...1).contains(pointY)
    else { return nil }
    return CGPoint(x: pointX, y: pointY)
  }

  private func focusCompleted(_ controls: DocumentCameraControlSnapshot) -> Bool {
    focusRequestIssued && controls.focusModeRawValue == 0
      && acknowledgedPoint != nil && nativePoint(controls) == acknowledgedPoint
  }

  private func annotated(
    _ observation: DocumentCaptureQualityObservation,
    controls: DocumentCameraControlSnapshot, ready: Bool, reposition: Bool = false
  ) -> DocumentCaptureQualityObservation {
    var control = controls
    control.settled = ready
    control.focusRequestCount = focusRequestCount
    control.adaptiveFailureReason = failureCode
    let assessment = DocumentCaptureQualityAssessment(
      ready: ready,
      blockingReasons: ready
        ? []
        : (reposition
          ? [.moveFartherAway]
          : (observation.assessment.ready
            ? [.cameraAdjusting] : observation.assessment.blockingReasons)),
      stableFrameCount: ready ? observation.assessment.stableFrameCount : 0)
    return DocumentCaptureQualityObservation(
      sequence: observation.sequence, geometryRevision: observation.geometryRevision,
      timestamp: observation.timestamp, metrics: observation.metrics, assessment: assessment,
      previewJPEGData: observation.previewJPEGData, liveContent: observation.liveContent,
      cameraControl: control, documentBounds: observation.documentBounds)
  }
}
