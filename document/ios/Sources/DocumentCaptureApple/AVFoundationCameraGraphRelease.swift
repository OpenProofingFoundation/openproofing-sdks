import AVFoundation
import Foundation

extension AVFoundationCameraSessionController {
  /// Do not report a failed startup while its graph still owns camera resources.
  func releaseFailedStartup(completion: @escaping @Sendable () -> Void) {
    dispatchPrecondition(condition: .onQueue(sessionQueue))
    state.nativeCaptureReady = false
    if state.captureSession.isRunning { state.captureSession.stopRunning() }
    state.stopWaiters.append { _ in completion() }
    releaseStoppedCaptureGraph()
  }

  /// A stopped session still owns its input graph. Detach it before another
  /// camera owner (including ARKit) changes the shared device's active format.
  func releaseStoppedCaptureGraph() {
    dispatchPrecondition(condition: .onQueue(sessionQueue))
    precondition(!state.captureSession.isRunning)
    state.graphReleasePending = true
    state.observationEpoch &+= 1
    state.deviceObservations.removeAll()
    state.temporalObservationEpoch &+= 1
    state.temporalClockObservation = nil
    for token in state.temporalNotifications { notifications.removeObserver(token) }
    state.temporalNotifications.removeAll()
    guard state.processors.isEmpty else { return }
    guard !state.graphDrainPending else { return }
    state.videoOutput.setSampleBufferDelegate(nil, queue: nil)
    state.metadataOutput.setMetadataObjectsDelegate(nil, queue: nil)
    state.pdf417Delegate = nil
    state.pdf417Candidate = nil
    if let analyzer = state.frameAnalyzer {
      state.graphDrainPending = true
      analyzer.ingressQueue.async { [self] in
        analyzer.analysisQueue.async { [self] in
          sessionQueue.async { [self] in finishCaptureGraphRelease() }
        }
      }
    } else {
      finishCaptureGraphRelease()
    }
  }

  private func finishCaptureGraphRelease() {
    dispatchPrecondition(condition: .onQueue(sessionQueue))
    if !state.zoomRetirementFailed || state.activeDevice != nil {
      do { try retireCurrentZoomRamp() } catch {
        // Detach even on failure, but do not acknowledge a clean handoff.
        state.zoomRetirementFailed = true
      }
    }
    state.isConfigured = false
    state.captureSession.beginConfiguration()
    for output in state.captureSession.outputs { state.captureSession.removeOutput(output) }
    for input in state.captureSession.inputs { state.captureSession.removeInput(input) }
    state.captureSession.commitConfiguration()
    state.frameAnalyzer?.reset()
    state.frameAnalyzer = nil
    state.activeInput = nil
    state.activeDevice = nil
    state.hardwareSelection = nil
    state.opticalSignature = ""
    state.needsOpticalReconfiguration = false
    state.nativeOperationUncertain = false
    state.manualFocusAppliedDeviceTime = nil
    state.graphDrainPending = false
    state.graphReleasePending = false
    let waiters = state.stopWaiters
    state.stopWaiters.removeAll()
    for waiter in waiters { waiter(!state.zoomRetirementFailed) }
  }
}
