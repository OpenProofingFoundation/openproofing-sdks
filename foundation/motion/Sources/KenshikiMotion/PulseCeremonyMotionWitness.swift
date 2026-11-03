import Foundation

#if os(iOS) && canImport(CoreMotion)
    import CoreMotion
#endif

/// Records device motion for the span of ONE holder ceremony and hands back the raw window.
///
/// Owns its own `CMMotionManager`, like `DefaultDevicePhysicsCollector` does: the app's ambient
/// sensor monitor streams at 12 Hz on the main queue for the live cockpit, which is the wrong
/// rate and the wrong thread for a hand-tremor trace, and reaching it from here would cross the
/// live-read boundary. Sampling runs on a private queue; `stop()` is the only hand-off.
///
/// The window never leaves memory here. Summarize it, fingerprint it, let the window go. The
/// fingerprint detects drift but does not make the discarded raw samples independently auditable.
public final class PulseCeremonyMotionWitness: @unchecked Sendable {
    public static let defaultSampleRateHz: Double = 50

    public let ceremony: PulseCeremonyKind
    public let sampleRateHz: Double

    private let lock = NSLock()
    private var trace = PulseCeremonyMotionTrace()
    public static let maximumSamples = 300
    public static let maximumWindowSeconds = 5.0

    #if os(iOS) && canImport(CoreMotion)
        private let manager = CMMotionManager()
        private let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "pulse.ceremony-motion-witness"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()
    #endif

    public init(ceremony: PulseCeremonyKind, sampleRateHz: Double = PulseCeremonyMotionWitness.defaultSampleRateHz) {
        self.ceremony = ceremony
        self.sampleRateHz = sampleRateHz
    }

    /// True when this device can produce a window at all. A simulator or a phone without an IMU
    /// yields `false`; the caller records "no witness" rather than an empty one.
    public var isAvailable: Bool {
        #if os(iOS) && canImport(CoreMotion)
            return manager.isDeviceMotionAvailable
        #else
            return false
        #endif
    }

    /// Begin sampling. Idempotent: a second call while running is ignored.
    public func start(at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let attempt = trace.start(ceremony: ceremony, date: date,
            uptime: ProcessInfo.processInfo.systemUptime, sampleRate: sampleRateHz) else { return }
        #if os(iOS) && canImport(CoreMotion)
            guard manager.isDeviceMotionAvailable else { return }
            manager.deviceMotionUpdateInterval = 1 / sampleRateHz
            let frames = CMMotionManager.availableAttitudeReferenceFrames()
            let hasMagneticReference = frames.contains(.xMagneticNorthZVertical)
            let frame: CMAttitudeReferenceFrame =
                hasMagneticReference ? .xMagneticNorthZVertical : .xArbitraryZVertical
            manager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
                guard let self, let motion else { return }
                self.append(motion, attempt: attempt, hasMagneticReference: hasMagneticReference)
            }
        #endif
    }

    /// End sampling and return the window, or nil if `start` was never called or no sample
    /// arrived (a mounted phone still produces samples; nil means the sensor said nothing).
    public func stop(at date: Date = Date()) -> PulseCeremonyMotionWindow? {
        lock.lock()
        #if os(iOS) && canImport(CoreMotion)
            manager.stopDeviceMotionUpdates()
        #endif
        defer { lock.unlock() }
        return trace.stop()
    }

    /// Snapshot just the samples at or before an admitted camera frame. This does not stop sampling.
    /// The caller still owns stopping and erasing the witness when its capture retires.
    public func snapshot(endingAtUptime frameTimestamp: Double) -> PulseCeremonyMotionCapture? {
        lock.lock()
        defer { lock.unlock() }
        return trace.snapshot(endingAtUptime: frameTimestamp)
    }

    #if os(iOS) && canImport(CoreMotion)
        private func append(_ motion: CMDeviceMotion, attempt: UUID, hasMagneticReference: Bool) {
            // Uncalibrated is the common indoor state and is recorded as a fact beside the value,
            // never as a reason to drop the value.
            let field = motion.magneticField
            let magnitude = Self.magneticFieldMagnitude(
                SIMD3(field.field.x, field.field.y, field.field.z),
                hasMagneticReference: hasMagneticReference)
            let calibrated = field.accuracy != .uncalibrated
            lock.lock()
            defer { lock.unlock() }
            trace.append(timestamp: motion.timestamp,
                acceleration: SIMD3(motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z),
                rotation: SIMD3(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z),
                gravity: SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z),
                magnetic: magnitude, calibrated: calibrated, generation: attempt)
        }
    #endif

    /// CoreMotion reports a zero-filled magnetic field when the selected attitude frame has no
    /// magnetic reference. Zero is a real numeric claim, so represent that platform absence as nil.
    static func magneticFieldMagnitude(
        _ field: SIMD3<Double>,
        hasMagneticReference: Bool
    ) -> Double? {
        guard hasMagneticReference else { return nil }
        let magnitude = (field.x * field.x + field.y * field.y + field.z * field.z).squareRoot()
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        return magnitude
    }
}

/// Explicit monotonic clock binding alongside the source-compatible Pulse window.
public struct PulseCeremonyMotionCapture: Sendable {
    public let window: PulseCeremonyMotionWindow
    public let startUptime: Double
    public let endUptime: Double
}
