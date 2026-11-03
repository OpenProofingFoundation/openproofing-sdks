import Foundation
import KenshikiMotion
@_spi(StorageAdapter) @_spi(StorageTestFixture) import KenshikiProtectedStorage
import SQLCipher
@testable import KenshikiReference
import XCTest

@MainActor final class WorkflowEvidenceTests: XCTestCase {
    func testLongMotionWorkflowStreamsFullExtremaAndCoverageWithBoundedSampleRetention() async throws {
        let workflow = UUID(), segment = UUID(), windows = 7200
        let persistence = FaceWorkflowPersistence(saveCapture: { _ in }, loadCapture: { _ in throw FaceWorkflowStorageFailure.unavailable },
            saveStage: { _ in }, loadStage: { _, _ in nil }, latestCaptureID: { nil }, appendEvent: { _ in },
            loadEvents: { _, cursor in
                (cursor..<min(cursor + 16, windows)).map { Self.longProjectionEvent(workflow, segment, $0) }
            })
        let boundary = Self.longProjectionEvent(workflow, segment, windows - 1)
        let projection = try await WorkflowMotionProjection.load(persistence: persistence, workflowID: workflow, through: boundary.id)
        XCTAssertEqual(projection.eventCount, windows)
        XCTAssertEqual(projection.windowCount, windows)
        XCTAssertEqual(projection.sampleCount, 360_000)
        XCTAssertEqual(projection.ranges["accelerationX"]?.minimum, -11)
        XCTAssertEqual(projection.ranges["accelerationX"]?.maximum, 23)
        XCTAssertEqual(projection.ranges["accelerationX"]?.count, projection.sampleCount)
        XCTAssertEqual(projection.observedSeconds, 7199.98, accuracy: 0.000001)
        XCTAssertEqual(projection.gapCount, 0)
        XCTAssertGreaterThan(projection.retainedSampleHighWatermark, 200)
        XCTAssertLessThanOrEqual(projection.retainedSampleHighWatermark, WorkflowMotionProjection.maximumRetainedSamplesPerSegment)
    }

    func testMotionProjectionBoundsResumeTailsAndRejectsStaleOrOutOfOrderSamples() throws {
        let workflow = UUID()
        let segments = (0..<40).map { _ in UUID() }
        let events = segments.map { projectionEvent(workflow, $0, "workflow.resumed", 1, [1, 2, 3]) }
        let forward = projectionEvent(workflow, segments[0], "sensor.window", 2, [-7, 8, 9])
        let projection = try WorkflowMotionProjection.project(projectionArchive(workflow, events + [forward]))
        XCTAssertEqual(projection.sampleCount, 123)
        XCTAssertEqual(projection.segmentCount, 40)
        XCTAssertEqual(projection.ranges["accelerationX"]?.minimum, -7)
        XCTAssertEqual(projection.ranges["accelerationX"]?.maximum, 9)
        XCTAssertLessThanOrEqual(projection.retainedSampleHighWatermark,
            WorkflowMotionProjection.maximumRetainedSegments * WorkflowMotionProjection.maximumRetainedSamplesPerSegment)
        let stale = projectionEvent(workflow, segments[0], "sensor.window", 1, [1, 2, 3])
        XCTAssertThrowsError(try WorkflowMotionProjection.project(projectionArchive(workflow, events + [stale]))) {
            guard case FaceWorkflowStorageFailure.invalidRecord = $0 else { return XCTFail("Expected explicit stale-evidence failure") }
        }
        let first = projectionEvent(workflow, segments[0], "sensor.window", 10, [1, 2, 3])
        let repeated = projectionEvent(workflow, segments[0], "sensor.window", 10, [1, 2, 3])
        let same = try WorkflowMotionProjection.project(projectionArchive(workflow, [first, repeated]))
        XCTAssertEqual(same.sampleCount, 3)
        XCTAssertEqual(same.duplicateSampleCount, 3)
        XCTAssertEqual(same.windowCount, 1)
        let pastTail = projectionEvent(workflow, segments[0], "sensor.window", 16, [4, 5, 6])
        XCTAssertThrowsError(try WorkflowMotionProjection.project(projectionArchive(workflow, [first, pastTail, repeated])))
        let outOfOrder = projectionEvent(workflow, segments[0], "sensor.window", 10.01, [9, 9, 9])
        XCTAssertThrowsError(try WorkflowMotionProjection.project(projectionArchive(workflow, [first, outOfOrder])))
    }

    private nonisolated static func longProjectionEvent(_ workflow: UUID, _ segment: UUID, _ index: Int) -> SavedWorkflowEvent {
        let uptime = 100 + Double(index)
        let date = Date(timeIntervalSince1970: 1792600000 + uptime)
        let value = index == 0 ? -11.0 : index == 7199 ? 23.0 : 0.0
        let window = PulseCeremonyMotionWindow(ceremony: .faceMatch, startedAt: date,
            endedAt: date.addingTimeInterval(0.98), requestedSampleRateHz: 50,
            samples: (0..<50).map { sample in
                .init(offsetSeconds: Double(sample) * 0.02, userAcceleration: SIMD3(value, 0, 0),
                    rotationRate: SIMD3(0, 0, 0), gravity: SIMD3(0, 1, 0), magneticFieldMicrotesla: nil)
            }, magnetometerCalibrated: false)
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
        return SavedWorkflowEvent(workflowID: workflow, action: "sensor.window", permissionStatus: "authorized",
            motion: .init(window: window, startUptime: uptime, endUptime: uptime + 0.98), segmentID: segment,
            id: id, occurredAt: window.endedAt, uptimeSeconds: uptime + 0.98)
    }

    func testMotionProjectionSpansMRZNFCSelfieAndRetakeWithExactRanges() throws {
        let workflow = UUID(), segment = UUID()
        let events = [projectionEvent(workflow, segment, "passport.mrz.captured", 10, [-2, 0.1, 0.2]),
                      projectionEvent(workflow, segment, "passport.nfc.committed", 10.06, [0.3, 4, 0.5]),
                      projectionEvent(workflow, segment, "selfie.captured", 10.12, [0.6, 0.7, 0.8]),
                      projectionEvent(workflow, segment, "selfie.retake", 10.18, [0.9, 1, 3])]
        let projection = try WorkflowMotionProjection.project(projectionArchive(workflow, events))
        XCTAssertEqual(projection.sampleCount, 12)
        XCTAssertEqual(projection.windowCount, 4)
        XCTAssertEqual(projection.ranges["accelerationX"]?.minimum, -2)
        XCTAssertEqual(projection.ranges["accelerationX"]?.maximum, 4)
        XCTAssertEqual(projection.ranges["rotationY"]?.minimum, -4)
        XCTAssertEqual(projection.ranges["rotationY"]?.maximum, 2)
        XCTAssertEqual(projection.ranges["gravityZ"]?.minimum, 0.5)
        XCTAssertEqual(projection.ranges["accelerationMagnitude"]?.maximum ?? 0, sqrt(16.05), accuracy: 0.000001)
        XCTAssertEqual(projection.observedSeconds, 0.22, accuracy: 0.000001)
        XCTAssertEqual(projection.gapCount, 0)
        XCTAssertGreaterThan(projection.ranges["accelerationRMS"]!.maximum, projection.ranges["accelerationRMS"]!.minimum)
        let projected = FaceComparisonTelemetry.motionFields(projection)
        XCTAssertEqual(projected.first { $0.key == "telemetry.workflowMotion.accelerationX" }?.value, .range(-2, 4))
    }

    func testMotionProjectionDeduplicatesOverlapsAndSeparatesResumeCoverage() throws {
        let workflow = UUID(), segment = UUID(), resumed = UUID()
        let first = projectionEvent(workflow, segment, "sensor.window", 100, [1, 2, 3])
        let overlap = projectionEvent(workflow, segment, "sensor.window", 100.02, [2, 3, 4])
        let later = projectionEvent(workflow, segment, "sensor.window", 101, [5, 6, 7])
        let restart = projectionEvent(workflow, resumed, "workflow.resumed", 1, [-8, -7, -6])
        let projection = try WorkflowMotionProjection.project(projectionArchive(workflow, [first, first, overlap, later, restart]))
        XCTAssertEqual(projection.eventCount, 4)
        XCTAssertEqual(projection.sampleCount, 10)
        XCTAssertEqual(projection.duplicateSampleCount, 2)
        XCTAssertEqual(projection.segmentCount, 2)
        XCTAssertEqual(projection.gapCount, 1)
        XCTAssertEqual(projection.gapSeconds, 0.92, accuracy: 0.000001)
        XCTAssertEqual(projection.observedSeconds, 0.14, accuracy: 0.000001)
        XCTAssertEqual(projection.ranges["accelerationX"]?.minimum, -8)
        XCTAssertEqual(projection.ranges["accelerationX"]?.maximum, 7)
    }

    func testMotionProjectionPreservesDeniedEmptyAndMissingMagneticEvidence() throws {
        let workflow = UUID(), segment = UUID()
        let denied = SavedWorkflowEvent(workflowID: workflow, action: "sensor.permission_changed", permissionStatus: "denied", segmentID: segment)
        let empty = try WorkflowMotionProjection.project(projectionArchive(workflow, [denied]))
        XCTAssertEqual(empty.permissions, ["denied"])
        XCTAssertEqual(empty.eventsWithoutMotion, 1)
        XCTAssertEqual(empty.sampleCount, 0)
        XCTAssertTrue(empty.ranges.isEmpty)
        XCTAssertNil(empty.firstSampleAt)
        let missing = projectionEvent(workflow, segment, "sensor.window", 3, [0, 1, 2], magnetic: false)
        let projection = try WorkflowMotionProjection.project(projectionArchive(workflow, [denied, missing]))
        XCTAssertEqual(projection.permissions, ["authorized", "denied"])
        XCTAssertNil(projection.ranges["magneticMagnitude"])
        XCTAssertEqual(projection.magneticSampleCount, 0)
        XCTAssertEqual(projection.uncalibratedWindowCount, 1)
        XCTAssertEqual(FaceComparisonTelemetry.motionFields(projection).first { $0.key == "telemetry.workflowMotion.magneticMagnitude" }?.value, .unavailable)
    }

    func testMotionProjectionRejectsConflictingSamplesAtTheSameSegmentTime() throws {
        let workflow = UUID(), segment = UUID()
        let original = projectionEvent(workflow, segment, "sensor.window", 3, [0, 1, 2])
        let changed = projectionEvent(workflow, segment, "sensor.window", 3, [9, 1, 2])
        XCTAssertThrowsError(try WorkflowMotionProjection.project(projectionArchive(workflow, [original, changed])))
    }

    func testHistoricalMotionProjectionPagesThroughBoundaryAndRejectsDifferentWorkflowOrTruncation() async throws {
        let workflow = UUID(), segment = UUID()
        let first = projectionEvent(workflow, segment, "passport.nfc.committed", 10, [-9, 1, 2])
        let boundary = projectionEvent(workflow, segment, "selfie.compare", 11, [3, 4, 5])
        let future = projectionEvent(workflow, segment, "selfie.retake", 12, [99, 100, 101])
        let persistence = FaceWorkflowPersistence(saveCapture: { _ in }, loadCapture: { _ in throw FaceWorkflowStorageFailure.unavailable },
            saveStage: { _ in }, loadStage: { _, _ in nil }, latestCaptureID: { nil }, appendEvent: { _ in },
            loadEvents: { id, cursor in
                guard id == workflow else { throw FaceWorkflowStorageFailure.invalidRecord }
                return Array([first, boundary, future].dropFirst(cursor).prefix(1))
            })
        let projection = try await WorkflowMotionProjection.load(persistence: persistence, workflowID: workflow, through: boundary.id)
        XCTAssertEqual(projection.ranges["accelerationX"]?.minimum, -9)
        XCTAssertEqual(projection.ranges["accelerationX"]?.maximum, 5)
        XCTAssertEqual(projection.eventCount, 2)
        XCTAssertThrowsError(try WorkflowMotionProjection.project(projectionArchive(UUID(), [first, boundary])))
        let truncated = WorkflowEvidenceArchive(schemaVersion: 1, workflowID: workflow, throughEventID: boundary.id,
            events: [first], truncated: true, nextSequence: 2)
        XCTAssertThrowsError(try WorkflowMotionProjection.project(truncated))
        let nextWorkflow = UUID()
        let fresh = projectionEvent(nextWorkflow, UUID(), "workflow.started", 1, [0, 0, 0])
        let reset = try WorkflowMotionProjection.project(projectionArchive(nextWorkflow, [fresh]))
        XCTAssertEqual(reset.ranges["accelerationX"]?.minimum, 0)
        XCTAssertEqual(reset.sampleCount, 3)
    }

    func testRecorderMotionProjectionReadsPersistedWindowsAndRetiresPriorWorkflow() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        var window: SavedWorkflowMotion?
        let recorder = WorkflowEvidenceRecorder(sensors: .init(start: { _ in }, stop: {}, motion: { window },
            motionPermission: { "authorized" }, location: {
                .init(permission: .denied, accuracy: .unavailable, observedAt: Date(), fix: nil, providerErrorCode: nil)
            }), persistence: repository.comparisonEffects)
        let workflow = UUID()
        try await recorder.start(workflowID: workflow)
        window = projectionEvent(workflow, UUID(), "sensor.window", 10, [-3, 1, 2]).motion
        _ = try await recorder.record("passport.nfc.committed")
        window = projectionEvent(workflow, UUID(), "sensor.window", 10.02, [1, 2, 7]).motion
        let boundary = try await recorder.record("selfie.captured")
        let projection = try await recorder.motionProjection(through: boundary)
        XCTAssertEqual(projection.sampleCount, 4)
        XCTAssertEqual(projection.duplicateSampleCount, 0, "The journal has already removed overlapping samples")
        XCTAssertEqual(projection.ranges["accelerationX"]?.minimum, -3)
        XCTAssertEqual(projection.ranges["accelerationX"]?.maximum, 7)
        await recorder.discardForErasure()
        window = nil
        let next = UUID()
        try await recorder.start(workflowID: next)
        let freshBoundary = try await recorder.record("telemetry.review")
        let empty = try await recorder.motionProjection(through: freshBoundary)
        XCTAssertEqual(empty.workflowID, next)
        XCTAssertEqual(empty.sampleCount, 0)
        XCTAssertTrue(empty.ranges.isEmpty)
        await recorder.stop("workflow.done")?.value
    }

    private func projectionArchive(_ workflow: UUID, _ events: [SavedWorkflowEvent]) -> WorkflowEvidenceArchive {
        .init(schemaVersion: 1, workflowID: workflow, throughEventID: events.last!.id,
            events: events, truncated: false, nextSequence: events.count + 1)
    }

    private func projectionEvent(_ workflow: UUID, _ segment: UUID, _ action: String, _ uptime: Double,
                                 _ values: [Double], magnetic: Bool = true) -> SavedWorkflowEvent {
        let date = Date(timeIntervalSince1970: 1792600000 + uptime)
        let duration = Double(values.count - 1) * 0.02
        let window = PulseCeremonyMotionWindow(ceremony: action.hasPrefix("passport") ? .passportChipRead : .faceMatch,
            startedAt: date, endedAt: date.addingTimeInterval(duration), requestedSampleRateHz: 50,
            samples: values.enumerated().map { index, value in
                .init(offsetSeconds: Double(index) * 0.02, userAcceleration: SIMD3(value, 0.1, 0.2),
                    rotationRate: SIMD3(0, -value, 0), gravity: SIMD3(0.5, 0.5, 0.5),
                    magneticFieldMicrotesla: magnetic ? 30 + abs(value) : nil)
            }, magnetometerCalibrated: magnetic)
        return SavedWorkflowEvent(workflowID: workflow, action: action, permissionStatus: "authorized",
            motion: SavedWorkflowMotion(window: window, startUptime: uptime, endUptime: uptime + duration),
            segmentID: segment, occurredAt: window.endedAt, uptimeSeconds: uptime + duration)
    }

    func testLargeMotionPagesAreByteBoundedAndPreserveEveryEvent() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let workflowID = UUID()
        let date = Date(timeIntervalSince1970: 1792600000)
        let window = PulseCeremonyMotionWindow(ceremony: .faceMatch, startedAt: date,
            endedAt: date.addingTimeInterval(4.98), requestedSampleRateHz: 50,
            samples: (0..<250).map { index in
                let value = Double(index) / 1000
                return .init(offsetSeconds: Double(index) * 0.02,
                    userAcceleration: SIMD3(value, value + 0.1, value + 0.2),
                    rotationRate: SIMD3(value + 0.3, value + 0.4, value + 0.5),
                    gravity: SIMD3(0, 1, 0), magneticFieldMicrotesla: 30 + value)
            }, magnetometerCalibrated: true)
        let motion = SavedWorkflowMotion(window: window, startUptime: 10, endUptime: 14.98)
        var expected: [UUID] = []
        for _ in 0..<160 {
            let value = event(workflowID, UUID(), motion: motion)
            try await repository.appendWorkflowEvent(value)
            expected.append(value.id)
        }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        var actual: [UUID] = []
        while actual.count < expected.count {
            let page = try await repository.loadWorkflowEvents(workflowID, after: actual.count)
            guard !page.isEmpty else { return XCTFail("Pagination lost committed events") }
            XCTAssertLessThan(page.count, expected.count, "Row count alone admitted an oversized motion page")
            let bytes = try page.reduce(0) { try $0 + encoder.encode($1).count }
            XCTAssertLessThanOrEqual(bytes, 1024 * 1024)
            actual.append(contentsOf: page.map(\.id))
        }
        XCTAssertEqual(actual, expected)
        let remaining = try await repository.loadWorkflowEvents(workflowID, after: actual.count)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testJourneySensorHeartbeatsPersistWithoutRenderingAndPublishFailureRecovery() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let sink = SwitchableEventSink(store: repository)
        await sink.allow()
        let effects = repository.comparisonEffects
        let persistence = FaceWorkflowPersistence(saveCapture: effects.saveCapture, loadCapture: effects.loadCapture,
            saveStage: effects.saveStage, loadStage: effects.loadStage, latestCaptureID: effects.latestCaptureID,
            appendEvent: { try await sink.append($0) }, loadEvents: effects.loadEvents)
        let recorder = WorkflowEvidenceRecorder(sensors: WorkflowSensorPort(start: { _ in }, stop: {},
            motion: { nil }, motionPermission: { "denied" }, location: {
                .init(permission: .denied, accuracy: .unavailable, observedAt: Date(), fix: nil, providerErrorCode: nil)
            }), persistence: persistence)
        let journey = PassportFaceJourneyController(
            comparison: FaceComparisonController(compare: { _ in throw FaceWorkflowStorageFailure.unavailable }),
            evidence: recorder)
        var notifications = 0
        journey.onEvidenceChange = { notifications += 1 }
        let workflow = UUID()
        try await recorder.start(workflowID: workflow)
        defer { recorder.stop("workflow.cancelled") }
        XCTAssertEqual(notifications, 1, "Entering recording must update the visible evidence state")
        var committedIDs: [UUID] = []
        for _ in 0..<64 { committedIDs.append(try await recorder.record("sensor.window").id) }
        XCTAssertEqual(notifications, 1, "Unchanged recording status must not rebuild expanded telemetry")
        await sink.deny()
        do { try await recorder.record("sensor.window"); XCTFail("Expected persistence failure") } catch { }
        XCTAssertEqual(notifications, 2, "Persistence failure must remain visible immediately")
        do { try await recorder.record("sensor.window"); XCTFail("Expected failed flush") } catch { }
        XCTAssertEqual(notifications, 2, "An unchanged failure must not invalidate the screen again")
        await sink.allow()
        committedIDs.append(try await recorder.record("sensor.window").id)
        XCTAssertEqual(notifications, 3, "Successful retry must clear the displayed failure")
        for _ in 0..<64 { committedIDs.append(try await recorder.record("sensor.window").id) }
        XCTAssertEqual(notifications, 3)
        let rows = try await repository.loadWorkflowEvents(workflow)
        let storedIDs = Set(rows.map(\.id))
        XCTAssertTrue(committedIDs.allSatisfy { storedIDs.contains($0) }, "Suppressing rendering must never discard evidence")
        XCTAssertGreaterThanOrEqual(rows.filter { $0.action == "sensor.window" }.count, 130,
            "The failed write must also survive its journal retry")
        await recorder.stop("workflow.done")?.value
        XCTAssertEqual(notifications, 4, "Stopping must publish idle")
        try await recorder.start(workflowID: UUID())
        XCTAssertEqual(notifications, 5, "A later recording session must publish its first state")
        await recorder.stop("workflow.done")?.value
    }

    func testLostAcknowledgementRetriesIdenticalEventAndDeduplicatesMotion() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let writer = LostEventAcknowledgement(store: repository)
        let journal = WorkflowEvidenceJournal(append: { try await writer.append($0) })
        let workflow = UUID(), segment = UUID()
        let first = event(workflow, segment, motion: motion(start: 100, count: 3))
        do { try await journal.record(first); XCTFail("Expected lost acknowledgement") } catch { }
        let second = event(workflow, segment, motion: motion(start: 100.02, count: 4))
        try await journal.record(second)
        let saved = try await repository.loadWorkflowEvents(workflow)
        XCTAssertEqual(saved.map(\.id), [first.id, second.id])
        XCTAssertEqual(saved.map { $0.motion?.samples.count }, [3, 2])
        XCTAssertEqual(saved[1].motion?.startUptime ?? 0, 100.06, accuracy: 0.000001)
        XCTAssertEqual(saved[1].motion?.endUptime ?? 0, 100.08, accuracy: 0.000001)
        let identities = await writer.identities()
        XCTAssertEqual(identities, [first.id, first.id, second.id])
        let reopened = try await fixture.repository().loadWorkflowEvents(workflow)
        XCTAssertEqual(reopened[1].motion?.summary.rawWindowSHA256, saved[1].motion?.summary.rawWindowSHA256)
    }

    func testGapsAndNewClockSegmentsAreRetainedWithoutInterpolation() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let journal = WorkflowEvidenceJournal(append: repository.comparisonEffects.appendEvent)
        let workflow = UUID(), segment = UUID()
        try await journal.record(event(workflow, segment, motion: motion(start: 100, count: 2)))
        try await journal.record(event(workflow, segment, motion: motion(start: 102, count: 2)))
        try await journal.record(event(workflow, UUID(), motion: motion(start: 1, count: 2)))
        let saved = try await repository.loadWorkflowEvents(workflow)
        XCTAssertEqual(saved[1].gapBeforeSeconds ?? 0, 1.96, accuracy: 0.000001)
        XCTAssertNil(saved[2].gapBeforeSeconds)
        XCTAssertEqual(saved[2].motion?.samples.count, 2)
    }

    func testDeniedAndStaleLocationsNeverBecomeUsableZeroCoordinates() throws {
        let now = Date(timeIntervalSince1970: 1792600000)
        let denied = SavedWorkflowLocation(permission: .denied, accuracy: .unavailable, observedAt: now,
            fix: nil, providerErrorCode: nil)
        try denied.validate()
        XCTAssertFalse(denied.usable)
        let stale = SavedWorkflowLocation(permission: .authorized, accuracy: .reduced, observedAt: now,
            fix: .init(timestamp: now.addingTimeInterval(-60), latitude: 42.1, longitude: -71.1,
                horizontalAccuracyMeters: 1000, altitudeMeters: nil, verticalAccuracyMeters: nil,
                simulatedBySoftware: false, producedByAccessory: false), providerErrorCode: nil)
        try stale.validate()
        XCTAssertFalse(stale.usable)
        XCTAssertEqual(stale.fix?.latitude, 42.1)
        let bad = SavedWorkflowLocation(permission: .authorized, accuracy: .full, observedAt: now,
            fix: .init(timestamp: now, latitude: 181, longitude: 0, horizontalAccuracyMeters: -1,
                altitudeMeters: nil, verticalAccuracyMeters: nil, simulatedBySoftware: nil, producedByAccessory: nil),
            providerErrorCode: nil)
        XCTAssertThrowsError(try bad.validate())
    }

    func testEventMetadataSubstitutionIsRejectedOnReadback() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let workflow = UUID()
        let repository = fixture.repository()
        try await repository.appendWorkflowEvent(event(workflow, UUID(), motion: motion(start: 100, count: 2)))
        try fixture.handle().withConnection { db in
            try PassportCaptureSchema.execute(db, "UPDATE workflow_event SET action='forged.action'")
        }
        do { _ = try await repository.loadWorkflowEvents(workflow); XCTFail("Expected substitution refusal") } catch { }
    }

    func testInvalidMotionVectorAndChangedSummaryAreRefused() throws {
        let original = event(UUID(), UUID(), motion: motion(start: 100, count: 3))
        let encoder = PropertyListEncoder()
        var body = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoder.encode(original), format: nil) as? [String: Any])
        var window = try XCTUnwrap(body["motion"] as? [String: Any])
        var samples = try XCTUnwrap(window["samples"] as? [[String: Any]])
        samples[0]["acceleration"] = [0.1, 0.2]
        window["samples"] = samples; body["motion"] = window
        let bad = try PropertyListDecoder().decode(SavedWorkflowEvent.self,
            from: PropertyListSerialization.data(fromPropertyList: body, format: .binary, options: 0))
        XCTAssertThrowsError(try bad.validate())
    }

    func testExportReadsOnlyCommittedEventsThroughItsAcknowledgedBoundary() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let workflow = UUID(), segment = UUID()
        let first = event(workflow, segment, motion: motion(start: 100, count: 2))
        let later = event(workflow, segment, motion: motion(start: 101, count: 2))
        try await repository.appendWorkflowEvent(first)
        try await repository.appendWorkflowEvent(later)
        let archive = try await WorkflowEvidenceArchive.load(persistence: fixture.repository().comparisonEffects,
            workflowID: workflow, through: first.id)
        XCTAssertEqual(archive.events.map(\.id), [first.id])
        XCTAssertFalse(archive.truncated)
        XCTAssertEqual(archive.nextSequence, 2)
        do {
            _ = try await WorkflowEvidenceArchive.load(persistence: repository.comparisonEffects,
                workflowID: workflow, through: UUID())
            XCTFail("A missing export boundary must not be invented")
        } catch { }
    }

    func testWorkflowCannotStartSensorsBeforeItsStartRecordCommits() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let sink = SwitchableEventSink(store: repository)
        let effects = repository.comparisonEffects
        let persistence = FaceWorkflowPersistence(saveCapture: effects.saveCapture, loadCapture: effects.loadCapture,
            saveStage: effects.saveStage, loadStage: effects.loadStage, latestCaptureID: effects.latestCaptureID,
            appendEvent: { try await sink.append($0) }, loadEvents: effects.loadEvents)
        var starts = 0, stops = 0
        let recorder = WorkflowEvidenceRecorder(sensors: WorkflowSensorPort(start: { _ in starts += 1 },
            stop: { stops += 1 }, motion: { nil }, motionPermission: { "denied" }, location: {
                .init(permission: .denied, accuracy: .unavailable, observedAt: Date(), fix: nil, providerErrorCode: nil)
            }), persistence: persistence)
        do { try await recorder.start(workflowID: UUID()); XCTFail("Expected start commit failure") } catch { }
        XCTAssertEqual(starts, 0)
        await sink.allow()
        let workflow = UUID()
        try await recorder.start(workflowID: workflow)
        XCTAssertEqual(starts, 1)
        let shutdown = recorder.stop("workflow.done")
        XCTAssertEqual(stops, 3)
        await shutdown?.value
        let saved = try await repository.loadWorkflowEvents(workflow)
        XCTAssertEqual(saved.map(\.action), ["workflow.started", "workflow.done"])
        XCTAssertTrue(saved.allSatisfy { $0.motion == nil && $0.location?.fix == nil })
    }

    func testDeletingWorkflowDiscardsFailedSensorQueueBeforeNewWorkflow() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        try await repository.save(try CaptureStoreFixture.capture())
        let sink = SwitchableEventSink(store: repository)
        let effects = repository.comparisonEffects
        let persistence = FaceWorkflowPersistence(saveCapture: effects.saveCapture, loadCapture: effects.loadCapture,
            saveStage: effects.saveStage, loadStage: effects.loadStage, latestCaptureID: effects.latestCaptureID,
            appendEvent: { try await sink.append($0) }, loadEvents: effects.loadEvents)
        let recorder = WorkflowEvidenceRecorder(sensors: WorkflowSensorPort(start: { _ in }, stop: {},
            motion: { nil }, motionPermission: { "denied" }, location: {
                .init(permission: .denied, accuracy: .unavailable, observedAt: Date(), fix: nil, providerErrorCode: nil)
            }), persistence: persistence)
        let oldWorkflow = UUID()
        do { try await recorder.start(workflowID: oldWorkflow); XCTFail("Expected queued write failure") } catch { }
        let comparison = FaceComparisonController(compare: { _ in throw FaceWorkflowStorageFailure.unavailable })
        let journey = PassportFaceJourneyController(comparison: comparison, persistence: repository.effects,
            evidence: recorder, comparisonPersistence: persistence)
        try await waitFor { journey.storageState == .ready }
        journey.send(.savedWork)
        journey.send(.reviewDeletion)
        journey.send(.deleteSavedPassport)
        try await waitFor { journey.storageState == .ready && journey.savedPassport == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
        await sink.allow()
        journey.send(.begin)
        try await waitFor { journey.phase == .passport }
        let freshWorkflow = try XCTUnwrap(recorder.latestEvent).workflowID
        XCTAssertNotEqual(freshWorkflow, oldWorkflow)
        let oldRows = try await repository.loadWorkflowEvents(oldWorkflow)
        let newRows = try await repository.loadWorkflowEvents(freshWorkflow)
        XCTAssertTrue(oldRows.isEmpty, "Deleted workflow events were replayed from the failed queue")
        XCTAssertEqual(newRows.first?.action, "workflow.started")
        await recorder.stop("workflow.cancelled")?.value
        journey.send(.cancel)
    }

    func testJournalRetirementWaitsForInflightWriterAndRejectsLateProducers() async throws {
        let sink = HeldJournalWriter()
        let journal = WorkflowEvidenceJournal(append: { try await sink.append($0) })
        let event = SavedWorkflowEvent(workflowID: UUID(), action: "sensor.window")
        let pending = Task { try await journal.record(event) }
        let startedDeadline = ContinuousClock.now + .seconds(3)
        while await sink.calls == 0, ContinuousClock.now < startedDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let callsBeforeRetirement = await sink.calls
        XCTAssertEqual(callsBeforeRetirement, 1)
        let retirement = Task { await journal.retire(); await sink.markRetired() }
        let retirementDeadline = ContinuousClock.now + .seconds(3)
        while !(await journal.isRetired), ContinuousClock.now < retirementDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let retired = await journal.isRetired
        XCTAssertTrue(retired)
        let prematurelyCompleted = await sink.retirementCompleted
        XCTAssertFalse(prematurelyCompleted)
        do { try await journal.record(event); XCTFail("Retired producer was accepted") }
        catch is CancellationError { }
        await sink.finish()
        await retirement.value
        do { try await pending.value; XCTFail("Retired waiter received a successful publication") }
        catch is CancellationError { }
        do { try await journal.flush(); XCTFail("Retired queue was restarted") }
        catch is CancellationError { }
        let finalCalls = await sink.calls
        XCTAssertEqual(finalCalls, 1)
    }

    private func waitFor(_ ready: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(ready())
    }

    private func event(_ workflow: UUID, _ segment: UUID, motion: SavedWorkflowMotion) -> SavedWorkflowEvent {
        SavedWorkflowEvent(workflowID: workflow, action: "sensor.window", permissionStatus: "authorized",
            motion: motion, segmentID: segment, occurredAt: motion.endedAt, uptimeSeconds: motion.endUptime)
    }

    private func motion(start: Double, count: Int) -> SavedWorkflowMotion {
        let date = Date(timeIntervalSince1970: 1792600000 + start)
        let duration = Double(count - 1) * 0.02
        let window = PulseCeremonyMotionWindow(ceremony: .faceMatch, startedAt: date,
            endedAt: date.addingTimeInterval(duration), requestedSampleRateHz: 50,
            samples: (0..<count).map { index in
                .init(offsetSeconds: Double(index) * 0.02, userAcceleration: SIMD3(0.1, 0.2, 0.3),
                    rotationRate: SIMD3(0.1, 0.1, 0.1), gravity: SIMD3(0, 1, 0), magneticFieldMicrotesla: 30)
            }, magnetometerCalibrated: true)
        return SavedWorkflowMotion(window: window, startUptime: start, endUptime: start + duration)
    }
}

private actor LostEventAcknowledgement {
    let store: PassportCaptureStore
    private var calls: [UUID] = []
    init(store: PassportCaptureStore) { self.store = store }
    func append(_ event: SavedWorkflowEvent) async throws {
        calls.append(event.id)
        try await store.appendWorkflowEvent(event)
        if calls.count == 1 { throw FaceWorkflowStorageFailure.unavailable }
    }
    func identities() -> [UUID] { calls }
}

private actor SwitchableEventSink {
    let store: PassportCaptureStore
    private var failing = true
    init(store: PassportCaptureStore) { self.store = store }
    func allow() { failing = false }
    func deny() { failing = true }
    func append(_ event: SavedWorkflowEvent) async throws {
        if failing { throw FaceWorkflowStorageFailure.unavailable }
        try await store.appendWorkflowEvent(event)
    }
}

private actor HeldJournalWriter {
    private(set) var calls = 0
    private(set) var retirementCompleted = false
    private var continuation: CheckedContinuation<Void, Never>?
    func append(_ event: SavedWorkflowEvent) async throws {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
    func markRetired() { retirementCompleted = true }
}
