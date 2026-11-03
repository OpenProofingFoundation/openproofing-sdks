import Foundation
@_spi(StorageTestFixture) import KenshikiProtectedStorage
@testable import KenshikiReference
import XCTest

@MainActor final class StorageHealthTests: XCTestCase {
    func testDocumentPhaseTraceIsBoundedAndContainsOnlyPhaseAndPresenceFacts() throws {
        var published = Data()
        let diagnostics = DocumentFlowDiagnostics { published = $0 }
        for _ in 0..<70 {
            diagnostics.record(phase: .back, persistence: .saved, failure: nil, hasFront: true, hasBack: false)
        }
        let entries = try JSONDecoder().decode([DocumentFlowDiagnostics.Entry].self, from: published)
        XCTAssertEqual(entries.count, 64)
        XCTAssertEqual(entries.first?.sequence, 7)
        XCTAssertEqual(entries.last?.sequence, 70)
        XCTAssertEqual(entries.last?.phase, "back")
        XCTAssertEqual(entries.last?.persistence, "saved")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: published) as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(encoded.last).keys),
            Set(["sequence", "phase", "persistence", "hasFront", "hasBack"]))
        XCTAssertLessThan(published.count, 16_384)
    }

    func testDocumentTraceWriteFailureCannotInterruptCaptureState() {
        let diagnostics = DocumentFlowDiagnostics { _ in throw CocoaError(.fileWriteOutOfSpace) }
        diagnostics.record(phase: .failure, persistence: .saving, failure: .storageSave, hasFront: false, hasBack: false)
        XCTAssertEqual(diagnostics.entries.last?.phase, "failure")
        XCTAssertEqual(diagnostics.entries.last?.failure, "storageSave")
    }

    func testTrustedBaseAliasCanonicalizesWithoutResolvingAnUntrustedChild() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trusted = root.appendingPathComponent("trusted")
        let alias = root.appendingPathComponent("os-alias")
        try FileManager.default.createDirectory(at: trusted, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: trusted)
        let url = PassportCaptureStore.databaseURL(applicationSupportRoot: alias)
        XCTAssertEqual(url, trusted.appendingPathComponent("PassportCheckpoint/passport.sqlite"))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let retained = Data("synthetic retained ciphertext".utf8)
        let outsideDatabase = outside.appendingPathComponent("passport.sqlite")
        try retained.write(to: outsideDatabase)
        try FileManager.default.createSymbolicLink(at: trusted.appendingPathComponent("PassportCheckpoint"), withDestinationURL: outside)
        XCTAssertEqual(PassportCaptureStore.databaseURL(applicationSupportRoot: alias), url)
        let identity = try StoreKeyIdentity(applicationID: "synthetic.storage", storeID: "root-test",
            purpose: "fixture", keychainAccessGroup: "TEST.synthetic.storage", accessPolicy: .identityWhenUnlocked)
        XCTAssertThrowsError(try ProtectedSQLiteStore.testing(databaseURL: url, identity: identity,
            key: Data(repeating: 7, count: 32))) { error in
            XCTAssertEqual(error as? ProtectedSQLiteError, .invalidLocation)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["passport.sqlite"])
        XCTAssertEqual(try Data(contentsOf: outsideDatabase), retained)
    }

    func testFailedConstructionRetriesOnceAndSharesRecoveredStoreAcrossBothPorts() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let saved = try CaptureStoreFixture.capture()
        let repository = fixture.repository()
        try await repository.save(saved)
        let before = try Data(contentsOf: fixture.url)
        let factory = RetryStoreFactory(store: repository)
        let provider = PassportCaptureStoreProvider { try await factory.make() }
        var reports: [StorageHealthReport] = []
        let diagnostics = StorageHealthDiagnostics { reports.append(try JSONDecoder().decode(StorageHealthReport.self, from: $0)) }
        let controller = PassportFaceJourneyController(
            comparison: FaceComparisonController(compare: { _ in throw FaceVisualAssessmentFailure.engine }),
            persistence: provider.effects, comparisonPersistence: provider.comparisonEffects)
        controller.onStorageHealthChange = { diagnostics.record(stage: $0, error: $1) }
        try await wait { controller.storageState == .failed }
        XCTAssertEqual(reports.last?.stage, .constructing)
        XCTAssertEqual(reports.last?.failure?.family, "keyCustody")
        XCTAssertEqual(reports.last?.failure?.status, -25308)
        controller.send(.retryStorage)
        try await wait { controller.storageState == .ready }
        XCTAssertEqual(controller.savedPassport?.id, saved.id)
        XCTAssertEqual(reports.last?.stage, .ready)
        XCTAssertNil(reports.last?.failure)
        let comparison = try await provider.comparisonEffects.latestCaptureID()
        XCTAssertNil(comparison)
        let passport = try await provider.effects.load()
        XCTAssertEqual(passport?.id, saved.id)
        let attempts = await factory.attempts
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    func testConcurrentPortsCoalesceConstructionAndKeepOneOwner() async throws {
        let repository = PassportCaptureStore(exists: { false },
            open: { _ in throw PassportCaptureStorageFailure.unavailable }, erase: {})
        let factory = SuccessfulStoreFactory(store: repository)
        let provider = PassportCaptureStoreProvider { await factory.make() }
        async let passport = provider.effects.load()
        async let comparison = provider.comparisonEffects.latestCaptureID()
        let values = try await (passport, comparison)
        XCTAssertNil(values.0)
        XCTAssertNil(values.1)
        let attempts = await factory.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testCorruptRetainedStorageFailureNeverErasesOrReplacesItsFiles() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let retained = Data("synthetic unreadable ciphertext to preserve".utf8)
        try retained.write(to: fixture.url)
        let provider = PassportCaptureStoreProvider { fixture.repository() }
        do { _ = try await provider.effects.load(); XCTFail("Corrupt retained store was accepted") }
        catch { XCTAssertEqual(error as? ProtectedStoreLifecycleError, .invalidLifecycle) }
        XCTAssertEqual(try Data(contentsOf: fixture.url), retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path + ".lifecycle"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path + ".encrypted-staging"))
    }

    func testStartupReportIdentifiesMRZFailureWithoutPretendingPassportLoadFailed() async throws {
        let persistence = PassportCapturePersistence(load: { nil }, save: { _ in }, delete: {},
            loadMRZ: { throw ProtectedSQLiteError.unavailable(26) })
        let diagnostics = StorageHealthDiagnostics(write: { _ in })
        let controller = PassportFaceJourneyController(
            comparison: FaceComparisonController(compare: { _ in throw FaceVisualAssessmentFailure.engine }),
            persistence: persistence)
        controller.onStorageHealthChange = { diagnostics.record(stage: $0, error: $1) }
        try await wait { controller.storageState == .failed }
        XCTAssertEqual(diagnostics.report.stage, .mrzLoad)
        XCTAssertEqual(diagnostics.report.failure?.family, "sqlite")
        XCTAssertEqual(diagnostics.report.failure?.status, 26)
        XCTAssertFalse(controller.canUseSavedPassport)
    }

    func testDiagnosticsRetainOnlyBoundedCodesAndObservedRootBoolean() throws {
        var bytes = Data()
        let diagnostics = StorageHealthDiagnostics { bytes = $0 }
        diagnostics.observeTrustedRoot(canonicalizationRequired: true)
        diagnostics.record(stage: .passportLoad, error: NSError(domain: "private-holder-domain", code: 123,
            userInfo: [NSLocalizedDescriptionKey: "/private/holder/identity SELECT passport_secret key_material"]))
        let report = try JSONDecoder().decode(StorageHealthReport.self, from: bytes)
        XCTAssertEqual(report.canonicalizationRequired, true)
        XCTAssertEqual(report.rawLocationPolicyMismatch, true)
        XCTAssertEqual(report.failure?.family, "unknown")
        XCTAssertEqual(report.failure?.code, "unclassified")
        let text = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["private-holder", "/private", "SELECT", "passport_secret", "key_material"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        diagnostics.record(stage: .ready)
        XCTAssertNil(diagnostics.report.failure)
        XCTAssertEqual(diagnostics.report.canonicalizationRequired, true)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition())
    }
}

private actor RetryStoreFactory {
    let store: PassportCaptureStore
    private(set) var attempts = 0
    init(store: PassportCaptureStore) { self.store = store }
    func make() throws -> PassportCaptureStore {
        attempts += 1
        if attempts == 1 { throw ProtectedStoreKeyError.keychainFailure(-25308) }
        return store
    }
}

private actor SuccessfulStoreFactory {
    let store: PassportCaptureStore
    private(set) var attempts = 0
    init(store: PassportCaptureStore) { self.store = store }
    func make() async -> PassportCaptureStore {
        attempts += 1
        await Task.yield()
        return store
    }
}
