import XCTest

@testable import KenshikiMotion

/// Pins the eight ceremony-motion features to synthetic traces whose answers are known by
/// construction. Phase 1 records these; nothing scores them yet, so these tests guard the
/// DEFINITIONS, not a verdict.
final class PulseCeremonyMotionSummaryTests: XCTestCase {
    private let rate = 50.0

    private func window(
        seconds: Double,
        ceremony: PulseCeremonyKind = .passportChipRead,
        accel: (Double) -> SIMD3<Double>,
        gravity: (Double) -> SIMD3<Double> = { _ in SIMD3(0, 0, -1) },
        field: (Double) -> Double? = { _ in nil }
    ) -> PulseCeremonyMotionWindow {
        let count = Int(seconds * rate)
        let samples = (0..<count).map { index -> PulseCeremonyMotionSample in
            let t = Double(index) / rate
            return PulseCeremonyMotionSample(
                offsetSeconds: t,
                userAcceleration: accel(t),
                rotationRate: SIMD3(0, 0, 0),
                gravity: gravity(t),
                magneticFieldMicrotesla: field(t))
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return PulseCeremonyMotionWindow(
            ceremony: ceremony,
            startedAt: start,
            endedAt: start.addingTimeInterval(seconds),
            requestedSampleRateHz: rate,
            samples: samples,
            magnetometerCalibrated: true)
    }

    func testDeadStillTraceHasZeroEnergyAndNoTremorRatio() {
        let summary = PulseCeremonyMotionSummarizer.summarize(
            window(seconds: 3) { _ in SIMD3(0, 0, 0) })
        XCTAssertEqual(summary.sampleCount, 150)
        XCTAssertEqual(summary.accelerationRMSg ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.rotationRMSRadPerSecond ?? -1, 0, accuracy: 1e-12)
        XCTAssertNil(summary.tremorBandRatio, "no energy at all → ratio is undefined, not 0")
        XCTAssertEqual(summary.gravityDominantAxis, "z")
        XCTAssertEqual(summary.gravityDominance ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(summary.gravityDriftRadians ?? 1, 0, accuracy: 1e-12)
        XCTAssertNil(summary.magneticDeltaMicrotesla)
    }

    func testTenHertzTremorDominatesTheBandRatio() {
        let summary = PulseCeremonyMotionSummarizer.summarize(
            window(seconds: 3) { t in SIMD3(0.02 * sin(2 * .pi * 10 * t), 0, 0) })
        XCTAssertGreaterThan(summary.tremorBandRatio ?? 0, 0.9)
    }

    func testSlowSwayFallsOutsideTheTremorBand() {
        let summary = PulseCeremonyMotionSummarizer.summarize(
            window(seconds: 3) { t in SIMD3(0.05 * sin(2 * .pi * 2 * t), 0, 0) })
        XCTAssertLessThan(summary.tremorBandRatio ?? 1, 0.1)
    }

    func testSettleRatioDropsWhenTheLastFifthOfASecondIsStill() {
        let summary = PulseCeremonyMotionSummarizer.summarize(
            window(seconds: 2) { t in t < 1.8 ? SIMD3(0.1, 0, 0) : SIMD3(0, 0, 0) })
        XCTAssertEqual(summary.settleRatio ?? 1, 0, accuracy: 1e-12)
        XCTAssertEqual(summary.approachRMSg ?? 0, 0.1, accuracy: 1e-12)
    }

    func testGravityDriftIsTheAngleBetweenFirstAndLastVectors() {
        let summary = PulseCeremonyMotionSummarizer.summarize(
            window(
                seconds: 2, accel: { _ in SIMD3(0, 0, 0) },
                gravity: { t in t < 1 ? SIMD3(0, 0, -1) : SIMD3(0, 1, 0) }))
        XCTAssertEqual(summary.gravityDriftRadians ?? 0, .pi / 2, accuracy: 1e-9)
    }

    func testMagneticDeltaIsMaxMinusMin() {
        let summary = PulseCeremonyMotionSummarizer.summarize(
            window(seconds: 1, accel: { _ in SIMD3(0, 0, 0) }, field: { t in 40 + 5 * t }))
        XCTAssertEqual(summary.magneticDeltaMicrotesla ?? 0, 4.9, accuracy: 1e-9)
    }

    func testMissingMagneticReferenceIsUnavailableNeverZero() {
        XCTAssertNil(
            PulseCeremonyMotionWitness.magneticFieldMagnitude(
                SIMD3(0, 0, 0), hasMagneticReference: false))
        XCTAssertNil(
            PulseCeremonyMotionWitness.magneticFieldMagnitude(
                SIMD3(0, 0, 0), hasMagneticReference: true))
        XCTAssertEqual(
            PulseCeremonyMotionWitness.magneticFieldMagnitude(
                SIMD3(3, 4, 0), hasMagneticReference: true),
            5)
    }

    func testUnderOneSecondOfSamplesYieldsNoTremorRatio() {
        let summary = PulseCeremonyMotionSummarizer.summarize(
            window(seconds: 0.5) { t in SIMD3(0.02 * sin(2 * .pi * 10 * t), 0, 0) })
        XCTAssertNil(summary.tremorBandRatio)
    }

    func testHashIsDeterministicAndSensitiveToOneSample() {
        let a = window(seconds: 1) { t in SIMD3(t, 0, 0) }
        let b = window(seconds: 1) { t in SIMD3(t, 0, 0) }
        XCTAssertEqual(PulseCeremonyMotionSummarizer.hash(a), PulseCeremonyMotionSummarizer.hash(b))
        XCTAssertEqual(PulseCeremonyMotionSummarizer.hash(a).count, 64)
        let c = window(seconds: 1) { t in SIMD3(t == 0.5 ? 0.5000001 : t, 0, 0) }
        XCTAssertNotEqual(PulseCeremonyMotionSummarizer.hash(a), PulseCeremonyMotionSummarizer.hash(c))
    }
}
