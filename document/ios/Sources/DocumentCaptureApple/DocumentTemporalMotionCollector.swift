import Foundation

#if os(iOS)
  import CoreMotion
#endif

/// Only start/stop are called by the session owner; framework motion values are
/// copied on a serial operation queue before crossing the callback boundary.
final class DocumentTemporalMotionCollector {
  typealias Handler = @Sendable (DocumentTemporalMotionSample?, String?) -> Void
  #if os(iOS)
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
      let queue = OperationQueue()
      queue.name = "IdentityEvidenceSDK.TemporalMotion"
      queue.maxConcurrentOperationCount = 1
      return queue
    }()
  #endif

  func start(handler: @escaping Handler) {
    #if os(iOS)
      manager.stopDeviceMotionUpdates()
      guard manager.isDeviceMotionAvailable else {
        handler(nil, "device_motion_unavailable")
        return
      }
      guard CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryZVertical) else {
        handler(nil, "motion_reference_frame_unavailable")
        return
      }
      manager.deviceMotionUpdateInterval = 0.01
      manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { motion, error in
        if error != nil { handler(nil, "device_motion_callback_error") }
        guard let motion else { return }
        let attitude = motion.attitude.quaternion
        handler(
          DocumentTemporalMotionSample(
            bootTimeSeconds: motion.timestamp,
            attitude: DocumentTemporalQuaternion(
              x: attitude.x, y: attitude.y, z: attitude.z, w: attitude.w),
            rotationRate: DocumentTemporalVector3(
              x: motion.rotationRate.x, y: motion.rotationRate.y, z: motion.rotationRate.z),
            gravity: DocumentTemporalVector3(
              x: motion.gravity.x, y: motion.gravity.y, z: motion.gravity.z),
            userAcceleration: DocumentTemporalVector3(
              x: motion.userAcceleration.x, y: motion.userAcceleration.y,
              z: motion.userAcceleration.z),
            referenceFrame: "xArbitraryZVertical_rotation_radians_per_second_acceleration_g"), nil)
      }
    #else
      handler(nil, "device_motion_platform_unavailable")
    #endif
  }

  func stop() {
    #if os(iOS)
      manager.stopDeviceMotionUpdates()
      queue.cancelAllOperations()
    #endif
  }
}
