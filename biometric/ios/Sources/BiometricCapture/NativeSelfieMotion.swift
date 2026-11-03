#if os(iOS)
import Foundation
import KenshikiMotion

/// Camera-lifetime adapter around the shared Pulse ceremony witness.
@MainActor
final class NativeSelfieMotion {
  private let witness = PulseCeremonyMotionWitness(ceremony: .faceMatch)
  private let permission = PulseMotionPermission()
  private(set) var status: PulseMotionPermission.Status = .notRequested
  func start() {
    permission.request { [weak self] status in
      guard let self else { return }
      self.status = status
      if status == .authorized { self.witness.start() }
    }
  }
  func stop() { permission.cancel(); _ = witness.stop() }

  func evidence(imageSHA256: String, frameTimestamp: Double) -> SelfieMotionEvidence? {
    let now = ProcessInfo.processInfo.systemUptime
    guard now >= frameTimestamp, now - frameTimestamp <= 1,
      let captured = witness.snapshot(endingAtUptime: frameTimestamp) else { return nil }
    return SelfieMotionEvidence(imageSHA256: imageSHA256, frameTimestampSeconds: frameTimestamp,
      windowStartTimestampSeconds: captured.startUptime, windowEndTimestampSeconds: captured.endUptime,
      requestedSampleRateHz: captured.window.requestedSampleRateHz, clockDomain: "core_motion_boot_seconds",
      alignment: "host_uptime_checked", summary: PulseCeremonyMotionSummarizer.summarize(captured.window))
  }
}
#endif
