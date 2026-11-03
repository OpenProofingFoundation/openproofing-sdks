import Foundation
@_spi(StorageAdapter) @_spi(StorageTestFixture) import KenshikiProtectedStorage
import SQLCipher
@testable import KenshikiReference
import XCTest

@MainActor final class FaceWorkflowPersistenceTests: XCTestCase {


    func testV1MigrationFailureAtEveryNewTablePreservesPassportAndRetries() async throws {
        for table in ["face_capture", "face_stage", "workflow_event"] {
            let fixture = try CaptureStoreFixture()
            defer { fixture.remove() }
            let original = try CaptureStoreFixture.capture()
            try await fixture.repository().save(original)
            try fixture.handle().withConnection { db in
                try PassportCaptureSchema.execute(db, "DROP TABLE comparison_snapshot")
                try PassportCaptureSchema.execute(db, "DROP TABLE liquid_pass_event")
                try PassportCaptureSchema.execute(db, "DROP TABLE workflow_event")
                try PassportCaptureSchema.execute(db, "DROP TABLE face_stage")
                try PassportCaptureSchema.execute(db, "DROP TABLE face_capture")
                try PassportCaptureSchema.execute(db, "DELETE FROM passport_schema_migrations WHERE version>=2")
                try PassportCaptureSchema.execute(db, "PRAGMA user_version=1")
                let name = strdup(table)
                defer { free(name); sqlite3_set_authorizer(db, nil, nil) }
                sqlite3_set_authorizer(db, { context, operation, name, _, _, _ in
                    guard operation == SQLITE_CREATE_TABLE, let context, let name else { return SQLITE_OK }
                    return strcmp(context.assumingMemoryBound(to: CChar.self), name) == 0 ? SQLITE_DENY : SQLITE_OK
                }, name)
                XCTAssertThrowsError(try PassportCaptureSchema.prepare(db))
                sqlite3_set_authorizer(db, nil, nil)
                XCTAssertEqual(try PassportCaptureSchema.integer(db, "PRAGMA user_version"), 1)
                XCTAssertEqual(try PassportCaptureSchema.integer(db, "SELECT count(*) FROM passport_schema_migrations"), 1)
                XCTAssertEqual(try PassportCaptureSchema.integer(db, "SELECT count(*) FROM sqlite_master WHERE name IN ('face_capture','face_stage','workflow_event')"), 0)
                XCTAssertEqual(try PassportCaptureSchema.string(db, "SELECT capture_id FROM passport_checkpoint"), original.id.uuidString)
            }
            let restored = try await fixture.repository().load()
            XCTAssertEqual(try restored?.encoded(), try original.encoded())
            try fixture.handle().withConnection { db in
                XCTAssertEqual(try PassportCaptureSchema.integer(db, "PRAGMA user_version"), PassportCaptureSchema.currentVersion)
            }
        }
    }

    func testCaptureAndStageRetriesAreIdempotentAndReopenPreservesEvidence() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let record = try capture()
        let repository = fixture.repository()
        try await repository.saveFaceCapture(record)
        try await repository.saveFaceCapture(record)
        let aura = stage(record, score: 0.72)
        try await repository.saveFaceStage(aura)
        try await repository.saveFaceStage(aura)
        let reopened = fixture.repository()
        let saved = try await reopened.loadFaceCapture(record.input.operationID)
        let result = try await reopened.loadFaceStage(record.input.operationID, engine: .aura)
        XCTAssertEqual(saved.input.reference, record.input.reference)
        XCTAssertEqual(saved.input.selfie, record.input.selfie)
        XCTAssertEqual(result?.id, aura.id)
        try fixture.handle().withConnection { db in
            XCTAssertEqual(try PassportCaptureSchema.integer(db, "SELECT count(*) FROM face_capture"), 1)
            XCTAssertEqual(try PassportCaptureSchema.integer(db, "SELECT count(*) FROM face_stage"), 1)
        }
    }

    func testChangedCaptureAndCrossPairAuraAreRejectedWithoutReplacingOriginal() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let original = try capture()
        try await repository.saveFaceCapture(original)
        let changed = try capture(id: original.input.operationID, marker: "substituted")
        await refuses { try await repository.saveFaceCapture(changed) }
        let other = try capture()
        try await repository.saveFaceCapture(other)
        let forged = SavedFaceStage(operationID: original.input.operationID, engine: .aura,
            durationMilliseconds: 2, aura: completion(other, score: 0.7))
        await refuses { try await repository.saveFaceStage(forged) }
        let saved = try await repository.loadFaceCapture(original.input.operationID)
        XCTAssertEqual(saved.input.selfie, original.input.selfie)
        let missing = try await repository.loadFaceStage(original.input.operationID, engine: .aura)
        XCTAssertNil(missing)
    }





    func testCorruptParentAndStageTimestampCannotBeReadAsValid() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let record = try capture()
        let repository = fixture.repository()
        try await repository.saveFaceCapture(record)
        try await repository.saveFaceStage(stage(record, score: 0.7))
        try fixture.handle().withConnection { db in
            try PassportCaptureSchema.execute(db, "UPDATE face_stage SET recorded_at_ms=1")
        }
        await refuses { _ = try await repository.loadFaceStage(record.input.operationID, engine: .aura) }
    }

    func testCancelledAuraRetainsCompletedOutcomeWithoutPublishingAndResumeReusesIt() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let record = try capture()
        let repository = fixture.repository()
        try await repository.saveFaceCapture(record)
        let held = HeldAuraOutcome(value: completion(record, score: 0.73))
        let pipeline = FaceWorkflowPipeline(persistence: repository.comparisonEffects,
            compare: { _ in try await held.run() })
        let task = Task { try await pipeline.runAura(record.input) }
        try await waitForAura(held)
        task.cancel()
        await held.finish()
        do { _ = try await task.value; XCTFail("Cancelled caller must not publish an outcome") }
        catch is CancellationError { }
        let stored = try await fixture.repository().loadFaceStage(record.input.operationID, engine: .aura)
        let completed = try XCTUnwrap(stored?.aura)
        XCTAssertEqual(completed.score, 0.73)
        let resumed = try await pipeline.runAura(record.input)
        XCTAssertEqual(resumed.score, 0.73)
        let calls = await held.calls
        XCTAssertEqual(calls, 1)
    }

    func testCancelledAuraPersistsInterruptionWhenEngineThrows() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let record = try capture()
        let repository = fixture.repository()
        try await repository.saveFaceCapture(record)
        let held = HeldAuraOutcome(value: completion(record, score: 0.73), throwsCancellation: true)
        let pipeline = FaceWorkflowPipeline(persistence: repository.comparisonEffects,
            compare: { _ in try await held.run() })
        let task = Task { try await pipeline.runAura(record.input) }
        try await waitForAura(held)
        task.cancel()
        await held.finish()
        do { _ = try await task.value; XCTFail("Cancelled caller must not publish an outcome") }
        catch is CancellationError { }
        let stored = try await fixture.repository().loadFaceStage(record.input.operationID, engine: .aura)
        XCTAssertNil(stored?.aura)
        XCTAssertEqual(stored?.errorCode, "comparison.error.interrupted")
    }

    func testCancelledAuraCommitCannotResurrectErasedStore() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let record = try capture()
        let repository = fixture.repository()
        try await repository.saveFaceCapture(record)
        let held = HeldAuraOutcome(value: completion(record, score: 0.73))
        let pipeline = FaceWorkflowPipeline(persistence: repository.comparisonEffects,
            compare: { _ in try await held.run() })
        let task = Task { try await pipeline.runAura(record.input) }
        try await waitForAura(held)
        task.cancel()
        try await repository.delete()
        await held.finish()
        await refuses { _ = try await task.value }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
        let restored = try await fixture.repository().latestFaceCaptureID()
        XCTAssertNil(restored)
    }

    private func waitForAura(_ held: HeldAuraOutcome) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await held.calls == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let started = await held.calls
        XCTAssertEqual(started, 1)
    }

    private func capture(id: UUID = UUID(), marker: String = "original") throws -> SavedFaceCapture {
        let passport = try CaptureStoreFixture.capture()
        let reference = try XCTUnwrap(passport.nfc.portrait)
        let selfie = Data(("synthetic-selfie-private-" + marker).utf8)
        return try SavedFaceCapture(input: FaceComparisonInput(operationID: id, reference: reference,
            referenceSHA256: SavedPassportCapture.digest(reference), selfie: selfie,
            selfieSHA256: SavedPassportCapture.digest(selfie), passport: passport, workflowID: UUID()))
    }

    private func completion(_ record: SavedFaceCapture, score: Double) -> FaceComparisonCompletion {
        FaceComparisonCompletion(operationID: record.input.operationID,
            referenceSHA256: record.input.referenceSHA256, selfieSHA256: record.input.selfieSHA256,
            score: score, resultSHA256: String(repeating: "a", count: 64))
    }

    private func stage(_ record: SavedFaceCapture, score: Double) -> SavedFaceStage {
        SavedFaceStage(operationID: record.input.operationID, engine: .aura,
            durationMilliseconds: 1, aura: completion(record, score: score))
    }

    private func refuses(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected rejection") } catch { }
    }
}

private actor HeldAuraOutcome {
    let value: FaceComparisonCompletion
    let throwsCancellation: Bool
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(value: FaceComparisonCompletion, throwsCancellation: Bool = false) {
        self.value = value; self.throwsCancellation = throwsCancellation
    }
    func run() async throws -> FaceComparisonCompletion {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        if throwsCancellation { throw CancellationError() }
        return value
    }
    func finish() { continuation?.resume(); continuation = nil }
}

private actor WorkflowEngineProbe {
    private var auraCalls = 0
    private var liquidScore: Double?
    func aura(_ input: FaceComparisonInput) -> FaceComparisonCompletion {
        auraCalls += 1
        return .init(operationID: input.operationID, referenceSHA256: input.referenceSHA256,
            selfieSHA256: input.selfieSHA256, score: 0.5, resultSHA256: String(repeating: "b", count: 64))
    }
    func liquid(_ input: FaceVisualAssessmentInput) -> FaceVisualAssessmentCompletion {
        liquidScore = input.aura?.score
        return .init(operationID: input.operationID, referenceSHA256: input.referenceSHA256,
            selfieSHA256: input.selfieSHA256, consistency: nil, issues: [], durationMilliseconds: 2,
            report: .init(summary: "Synthetic assessment", sections: []))
    }
    func observed() -> (auraCalls: Int, liquidScore: Double?) { (auraCalls, liquidScore) }
}
