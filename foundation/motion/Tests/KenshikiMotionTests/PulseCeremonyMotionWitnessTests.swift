import Foundation
import XCTest
@testable import KenshikiMotion

final class PulseCeremonyMotionWitnessTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1000)

    private func append(_ trace: inout PulseCeremonyMotionTrace, _ generation: UUID,
                        time: Double, calibrated: Bool = true, acceleration: Double = 0.01) {
        trace.append(timestamp: time, acceleration: SIMD3(acceleration, 0, 0), rotation: SIMD3(0, 0.1, 0),
                     gravity: SIMD3(0, 1, 0), magnetic: 30, calibrated: calibrated, generation: generation)
    }

    func testCountAndTimePruningBoundActualRetainedSamples() throws {
        var trace = PulseCeremonyMotionTrace()
        let generation = try XCTUnwrap(trace.start(ceremony: .faceMatch, date: date, uptime: 10, sampleRate: 100))
        for index in 0..<1000 { append(&trace, generation, time: 10 + Double(index) / 100) }
        let window = try XCTUnwrap(trace.snapshot(endingAtUptime: 10 + Double(999) / 100))
        XCTAssertEqual(window.window.samples.count, 300)
        XCTAssertEqual(window.startUptime, 17, accuracy: 0.000001)
        XCTAssertEqual(window.window.samples.first?.offsetSeconds, 0)
        append(&trace, generation, time: 30)
        append(&trace, generation, time: 30.1)
        let pruned = try XCTUnwrap(trace.snapshot(endingAtUptime: 30.1))
        XCTAssertEqual(pruned.window.samples.count, 2)
        XCTAssertEqual(pruned.startUptime, 30)
    }

    func testCalibrationBelongsToSelectedWindowNotLaterSamples() throws {
        var trace = PulseCeremonyMotionTrace()
        let generation = try XCTUnwrap(trace.start(ceremony: .faceMatch, date: date, uptime: 10, sampleRate: 50))
        append(&trace, generation, time: 10, calibrated: false)
        append(&trace, generation, time: 10.1, calibrated: false)
        for index in 2...9 { append(&trace, generation, time: 10 + Double(index) / 10) }
        XCTAssertFalse(try XCTUnwrap(trace.snapshot(endingAtUptime: 10.1)).window.magnetometerCalibrated)
        XCTAssertTrue(try XCTUnwrap(trace.snapshot(endingAtUptime: 10.9)).window.magnetometerCalibrated)
    }

    func testFrameCutoffExcludesFutureSamplesAndStaleWindow() throws {
        var trace = PulseCeremonyMotionTrace()
        let generation = try XCTUnwrap(trace.start(ceremony: .faceMatch, date: date, uptime: 10, sampleRate: 50))
        append(&trace, generation, time: 10)
        append(&trace, generation, time: 10.1)
        append(&trace, generation, time: 10.2)
        let bound = try XCTUnwrap(trace.snapshot(endingAtUptime: 10.15))
        XCTAssertEqual(bound.window.samples.count, 2)
        XCTAssertEqual(bound.endUptime, 10.1)
        XCTAssertNil(trace.snapshot(endingAtUptime: 10.5))
        XCTAssertNil(trace.snapshot(endingAtUptime: 9))
        XCTAssertNil(trace.snapshot(endingAtUptime: .nan))
    }

    func testRetiredGenerationCannotAppendOrSurviveRestart() throws {
        var trace = PulseCeremonyMotionTrace()
        let first = try XCTUnwrap(trace.start(ceremony: .faceMatch, date: date, uptime: 10, sampleRate: 50))
        append(&trace, first, time: 10)
        append(&trace, first, time: 10.1)
        XCTAssertNil(trace.start(ceremony: .faceMatch, date: date, uptime: 20, sampleRate: 50))
        XCTAssertNotNil(trace.stop())
        append(&trace, first, time: 10.2)
        XCTAssertNil(trace.snapshot(endingAtUptime: 10.2))
        XCTAssertNil(trace.stop())
        let second = try XCTUnwrap(trace.start(ceremony: .faceMatch, date: date, uptime: 20, sampleRate: 50))
        append(&trace, first, time: 20)
        append(&trace, first, time: 20.1)
        XCTAssertNil(trace.snapshot(endingAtUptime: 20.1))
        append(&trace, second, time: 20)
        append(&trace, second, time: 20.1)
        XCTAssertEqual(try XCTUnwrap(trace.snapshot(endingAtUptime: 20.1)).window.samples.count, 2)
    }

    func testInvalidRatesNonfiniteOrReorderedSamplesAreRejected() throws {
        for rate in [0, -1, .nan, .infinity, 1001] {
            var trace = PulseCeremonyMotionTrace()
            XCTAssertNil(trace.start(ceremony: .faceMatch, date: date, uptime: 10, sampleRate: rate))
        }
        var trace = PulseCeremonyMotionTrace()
        let generation = try XCTUnwrap(trace.start(ceremony: .faceMatch, date: date, uptime: 10, sampleRate: 50))
        append(&trace, generation, time: 10)
        append(&trace, generation, time: 9)
        append(&trace, generation, time: 10)
        append(&trace, generation, time: .infinity)
        append(&trace, generation, time: 10.01, acceleration: .nan)
        append(&trace, generation, time: 10.1)
        XCTAssertEqual(try XCTUnwrap(trace.stop()).samples.count, 2)
    }

    func testStopRebasesTrimmedSamplesAndBoundsReturnedWallTime() throws {
        var trace = PulseCeremonyMotionTrace()
        let generation = try XCTUnwrap(trace.start(ceremony: .faceMatch, date: date, uptime: 10, sampleRate: 50))
        append(&trace, generation, time: 10)
        append(&trace, generation, time: 18)
        append(&trace, generation, time: 18.1)
        let window = try XCTUnwrap(trace.stop())
        XCTAssertEqual(window.startedAt, date.addingTimeInterval(8))
        XCTAssertEqual(window.endedAt.timeIntervalSince(date), 8.1, accuracy: 0.000001)
        XCTAssertEqual(window.samples.first?.offsetSeconds, 0)
        XCTAssertEqual(window.samples.last?.offsetSeconds ?? -1, 0.1, accuracy: 0.000001)
    }
}
