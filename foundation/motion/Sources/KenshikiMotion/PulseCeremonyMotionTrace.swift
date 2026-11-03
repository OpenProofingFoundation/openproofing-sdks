import Foundation

/// The witness's bounded state machine, isolated from the platform callback queue.
/// The owner holds its lock while entering any of these operations.
struct PulseCeremonyMotionTrace {
    private struct Entry {
        let sample: PulseCeremonyMotionSample
        let calibrated: Bool
    }
    private struct Session {
        let generation: UUID
        let ceremony: PulseCeremonyKind
        let startedAt: Date
        let uptime: Double
        let rate: Double
        var entries: [Entry] = []
    }
    private var session: Session?

    mutating func start(ceremony: PulseCeremonyKind, date: Date, uptime: Double, sampleRate: Double) -> UUID? {
        guard session == nil, uptime.isFinite, uptime >= 0,
              date.timeIntervalSince1970.isFinite, sampleRate.isFinite,
              sampleRate > 0, sampleRate <= 1000 else { return nil }
        let generation = UUID()
        session = Session(generation: generation, ceremony: ceremony, startedAt: date, uptime: uptime, rate: sampleRate)
        return generation
    }

    mutating func append(timestamp: Double, acceleration: SIMD3<Double>, rotation: SIMD3<Double>,
                         gravity: SIMD3<Double>, magnetic: Double?, calibrated: Bool, generation: UUID) {
        guard var active = session, active.generation == generation else { return }
        let offset = timestamp - active.uptime
        let values = [timestamp, offset, acceleration.x, acceleration.y, acceleration.z,
                      rotation.x, rotation.y, rotation.z, gravity.x, gravity.y, gravity.z]
        guard values.allSatisfy(\.isFinite), offset >= 0,
              magnetic.map({ $0.isFinite && $0 >= 0 }) ?? true,
              active.entries.last.map({ offset > $0.sample.offsetSeconds }) ?? true else { return }
        let sample = PulseCeremonyMotionSample(offsetSeconds: offset, userAcceleration: acceleration,
            rotationRate: rotation, gravity: gravity, magneticFieldMicrotesla: magnetic)
        active.entries.append(Entry(sample: sample, calibrated: calibrated))
        active.entries.removeAll { $0.sample.offsetSeconds < offset - PulseCeremonyMotionWitness.maximumWindowSeconds }
        if active.entries.count > PulseCeremonyMotionWitness.maximumSamples {
            active.entries.removeFirst(active.entries.count - PulseCeremonyMotionWitness.maximumSamples)
        }
        session = active
    }

    func snapshot(endingAtUptime timestamp: Double) -> PulseCeremonyMotionCapture? {
        guard let active = session, timestamp.isFinite, timestamp >= active.uptime else { return nil }
        let entries = active.entries.filter {
            let time = active.uptime + $0.sample.offsetSeconds
            return time <= timestamp && time >= timestamp - PulseCeremonyMotionWitness.maximumWindowSeconds
        }
        guard entries.count >= 2, let last = entries.last,
              timestamp - active.uptime - last.sample.offsetSeconds <= 0.2 else { return nil }
        return capture(active, entries: entries)
    }

    mutating func stop() -> PulseCeremonyMotionWindow? {
        defer { session = nil }
        guard let active = session else { return nil }
        return capture(active, entries: active.entries)?.window
    }

    private func capture(_ active: Session, entries: [Entry]) -> PulseCeremonyMotionCapture? {
        guard let first = entries.first, let last = entries.last else { return nil }
        let offset = first.sample.offsetSeconds
        let samples = entries.map { entry in
            let sample = entry.sample
            return PulseCeremonyMotionSample(offsetSeconds: sample.offsetSeconds - offset,
                userAcceleration: sample.userAcceleration, rotationRate: sample.rotationRate,
                gravity: sample.gravity, magneticFieldMicrotesla: sample.magneticFieldMicrotesla)
        }
        let window = PulseCeremonyMotionWindow(ceremony: active.ceremony,
            startedAt: active.startedAt.addingTimeInterval(offset),
            endedAt: active.startedAt.addingTimeInterval(last.sample.offsetSeconds),
            requestedSampleRateHz: active.rate, samples: samples,
            magnetometerCalibrated: entries.filter(\.calibrated).count * 2 >= entries.count)
        return PulseCeremonyMotionCapture(window: window, startUptime: active.uptime + offset,
                                         endUptime: active.uptime + last.sample.offsetSeconds)
    }
}
