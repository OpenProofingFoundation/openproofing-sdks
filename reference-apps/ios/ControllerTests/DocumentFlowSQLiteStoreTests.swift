import CryptoKit
import DocumentSDK
@testable import DocumentCaptureApple
import Foundation
import KenshikiEvidenceManifest
@_spi(StorageAdapter) @_spi(StorageTestFixture) import KenshikiProtectedStorage
import SQLCipher
import XCTest
import UIKit
@testable import KenshikiReference

/// Actual SQLCipher/lifecycle integration with synthetic test keys; no hardware-signing claim.
@MainActor final class DocumentFlowSQLiteStoreTests: XCTestCase {
    func testSavedRawPDF417RendersStructuredFieldsWithoutScanningOrRewritingEvidence() async throws {
        let fixture = try fixture(), store = fixture.store()
        let first = try await store.save(.init(workflowID: UUID(), revision: 0,
            front: observation(.front, motion: true), back: nil))
        let back = try rawLiveBack(payload: structuredPayload())
        let pair = try await store.save(.init(workflowID: first.workflowID, revision: first.revision,
            front: first.front, back: back))
        let before = try Data(contentsOf: fixture.url)
        var acquisitions = 0, processing = 0
        let ports = DocumentFlowPorts(makeCamera: {
            acquisitions += 1
            return NoScanDocumentCamera()
        }, prepare: { _ in
            processing += 1; throw DocumentFlowFailure.preparation
        }, extract: { _ in
            processing += 1; throw DocumentFlowFailure.extraction
        }, portraits: { _ in
            processing += 1; throw DocumentFlowFailure.portrait
        }, sha256: { CaptureEvidenceManifest.sha256($0) })
        let controller = DocumentFlowController(ports: ports, persistence: fixture.store())
        controller.setForeground(true)
        controller.send(.visible)
        controller.send(.reopen)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .review)
        let host = DocumentFlowHost(controller: controller)
        let renderer = host.makeRenderer()
        renderer.loadViewIfNeeded()
        let label = try XCTUnwrap(structuredLabel(in: renderer.view))
        let expected = AAMVAPDF417Parser.parse(structuredPayload())
        XCTAssertEqual(expected.status, .readable)
        XCTAssertEqual(expected.fields["DCS"], "EXAMPLE")
        XCTAssertEqual(expected.fields["DAC"], "ALICE")
        XCTAssertEqual(expected.fields["DAQ"], "EXAMPLE123")
        XCTAssertEqual(label.text, expected.fields.sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value }.joined(separator: "\n"))
        XCTAssertEqual(acquisitions, 0)
        XCTAssertEqual(processing, 0)
        XCTAssertTrue(try XCTUnwrap(controller.back).reading.parsedPDF417.isEmpty)
        let restored = try await fixture.store().load()
        XCTAssertEqual(try encoded(XCTUnwrap(restored)), try encoded(pair))
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    func testLiveStructuredResultsRejectMalformedPayloadInsteadOfUsingUnrelatedCachedFields() {
        let cached = AAMVAPDF417Parser.parse(structuredPayload())
        let reading = DocumentFlowReading(sourceSHA256: "synthetic", recognizedText: [],
            pdf417Payloads: ["malformed"], parsedPDF417: [cached], barcodeOrigin: .admittedLiveMetadata)
        XCTAssertTrue(reading.structuredPDF417Results.allSatisfy { $0.fields.isEmpty && $0.status == .malformed })
    }

    func testHistoricalStructuredResultsRemainReadableWithoutChangingEncodedReading() throws {
        let cached = AAMVAPDF417Parser.parse(structuredPayload())
        let reading = DocumentFlowReading(sourceSHA256: "synthetic", recognizedText: [],
            pdf417Payloads: [], parsedPDF417: [cached])
        let before = try encoded(reading)
        XCTAssertEqual(reading.structuredPDF417Results, [cached])
        XCTAssertEqual(try encoded(reading), before)
    }

    private func structuredLabel(in view: UIView) -> UILabel? {
        if let label = view as? UILabel, label.accessibilityIdentifier == "document.back.fields.text" { return label }
        return view.subviews.lazy.compactMap { self.structuredLabel(in: $0) }.first
    }

    private func structuredPayload() -> String {
        let fields = ["DBA": "09242030", "DBD": "09242020", "DBB": "01011980", "DAG": "1 SAMPLE ST",
            "DAI": "EXAMPLE CITY", "DAJ": "WA", "DAK": "98000", "DAQ": "EXAMPLE123", "DCS": "EXAMPLE", "DAC": "ALICE"]
        let body = "DL" + fields.sorted { $0.key < $1.key }.map { $0.key + $0.value + "\n" }.joined() + "\r"
        return "@\n\u{1e}\rANSI 636045090201DL0031" + String(format: "%04d", body.utf8.count) + body
    }

    @MainActor private final class NoScanDocumentCamera: DocumentFlowCamera {
        func start() async throws { throw DocumentFlowFailure.cameraStart }
        func stop() async throws {}
        func capture(side: DocumentSide) async throws -> DocumentFlowSource { throw DocumentFlowFailure.capture }
    }
    private func fixture(signer: SQLiteDocumentSigner = SQLiteDocumentSigner()) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("document.sqlite")
        let identity = try StoreKeyIdentity(applicationID: "test.document-custody", storeID: "document-fixture", purpose: "capture",
            keychainAccessGroup: "test.document", accessPolicy: .identityWhenUnlocked)
        let key = Data(repeating: 0x39, count: 32)
        addTeardownBlock { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
        let configuration = DocumentFlowSQLiteStore.Configuration(applicationID: identity.applicationID,
            exists: { FileManager.default.fileExists(atPath: url.path) },
            open: { existing in try .testing(databaseURL: url, identity: identity, key: key, requiresExisting: existing) },
            pending: { try ProtectedSQLiteStore.hasPendingErasure(databaseURL: url, identity: identity) },
            prepareErase: { try ProtectedSQLiteStore.prepareErasureTesting(databaseURL: url, identity: identity) },
            signer: signer, eraseSigning: {
                guard !FileManager.default.fileExists(atPath: url.path) else { throw SQLiteDocumentSigner.Failure.signing }
                try await signer.erase()
            })
        return Fixture(url: url, identity: identity, key: key, configuration: configuration)
    }
    private struct Fixture {
        let url: URL
        let identity: StoreKeyIdentity
        let key: Data
        let configuration: DocumentFlowSQLiteStore.Configuration
        func store() -> DocumentFlowSQLiteStore { .init(configuration: configuration) }
        func database() throws -> ProtectedSQLiteStore {
            try .testing(databaseURL: url, identity: identity, key: key, requiresExisting: true)
        }
    }

    func testMissingLoadCreatesNeitherDatabaseNorSigningKey() async throws {
        let signer = SQLiteDocumentSigner(), fixture = try fixture(signer: signer)
        let result = try await fixture.store().load()
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.deletingLastPathComponent().path))
        let preparations = await signer.preparations
        XCTAssertEqual(preparations, 0)
    }

    func testFrontAndPairedRevisionsReopenExactBytesFromEncryptedDatabase() async throws {
        let fixture = try fixture(), store = fixture.store(), front = try observation(.front)
        let first = try await store.save(.init(workflowID: UUID(), revision: 0, front: front, back: nil))
        XCTAssertEqual(first.revision, 1)
        let reopenedValue = try await fixture.store().load()
        let reopened = try XCTUnwrap(reopenedValue)
        XCTAssertEqual(try encoded(reopened), try encoded(first))
        let pair = try await store.save(.init(workflowID: first.workflowID, revision: first.revision, front: front, back: observation(.back)))
        XCTAssertEqual(pair.revision, 2)
        let restoredValue = try await fixture.store().load()
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(try encoded(restored), try encoded(pair))
        let disk = try Data(contentsOf: fixture.url)
        XCTAssertFalse(disk.starts(with: Data("SQLite format 3".utf8)))
        let count = try fixture.database().withConnection { try PassportCaptureSchema.integer($0, "SELECT count(*) FROM document_capture_records") }
        XCTAssertEqual(count, 2, "Earlier signed revisions remain until explicit delete")
    }

    func testLostAcknowledgementRetryReturnsSameSignedFrontAndBackRevisions() async throws {
        let fixture = try fixture(), store = fixture.store()
        let input = DocumentFlowSnapshot(workflowID: UUID(), revision: 0, front: try observation(.front), back: nil)
        let first = try await store.save(input)
        let proofBefore = try fixture.database().withConnection { try PassportCaptureSchema.string($0, "SELECT hex(signed_manifest) FROM document_capture_records WHERE revision=1") }
        let retried = try await fixture.store().save(input)
        XCTAssertEqual(try encoded(retried), try encoded(first))
        let proofAfter = try fixture.database().withConnection { try PassportCaptureSchema.string($0, "SELECT hex(signed_manifest) FROM document_capture_records WHERE revision=1") }
        XCTAssertEqual(proofBefore, proofAfter)
        let pairedInput = DocumentFlowSnapshot(workflowID: first.workflowID, revision: first.revision, front: first.front, back: try observation(.back))
        let pair = try await store.save(pairedInput), pairRetry = try await store.save(pairedInput)
        XCTAssertEqual(try encoded(pairRetry), try encoded(pair))
        let count = try fixture.database().withConnection { try PassportCaptureSchema.integer($0, "SELECT count(*) FROM document_capture_records") }
        XCTAssertEqual(count, 2, "Acknowledgement retries must not mint a new revision or signature")
        do { _ = try await store.save(.init(workflowID: input.workflowID, revision: 0, front: observation(.front), back: nil)); XCTFail("Different content cannot reuse the same new-workflow admission") }
        catch DocumentFlowSQLiteStore.Failure.staleRevision {}
    }

    func testMissingHistoricalSigningKeyRefusesReadAndSaveWithoutReplacement() async throws {
        let signer = SQLiteDocumentSigner(), fixture = try fixture(signer: signer)
        let first = try await fixture.store().save(.init(workflowID: UUID(), revision: 0, front: observation(.front), back: nil))
        await signer.hide()
        do { _ = try await fixture.store().load(); XCTFail("Missing retained key must refuse") }
        catch EvidenceManifestError.untrustedSigningKey {}
        do { _ = try await fixture.store().save(.init(workflowID: first.workflowID, revision: 1, front: first.front, back: observation(.back))); XCTFail("No replacement key") }
        catch EvidenceManifestError.untrustedSigningKey {}
        let count = await signer.preparations
        XCTAssertEqual(count, 1)
    }

    func testFailedSignatureAndStaleRevisionPreservePreviousCommit() async throws {
        let signer = SQLiteDocumentSigner(), fixture = try fixture(signer: signer), store = fixture.store()
        let first = try await store.save(.init(workflowID: UUID(), revision: 0, front: observation(.front), back: nil))
        await signer.failSigning(true)
        do { _ = try await store.save(.init(workflowID: first.workflowID, revision: 1, front: first.front, back: observation(.back))); XCTFail("Signer failure") }
        catch SQLiteDocumentSigner.Failure.signing {}
        await signer.failSigning(false)
        let currentValue = try await store.load()
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(try encoded(current), try encoded(first))
        do { _ = try await store.save(.init(workflowID: UUID(), revision: 1, front: first.front, back: observation(.back))); XCTFail("Foreign workflow") }
        catch DocumentFlowSQLiteStore.Failure.staleRevision {}
        let lastValue = try await store.load()
        let last = try XCTUnwrap(lastValue)
        XCTAssertEqual(try encoded(last), try encoded(first))
    }

    func testAlteredSignedPayloadAndNativeMetadataAreRefused() async throws {
        let fixture = try fixture(), store = fixture.store()
        let first = try await store.save(.init(workflowID: UUID(), revision: 0, front: observation(.front), back: nil))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(first)) as? [String: Any])
        var front = try XCTUnwrap(object["front"] as? [String: Any])
        var reading = try XCTUnwrap(front["reading"] as? [String: Any])
        reading["recognizedText"] = ["altered retained reading"]; front["reading"] = reading; object["front"] = front
        let changed = try JSONSerialization.data(withJSONObject: object)
        try fixture.database().withConnection { db in
            let query = try PassportCaptureSchema.statement(db, "UPDATE document_capture_records SET payload=? WHERE revision=1")
            defer { sqlite3_finalize(query) }
            try changed.withUnsafeBytes { bytes in
                try PassportCaptureSchema.check(sqlite3_bind_blob(query, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
            }
            try PassportCaptureSchema.done(query)
        }
        do { _ = try await store.load(); XCTFail("A SQLCipher row is not sufficient without its signature binding") }
        catch {}
        let invalid = try observation(.front, metadataCaptureID: UUID())
        do { _ = try await fixture.store().save(.init(workflowID: UUID(), revision: 0, front: invalid, back: nil)); XCTFail("Foreign metadata") }
        catch DocumentFlowFailure.sourceBinding {}
    }

    func testConcurrentReplacementDuringSigningCannotOverwriteNewerRevision() async throws {
        let gate = SQLiteDocumentSigningGate(), signer = SQLiteDocumentSigner()
        let fixture = try fixture(signer: signer), firstStore = fixture.store(), secondStore = fixture.store()
        let first = try await firstStore.save(.init(workflowID: UUID(), revision: 0, front: observation(.front), back: nil))
        await signer.suspendNext(on: gate)
        let back = try observation(.back)
        let pending = Task { try await firstStore.save(.init(workflowID: first.workflowID, revision: 1, front: first.front, back: back)) }
        await gate.waitForEntry()
        let replacement = try await secondStore.save(.init(workflowID: UUID(), revision: 0, front: observation(.front), back: nil))
        await gate.release()
        do { _ = try await pending.value; XCTFail("CAS must reject old admission") }
        catch DocumentFlowSQLiteStore.Failure.staleRevision {}
        let loadedValue = try await secondStore.load()
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(try encoded(loaded), try encoded(replacement))
    }

    func testSQLFailureAfterRevisionInsertRollsBackEntirePublication() async throws {
        let fixture = try fixture(), store = fixture.store()
        let first = try await store.save(.init(workflowID: UUID(), revision: 0, front: observation(.front), back: nil))
        try fixture.database().withConnection { db in
            try PassportCaptureSchema.execute(db, "CREATE TRIGGER synthetic_commit_failure BEFORE UPDATE ON document_capture_current BEGIN SELECT RAISE(ABORT,'synthetic publication failure'); END")
        }
        do { _ = try await store.save(.init(workflowID: first.workflowID, revision: 1, front: first.front, back: observation(.back))); XCTFail("SQL failure must propagate") }
        catch ProtectedSQLiteError.unavailable {}
        let loadedValue = try await store.load(), loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(try encoded(loaded), try encoded(first))
        let count = try fixture.database().withConnection { try PassportCaptureSchema.integer($0, "SELECT count(*) FROM document_capture_records") }
        XCTAssertEqual(count, 1, "Failed pointer publication must roll back the inserted revision too")
    }

    func testCallerCancellationDoesNotCancelAnAdmittedSignedPublication() async throws {
        let gate = SQLiteDocumentSigningGate(), signer = SQLiteDocumentSigner()
        let fixture = try fixture(signer: signer), store = fixture.store(), front = try observation(.front)
        await signer.suspendNext(on: gate)
        let pending = Task { try await store.save(.init(workflowID: UUID(), revision: 0, front: front, back: nil)) }
        await gate.waitForEntry()
        pending.cancel()
        await gate.release()
        let committed = try await pending.value
        let loadedValue = try await fixture.store().load(), loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(try encoded(loaded), try encoded(committed))
    }

    func testExternalErasureDuringSigningCannotRepublishThroughOldLifecycleOwner() async throws {
        let gate = SQLiteDocumentSigningGate(), signer = SQLiteDocumentSigner()
        let fixture = try fixture(signer: signer), store = fixture.store()
        let first = try await store.save(.init(workflowID: UUID(), revision: 0, front: observation(.front), back: nil))
        await signer.suspendNext(on: gate)
        let back = try observation(.back)
        let pending = Task { try await store.save(.init(workflowID: first.workflowID, revision: 1, front: first.front, back: back)) }
        await gate.waitForEntry()
        try ProtectedSQLiteStore.eraseTesting(databaseURL: fixture.url, identity: fixture.identity)
        await gate.release()
        do { _ = try await pending.value; XCTFail("No stale owner may recreate an erased database") }
        catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    func testExplicitDeleteRemovesCiphertextThenSigningCustody() async throws {
        let signer = SQLiteDocumentSigner(), fixture = try fixture(signer: signer), store = fixture.store()
        _ = try await store.save(.init(workflowID: UUID(), revision: 0, front: observation(.front), back: nil))
        try await store.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
        let key = try await signer.existingSigningPublicKeyHash()
        XCTAssertNil(key)
        let value = try await store.load()
        XCTAssertNil(value)
    }

    func testFailedSigningKeyErasureRemainsEraseOnlyAcrossFreshOwnerUntilRetry() async throws {
        let signer = SQLiteDocumentSigner(), fixture = try fixture(signer: signer), store = fixture.store()
        let input = DocumentFlowSnapshot(workflowID: UUID(), revision: 0, front: try observation(.front), back: nil)
        _ = try await store.save(input)
        await signer.failErasure(true)
        do { try await store.delete(); XCTFail("Signing-key cleanup failure must propagate") }
        catch SQLiteDocumentSigner.Failure.signing {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
        XCTAssertTrue(try ProtectedSQLiteStore.hasPendingErasure(databaseURL: fixture.url, identity: fixture.identity))
        for candidate in [store, fixture.store()] {
            do { _ = try await candidate.load(); XCTFail("Pending cleanup is not missing evidence") }
            catch DocumentFlowSQLiteStore.Failure.retired {}
            do { _ = try await candidate.save(input); XCTFail("Pending cleanup cannot recreate ciphertext or key") }
            catch DocumentFlowSQLiteStore.Failure.retired {}
        }
        let preparations = await signer.preparations
        XCTAssertEqual(preparations, 1)
        await signer.failErasure(false)
        try await fixture.store().delete()
        XCTAssertFalse(try ProtectedSQLiteStore.hasPendingErasure(databaseURL: fixture.url, identity: fixture.identity))
        let key = try await signer.existingSigningPublicKeyHash(), restored = try await fixture.store().load()
        XCTAssertNil(key)
        XCTAssertNil(restored)
    }

    func testSubstitutedNativeAdmissionAndTemporalStillFactsCannotEnterSignedStore() async throws {
        let fixture = try fixture(), store = fixture.store(), front = try observation(.front)
        let first = try await store.save(.init(workflowID: UUID(), revision: 0, front: front, back: nil))
        for field in ["admissionSession", "admissionSide", "admissionRequestedAt", "temporalSession", "temporalSide", "temporalStillHash", "temporalTimestamp", "temporalAttempt"] {
            var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: front.source.nativeMetadata) as? [String: Any])
            if field.hasPrefix("admission") {
                var admission = try XCTUnwrap(metadata["admission"] as? [String: Any])
                switch field {
                case "admissionSession": admission["sessionID"] = ["rawValue": UUID().uuidString]
                case "admissionSide": admission["side"] = DocumentSide.back.rawValue
                default: admission["userRequestedAt"] = 0
                }
                metadata["admission"] = admission
            } else {
                var temporal = try XCTUnwrap(metadata["temporalEvidence"] as? [String: Any])
                var manifest = try XCTUnwrap(temporal["manifest"] as? [String: Any])
                var binding = try XCTUnwrap(manifest["binding"] as? [String: Any])
                switch field {
                case "temporalSession": binding["sessionID"] = UUID().uuidString
                case "temporalSide": binding["side"] = DocumentSide.back.rawValue
                case "temporalStillHash": binding["stillSHA256"] = String(repeating: "0", count: 64)
                case "temporalTimestamp":
                    var timestamp = try XCTUnwrap(binding["stillTimestamp"] as? [String: Any]); timestamp["value"] = 2
                    binding["stillTimestamp"] = timestamp
                default: binding["attemptID"] = UUID().uuidString
                }
                manifest["binding"] = binding; temporal["manifest"] = manifest; metadata["temporalEvidence"] = temporal
            }
            let source = DocumentFlowSource(side: front.source.side, data: front.source.data, sha256: front.source.sha256,
                pixelWidth: front.source.pixelWidth, pixelHeight: front.source.pixelHeight, captureID: front.source.captureID,
                capturedAt: front.source.capturedAt, nativeMetadata: try JSONSerialization.data(withJSONObject: metadata))
            let substituted = DocumentFlowObservation(source: source, prepared: front.prepared, reading: front.reading, portraits: front.portraits)
            do { _ = try await store.save(.init(workflowID: UUID(), revision: 0, front: substituted, back: nil)); XCTFail("Foreign native facts: \(field)") }
            catch DocumentFlowFailure.sourceBinding {}
        }
        let value = try await fixture.store().load(), restored = try XCTUnwrap(value)
        XCTAssertEqual(try encoded(restored), try encoded(first))
        let count = try fixture.database().withConnection { try PassportCaptureSchema.integer($0, "SELECT count(*) FROM document_capture_records") }
        XCTAssertEqual(count, 1)
    }

    func testMotionReceiptAndWholeSnapshotCommitTogetherAndFrontReceiptIsReusedForBack() async throws {
        let fixture = try fixture(), store = fixture.store(), input = DocumentFlowSnapshot(workflowID: UUID(), revision: 0, front: try observation(.front, motion: true), back: nil)
        let front = try await store.save(input)
        let firstProof = try fixture.database().withConnection { try PassportCaptureSchema.string($0, "SELECT hex(signed_manifest) FROM document_capture_motion") }
        let retried = try await fixture.store().save(input)
        XCTAssertEqual(try encoded(retried), try encoded(front))
        let pair = try await store.save(.init(workflowID: front.workflowID, revision: front.revision, front: front.front, back: observation(.back)))
        let restoredValue = try await fixture.store().load(), restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(try encoded(restored), try encoded(pair))
        let count = try fixture.database().withConnection { try PassportCaptureSchema.integer($0, "SELECT count(*) FROM document_capture_motion") }
        let retainedProof = try fixture.database().withConnection { try PassportCaptureSchema.string($0, "SELECT hex(signed_manifest) FROM document_capture_motion") }
        XCTAssertEqual(count, 1, "Back has no newly collected motion; the original front receipt is reused")
        XCTAssertEqual(firstProof, retainedProof)
        let signer = fixture.configuration.signer
        let preparesBefore = try await signer.existingSigningPublicKeyHash()
        XCTAssertNotNil(preparesBefore)
    }

    func testAdmittedLiveBackReopensRawSourceAndPreservesFrontAndMotionProof() async throws {
        let fixture = try fixture(), store = fixture.store()
        let first = try await store.save(.init(workflowID: UUID(), revision: 0,
            front: observation(.front, motion: true), back: nil))
        let originalFront = try captureBytes(fixture)
        let originalMotion = try fixture.database().withConnection {
            try PassportCaptureSchema.string($0, "SELECT hex(payload)||':'||hex(metadata)||':'||hex(signed_manifest) FROM document_capture_motion")
        }
        let back = try rawLiveBack()
        let paired = try await store.save(.init(workflowID: first.workflowID, revision: first.revision,
            front: first.front, back: back))
        let loadedValue = try await fixture.store().load(), restored = try XCTUnwrap(loadedValue)
        let restoredBack = try XCTUnwrap(restored.back)
        XCTAssertEqual(try encoded(restored), try encoded(paired))
        XCTAssertEqual(try encoded(restored.front), try encoded(first.front))
        XCTAssertEqual(try encoded(restoredBack.source), try encoded(back.source))
        XCTAssertNil(restoredBack.prepared)
        XCTAssertEqual(restoredBack.reading.barcodeOrigin, .admittedLiveMetadata)
        XCTAssertEqual(restoredBack.reading.pdf417Payloads, back.reading.pdf417Payloads)
        XCTAssertTrue(restoredBack.reading.recognizedText.isEmpty)
        XCTAssertTrue(restoredBack.reading.parsedPDF417.isEmpty)
        XCTAssertNil(restoredBack.reading.licenseFront)
        XCTAssertTrue(restoredBack.portraits.isEmpty)
        XCTAssertEqual(try captureBytes(fixture), originalFront)
        XCTAssertEqual(try fixture.database().withConnection {
            try PassportCaptureSchema.string($0, "SELECT hex(payload)||':'||hex(metadata)||':'||hex(signed_manifest) FROM document_capture_motion")
        }, originalMotion)
        XCTAssertEqual(try fixture.database().withConnection {
            try PassportCaptureSchema.integer($0, "SELECT count(*) FROM document_capture_motion")
        }, 1)
        let acknowledgedRetry = try await fixture.store().save(.init(workflowID: first.workflowID,
            revision: first.revision, front: first.front, back: back))
        XCTAssertEqual(try encoded(acknowledgedRetry), try encoded(paired))
    }

    func testUnboundRawBackAndForgedLiveOriginsPreservePreviousAtomicPublication() async throws {
        let fixture = try fixture(), store = fixture.store()
        let first = try await store.save(.init(workflowID: UUID(), revision: 0,
            front: observation(.front, motion: true), back: nil))
        let originalFront = try captureBytes(fixture)
        let originalMotion = try fixture.database().withConnection {
            try PassportCaptureSchema.string($0, "SELECT hex(signed_manifest) FROM document_capture_motion")
        }
        for mutation in ["mismatch", "missingCandidate", "wrongGate", "missingOrigin", "emptyPayload",
            "duplicatePayload", "recognizedText", "parsedFields", "preparedLive", "forgedPreparedOrigin", "rawFront"] {
            let raw = try rawLiveBack(), ordinary = try observation(.back)
            var source = raw.source, prepared = raw.prepared, reading = raw.reading
            switch mutation {
            case "mismatch":
                reading = .init(sourceSHA256: source.sha256, recognizedText: [], pdf417Payloads: ["different synthetic payload"], barcodeOrigin: .admittedLiveMetadata)
            case "missingCandidate", "wrongGate":
                var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: source.nativeMetadata) as? [String: Any])
                if mutation == "missingCandidate" { metadata.removeValue(forKey: "admittedLivePDF417Candidate") }
                else {
                    var admission = try XCTUnwrap(metadata["admission"] as? [String: Any])
                    admission["qualityGate"] = DocumentCaptureQualityGate.operatorInitiatedAdvisory.rawValue
                    metadata["admission"] = admission
                }
                source = DocumentFlowSource(side: source.side, data: source.data, sha256: source.sha256,
                    pixelWidth: source.pixelWidth, pixelHeight: source.pixelHeight, captureID: source.captureID,
                    capturedAt: source.capturedAt, nativeMetadata: try JSONSerialization.data(withJSONObject: metadata))
            case "missingOrigin":
                reading = .init(sourceSHA256: source.sha256, recognizedText: [], pdf417Payloads: reading.pdf417Payloads)
            case "emptyPayload":
                reading = .init(sourceSHA256: source.sha256, recognizedText: [], pdf417Payloads: [""], barcodeOrigin: .admittedLiveMetadata)
            case "duplicatePayload":
                reading = .init(sourceSHA256: source.sha256, recognizedText: [], pdf417Payloads: reading.pdf417Payloads + reading.pdf417Payloads, barcodeOrigin: .admittedLiveMetadata)
            case "recognizedText":
                reading = .init(sourceSHA256: source.sha256, recognizedText: ["invented OCR"], pdf417Payloads: reading.pdf417Payloads, barcodeOrigin: .admittedLiveMetadata)
            case "parsedFields":
                reading = .init(sourceSHA256: source.sha256, recognizedText: [], pdf417Payloads: reading.pdf417Payloads,
                    parsedPDF417: [AAMVAPDF417Parser.parse("invalid")], barcodeOrigin: .admittedLiveMetadata)
            case "preparedLive": prepared = ordinary.prepared
            case "forgedPreparedOrigin":
                source = ordinary.source; prepared = ordinary.prepared
                reading = .init(sourceSHA256: source.sha256, recognizedText: [], pdf417Payloads: ["forged synthetic payload"], barcodeOrigin: .admittedLiveMetadata)
            default:
                source = first.front.source; prepared = nil; reading = first.front.reading
            }
            let invalid = DocumentFlowObservation(source: source, prepared: prepared, reading: reading, portraits: [])
            do {
                if mutation == "rawFront" {
                    _ = try await store.save(.init(workflowID: UUID(), revision: 0, front: invalid, back: nil))
                } else {
                    _ = try await store.save(.init(workflowID: first.workflowID, revision: first.revision,
                        front: first.front, back: invalid))
                }
                XCTFail("Unbound live representation accepted: \(mutation)")
            } catch DocumentFlowSQLiteStore.Failure.invalidRecord {} catch DocumentFlowFailure.sourceBinding {}
            let loadedValue = try await fixture.store().load(), restored = try XCTUnwrap(loadedValue)
            XCTAssertEqual(try encoded(restored), try encoded(first), mutation)
            XCTAssertEqual(try captureBytes(fixture), originalFront, mutation)
            XCTAssertEqual(try fixture.database().withConnection {
                try PassportCaptureSchema.integer($0, "SELECT revision FROM document_capture_current WHERE slot=1")
            }, 1, mutation)
            XCTAssertEqual(try fixture.database().withConnection {
                try PassportCaptureSchema.integer($0, "SELECT count(*) FROM document_capture_records")
            }, 1, mutation)
            XCTAssertEqual(try fixture.database().withConnection {
                try PassportCaptureSchema.string($0, "SELECT hex(signed_manifest) FROM document_capture_motion")
            }, originalMotion, mutation)
        }
    }

    func testMissingTamperedOrForeignMotionRowRefusesWholeReview() async throws {
        for mutation in ["DELETE FROM document_capture_motion", "UPDATE document_capture_motion SET payload=X'00'",
            "UPDATE document_capture_motion SET source_capture_id='00000000-0000-0000-0000-000000000000'",
            "UPDATE document_capture_motion SET signed_manifest=X'00'"] {
            let fixture = try fixture(), store = fixture.store()
            _ = try await store.save(.init(workflowID: UUID(), revision: 0, front: observation(.front, motion: true), back: nil))
            try fixture.database().withConnection { try PassportCaptureSchema.execute($0, mutation) }
            do { _ = try await store.load(); XCTFail("A snapshot cannot publish without its exact complete motion signature set") }
            catch {}
        }
    }

    func testMotionKeyLossNeverMintsReplacementOrReturnsPartialSnapshot() async throws {
        let signer = SQLiteDocumentSigner(), fixture = try fixture(signer: signer), store = fixture.store()
        let input = DocumentFlowSnapshot(workflowID: UUID(), revision: 0, front: try observation(.front, motion: true), back: nil)
        _ = try await store.save(input)
        await signer.hide()
        do { _ = try await fixture.store().load(); XCTFail("Retained motion needs its existing key") }
        catch EvidenceManifestError.untrustedSigningKey {}
        do { _ = try await fixture.store().save(input); XCTFail("Even acknowledgement retry must verify existing custody") }
        catch EvidenceManifestError.untrustedSigningKey {}
        let preparations = await signer.preparations
        XCTAssertEqual(preparations, 1)
    }

    func testLegacyV1ReadAndMigrationPreserveOriginalPayloadMetadataAndSignatureBytes() async throws {
        let signer = SQLiteDocumentSigner(), fixture = try fixture(signer: signer)
        let legacy = try await seedLegacyV1(fixture, signer: signer)
        let legacyReading = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(legacy.front.reading)) as? [String: Any])
        let legacyNative = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy.front.source.nativeMetadata) as? [String: Any])
        XCTAssertNil(legacyReading["barcodeOrigin"], "New optional provenance must not rewrite legacy reading bytes")
        XCTAssertNil(legacyNative["admittedLivePDF417Candidate"], "Historical captures do not acquire live metadata provenance")
        let before = try captureBytes(fixture)
        let loadedValue = try await fixture.store().load(), loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(try encoded(loaded), try encoded(legacy))
        XCTAssertEqual(try fixture.database().withConnection { try PassportCaptureSchema.integer($0, "PRAGMA user_version") }, 1)
        let store = fixture.store()
        _ = try await store.save(.init(workflowID: legacy.workflowID, revision: legacy.revision, front: legacy.front, back: observation(.back)))
        XCTAssertEqual(try fixture.database().withConnection { try PassportCaptureSchema.integer($0, "PRAGMA user_version") }, 2)
        XCTAssertEqual(try captureBytes(fixture), before)
        XCTAssertEqual(try fixture.database().withConnection { try PassportCaptureSchema.integer($0, "SELECT count(*) FROM document_capture_motion") }, 0)
    }

    func testFailureAfterMotionInsertRollsBackSnapshotPointerAndSchemaMigration() async throws {
        let signer = SQLiteDocumentSigner(), fixture = try fixture(signer: signer)
        let legacy = try await seedLegacyV1(fixture, signer: signer), before = try captureBytes(fixture)
        try fixture.database().withConnection {
            try PassportCaptureSchema.execute($0, "CREATE TRIGGER synthetic_after_motion BEFORE INSERT ON document_capture_records BEGIN SELECT RAISE(ABORT,'synthetic snapshot failure after motion insert'); END")
        }
        do { _ = try await fixture.store().save(.init(workflowID: UUID(), revision: 0, front: observation(.front, motion: true), back: nil)); XCTFail("No partial capture success") }
        catch ProtectedSQLiteError.unavailable {}
        XCTAssertEqual(try captureBytes(fixture), before)
        XCTAssertEqual(try fixture.database().withConnection { try PassportCaptureSchema.integer($0, "PRAGMA user_version") }, 1)
        XCTAssertEqual(try fixture.database().withConnection { try PassportCaptureSchema.integer($0, "SELECT count(*) FROM sqlite_master WHERE name='document_capture_motion'") }, 0)
        let value = try await fixture.store().load(), restored = try XCTUnwrap(value)
        XCTAssertEqual(try encoded(restored), try encoded(legacy))
    }

    func testFutureAndMalformedSchemasArePreservedAndRefused() async throws {
        for mutation in ["PRAGMA user_version=99", "ALTER TABLE document_capture_records ADD COLUMN foreign_field TEXT"] {
            let signer = SQLiteDocumentSigner(), fixture = try fixture(signer: signer)
            _ = try await seedLegacyV1(fixture, signer: signer)
            let before = try captureBytes(fixture)
            try fixture.database().withConnection { try PassportCaptureSchema.execute($0, mutation) }
            do { _ = try await fixture.store().load(); XCTFail("Unknown storage must not be guessed or rebuilt") }
            catch DocumentFlowSQLiteStore.Failure.invalidRecord {}
            XCTAssertEqual(try captureBytes(fixture), before)
        }
    }

    private func captureBytes(_ fixture: Fixture) throws -> String? {
        try fixture.database().withConnection {
            try PassportCaptureSchema.string($0, "SELECT record_id||':'||hex(payload)||':'||hex(metadata)||':'||hex(signed_manifest)||':'||key_anchor FROM document_capture_records WHERE revision=1")
        }
    }
    private func seedLegacyV1(_ fixture: Fixture, signer: SQLiteDocumentSigner) async throws -> DocumentFlowSnapshot {
        let snapshot = DocumentFlowSnapshot(workflowID: UUID(), revision: 1, front: try observation(.front), back: nil)
        let payload = try encoded(snapshot), id = UUID(), anchor = try await signer.prepareSigningPublicKeyHash()
        let metadata = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "workflowID": snapshot.workflowID.uuidString,
            "revision": 1, "frontCaptureID": snapshot.front.source.captureID.uuidString,
            "payloadSHA256": CaptureEvidenceManifest.sha256(payload)], options: [.sortedKeys, .withoutEscapingSlashes])
        let context = try CapturePublicationContext(applicationID: fixture.identity.applicationID, installationID: "local-signing-key:" + anchor,
            workflowID: snapshot.workflowID, generation: 1, attemptID: snapshot.front.source.captureID,
            observedAtMilliseconds: Int64(snapshot.front.source.capturedAt.timeIntervalSince1970 * 1000))
        let manifest = try CaptureEvidenceManifest(context: context, recordID: id, recordKind: "document-review",
            payloadSHA256: CaptureEvidenceManifest.sha256(payload), capabilityManifestSHA256: CaptureEvidenceManifest.sha256(metadata),
            sources: [.init(recordID: id, role: "document-review", sha256: CaptureEvidenceManifest.sha256(payload)),
                .init(recordID: snapshot.front.source.captureID, role: "optical-source", sha256: snapshot.front.source.sha256)],
            policyIDs: ["local-document-review-v1"])
        let proof = try await signer.sign(manifest), signed = try encoded(SignedCaptureEvidenceManifest(manifest: manifest, proof: proof))
        let db = try fixture.configuration.open(false)
        try db.withConnection { handle in
            try PassportCaptureSchema.execute(handle, "CREATE TABLE document_capture_records(revision INTEGER PRIMARY KEY CHECK(revision>0),record_id TEXT NOT NULL UNIQUE,payload BLOB NOT NULL,metadata BLOB NOT NULL,signed_manifest BLOB NOT NULL,key_anchor TEXT NOT NULL) STRICT")
            try PassportCaptureSchema.execute(handle, "CREATE TABLE document_capture_current(slot INTEGER PRIMARY KEY CHECK(slot=1),revision INTEGER NOT NULL REFERENCES document_capture_records(revision)) STRICT")
            let query = try PassportCaptureSchema.statement(handle, "INSERT INTO document_capture_records VALUES(1,?,?,?,?,?)")
            defer { sqlite3_finalize(query) }
            try PassportCaptureSchema.bind(id.uuidString, at: 1, to: query)
            for (index, bytes) in [(Int32(2), payload), (3, metadata), (4, signed)] {
                try bytes.withUnsafeBytes { buffer in
                    try PassportCaptureSchema.check(sqlite3_bind_blob(query, index, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
                }
            }
            try PassportCaptureSchema.bind(anchor, at: 5, to: query); try PassportCaptureSchema.done(query)
            try PassportCaptureSchema.execute(handle, "INSERT INTO document_capture_current VALUES(1,1)")
            try PassportCaptureSchema.execute(handle, "PRAGMA user_version=1")
        }
        return snapshot
    }

    private func rawLiveBack(payload: String = "SYNTHETIC-LIVE-PDF417-CANDIDATE") throws -> DocumentFlowObservation {
        let original = try observation(.back)
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: original.source.nativeMetadata) as? [String: Any])
        var admission = try XCTUnwrap(metadata["admission"] as? [String: Any])
        admission["qualityGate"] = DocumentCaptureQualityGate.livePDF417AutoCapture.rawValue
        metadata["admission"] = admission; metadata["admittedLivePDF417Candidate"] = payload
        let source = DocumentFlowSource(side: .back, data: original.source.data, sha256: original.source.sha256,
            pixelWidth: original.source.pixelWidth, pixelHeight: original.source.pixelHeight,
            captureID: original.source.captureID, capturedAt: original.source.capturedAt,
            nativeMetadata: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]))
        return .init(source: source, prepared: nil,
            reading: .init(sourceSHA256: source.sha256, recognizedText: [], pdf417Payloads: [payload],
                barcodeOrigin: .admittedLiveMetadata), portraits: [])
    }

    private func observation(_ side: DocumentSide, metadataCaptureID: UUID? = nil, motion: Bool = false) throws -> DocumentFlowObservation {
        let data = Data("synthetic-\(side.rawValue)-original".utf8), prepared = data + Data([4]), captureID = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let digest = CaptureEvidenceManifest.sha256(data), output = CaptureEvidenceManifest.sha256(prepared)
        let session = CaptureSessionID(), attempt = UUID()
        let timestamp = DocumentCaptureClockTimestamp(value: 1, timescale: 1, flags: 1, epoch: 0, clock: .captureSessionSynchronizationClock)
        let admission = DocumentCaptureAdmissionSnapshot(request: .init(sessionID: session, side: side,
            qualityGate: .operatorInitiatedAdvisory, attemptID: attempt, userRequestedAt: date),
            admittedAt: date, photoSettingsUniqueID: 1, observation: nil)
        let temporal = DocumentTemporalEvidence(manifest: .init(schemaVersion: 1, sequenceID: UUID(),
            binding: .init(sessionID: session.rawValue.uuidString, attemptID: attempt.uuidString,
                side: side.rawValue, stillSHA256: digest, stillTimestamp: timestamp, stillHostTimeSeconds: 1),
            configuration: .init(enabled: true), frames: [], motionSamples: [], clockCorrelation: nil,
            status: "unavailable", termination: "synthetic-fixture", issues: ["synthetic-no-video"],
            gaps: [], omittedDiagnosticCount: 0, evictedFrameCount: 0, evictedMotionSampleCount: 0), frames: [])
        let motionEvidence: DocumentMotionEvidence?
        if motion {
            let sample = DocumentTemporalMotionSample(bootTimeSeconds: 100.25,
                attitude: .init(x: 0, y: 0, z: 0, w: 1), rotationRate: .init(x: 0, y: 0.1, z: 0.2),
                gravity: .init(x: 0, y: 0, z: -1), userAcceleration: .init(x: 0, y: 0, z: 0),
                referenceFrame: "xArbitraryZVertical_rotation_radians_per_second_acceleration_g")
            let fields: [String: Any] = ["schemaVersion": 1, "recordingID": UUID().uuidString,
                "binding": try JSONSerialization.jsonObject(with: encoded(DocumentTemporalBinding(
                    sessionID: session.rawValue.uuidString, attemptID: attempt.uuidString, side: side.rawValue,
                    stillSHA256: digest, stillTimestamp: timestamp, stillHostTimeSeconds: nil))),
                "startedAt": ["hostBeforeSeconds": 100, "bootTimeSeconds": 100, "hostAfterSeconds": 100.001,
                    "method": "CMClockGetHostTimeClock_brackets_ProcessInfo_systemUptime"],
                "endedAt": ["hostBeforeSeconds": 101, "bootTimeSeconds": 101, "hostAfterSeconds": 101.001,
                    "method": "CMClockGetHostTimeClock_brackets_ProcessInfo_systemUptime"],
                "samples": [try JSONSerialization.jsonObject(with: encoded(sample))], "issues": [],
                "maximumSampleCount": DocumentTemporalConfiguration().maximumMotionSamples,
                "maximumIssueCount": DocumentTemporalConfiguration().maximumDiagnostics,
                "omittedSampleCount": 0, "omittedIssueCount": 0, "status": "recorded"]
            motionEvidence = try JSONDecoder().decode(DocumentMotionEvidence.self, from: JSONSerialization.data(withJSONObject: fields))
        } else { motionEvidence = nil }
        let photo = CapturedDocumentPhoto(sessionID: session, side: side, requestedAt: date,
            captureTimestamp: timestamp,
            processedAt: date, data: data, fidelity: .init(pixelWidth: 100, pixelHeight: 60, fileByteCount: data.count,
                uniformTypeIdentifier: "public.png", orientation: 1, cameraModel: nil, lensModel: nil,
                exposureTimeSeconds: nil, fNumber: nil, isoSpeed: nil, sha256: digest, optical: nil), admission: admission, temporalEvidence: temporal, motionEvidence: motionEvidence)
        let geometry = DocumentGeometryObservation(method: .visionDocumentSegmentation, implementationVersion: "synthetic-test",
            requestRevision: 1, confidence: 1, normalizedCoordinateQuantization: nil, analysisPixelWidth: nil,
            analysisPixelHeight: nil, regionOfInterest: CGRect(x: 0, y: 0, width: 1, height: 1),
            orientedPixelWidth: 100, orientedPixelHeight: 60,
            quadrilateral: .init(topLeft: .init(x: 0, y: 1), topRight: .init(x: 1, y: 1), bottomRight: .init(x: 1, y: 0), bottomLeft: .init(x: 0, y: 0)))
        let derivation = DocumentImageDerivation(schemaVersion: 3, sourceSHA256: digest, sourceOrientation: 1,
            operation: .perspectiveCorrection, implementationVersion: "synthetic-test", geometry: geometry,
            outputPixelWidth: 100, outputPixelHeight: 60, outputUniformTypeIdentifier: "public.png", usesNonuniformScaling: false, outputSHA256: output)
        return .init(source: .init(side: side, data: data, sha256: digest, pixelWidth: 100, pixelHeight: 60,
            captureID: captureID, capturedAt: date, nativeMetadata: try encoded(DocumentFlowCaptureMetadata(photo, captureID: metadataCaptureID ?? captureID))),
            prepared: .init(sourceSHA256: digest, data: prepared, sha256: output, pixelWidth: 100, pixelHeight: 60, derivation: try encoded(derivation)),
            reading: .init(sourceSHA256: digest, recognizedText: ["SYNTHETIC"], pdf417Payloads: ["invalid"], parsedPDF417: [AAMVAPDF417Parser.parse("invalid")]), portraits: [])
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private actor SQLiteDocumentSigner: EvidenceManifestSigning {
    enum Failure: Error { case signing }
    let key = P256.Signing.PrivateKey()
    private var hidden = false
    private var fails = false
    private var eraseFails = false
    private var gate: SQLiteDocumentSigningGate?
    private(set) var preparations = 0
    private var hash: String { CaptureEvidenceManifest.sha256(key.publicKey.x963Representation) }
    func hide() { hidden = true }
    func erase() throws { if eraseFails { throw Failure.signing }; hidden = true }
    func failErasure(_ value: Bool) { eraseFails = value }
    func failSigning(_ value: Bool) { fails = value }
    func suspendNext(on gate: SQLiteDocumentSigningGate) { self.gate = gate }
    func prepareSigningPublicKeyHash() async throws -> String { preparations += 1; return hash }
    func existingSigningPublicKeyHash() async throws -> String? { hidden ? nil : hash }
    func sign(_ manifest: CaptureEvidenceManifest) async throws -> EvidenceManifestProof {
        if fails { throw Failure.signing }
        let waiting = gate; gate = nil
        await waiting?.enter()
        return .init(schemaVersion: "synthetic.p256.v1", signingPublicKeyHash: hash,
            proofBytes: try key.signature(for: manifest.signingBytes()).derRepresentation)
    }
    func verify(_ manifest: CaptureEvidenceManifest, proof: EvidenceManifestProof, trustedSigningPublicKeyHash: String) async throws -> Bool {
        guard !hidden, trustedSigningPublicKeyHash == hash, proof.signingPublicKeyHash == hash,
            proof.schemaVersion == "synthetic.p256.v1" else { return false }
        let signature = try P256.Signing.ECDSASignature(derRepresentation: proof.proofBytes)
        return key.publicKey.isValidSignature(signature, for: try manifest.signingBytes())
    }
}
private actor SQLiteDocumentSigningGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func enter() async { entered = true; waiter?.resume(); waiter = nil; await withCheckedContinuation { continuation = $0 } }
    func waitForEntry() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
}
