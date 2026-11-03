#if os(iOS)
  import Foundation
  import DocumentCaptureApple

  /// Independently checks the published observation claim, not merely its envelope hashes.
  public enum CaptureTemporalObservationContract {
    public static func verify(_ value: DocumentTemporalManifest) throws {
      guard value.issues.count <= value.configuration.maximumDiagnostics,
        value.gaps.count <= value.configuration.maximumDiagnostics - value.issues.count,
        value.gaps.allSatisfy({ $0.count >= 1 }),
        value.binding.stillHostTimeSeconds?.isFinite != false
      else { throw failure }
      try verifyOrderedObservations(value)
      if value.status == "recorded" { try verifyCoverage(value) }
    }

    private static var failure: CaptureIntegrityError { .integrityVerificationFailed }

    private static func numeric(_ time: DocumentCaptureClockTimestamp) -> Bool {
      time.timescale > 0 && time.flags & 1 != 0 && time.flags & 28 == 0
    }

    private static func seconds(_ time: DocumentCaptureClockTimestamp) -> Double {
      Double(time.value) / Double(time.timescale)
    }

    private static func verifyOrderedObservations(_ value: DocumentTemporalManifest) throws {
      var previous: DocumentTemporalFrameMetadata?
      for frame in value.frames {
        guard numeric(frame.timestamp), frame.hostTimeSeconds?.isFinite != false else {
          throw failure
        }
        if let previous {
          guard frame.timestamp.epoch == previous.timestamp.epoch,
            seconds(frame.timestamp) > seconds(previous.timestamp)
          else { throw failure }
          if let currentHost = frame.hostTimeSeconds, let previousHost = previous.hostTimeSeconds {
            guard currentHost > previousHost else { throw failure }
          }
        }
        previous = frame
      }
      var previousMotion: Double?
      for sample in value.motionSamples {
        let numbers = [
          sample.bootTimeSeconds, sample.attitude.x, sample.attitude.y, sample.attitude.z,
          sample.attitude.w, sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z,
          sample.gravity.x, sample.gravity.y, sample.gravity.z, sample.userAcceleration.x,
          sample.userAcceleration.y, sample.userAcceleration.z,
        ]
        guard numbers.allSatisfy(\.isFinite),
          previousMotion.map({ sample.bootTimeSeconds > $0 }) ?? true
        else { throw failure }
        previousMotion = sample.bootTimeSeconds
      }
    }

    private static func verifyCoverage(_ value: DocumentTemporalManifest) throws {
      guard numeric(value.binding.stillTimestamp),
        let still = value.binding.stillHostTimeSeconds, still.isFinite,
        value.frames.allSatisfy({
          $0.hostTimeSeconds != nil && $0.timestamp.epoch == value.binding.stillTimestamp.epoch
        }),
        let first = value.frames.first?.hostTimeSeconds,
        let last = value.frames.last?.hostTimeSeconds,
        let correlation = value.clockCorrelation,
        correlation.hostBeforeSeconds.isFinite, correlation.hostAfterSeconds.isFinite,
        correlation.bootTimeSeconds.isFinite,
        correlation.hostBeforeSeconds <= correlation.hostAfterSeconds,
        let firstMotion = value.motionSamples.first, let lastMotion = value.motionSamples.last
      else { throw failure }
      let lower = still - value.configuration.preCaptureDuration
      let upper = still + value.configuration.postCaptureDuration
      let error = (correlation.hostAfterSeconds - correlation.hostBeforeSeconds) / 2
      let offset = correlation.hostBeforeSeconds + error - correlation.bootTimeSeconds
      let firstMotionHost = firstMotion.bootTimeSeconds + offset + error
      let lastMotionHost = lastMotion.bootTimeSeconds + offset - error
      guard lower.isFinite, upper.isFinite, error.isFinite, offset.isFinite,
        firstMotionHost.isFinite, lastMotionHost.isFinite,
        first <= lower, last >= upper,
        firstMotionHost <= lower, lastMotionHost >= upper
      else { throw failure }
    }
  }
#endif
