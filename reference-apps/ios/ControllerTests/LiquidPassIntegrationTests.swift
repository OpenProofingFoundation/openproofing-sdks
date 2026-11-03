import Foundation
import SQLCipher
@_spi(StorageAdapter) @_spi(StorageTestFixture) import KenshikiProtectedStorage
@testable import BiometricCapture
@testable import KenshikiReference
import XCTest

@MainActor final class LiquidPassIntegrationTests: XCTestCase {
    func testLargePassHistoryReadsSharedEvidenceOnceAndRevalidatesOnNextLoad() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let store = fixture.repository()
        let capture = try await historicalCapture(store)
        let workflowID = try XCTUnwrap(capture.input.workflowID)
        for _ in 0..<32 {
            try await store.appendWorkflowEvent(SavedWorkflowEvent(workflowID: workflowID, action: "sensor.window"))
        }
        let compare = SavedWorkflowEvent(workflowID: workflowID, action: "selfie.compare")
        try await store.appendWorkflowEvent(compare)
        let archive = try await WorkflowEvidenceArchive.load(persistence: store.comparisonEffects,
            workflowID: workflowID, through: compare.id)
        try await store.saveComparisonSnapshot(SavedComparisonSnapshot(capture: capture, archive: archive))
        let aura = SavedFaceStage(operationID: capture.input.operationID, engine: .aura, durationMilliseconds: 1,
            aura: .init(operationID: capture.input.operationID, referenceSHA256: capture.input.referenceSHA256,
                selfieSHA256: capture.input.selfieSHA256, score: 0.7, resultSHA256: String(repeating: "a", count: 64)))
        try await store.saveFaceStage(aura)
        let engine = PassEngineFixture(store: store, directory: directory)
        let input = try await request(capture: capture, aura: aura, store: store)
        let descriptor = try await engine.describe(.quality, input)
        // Fill the full supported history in one fixture transaction, avoiding expensive
        // repeated application writes while still exercising production validation on read.
        var records: [SavedLiquidPass] = []
        for _ in 0..<512 {
            let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
            records.append(pending)
            records.append(pending.failed(.init(reason: .deadline), code: "deadline"))
        }
        try fixture.handle().withConnection { db in
            try insertPassRecords(records, db: db)
            let counts = PassHistoryReadCounts()
            let pointer = Unmanaged.passUnretained(counts).toOpaque()
            sqlite3_set_authorizer(db, { context, operation, table, column, _, _ in
                guard operation == SQLITE_READ, let context, let table, let column,
                      String(cString: column) == "payload" else { return SQLITE_OK }
                Unmanaged<PassHistoryReadCounts>.fromOpaque(context).takeUnretainedValue().record(String(cString: table))
                return SQLITE_OK
            }, pointer)
            sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
                guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                Unmanaged<PassHistoryReadCounts>.fromOpaque(context).takeUnretainedValue().statement(String(cString: sql))
                return 0
            }, pointer)
            defer { sqlite3_set_authorizer(db, nil, nil); sqlite3_trace_v2(db, 0, nil, nil) }
            let loaded = try PassportCaptureStore.readLiquidPasses(db, operationID: capture.input.operationID)
            XCTAssertEqual(loaded.map(\.id), records.map(\.id))
            XCTAssertEqual(counts.tables["comparison_snapshot"], 1)
            XCTAssertEqual(counts.tables["face_stage"], 1)
            XCTAssertEqual(counts.tables["face_capture"], 1)
            // Authorizer callbacks also cover SQLite statement re-preparation; execution
            // tracing below counts the three actual evidence SELECTs independently.
            XCTAssertLessThanOrEqual(counts.tables["workflow_event"] ?? 0, 4)
            XCTAssertEqual(counts.statements.filter { $0.contains("FROM workflow_event") }.count, 3,
                counts.statements.joined(separator: "\n"))
            sqlite3_set_authorizer(db, nil, nil)
            sqlite3_trace_v2(db, 0, nil, nil)
            let update = try PassportCaptureSchema.statement(db, "UPDATE workflow_event SET action='selfie.retake' WHERE event_id=?")
            defer { sqlite3_finalize(update) }
            try PassportCaptureSchema.bind(compare.id.uuidString, at: 1, to: update)
            try PassportCaptureSchema.done(update)
            XCTAssertThrowsError(try PassportCaptureStore.readLiquidPasses(db, operationID: capture.input.operationID),
                "A subsequent operation must revalidate evidence instead of trusting the previous read")
        }
    }

    func testPendingAdmissionReservesLastTerminalSlotAndRejectsAnotherAttempt() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let (capture, aura) = try await seed(fixture)
        let store = fixture.repository()
        let engine = PassEngineFixture(store: store, directory: directory)
        let input = try await request(capture: capture, aura: aura, store: store)
        let descriptor = try await engine.describe(.quality, input)
        var records: [SavedLiquidPass] = []
        for _ in 0..<511 {
            let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
            records += [pending, pending.failed(.init(reason: .deadline), code: "deadline")]
        }
        try fixture.handle().withConnection { try insertPassRecords(records, db: $0) }
        let admitted = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
        try await store.saveLiquidPass(admitted)
        let rejected = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
        do { try await store.saveLiquidPass(rejected); XCTFail("Pending stole an outstanding terminal slot") }
        catch FaceWorkflowStorageFailure.capacity { }
        let terminal = admitted.failed(.init(reason: .deadline, rawOutput: String(repeating: "x", count: 32768)), code: "deadline")
        try await store.saveLiquidPass(terminal)
        try await store.saveLiquidPass(terminal) // An acknowledged terminal remains idempotent at capacity.
        let loaded = try await store.loadLiquidPasses(capture.input.operationID)
        XCTAssertEqual(loaded.count, 1024)
        XCTAssertEqual(loaded.last?.id, terminal.id)
        XCTAssertFalse(loaded.contains { $0.id == rejected.id })
        do { try await store.saveLiquidPass(rejected); XCTFail("Full history accepted another pending attempt") }
        catch FaceWorkflowStorageFailure.capacity { }
    }

    func testHistoricalV3PassHistoryRetainsItsThreeTaskMeaning() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let (capture, aura) = try await seed(fixture)
        let store = fixture.repository()
        let engine = PassEngineFixture(store: store, directory: directory)
        let input = try await request(capture: capture, aura: aura, store: store)
        var records: [SavedLiquidPass] = []
        for pass in [LiquidEvidencePass.quality, .comparison, .presentation] {
            let base = try await engine.describe(pass, input)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
            object["profileID"] = "lfm25-vl16b-affine4-g64-mlx-discrete-review-v3"
            let descriptor = try JSONDecoder().decode(LiquidPassDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
            let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
            records += [pending, pending.failed(.init(reason: .deadline), code: "deadline")]
        }
        let historical = LegacyLiquidArchive.presentation(capture: capture, aura: aura, events: records)
        XCTAssertEqual(historical.totalTaskCount, 3)
        XCTAssertEqual(historical.completedTaskCount, 0)
        XCTAssertTrue(LegacyLiquidArchive.isHistorical(historical))
        XCTAssertEqual(historical.aggregateStatus, .failed)
        XCTAssertFalse(historical.report?.sections.contains { $0.titleKey == "report.pass.age" } ?? true)
    }

    func testPendingWithLargeContextAndProjectionIsRefusedBeforeItsFailureCanOverflow() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let (capture, aura) = try await seed(fixture)
        let store = fixture.repository()
        let engine = PassEngineFixture(store: store, directory: directory)
        let input = try await request(capture: capture, aura: aura, store: store)
        let base = try await engine.describe(.quality, input)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        for (contextBytes, projectionBytes) in [(32768, 8192), (16000, 16000), (32768, 32768)] {
            let descriptor = try capacityDescriptor(base, contextBytes: contextBytes, projectionBytes: projectionBytes)
            let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
            try pending.validate(capture: capture, aura: aura)
            let terminal = pending.failed(.init(reason: .deadline, rawOutput: String(repeating: "\u{1F600}", count: 8192),
                promptTokens: 4096, generatedTokens: 384, metrics: .init(activeMemoryBytes: 1, cacheMemoryBytes: 2, peakMemoryBytes: 3)), code: "deadline")
            XCTAssertGreaterThan(try encoder.encode(terminal).count, 65536)
            do { try await store.saveLiquidPass(pending); XCTFail("Admitted a descriptor whose failure cannot fit") }
            catch FaceWorkflowStorageFailure.capacity { }
            catch FaceWorkflowStorageFailure.invalidRecord {
                XCTAssertGreaterThan(try encoder.encode(pending).count, 65536,
                    "A pending that fits must be rejected by terminal admission, not malformed-record handling")
            }
        }
        let events = try await fixture.repository().loadLiquidPasses(capture.input.operationID)
        XCTAssertTrue(events.isEmpty, "Refusal must not leave an orphan that later becomes interrupted")
    }

    func testAdmittedPendingPersistsMaximumFailureIncludingUnicodeExpansionAndMetrics() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let (capture, aura) = try await seed(fixture)
        let store = fixture.repository()
        let engine = PassEngineFixture(store: store, directory: directory)
        let input = try await request(capture: capture, aura: aura, store: store)
        let descriptor = try await engine.describe(.quality, input)
        let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
        try await store.saveLiquidPass(pending)
        let raw = String(repeating: "\r\n", count: 8191) + "\u{00E9}" + String(repeating: "\u{0301}", count: 8192)
        XCTAssertEqual(raw.count, 8192); XCTAssertEqual(raw.utf8.count, 32768)
        let metrics = LiquidRuntimeMetrics(modelSetupMilliseconds: 1, imagePreparationMilliseconds: 2,
            grammarPreparationMilliseconds: 3, prefillMilliseconds: 4, generationMilliseconds: 5,
            cleanupMilliseconds: 6, activeMemoryBytes: Int.max, cacheMemoryBytes: Int.max - 1, peakMemoryBytes: Int.max - 2)
        let terminal = pending.failed(.init(reason: .deadline, rawOutput: raw, promptTokens: Int.max - 3,
            generatedTokens: Int.max - 4, metrics: metrics), code: String(repeating: "a", count: 126) + "\u{00E9}",
            durationMilliseconds: Double.greatestFiniteMagnitude)
        try await store.saveLiquidPass(terminal)
        try await store.saveLiquidPass(terminal)
        let events = try await fixture.repository().loadLiquidPasses(capture.input.operationID)
        XCTAssertEqual(events.count, 2)
        let saved = try XCTUnwrap(events.last?.failure)
        XCTAssertEqual(saved.rawOutput, raw)
        let metricsEncoder = JSONEncoder(); metricsEncoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try metricsEncoder.encode(XCTUnwrap(saved.metrics)), try metricsEncoder.encode(metrics))
        XCTAssertEqual(events.last?.id, terminal.id)
    }

    private func capacityDescriptor(_ base: LiquidPassDescriptor, contextBytes: Int, projectionBytes: Int) throws -> LiquidPassDescriptor {
        func padded(_ data: Data, to count: Int) throws -> Data {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["padding"] = ""
            let overhead = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).count
            object["padding"] = String(repeating: "x", count: count - overhead)
            let result = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            XCTAssertEqual(result.count, count)
            return result
        }
        let context = try padded(base.contextJSON, to: contextBytes)
        let projection = try padded(try XCTUnwrap(base.modelInputJSON), to: projectionBytes)
        // Historical descriptors use the same row envelope without v4 snapshot re-derivation.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        object["profileID"] = "historical-capacity-v3"
        object["contextJSON"] = context.base64EncodedString()
        object["contextSHA256"] = SavedPassportCapture.digest(context)
        object["modelInputJSON"] = projection.base64EncodedString()
        object["modelInputSHA256"] = SavedPassportCapture.digest(projection)
        return try JSONDecoder().decode(LiquidPassDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testPassCapacityAccountsForAllOutstandingRowsAndMaximumTerminalBytes() throws {
        func check(_ status: SavedLiquidPass.Status = .pending, bytes: Int = 17,
                   operationRows: Int = 1022, operationOutstanding: Int = 0,
                   globalRows: Int = 8190, globalOutstanding: Int = 0, globalBytes: Int) throws {
            try PassportCaptureStore.validateLiquidPassCapacity(status: status, encodedBytes: bytes,
                operationRows: operationRows, operationOutstanding: operationOutstanding,
                globalRows: globalRows, globalOutstanding: globalOutstanding, globalBytes: globalBytes)
        }
        let maximum = 32 * 1024 * 1024
        XCTAssertThrowsError(try check(operationRows: Int.max, operationOutstanding: Int.max,
            globalRows: Int.max, globalOutstanding: Int.max, globalBytes: 0))
        XCTAssertThrowsError(try check(operationRows: -1, globalBytes: 0))
        XCTAssertThrowsError(try check(globalOutstanding: -1, globalBytes: 0))
        XCTAssertThrowsError(try check(globalBytes: -1))
        XCTAssertNoThrow(try check(globalBytes: maximum - 65536 - 17))
        XCTAssertThrowsError(try check(operationRows: 1023, globalBytes: 0))
        XCTAssertThrowsError(try check(globalRows: 8191, globalBytes: 0))
        XCTAssertThrowsError(try check(globalBytes: maximum - 65536 - 16))
        // Outstanding attempts from other operations also retain their complete reservation.
        XCTAssertNoThrow(try check(operationRows: 1000, globalRows: 8180,
            globalOutstanding: 10, globalBytes: maximum - 11 * 65536 - 17))
        XCTAssertThrowsError(try check(operationRows: 1000, globalRows: 8181,
            globalOutstanding: 10, globalBytes: 0))
        XCTAssertThrowsError(try check(operationRows: 1000, globalRows: 8180,
            globalOutstanding: 10, globalBytes: maximum - 11 * 65536 - 16))
        // A terminal consumes the reservation atomically, including its maximum legal size.
        XCTAssertNoThrow(try check(.failed, bytes: 65536, operationRows: 1023, operationOutstanding: 1,
            globalRows: 8191, globalOutstanding: 1, globalBytes: maximum - 65536))
    }









    func testOutcomeRequiresMatchingPendingAttemptAndCannotBeRewritten() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let (capture, aura) = try await seed(fixture)
        let store = fixture.repository()
        let service = PassEngineFixture(store: store, directory: directory)
        let request = try await request(capture: capture, aura: aura, store: store)
        let descriptor = try await service.describe(.quality, request)
        let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
        let failed = pending.failed(.init(reason: .deadline, rawOutput: "partial"), code: "deadline")
        do { try await store.saveLiquidPass(failed); XCTFail("Outcome without pending was admitted") } catch { }
        try await store.saveLiquidPass(pending)
        try await store.saveLiquidPass(pending)
        try await store.saveLiquidPass(failed)
        try await store.saveLiquidPass(failed)
        do {
            try await store.saveLiquidPass(pending.failed(.init(reason: .engine), code: "engine"))
            XCTFail("Terminal outcome was rewritten")
        } catch { }
        let saved = try await store.loadLiquidPasses(capture.input.operationID)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.last?.failure?.rawOutput, "partial")
        let exported = try failed.exportObject()
        let requestObject = try XCTUnwrap(exported["descriptor"] as? [String: Any])
        let context = try XCTUnwrap(requestObject["inputContext"] as? [String: Any])
        XCTAssertEqual(context["pass"] as? String, "quality")
        XCTAssertNil(requestObject["contextJSON"])
    }

    func testV2MigrationFailureAtIndexCreationPreservesCapturesAndRetries() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let (capture, _) = try await seed(fixture)
        try fixture.handle().withConnection { db in
            try PassportCaptureSchema.execute(db, "DROP TABLE comparison_snapshot")
            try PassportCaptureSchema.execute(db, "DROP TABLE liquid_pass_event")
            try PassportCaptureSchema.execute(db, "DELETE FROM passport_schema_migrations WHERE version>=3")
            try PassportCaptureSchema.execute(db, "PRAGMA user_version=2")
            sqlite3_set_authorizer(db, { _, operation, _, _, _, _ in operation == SQLITE_CREATE_INDEX ? SQLITE_DENY : SQLITE_OK }, nil)
            XCTAssertThrowsError(try PassportCaptureSchema.prepare(db))
            sqlite3_set_authorizer(db, nil, nil)
            XCTAssertEqual(try PassportCaptureSchema.integer(db, "PRAGMA user_version"), 2)
            XCTAssertEqual(try PassportCaptureSchema.integer(db, "SELECT count(*) FROM sqlite_master WHERE name='liquid_pass_event'"), 0)
        }
        let reopened = try await fixture.repository().loadFaceCapture(capture.input.operationID)
        XCTAssertEqual(reopened.input.selfie, capture.input.selfie)
        try fixture.handle().withConnection { db in
            XCTAssertEqual(try PassportCaptureSchema.integer(db, "PRAGMA user_version"), PassportCaptureSchema.currentVersion)
        }
    }

    func testMalformedModelAgeRangeCannotEnterStorageOrCrashPresentation() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let (capture, aura) = try await seed(fixture)
        let store = fixture.repository()
        let service = PassEngineFixture(store: store, directory: directory)
        let request = try await request(capture: capture, aura: aura, store: store)
        let descriptor = try await service.describe(.age, request)
        let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
        try await store.saveLiquidPass(pending)
        let result = try await service.assess(.age, request)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        var report = try XCTUnwrap(value["report"] as? [String: Any])
        report["referenceAgeRange"] = [40]
        value["report"] = report
        let invalid = try JSONDecoder().decode(LiquidPassResult.self, from: JSONSerialization.data(withJSONObject: value))
        do { try await store.saveLiquidPass(pending.completed(invalid)); XCTFail("Malformed age interval was admitted") } catch { }
        let stored = try await store.loadLiquidPasses(capture.input.operationID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.status, .pending)
    }



    func testComparisonSnapshotFreezesCompareBoundaryAndRejectsForgedOrLaterArchives() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let store = fixture.repository()
        let image = Data("snapshot-selfie".utf8)
        let workflowID = UUID()
        let captureEvent = SavedWorkflowEvent(workflowID: workflowID, action: "selfie.captured")
        let compareEvent = SavedWorkflowEvent(workflowID: workflowID, action: "selfie.compare")
        let laterEvent = SavedWorkflowEvent(workflowID: workflowID, action: "report.copy")
        let capture = try SavedFaceCapture(input: .init(operationID: UUID(), reference: image,
            referenceSHA256: SavedPassportCapture.digest(image), selfie: image,
            selfieSHA256: SavedPassportCapture.digest(image), workflowID: workflowID))
        try await store.saveFaceCapture(capture)
        for event in [captureEvent, compareEvent, laterEvent] { try await store.appendWorkflowEvent(event) }
        let archive = try await WorkflowEvidenceArchive.load(persistence: store.comparisonEffects,
            workflowID: workflowID, through: compareEvent.id)
        let snapshot = try SavedComparisonSnapshot(capture: capture, archive: archive)
        try await store.saveComparisonSnapshot(snapshot)
        try await store.saveComparisonSnapshot(snapshot)
        let loaded = try await store.loadComparisonSnapshot(capture.input.operationID)
        let reopened = try XCTUnwrap(loaded)
        XCTAssertEqual(reopened.archive?.events.map(\.id), [captureEvent.id, compareEvent.id])
        XCTAssertEqual(try reopened.manifest(), try snapshot.manifest())
        let newCompare = SavedWorkflowEvent(workflowID: workflowID, action: "comparison.retry")
        try await store.appendWorkflowEvent(newCompare)
        let later = try await WorkflowEvidenceArchive.load(persistence: store.comparisonEffects,
            workflowID: workflowID, through: newCompare.id)
        do {
            try await store.saveComparisonSnapshot(SavedComparisonSnapshot(capture: capture, archive: later))
            XCTFail("An operation's frozen evidence boundary changed")
        } catch { }
        let fake = SavedWorkflowEvent(workflowID: workflowID, action: "selfie.compare")
        let forged = WorkflowEvidenceArchive(schemaVersion: 1, workflowID: workflowID, throughEventID: fake.id,
            events: [captureEvent, fake], truncated: false, nextSequence: 3)
        let other = try SavedFaceCapture(input: .init(operationID: UUID(), reference: image,
            referenceSHA256: SavedPassportCapture.digest(image), selfie: image,
            selfieSHA256: SavedPassportCapture.digest(image), workflowID: workflowID))
        try await store.saveFaceCapture(other)
        do {
            try await store.saveComparisonSnapshot(SavedComparisonSnapshot(capture: other, archive: forged))
            XCTFail("Invented telemetry was admitted")
        } catch { }
        let rejected = try await store.loadComparisonSnapshot(other.input.operationID)
        XCTAssertNil(rejected)
    }

    func testV4MigrationRollbackAtEveryBoundaryPreservesExactV3PassBytes() async throws {
        let boundaries: [(Int32, String)] = [(SQLITE_CREATE_TABLE, "liquid_pass_event_v4"),
            (SQLITE_INSERT, "liquid_pass_event_v4"), (SQLITE_DROP_TABLE, "liquid_pass_event"),
            (SQLITE_ALTER_TABLE, "main"), (SQLITE_CREATE_INDEX, "liquid_pass_operation"),
            (SQLITE_CREATE_TABLE, "comparison_snapshot"), (SQLITE_INSERT, "passport_schema_migrations"),
            (SQLITE_PRAGMA, "user_version"), (SQLITE_TRANSACTION, "COMMIT")]
        for (operation, name) in boundaries {
            let fixture = try CaptureStoreFixture()
            defer { fixture.remove() }
            let (capture, aura) = try await seed(fixture)
            let store = fixture.repository()
            let engine = PassEngineFixture(store: store, directory: directory)
            let request = try await request(capture: capture, aura: aura, store: store)
            let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id,
                descriptor: try await engine.describe(.quality, request))
            try await store.saveLiquidPass(pending)
            try fixture.handle().withConnection { db in
                try PassportCaptureSchema.execute(db, "DROP INDEX liquid_pass_operation")
                try PassportCaptureSchema.execute(db, "ALTER TABLE liquid_pass_event RENAME TO temporary_pass")
                try PassportCaptureSchema.execute(db, PassportCaptureSchema.passSQL)
                try PassportCaptureSchema.execute(db, "INSERT INTO liquid_pass_event SELECT * FROM temporary_pass ORDER BY rowid")
                try PassportCaptureSchema.execute(db, "DROP TABLE temporary_pass")
                try PassportCaptureSchema.execute(db, PassportCaptureSchema.passIndexSQL)
                try PassportCaptureSchema.execute(db, "DROP TABLE comparison_snapshot")
                try PassportCaptureSchema.execute(db, "DELETE FROM passport_schema_migrations WHERE version=4")
                try PassportCaptureSchema.execute(db, "PRAGMA user_version=3")
                let before = try PassportCaptureSchema.string(db, "SELECT hex(payload) FROM liquid_pass_event")
                let rule = MigrationFailureRule(operation: operation, name: name)
                let pointer = Unmanaged.passRetained(rule).toOpaque()
                defer { Unmanaged<MigrationFailureRule>.fromOpaque(pointer).release(); sqlite3_set_authorizer(db, nil, nil) }
                sqlite3_set_authorizer(db, { context, action, first, second, _, _ in
                    guard let context else { return SQLITE_OK }
                    let rule = Unmanaged<MigrationFailureRule>.fromOpaque(context).takeUnretainedValue()
                    if action == rule.operation, first.map({ String(cString: $0) }) == rule.name,
                       action != SQLITE_PRAGMA || second.map({ String(cString: $0) }) == "4" { return SQLITE_DENY }
                    return SQLITE_OK
                }, pointer)
                XCTAssertThrowsError(try PassportCaptureSchema.prepare(db), "Missing failure at \(name)")
                sqlite3_set_authorizer(db, nil, nil)
                XCTAssertEqual(try PassportCaptureSchema.integer(db, "PRAGMA user_version"), 3)
                XCTAssertEqual(try PassportCaptureSchema.integer(db, "SELECT count(*) FROM passport_schema_migrations"), 3)
                XCTAssertEqual(try PassportCaptureSchema.string(db, "SELECT hex(payload) FROM liquid_pass_event"), before)
                XCTAssertEqual(try PassportCaptureSchema.string(db, "SELECT sql FROM sqlite_master WHERE name='liquid_pass_event'"), PassportCaptureSchema.passSQL)
                try PassportCaptureSchema.prepare(db)
                XCTAssertEqual(try PassportCaptureSchema.integer(db, "PRAGMA user_version"), 4)
                XCTAssertEqual(try PassportCaptureSchema.string(db, "SELECT hex(payload) FROM liquid_pass_event"), before)
            }
        }
    }

    func testPartialTaskReportExportsPartialInsteadOfCompleted() throws {
        let input = FaceInputTelemetry(operationID: UUID(), referenceSHA256: "r", selfieSHA256: "s",
            referenceBytes: 1, selfieBytes: 1, captureContext: nil)
        let value = FaceVisualAssessmentCompletion(operationID: input.operationID, referenceSHA256: "r", selfieSHA256: "s",
            consistency: nil, issues: [], durationMilliseconds: 50,
            report: .init(summary: "Quality completed; other tasks failed", sections: []),
            aggregateStatus: .partial, completedTaskCount: 1, totalTaskCount: 5)
        let exported = try XCTUnwrap(FaceComparisonReportExport.make(input: input, phase: .completed(0.6),
            visual: .completed(value), auraTelemetry: [], duration: 1, visualDuration: 50))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
        let liquid = try XCTUnwrap(object["liquid"] as? [String: Any])
        XCTAssertEqual(liquid["status"] as? String, "partial")
        XCTAssertEqual(liquid["completedTaskCount"] as? Int, 1)
        XCTAssertEqual(liquid["totalTaskCount"] as? Int, 5)
    }

    func testV4PassRejectsSubstitutedAuraAndSnapshotBindings() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let (capture, aura) = try await seed(fixture)
        let store = fixture.repository()
        let engine = PassEngineFixture(store: store, directory: directory)
        let base = try await request(capture: capture, aura: aura, store: store)
        let substitute = FaceComparisonCompletion(operationID: capture.input.operationID,
            referenceSHA256: capture.input.referenceSHA256, selfieSHA256: capture.input.selfieSHA256,
            score: 0.99, resultSHA256: aura.aura?.resultSHA256)
        let request = LiquidPassRequest(reference: capture.input.reference, referenceSHA256: capture.input.referenceSHA256,
            selfie: capture.input.selfie, selfieSHA256: capture.input.selfieSHA256, measurements: base.measurements,
            aura: try FaceComparisonHost.auraContext(.init(source: capture.input, aura: substitute)),
            document: base.document, workflow: base.workflow, workflowSnapshotJSON: base.workflowSnapshotJSON)
        let descriptor = try await engine.describe(.comparison, request)
        do {
            try await store.saveLiquidPass(SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor))
            XCTFail("An ephemeral replacement score was admitted")
        } catch { }
        let withoutSnapshot = LiquidPassRequest(reference: capture.input.reference, referenceSHA256: capture.input.referenceSHA256,
            selfie: capture.input.selfie, selfieSHA256: capture.input.selfieSHA256, measurements: base.measurements,
            aura: base.aura, document: base.document, workflow: base.workflow)
        do {
            let missing = try await engine.describe(.quality, withoutSnapshot)
            try await store.saveLiquidPass(SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: missing))
            XCTFail("A v4 pass without its committed snapshot was admitted")
        } catch { }
        let records = try await store.loadLiquidPasses(capture.input.operationID)
        XCTAssertTrue(records.isEmpty)
    }





    func testRehashedWorkflowMeasurementAndModelProjectionSubstitutionsAreRejected() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let store = fixture.repository()
        let selfie = try admittedCapture()
        let captureContext = FaceCaptureContext(capture: selfie)
        XCTAssertTrue(captureContext.receipt.admissionValid)
        let workflowID = UUID()
        let captureEvent = SavedWorkflowEvent(workflowID: workflowID, action: "selfie.captured",
            captureID: selfie.id, imageSHA256: selfie.sha256)
        try await store.appendWorkflowEvent(captureEvent)
        let capture = try SavedFaceCapture(input: .init(operationID: UUID(), reference: selfie.encodedPNG,
            referenceSHA256: selfie.sha256, selfie: selfie.encodedPNG, selfieSHA256: selfie.sha256,
            captureContext: captureContext, workflowID: workflowID, captureEventID: captureEvent.id))
        try await store.saveFaceCapture(capture)
        let aura = SavedFaceStage(operationID: capture.input.operationID, engine: .aura, durationMilliseconds: 1,
            aura: .init(operationID: capture.input.operationID, referenceSHA256: selfie.sha256, selfieSHA256: selfie.sha256,
                score: 0.7, resultSHA256: String(repeating: "a", count: 64)))
        try await store.saveFaceStage(aura)
        let boundary = SavedWorkflowEvent(workflowID: workflowID, action: "selfie.compare")
        try await store.appendWorkflowEvent(boundary)
        let archive = try await WorkflowEvidenceArchive.load(persistence: store.comparisonEffects, workflowID: workflowID, through: boundary.id)
        try await store.saveComparisonSnapshot(SavedComparisonSnapshot(capture: capture, archive: archive))
        let request = try await request(capture: capture, aura: aura, store: store)
        let service = PassEngineFixture(store: store, directory: directory)
        let original = try await service.describe(.sensorConsistency, request)
        for change in ["workflow", "depth", "motion", "document", "modelOnly"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            var context = try XCTUnwrap(JSONSerialization.jsonObject(with: original.contextJSON) as? [String: Any])
            var model = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(original.modelInputJSON)) as? [String: Any])
            if change == "workflow" {
                var workflow = try XCTUnwrap(context["workflow"] as? [String: Any])
                workflow["motionSampleCount"] = 99999
                context["workflow"] = workflow; model["workflow"] = workflow
            } else if change == "document" {
                context["document"] = ["birthDateYYMMDD": "000101", "possibleCurrentAges": [26]]
            } else {
                var measurements = try XCTUnwrap(context["measurements"] as? [String: Any])
                measurements[change == "depth" ? "depth" : "motion"] = ["fake": 999]
                if change != "modelOnly" { context["measurements"] = measurements }
                model["measurements"] = measurements
            }
            let contextBytes = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys, .withoutEscapingSlashes])
            let modelBytes = try JSONSerialization.data(withJSONObject: model, options: [.sortedKeys, .withoutEscapingSlashes])
            object["contextJSON"] = contextBytes.base64EncodedString()
            object["contextSHA256"] = SavedPassportCapture.digest(contextBytes)
            object["modelInputJSON"] = modelBytes.base64EncodedString()
            object["modelInputSHA256"] = SavedPassportCapture.digest(modelBytes)
            let forged = try JSONDecoder().decode(LiquidPassDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
            do {
                try await store.saveLiquidPass(SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: forged))
                XCTFail("Rehashed \(change) substitution was admitted")
            } catch { }
        }
        let records = try await store.loadLiquidPasses(capture.input.operationID)
        XCTAssertTrue(records.isEmpty)
    }

    func testHistoricalSnapshotRecoveryStopsAtOriginalCompareBeforeLongTail() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let store = fixture.repository()
        let capture = try await historicalCapture(store)
        let workflowID = try XCTUnwrap(capture.input.workflowID)
        let original = SavedWorkflowEvent(workflowID: workflowID, action: "selfie.compare")
        try await store.appendWorkflowEvent(original)
        for index in 0..<64 {
            try await store.appendWorkflowEvent(SavedWorkflowEvent(workflowID: workflowID, action: "sensor.window",
                occurredAt: Date().addingTimeInterval(Double(index + 1) * 300)))
        }
        let retry = SavedWorkflowEvent(workflowID: workflowID, action: "comparison.retry")
        try await store.appendWorkflowEvent(retry)
        let observed = try await SavedComparisonSnapshot.historicalBoundary(capture: capture, persistence: store.comparisonEffects)
        do {
            try await store.saveComparisonSnapshot(SavedComparisonSnapshot(capture: capture, archive: nil,
                unavailableReason: .missingBoundary, unavailableBoundary: observed.boundary))
            XCTFail("A caller suppressed a recoverable original boundary")
        } catch { }
        let controller = FaceComparisonController(compare: { _ in throw FaceWorkflowStorageFailure.unavailable }, persistence: store.comparisonEffects)
        try await controller.freezeComparisonSnapshot(operationID: capture.input.operationID, through: retry.id, recovering: true)
        let saved = try await store.loadComparisonSnapshot(capture.input.operationID)
        XCTAssertEqual(saved?.archive?.throughEventID, original.id)
        XCTAssertEqual(saved?.archive?.events.count, 2)
        XCTAssertNil(saved?.unavailableReason)
        XCTAssertFalse(saved?.archive?.events.contains { $0.action == "sensor.window" || $0.id == retry.id } ?? true)
    }

    func testHistoricalSnapshotRecoveryDoesNotBorrowLaterRetakeComparison() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let store = fixture.repository()
        let capture = try await historicalCapture(store)
        let workflowID = try XCTUnwrap(capture.input.workflowID)
        for action in ["selfie.retake", "selfie.captured", "selfie.compare", "comparison.retry"] {
            try await store.appendWorkflowEvent(SavedWorkflowEvent(workflowID: workflowID, action: action))
        }
        let observed = try await SavedComparisonSnapshot.historicalBoundary(capture: capture, persistence: store.comparisonEffects)
        do {
            try await store.saveComparisonSnapshot(SavedComparisonSnapshot(capture: capture, archive: nil,
                unavailableReason: .missingBoundary, unavailableBoundary: observed.boundary))
            XCTFail("The wrong unavailability reason was admitted")
        } catch { }
        let controller = FaceComparisonController(compare: { _ in throw FaceWorkflowStorageFailure.unavailable }, persistence: store.comparisonEffects)
        try await controller.freezeComparisonSnapshot(operationID: capture.input.operationID, through: nil, recovering: true)
        let saved = try await store.loadComparisonSnapshot(capture.input.operationID)
        XCTAssertNil(saved?.archive)
        XCTAssertEqual(saved?.unavailableReason, .supersededCapture)
        let manifest = try XCTUnwrap(saved).manifest()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        XCTAssertNil(object["workflowID"])
        XCTAssertEqual(object["lastSequence"] as? Int, 0)
    }

    func testHistoricalSnapshotRecoveryNeverDowngradesStorageReadFailure() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let store = fixture.repository()
        let capture = try await historicalCapture(store)
        var effects = store.comparisonEffects
        effects.loadEvents = { _, _ in throw FaceWorkflowStorageFailure.unavailable }
        let controller = FaceComparisonController(compare: { _ in throw FaceWorkflowStorageFailure.unavailable }, persistence: effects)
        do {
            try await controller.freezeComparisonSnapshot(operationID: capture.input.operationID, through: nil, recovering: true)
            XCTFail("A storage failure became missing historical evidence")
        } catch { }
        let saved = try await store.loadComparisonSnapshot(capture.input.operationID)
        XCTAssertNil(saved)
    }

    func testHistoricalSnapshotRejectsActionAndTimestampMetadataCorruption() async throws {
        for mutation in ["action", "time"] {
            for alreadySaved in [false, true] {
                let fixture = try CaptureStoreFixture()
                defer { fixture.remove() }
                let store = fixture.repository()
                let capture = try await historicalCapture(store)
                let workflowID = try XCTUnwrap(capture.input.workflowID)
                let compare = SavedWorkflowEvent(workflowID: workflowID, action: "selfie.compare")
                try await store.appendWorkflowEvent(compare)
                let archive = try await WorkflowEvidenceArchive.load(persistence: store.comparisonEffects,
                    workflowID: workflowID, through: compare.id)
                let snapshot = try SavedComparisonSnapshot(capture: capture, archive: archive)
                let observed = try await SavedComparisonSnapshot.historicalBoundary(capture: capture, persistence: store.comparisonEffects)
                if alreadySaved { try await store.saveComparisonSnapshot(snapshot) }
                try fixture.handle().withConnection { db in
                    let sql = mutation == "action"
                        ? "UPDATE workflow_event SET action='selfie.retake' WHERE event_id=?"
                        : "UPDATE workflow_event SET occurred_at_ms=occurred_at_ms+1 WHERE event_id=?"
                    let query = try PassportCaptureSchema.statement(db, sql)
                    defer { sqlite3_finalize(query) }
                    try PassportCaptureSchema.bind(compare.id.uuidString, at: 1, to: query)
                    try PassportCaptureSchema.done(query)
                }
                do {
                    try await store.saveComparisonSnapshot(snapshot)
                    XCTFail("Corrupt \(mutation) metadata entered snapshot storage")
                } catch { }
                if alreadySaved {
                    do {
                        _ = try await store.loadComparisonSnapshot(capture.input.operationID)
                        XCTFail("Corrupt \(mutation) metadata survived snapshot readback")
                    } catch { }
                }
                do {
                    let unavailable = try SavedComparisonSnapshot(capture: capture, archive: nil, unavailableReason: .missingBoundary,
                        unavailableBoundary: observed.boundary)
                    try await store.saveComparisonSnapshot(unavailable)
                    XCTFail("Corrupt metadata was relabeled unavailable")
                } catch { }
            }
        }
    }

    func testUnavailableSnapshotAndPassRemainReadableAfterLaterRetake() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let store = fixture.repository()
        let capture = try await historicalCapture(store)
        let workflowID = try XCTUnwrap(capture.input.workflowID)
        let aura = SavedFaceStage(operationID: capture.input.operationID, engine: .aura, durationMilliseconds: 1,
            aura: .init(operationID: capture.input.operationID, referenceSHA256: capture.input.referenceSHA256,
                selfieSHA256: capture.input.selfieSHA256, score: 0.7, resultSHA256: String(repeating: "a", count: 64)))
        try await store.saveFaceStage(aura)
        try await store.appendWorkflowEvent(SavedWorkflowEvent(workflowID: workflowID, action: "comparison.retry"))
        let controller = FaceComparisonController(compare: { _ in throw FaceWorkflowStorageFailure.unavailable }, persistence: store.comparisonEffects)
        try await controller.freezeComparisonSnapshot(operationID: capture.input.operationID, through: nil, recovering: true)
        let loaded = try await store.loadComparisonSnapshot(capture.input.operationID)
        let before = try XCTUnwrap(loaded)
        XCTAssertEqual(before.unavailableReason, .missingBoundary)
        XCTAssertEqual(before.unavailableBoundary?.sequence, 2)
        let service = PassEngineFixture(store: store, directory: directory)
        let request = try LiquidPassEvidence.request(capture: capture, aura: aura, snapshot: before)
        let descriptor = try await service.describe(.quality, request)
        let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
        try await store.saveLiquidPass(pending)
        let result = try await service.assess(.quality, request)
        let completed = pending.completed(result)
        try await store.saveLiquidPass(completed)
        for action in ["selfie.retake", "selfie.captured", "selfie.compare"] {
            try await store.appendWorkflowEvent(SavedWorkflowEvent(workflowID: workflowID, action: action))
        }
        let after = try await store.loadComparisonSnapshot(capture.input.operationID)
        XCTAssertEqual(after?.unavailableReason, .missingBoundary)
        XCTAssertEqual(after?.unavailableBoundary, before.unavailableBoundary)
        XCTAssertEqual(try after?.manifest(), try before.manifest())
        let passes = try await store.loadLiquidPasses(capture.input.operationID)
        XCTAssertEqual(passes.map(\.id), [pending.id, completed.id])
        XCTAssertEqual(passes.last?.result?.contextSHA256, descriptor.contextSHA256)
    }

#if DEBUG


    func testDebugDiagnosticsSharedLiveStoreExportsAfterDeleteAndRecaptureWithoutRestart() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let (oldCapture, _) = try await seed(fixture)
        let shared = fixture.repository()
        let obsolete = fixture.repository()
        _ = try await obsolete.latestFaceCaptureID()
        let folder = fixture.directory.appendingPathComponent("diagnostics", isDirectory: true)
        let diagnostics = try DebugComparisonDiagnostics.live(persistence: shared.comparisonEffects, directory: folder)
        try await diagnostics.processNextRequest()
        try diagnosticRequest(folder, id: UUID())
        try await diagnostics.processNextRequest()
        XCTAssertEqual(try diagnosticResponse(folder)["operationID"] as? String, oldCapture.input.operationID.uuidString)
        try await shared.delete()
        try DebugComparisonDiagnostics.eraseExports(directory: folder)
        let (newCapture, _) = try await seed(fixture)
        XCTAssertNotEqual(newCapture.input.operationID, oldCapture.input.operationID)
        try diagnosticRequest(folder, id: UUID())
        try await diagnostics.processNextRequest()
        let response = try diagnosticResponse(folder)
        XCTAssertEqual(response["status"] as? String, "completed")
        XCTAssertEqual(response["operationID"] as? String, newCapture.input.operationID.uuidString)
        do { _ = try await obsolete.latestFaceCaptureID(); XCTFail("An independent stale owner was revived") }
        catch ProtectedStoreLifecycleError.staleHandle { }
    }



    func testDebugDiagnosticsRejectsMalformedStaleOversizeAndPathRequestsBeforeLease() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let folder = fixture.directory.appendingPathComponent("diagnostics", isDirectory: true)
        let lease = DiagnosticLeaseProbe()
        let diagnostics = DebugComparisonDiagnostics(directory: folder, persistence: .unavailable,
            lease: { work in try await lease.run(work) })
        try await diagnostics.processNextRequest()
        for mutation in ["unknown", "path", "boolean", "malformed", "stale", "oversized"] {
            let id = UUID()
            var request: [String: Any] = ["version": 1, "requestID": id.uuidString]
            if mutation == "unknown" { request["outputPath"] = "../../leak.json" }
            if mutation == "path" { request["operationID"] = "../../passport.sqlite" }
            if mutation == "boolean" { request["version"] = true }
            let bytes: Data
            if mutation == "malformed" { bytes = Data("{broken".utf8) }
            else if mutation == "oversized" { bytes = Data(repeating: 32, count: DebugComparisonDiagnostics.maximumRequestBytes + 1) }
            else { bytes = try JSONSerialization.data(withJSONObject: request) }
            try bytes.write(to: folder.appendingPathComponent("request.json"), options: .atomic)
            if mutation == "stale" {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)],
                    ofItemAtPath: folder.appendingPathComponent("request.json").path)
            }
            try await diagnostics.processNextRequest()
            let response = try diagnosticResponse(folder)
            let expected = mutation == "stale" ? "request_stale" : mutation == "oversized" ? "request_too_large" : "request_invalid"
            XCTAssertEqual(response["errorCode"] as? String, expected, mutation)
            XCTAssertNil(response["report"])
        }
        let calls = await lease.calls
        XCTAssertEqual(calls, 0)
    }

    func testDebugDiagnosticsRejectsRequestSymlinkWithoutReadingTarget() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let folder = fixture.directory.appendingPathComponent("diagnostics", isDirectory: true)
        let diagnostics = DebugComparisonDiagnostics(directory: folder, persistence: .unavailable)
        try await diagnostics.processNextRequest()
        let privateFile = fixture.directory.appendingPathComponent("private.json")
        let sentinel = "private-target-must-not-be-read"
        try Data(sentinel.utf8).write(to: privateFile)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("request.json"), withDestinationURL: privateFile)
        try await diagnostics.processNextRequest()
        let response = try diagnosticResponse(folder)
        XCTAssertEqual(response["errorCode"] as? String, "file_unsafe")
        XCTAssertFalse(String(decoding: try Data(contentsOf: folder.appendingPathComponent("response.json")), as: UTF8.self).contains(sentinel))
        XCTAssertEqual(try String(contentsOf: privateFile, encoding: .utf8), sentinel)
    }

    func testDebugDiagnosticsCancellationSettlesOneExportWithoutPublishingAndCanRetry() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        _ = try await seed(fixture)
        let folder = fixture.directory.appendingPathComponent("diagnostics", isDirectory: true)
        let gate = PassProgressGate()
        let lease = DiagnosticLeaseProbe()
        let diagnostics = DebugComparisonDiagnostics(directory: folder, persistence: fixture.repository().comparisonEffects,
            lease: { work in try await lease.run { await gate.hold(); try Task.checkCancellation(); return try await work() } })
        try await diagnostics.processNextRequest()
        try diagnosticRequest(folder, id: UUID())
        let task = Task { try await diagnostics.processNextRequest() }
        while !(await gate.entered) { await Task.yield() }
        try await diagnostics.processNextRequest() // The same actor cannot admit a duplicate export.
        task.cancel()
        await gate.release()
        do { try await task.value; XCTFail("Cancelled export returned success") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("response.json").path))
        let calls = await lease.calls
        let maximum = await lease.maximumActive
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(maximum, 1)
        // A new foreground worker can retry the same request after cancellation.
        let resumed = DebugComparisonDiagnostics(directory: folder, persistence: fixture.repository().comparisonEffects,
            lease: { work in try await lease.run(work) })
        try await resumed.processNextRequest()
        XCTAssertEqual(try diagnosticResponse(folder)["status"] as? String, "completed")
    }

    func testDebugDiagnosticsOrphanPendingIsReconciliationEvidenceNotLiveInference() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let (capture, aura) = try await seed(fixture)
        let store = fixture.repository()
        let engine = PassEngineFixture(store: store, directory: directory)
        let input = try await request(capture: capture, aura: aura, store: store)
        let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id,
            descriptor: try await engine.describe(.quality, input))
        try await store.saveLiquidPass(pending)
        let folder = fixture.directory.appendingPathComponent("diagnostics", isDirectory: true)
        let diagnostics = DebugComparisonDiagnostics(directory: folder, persistence: store.comparisonEffects)
        try await diagnostics.processNextRequest()
        try diagnosticRequest(folder, id: UUID())
        try await diagnostics.processNextRequest()
        let report = try XCTUnwrap(try diagnosticResponse(folder)["report"] as? [String: Any])
        let observation = try XCTUnwrap(report["diagnosticObservation"] as? [String: Any])
        XCTAssertEqual(observation["inferenceActive"] as? Bool, false)
        XCTAssertEqual(observation["reconciliationRequired"] as? Bool, true)
        XCTAssertEqual(observation["unresolvedPendingAttemptCount"] as? Int, 1)
        XCTAssertNotEqual((report["liquid"] as? [String: Any])?["status"] as? String, "processing")
        let stored = try await store.loadLiquidPasses(capture.input.operationID)
        XCTAssertEqual(stored.map(\.id), [pending.id])
        XCTAssertEqual(stored.first?.status, .pending)
    }



    func testDebugDiagnosticsRechecksFreshnessAfterWaitingForInferenceLease() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let folder = fixture.directory.appendingPathComponent("diagnostics", isDirectory: true)
        let gate = PassProgressGate()
        let clock = DiagnosticTestClock()
        let diagnostics = DebugComparisonDiagnostics(directory: folder, persistence: .unavailable,
            lease: { work in await gate.hold(); return try await work() }, now: { clock.read() })
        try await diagnostics.processNextRequest()
        try diagnosticRequest(folder, id: UUID())
        let task = Task { try await diagnostics.processNextRequest() }
        while !(await gate.entered) { await Task.yield() }
        clock.advance(601)
        await gate.release()
        try await task.value
        XCTAssertEqual(try diagnosticResponse(folder)["errorCode"] as? String, "request_stale")
    }

    func testDebugDiagnosticsRejectsOversizedCommittedReportWithBoundedError() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let (capture, aura) = try await seed(fixture)
        let store = fixture.repository()
        let engine = PassEngineFixture(store: store, directory: directory)
        let input = try await request(capture: capture, aura: aura, store: store)
        let descriptor = try await engine.describe(.quality, input)
        var records: [SavedLiquidPass] = []
        for _ in 0..<512 {
            let pending = SavedLiquidPass(operationID: capture.input.operationID, auraID: aura.id, descriptor: descriptor)
            records += [pending, pending.failed(.init(reason: .deadline, rawOutput: String(repeating: "x", count: 32768)), code: "deadline")]
        }
        try fixture.handle().withConnection { try insertPassRecords(records, db: $0) }
        let folder = fixture.directory.appendingPathComponent("diagnostics", isDirectory: true)
        let diagnostics = DebugComparisonDiagnostics(directory: folder, persistence: store.comparisonEffects)
        try await diagnostics.processNextRequest()
        let requestID = UUID()
        try diagnosticRequest(folder, id: requestID)
        try await diagnostics.processNextRequest()
        let response = try diagnosticResponse(folder)
        XCTAssertEqual(response["requestID"] as? String, requestID.uuidString)
        XCTAssertEqual(response["errorCode"] as? String, "report_too_large")
        XCTAssertTrue(response["report"] == nil, "An oversized export must contain only its bounded error")
        XCTAssertLessThan(try Data(contentsOf: folder.appendingPathComponent("response.json")).count, 1024)
    }

    func testDebugDiagnosticsEraseWaitsForExportLeaseAndLeavesNoReport() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        _ = try await seed(fixture)
        let folder = fixture.directory.appendingPathComponent("diagnostics", isDirectory: true)
        let scheduler = FaceInferenceScheduler()
        let gate = PassProgressGate()
        let diagnostics = DebugComparisonDiagnostics(directory: folder, persistence: fixture.repository().comparisonEffects,
            lease: { work in try await scheduler.run { await gate.hold(); return try await work() } })
        try await diagnostics.processNextRequest()
        try diagnosticRequest(folder, id: UUID())
        let exporting = Task { try await diagnostics.processNextRequest() }
        while !(await gate.entered) { await Task.yield() }
        let erasing = Task { try await scheduler.run { try DebugComparisonDiagnostics.eraseExports(directory: folder) } }
        while await scheduler.queuedCount == 0 { await Task.yield() }
        await gate.release()
        try await exporting.value
        try await erasing.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("response.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("request.json").path))
    }

    func testDebugDiagnosticsExpiresAndErasesProtectedExports() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        _ = try await seed(fixture)
        let folder = fixture.directory.appendingPathComponent("diagnostics", isDirectory: true)
        let diagnostics = DebugComparisonDiagnostics(directory: folder, persistence: fixture.repository().comparisonEffects)
        try await diagnostics.processNextRequest()
        try diagnosticRequest(folder, id: UUID())
        try await diagnostics.processNextRequest()
        let response = folder.appendingPathComponent("response.json")
        XCTAssertEqual(try response.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: response.path)
        try await diagnostics.processNextRequest()
        XCTAssertFalse(FileManager.default.fileExists(atPath: response.path))
        try DebugComparisonDiagnostics.eraseExports(directory: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("request.json").path))
    }

    private func diagnosticRequest(_ folder: URL, id: UUID, operationID: String? = nil) throws {
        var object: [String: Any] = ["version": 1, "requestID": id.uuidString]
        if let operationID { object["operationID"] = operationID }
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("request.json"), options: .atomic)
    }

    private func diagnosticResponse(_ folder: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("response.json"))) as? [String: Any])
    }
#endif

    private func insertPassRecords(_ records: [SavedLiquidPass], db: OpaquePointer) throws {
        try PassportCaptureSchema.execute(db, "BEGIN IMMEDIATE")
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        for event in records {
            let data = try encoder.encode(event)
            let query = try PassportCaptureSchema.statement(db, "INSERT INTO liquid_pass_event VALUES(?,?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(query) }
            for (offset, text) in [event.id.uuidString, event.attemptID.uuidString, event.operationID.uuidString,
                event.auraID.uuidString, event.descriptor.task.rawValue, event.status.rawValue].enumerated() {
                try PassportCaptureSchema.bind(text, at: Int32(offset + 1), to: query)
            }
            try PassportCaptureSchema.check(sqlite3_bind_int64(query, 7, Int64(event.recordedAt.timeIntervalSince1970 * 1000)))
            try PassportCaptureSchema.bind(SavedPassportCapture.digest(data), at: 8, to: query)
            try PassportCaptureSchema.check(data.withUnsafeBytes {
                sqlite3_bind_blob(query, 9, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            })
            try PassportCaptureSchema.done(query)
        }
        try PassportCaptureSchema.execute(db, "COMMIT")
    }

    private func historicalCapture(_ store: PassportCaptureStore) async throws -> SavedFaceCapture {
        let selfie = try admittedCapture()
        let workflowID = UUID()
        let event = SavedWorkflowEvent(workflowID: workflowID, action: "selfie.captured", captureID: selfie.id, imageSHA256: selfie.sha256)
        try await store.appendWorkflowEvent(event)
        let capture = try SavedFaceCapture(input: .init(operationID: UUID(), reference: selfie.encodedPNG,
            referenceSHA256: selfie.sha256, selfie: selfie.encodedPNG, selfieSHA256: selfie.sha256,
            captureContext: FaceCaptureContext(capture: selfie), workflowID: workflowID, captureEventID: event.id))
        try await store.saveFaceCapture(capture)
        return capture
    }

    private func admittedCapture() throws -> CapturedSelfie {
        // Same explicit engineering policy and frame/depth bindings used by telemetryCapture
        // in FaceComparisonControllerTests; the camera-only fixture intentionally is not admitted.
        let source = try CaptureTestFixtures.capture()
        var receipt = SelfieAdmissionReceipt(policyVersion: SelfieAdmissionPolicy.version, trigger: .manual,
            frameTimestamp: 1, anchorID: UUID(), consecutiveTrackedFrames: 12, blinkCompletedAt: 0.5, blinkAge: 0.55,
            leftEyeClosed: 0.1, rightEyeClosed: 0.2, eyesOpen: true, steadyHoldDuration: 1.2,
            captureQuality: 0.73, captureQualityEnforced: false, insideGuide: true, guideContainmentEnforced: false)
        receipt.effectivePolicy = .engineeringV1
        receipt.frameEvidence = SelfieFrameEvidence(sessionID: UUID(), sequence: 4, guideRevision: 2,
            pixelWidth: 1, pixelHeight: 1, orientation: 1, qualityRevision: 1, analysisDuration: 0.02, frameAgeAtAdmission: 0.05)
        receipt.depthEvidence = SelfieDepthEvidence(schemaVersion: 1,
            measurement: .init(policy: .engineeringV1, sampleCount: 128, residualRMS: 0.012), imageTimestamp: 1,
            depthTimestamp: 1, orientation: 1, mapWidth: 16, mapHeight: 16, filtered: false,
            ageAtAdmission: 0.05 + receipt.frameTimestamp - 1, imageSHA256: source.sha256)
        return CapturedSelfie(encodedPNG: source.encodedPNG, admissionReceipt: receipt)
    }

    private func request(capture: SavedFaceCapture, aura: SavedFaceStage, store: PassportCaptureStore) async throws -> LiquidPassRequest {
        let loaded = try await store.loadComparisonSnapshot(capture.input.operationID)
        return try LiquidPassEvidence.request(capture: capture, aura: aura, snapshot: XCTUnwrap(loaded))
    }

    private func seed(_ fixture: CaptureStoreFixture) async throws -> (SavedFaceCapture, SavedFaceStage) {
        let passport = try CaptureStoreFixture.capture()
        let reference = try XCTUnwrap(passport.nfc.portrait)
        let selfie = Data("synthetic-pass-selfie".utf8)
        let capture = try SavedFaceCapture(input: .init(operationID: UUID(), reference: reference,
            referenceSHA256: SavedPassportCapture.digest(reference), selfie: selfie,
            selfieSHA256: SavedPassportCapture.digest(selfie), passport: passport))
        let aura = SavedFaceStage(operationID: capture.input.operationID, engine: .aura, durationMilliseconds: 1,
            aura: .init(operationID: capture.input.operationID, referenceSHA256: capture.input.referenceSHA256,
                selfieSHA256: capture.input.selfieSHA256, score: 0.7, resultSHA256: String(repeating: "a", count: 64)))
        try await fixture.repository().saveFaceCapture(capture)
        try await fixture.repository().saveFaceStage(aura)
        try await fixture.repository().saveComparisonSnapshot(SavedComparisonSnapshot(capture: capture, archive: nil))
        return (capture, aura)
    }
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contracts")
    }
}

private actor PassEngineFixture {
    let store: PassportCaptureStore
    let engine: ArchiveDescriptorFixture
    var failQualityOnce: Bool
    private var invoked: [LiquidEvidencePass] = []
    private var released = 0
    init(store: PassportCaptureStore, directory: URL, failQualityOnce: Bool = false) {
        self.store = store; engine = .init(modelDirectory: directory.appendingPathComponent("unused"), contractDirectory: directory)
        self.failQualityOnce = failQualityOnce
    }

    func describe(_ pass: LiquidEvidencePass, _ input: LiquidPassRequest) async throws -> LiquidPassDescriptor {
        try await engine.describe(pass: pass, request: input)
    }
    func assess(_ pass: LiquidEvidencePass, _ input: LiquidPassRequest) async throws -> LiquidPassResult {
        let operation = try await store.latestFaceCaptureID()
        guard let operation else { throw FaceWorkflowStorageFailure.missingRecord }
        let records = try await store.loadLiquidPasses(operation)
        guard records.contains(where: { $0.status == .pending && $0.descriptor.task == pass }) else {
            throw FaceWorkflowStorageFailure.missingRecord
        }
        invoked.append(pass)
        if pass == .quality, failQualityOnce {
            failQualityOnce = false
            throw LiquidPassFailure(reason: .tokenLimit, rawOutput: "partial", promptTokens: 100, generatedTokens: 384)
        }
        let descriptor = try await describe(pass, input)
        var output: [String: Any] = ["summary": pass.rawValue, "observations": ["Synthetic observation"], "limitations": []]
        switch pass {
        case .quality: output["issues"] = [] as [String]
        case .comparison: output["auraRelationship"] = "supports"
        case .age: output["referenceAgeRange"] = [40, 60]; output["selfieAgeRange"] = [40, 60]
        case .presentation, .sensorConsistency: output["indicators"] = [] as [String]
        }
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        let result: [String: Any] = ["pass": pass.rawValue, "profileID": descriptor.profileID,
            "artifactSHA256": descriptor.artifactSHA256, "promptContractSHA256": descriptor.promptContractSHA256,
            "referenceSHA256": input.referenceSHA256, "selfieSHA256": input.selfieSHA256,
            "contextSHA256": descriptor.contextSHA256, "promptSHA256": descriptor.promptSHA256,
            "schemaSHA256": descriptor.schemaSHA256, "outputJSON": bytes.base64EncodedString(), "report": output,
            "durationMilliseconds": 1, "promptTokens": 100, "generatedTokens": 30, "peakMemoryBytes": 10000]
        return try JSONDecoder().decode(LiquidPassResult.self, from: JSONSerialization.data(withJSONObject: result))
    }
    func release() { released += 1 }
    func calls() -> [LiquidEvidencePass] { invoked }
    func releases() -> Int { released }
}

private actor PassProgressGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class MigrationFailureRule {
    let operation: Int32
    let name: String
    init(operation: Int32, name: String) { self.operation = operation; self.name = name }
}

private final class PassHistoryReadCounts {
    var tables: [String: Int] = [:]
    var statements: [String] = []
    func record(_ table: String) { tables[table, default: 0] += 1 }
    func statement(_ sql: String) { statements.append(sql) }
}

private actor CleanupFailureProbe {
    private(set) var releases = 0
    private(set) var assessments = 0
    func assess() throws -> LiquidPassResult {
        assessments += 1
        throw FaceWorkflowStorageFailure.invalidRecord
    }
    func release() throws {
        releases += 1
        throw FaceWorkflowStorageFailure.conflict
    }
}

#if DEBUG
private actor DiagnosticLeaseProbe {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    func run(_ work: @Sendable () async throws -> Data) async throws -> Data {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        return try await work()
    }
}
#endif

#if DEBUG
private final class DiagnosticTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}
#endif
