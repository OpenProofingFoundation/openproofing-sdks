import CryptoKit
import Foundation

/// Which holder ceremony a motion window was recorded around. The witness is scoped to one
/// ceremony at a time; the kind travels with the window so a reader never has to infer it
/// from timing.
public enum PulseCeremonyKind: String, Codable, Sendable {
    case passportChipRead = "passport_chip_read"
    case passportPageScan = "passport_page_scan"
    case faceMatch = "face_match"
}

/// One device-motion sample, gravity already removed by CoreMotion. Axes are the device frame.
/// Raw, full precision — the Data doctrine: atoms first, bands beside them, never instead.
public struct PulseCeremonyMotionSample: Equatable, Sendable {
    /// Seconds since the window started.
    public let offsetSeconds: Double
    /// User acceleration in g.
    public let userAcceleration: SIMD3<Double>
    /// Rotation rate in rad/s.
    public let rotationRate: SIMD3<Double>
    /// Gravity unit vector in the device frame.
    public let gravity: SIMD3<Double>
    /// Calibrated magnetic field magnitude in µT, nil when CoreMotion offered none.
    public let magneticFieldMicrotesla: Double?

    public init(
        offsetSeconds: Double,
        userAcceleration: SIMD3<Double>,
        rotationRate: SIMD3<Double>,
        gravity: SIMD3<Double>,
        magneticFieldMicrotesla: Double?
    ) {
        self.offsetSeconds = offsetSeconds
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
        self.gravity = gravity
        self.magneticFieldMicrotesla = magneticFieldMicrotesla
    }
}

/// The raw trace the witness collected for one ceremony. Lives in memory for the ceremony only;
/// what persists is `PulseCeremonyMotionSummary`, which carries this window's exact fingerprint.
/// The fingerprint detects accidental drift while the window is in hand; it is not a substitute
/// for the discarded samples and cannot independently prove or reconstruct them later.
public struct PulseCeremonyMotionWindow: Equatable, Sendable {
    public let ceremony: PulseCeremonyKind
    public let startedAt: Date
    public let endedAt: Date
    public let requestedSampleRateHz: Double
    public let samples: [PulseCeremonyMotionSample]
    /// Whether CoreMotion reported the magnetometer as calibrated for the majority of samples.
    /// Indoors this is commonly false; it is recorded, never used as a reason to drop the row.
    public let magnetometerCalibrated: Bool

    public init(
        ceremony: PulseCeremonyKind,
        startedAt: Date,
        endedAt: Date,
        requestedSampleRateHz: Double,
        samples: [PulseCeremonyMotionSample],
        magnetometerCalibrated: Bool
    ) {
        self.ceremony = ceremony
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.requestedSampleRateHz = requestedSampleRateHz
        self.samples = samples
        self.magnetometerCalibrated = magnetometerCalibrated
    }

    public var durationSeconds: Double { endedAt.timeIntervalSince(startedAt) }
}

/// The scalars that describe how the phone moved while the holder performed a ceremony.
///
/// Eight derived features, all cheap, none individually decisive. Phase 1 records them; nothing scores
/// them. The summary is deliberately a data record (no behaviour) so it stays under the type
/// gate and so a test can construct one by hand.
///
/// - `accelerationRMSg`, `rotationRMSRadPerSecond`: total motion energy. A mounted phone reads
///   near zero on both.
/// - `tremorBandRatio`: share of user-acceleration energy in the 8–12 Hz band (physiological hand
///   tremor) over all energy above 1 Hz. Computed by Goertzel at 1 Hz bins — no FFT dependency.
/// - `gravityDominance`: |largest gravity component| / |gravity|; `gravityDominantAxis` names it.
///   A phone held flat over a passport is z-dominant.
/// - `gravityDriftRadians`: angle between the first and last gravity vectors — humans drift.
/// - `approachRMSg`: energy in the first half second (the lift / orient gesture).
/// - `settleRatio`: RMS of the final 200 ms over the whole window (< 1 means the hand steadied).
/// - `magneticDeltaMicrotesla`: max − min field magnitude over the window.
public struct PulseCeremonyMotionSummary: Equatable, Codable, Sendable {
    public static let tremorBandHz: ClosedRange<Double> = 8...12
    public static let approachSeconds: Double = 0.5
    public static let settleSeconds: Double = 0.2

    public let ceremony: PulseCeremonyKind
    public let sampleCount: Int
    public let durationSeconds: Double
    public let accelerationRMSg: Double?
    public let rotationRMSRadPerSecond: Double?
    public let tremorBandRatio: Double?
    public let gravityDominantAxis: String?
    public let gravityDominance: Double?
    public let gravityDriftRadians: Double?
    public let approachRMSg: Double?
    public let settleRatio: Double?
    public let magneticDeltaMicrotesla: Double?
    public let magnetometerCalibrated: Bool
    public let rawWindowSHA256: String

    public init(
        ceremony: PulseCeremonyKind,
        sampleCount: Int,
        durationSeconds: Double,
        accelerationRMSg: Double?,
        rotationRMSRadPerSecond: Double?,
        tremorBandRatio: Double?,
        gravityDominantAxis: String?,
        gravityDominance: Double?,
        gravityDriftRadians: Double?,
        approachRMSg: Double?,
        settleRatio: Double?,
        magneticDeltaMicrotesla: Double?,
        magnetometerCalibrated: Bool,
        rawWindowSHA256: String
    ) {
        self.ceremony = ceremony
        self.sampleCount = sampleCount
        self.durationSeconds = durationSeconds
        self.accelerationRMSg = accelerationRMSg
        self.rotationRMSRadPerSecond = rotationRMSRadPerSecond
        self.tremorBandRatio = tremorBandRatio
        self.gravityDominantAxis = gravityDominantAxis
        self.gravityDominance = gravityDominance
        self.gravityDriftRadians = gravityDriftRadians
        self.approachRMSg = approachRMSg
        self.settleRatio = settleRatio
        self.magneticDeltaMicrotesla = magneticDeltaMicrotesla
        self.magnetometerCalibrated = magnetometerCalibrated
        self.rawWindowSHA256 = rawWindowSHA256
    }
}

/// Window → summary. Pure: no clock, no sensors, no I/O. The only place the eight features are
/// defined, so a test that pins one pins the product's definition of it.
public enum PulseCeremonyMotionSummarizer {
    public static func summarize(_ window: PulseCeremonyMotionWindow) -> PulseCeremonyMotionSummary {
        let samples = window.samples
        let duration = window.durationSeconds
        let accelMagnitudes = samples.map { magnitude($0.userAcceleration) }
        let rotationMagnitudes = samples.map { magnitude($0.rotationRate) }

        let gravityFirst = samples.first?.gravity
        let gravityLast = samples.last?.gravity
        let meanGravity =
            samples.isEmpty
            ? nil
            : samples.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.gravity } / Double(samples.count)
        let dominance = meanGravity.flatMap(dominantAxis)

        let approachEnd = PulseCeremonyMotionSummary.approachSeconds
        let settleStart = duration - PulseCeremonyMotionSummary.settleSeconds
        let approach = zip(samples, accelMagnitudes)
            .filter { $0.0.offsetSeconds < approachEnd }.map(\.1)
        let settle = zip(samples, accelMagnitudes)
            .filter { $0.0.offsetSeconds >= settleStart }.map(\.1)
        let overallRMS = rms(accelMagnitudes)
        let settleRMS = rms(settle)

        let fields = samples.compactMap(\.magneticFieldMicrotesla)
        let magneticDelta: Double?
        if let top = fields.max(), let bottom = fields.min() { magneticDelta = top - bottom } else { magneticDelta = nil }

        return PulseCeremonyMotionSummary(
            ceremony: window.ceremony,
            sampleCount: samples.count,
            durationSeconds: duration,
            accelerationRMSg: overallRMS,
            rotationRMSRadPerSecond: rms(rotationMagnitudes),
            tremorBandRatio: tremorBandRatio(
                axes: [
                    samples.map(\.userAcceleration.x),
                    samples.map(\.userAcceleration.y),
                    samples.map(\.userAcceleration.z),
                ],
                sampleRateHz: effectiveSampleRate(window)),
            gravityDominantAxis: dominance?.axis,
            gravityDominance: dominance?.share,
            gravityDriftRadians: both(gravityFirst, gravityLast).map(angle),
            approachRMSg: rms(approach),
            settleRatio: both(settleRMS, overallRMS).flatMap { $1 > 0 ? $0 / $1 : nil },
            magneticDeltaMicrotesla: magneticDelta,
            magnetometerCalibrated: window.magnetometerCalibrated,
            rawWindowSHA256: hash(window)
        )
    }

    /// Deterministic digest of every window field using big-endian IEEE-754 bit patterns. No
    /// rounding or text formatting may make distinct raw values share a serialization.
    public static func hash(_ window: PulseCeremonyMotionWindow) -> String {
        var bytes = Data()
        func appendUInt64(_ value: UInt64) {
            var bigEndian = value.bigEndian
            Swift.withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
        }
        func appendDouble(_ value: Double) { appendUInt64(value.bitPattern) }
        func appendString(_ value: String) {
            let encoded = Data(value.utf8)
            appendUInt64(UInt64(encoded.count))
            bytes.append(encoded)
        }

        appendString(window.ceremony.rawValue)
        appendDouble(window.startedAt.timeIntervalSinceReferenceDate)
        appendDouble(window.endedAt.timeIntervalSinceReferenceDate)
        appendDouble(window.requestedSampleRateHz)
        appendUInt64(UInt64(window.samples.count))
        appendUInt64(window.magnetometerCalibrated ? 1 : 0)
        for sample in window.samples {
            appendDouble(sample.offsetSeconds)
            for value in [
                sample.userAcceleration.x, sample.userAcceleration.y, sample.userAcceleration.z,
                sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z,
                sample.gravity.x, sample.gravity.y, sample.gravity.z,
            ] {
                appendDouble(value)
            }
            if let magneticField = sample.magneticFieldMicrotesla {
                appendUInt64(1)
                appendDouble(magneticField)
            } else {
                appendUInt64(0)
            }
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Features

    static func effectiveSampleRate(_ window: PulseCeremonyMotionWindow) -> Double {
        guard window.samples.count > 1,
            let first = window.samples.first?.offsetSeconds,
            let last = window.samples.last?.offsetSeconds,
            last > first
        else { return window.requestedSampleRateHz }
        return Double(window.samples.count - 1) / (last - first)
    }

    /// Energy at 8–12 Hz over energy at ≥ 1 Hz, by Goertzel at integer-Hz bins, summed over
    /// the three axes. PER AXIS, never on the magnitude: |sin| is a rectified wave whose spectrum
    /// sits at twice the tremor frequency, so a magnitude analysis reports a 10 Hz hand as 20 Hz
    /// and the band reads empty (the first test run of this file caught exactly that).
    /// Needs at least one second of samples so the 1 Hz bin is resolvable; below that nil, not 0.
    static func tremorBandRatio(axes: [[Double]], sampleRateHz: Double) -> Double? {
        guard let count = axes.first?.count, sampleRateHz > 0,
            count >= Int(sampleRateHz.rounded(.down)), count >= 2
        else { return nil }
        let nyquist = sampleRateHz / 2
        var total = 0.0
        var band = 0.0
        for signal in axes {
            let mean = signal.reduce(0, +) / Double(count)
            let centered = signal.map { $0 - mean }
            var bin = 1.0
            while bin < nyquist {
                let power = goertzelPower(centered, frequencyHz: bin, sampleRateHz: sampleRateHz)
                total += power
                if PulseCeremonyMotionSummary.tremorBandHz.contains(bin) { band += power }
                bin += 1
            }
        }
        guard total > 0 else { return nil }
        return band / total
    }

    static func goertzelPower(_ signal: [Double], frequencyHz: Double, sampleRateHz: Double) -> Double {
        let omega = 2 * Double.pi * frequencyHz / sampleRateHz
        let coefficient = 2 * cos(omega)
        var previous = 0.0
        var beforePrevious = 0.0
        for value in signal {
            let current = value + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        return previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
    }

    static func rms(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }

    static func magnitude(_ vector: SIMD3<Double>) -> Double {
        (vector.x * vector.x + vector.y * vector.y + vector.z * vector.z).squareRoot()
    }

    static func dominantAxis(_ gravity: SIMD3<Double>) -> (axis: String, share: Double)? {
        let total = magnitude(gravity)
        guard total > 0 else { return nil }
        let components = [("x", abs(gravity.x)), ("y", abs(gravity.y)), ("z", abs(gravity.z))]
        guard let top = components.max(by: { $0.1 < $1.1 }) else { return nil }
        return (top.0, top.1 / total)
    }

    static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let denominator = magnitude(a) * magnitude(b)
        guard denominator > 0 else { return 0 }
        let cosine = (a.x * b.x + a.y * b.y + a.z * b.z) / denominator
        return acos(min(1, max(-1, cosine)))
    }

    private static func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}
