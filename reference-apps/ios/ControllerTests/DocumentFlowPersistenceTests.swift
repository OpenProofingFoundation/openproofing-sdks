import DocumentSDK
import DocumentCaptureApple
import Foundation
import XCTest
@testable import KenshikiReference

private enum DocumentPersistenceProbeError: Error { case unavailable, staleRevision }

/// Deliberately ignores cancellation, modelling an admitted disk write or read that still returns.
private actor DocumentPersistenceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor private final class DocumentPersistenceProbe: DocumentFlowPersistence {
    private(set) var saved: DocumentFlowSnapshot?
    private(set) var saveCalls = 0
    private(set) var loadCalls = 0
    private(set) var deleteCalls = 0
    private var saveGate: DocumentPersistenceGate?
    private var loadGate: DocumentPersistenceGate?
    private var failedSaveCalls: Set<Int> = []
    private var loadFails = false
    private var deleteFails = false

    func configure(saveGate: DocumentPersistenceGate? = nil, loadGate: DocumentPersistenceGate? = nil,
                   failedSaveCalls: Set<Int> = [], loadFails: Bool = false, deleteFails: Bool = false) {
        self.saveGate = saveGate; self.loadGate = loadGate
        self.failedSaveCalls = failedSaveCalls; self.loadFails = loadFails; self.deleteFails = deleteFails
    }

    func replaceSaved(_ snapshot: DocumentFlowSnapshot) { saved = snapshot }

    func save(_ snapshot: DocumentFlowSnapshot) async throws -> DocumentFlowSnapshot {
        saveCalls += 1
        let call = saveCalls
        await saveGate?.wait()
        if failedSaveCalls.contains(call) { throw DocumentPersistenceProbeError.unavailable }
        let previous = saved?.workflowID == snapshot.workflowID ? saved?.revision : nil
        guard snapshot.revision == (previous ?? 0) else { throw DocumentPersistenceProbeError.staleRevision }
        let retained = DocumentFlowSnapshot(workflowID: snapshot.workflowID,
            revision: snapshot.revision + 1, front: snapshot.front, back: snapshot.back)
        saved = retained
        return retained
    }

    func load() async throws -> DocumentFlowSnapshot? {
        loadCalls += 1
        let value = saved
        await loadGate?.wait()
        if loadFails { throw DocumentPersistenceProbeError.unavailable }
        return value
    }

    func delete() async throws {
        deleteCalls += 1
        if deleteFails { throw DocumentPersistenceProbeError.unavailable }
        saved = nil
    }
}

@MainActor private final class DocumentPersistenceCamera: DocumentFlowCamera {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var captures: [DocumentSide] = []
    private(set) var startedSides: [DocumentSide] = []
    private(set) var candidates: [String?] = []
    var livePDF417: (@MainActor (String) -> Void)?
    func observeLivePDF417(_ receive: @escaping @MainActor (String) -> Void) { livePDF417 = receive }
    func start(side: DocumentSide) async throws { startedSides.append(side); try await start() }
    func capture(side: DocumentSide, observationIdentity: DocumentCaptureObservationIdentity?, livePDF417Candidate: String?) async throws -> DocumentFlowSource {
        candidates.append(livePDF417Candidate)
        return try await capture(side: side)
    }

    func start() async throws { starts += 1 }
    func stop() async throws { stops += 1 }
    func capture(side: DocumentSide) async throws -> DocumentFlowSource {
        captures.append(side)
        let bytes = Data(side == .front ? [11, 12, 13] : [21, 22, 23])
        return DocumentFlowSource(side: side, data: bytes, sha256: persistenceDigest(bytes),
            pixelWidth: 100, pixelHeight: 60,
            captureID: side == .front
                ? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
                : UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)),
            capturedAt: Date(timeIntervalSince1970: side == .front ? 100 : 200),
            nativeMetadata: Data(side == .front ? "synthetic-front-native-metadata".utf8 : "synthetic-back-native-metadata".utf8))
    }
}

@MainActor private final class DocumentPersistenceProcessing {
    private(set) var cameras: [DocumentPersistenceCamera] = []
    private(set) var preparationCalls = 0
    private(set) var extractionCalls = 0
    private(set) var portraitCalls = 0
    var failBackPreparation = false
    var failBackExtraction = false

    var ports: DocumentFlowPorts {
        DocumentFlowPorts(makeCamera: {
            let camera = DocumentPersistenceCamera()
            self.cameras.append(camera)
            return camera
        }, prepare: { source in
            self.preparationCalls += 1
            if source.side == .back, self.failBackPreparation { throw DocumentPersistenceProbeError.unavailable }
            let bytes = source.data + Data([31])
            return DocumentFlowPrepared(sourceSHA256: source.sha256, data: bytes,
                sha256: persistenceDigest(bytes), pixelWidth: 100, pixelHeight: 60,
                derivation: Data("synthetic-persistence-derivation".utf8))
        }, extract: { source in
            self.extractionCalls += 1
            if source.side == .back, self.failBackExtraction { throw DocumentPersistenceProbeError.unavailable }
            return DocumentFlowReading(sourceSHA256: source.sha256,
                recognizedText: [source.side == .front ? "SYNTHETIC FRONT" : "SYNTHETIC BACK"],
                pdf417Payloads: ["synthetic-unreadable-barcode"],
                parsedPDF417: [AAMVAPDF417Parser.parse("synthetic-unreadable-barcode")])
        }, portraits: { prepared in
            self.portraitCalls += 1
            let face = PortraitFaceObservation(boundingBox: .init(x: 0.2, y: 0.2, width: 0.15, height: 0.3), confidence: 1)
            let geometry = try XCTUnwrap(PortraitCropPolicy.evaluate(faces: [face], imageWidth: 100, imageHeight: 60).candidates.first)
            let bytes = Data([41, 42, 43])
            return [DocumentFlowPortrait(sourceSHA256: prepared.sha256, data: bytes,
                sha256: persistenceDigest(bytes), geometry: geometry)]
        }, sha256: persistenceDigest)
    }
}

/// These synthetic ports qualify controller sequencing, never SQLCipher, platform signing or a camera.
@MainActor final class DocumentFlowPersistenceTests: XCTestCase {
    func testFrontSaveCompletesBeforeBackAndExplicitReopenDoesNotAcquireOrReprocess() async throws {
        let store = DocumentPersistenceProbe(), gate = DocumentPersistenceGate()
        store.configure(saveGate: gate)
        let processing = DocumentPersistenceProcessing(), controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await eventually { await gate.entered }
        XCTAssertEqual(controller.phase, .processing)
        XCTAssertEqual(controller.persistenceState, .saving)
        XCTAssertNil(store.saved)
        await gate.release()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        XCTAssertEqual(controller.persistenceState, .saved)
        let saved = try XCTUnwrap(store.saved)
        XCTAssertEqual(saved.revision, 1)
        XCTAssertNil(saved.back)
        XCTAssertEqual(saved.front.source.data, Data([11, 12, 13]))
        XCTAssertEqual(saved.front.prepared?.data, Data([11, 12, 13, 31]))
        XCTAssertEqual(saved.front.portraits.count, 1)
        XCTAssertEqual(saved.front.source.capturedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(saved.front.source.nativeMetadata, Data("synthetic-front-native-metadata".utf8))
        controller.send(.hidden)
        await controller.waitUntilSettled()
        let reopening = DocumentPersistenceProcessing(), restored = idle(reopening, store: store)
        restored.send(.reopen)
        await restored.waitUntilSettled()
        XCTAssertEqual(restored.phase, .review)
        XCTAssertEqual(restored.persistenceState, .restored)
        XCTAssertEqual(try encoded(XCTUnwrap(restored.front)), try encoded(saved.front))
        XCTAssertNil(restored.back)
        XCTAssertTrue(reopening.cameras.isEmpty)
        XCTAssertEqual(reopening.preparationCalls + reopening.extractionCalls + reopening.portraitCalls, 0)
        restored.send(.retakeBack)
        await restored.waitUntilSettled()
        XCTAssertEqual(restored.phase, .back)
        XCTAssertEqual(reopening.cameras.count, 1)
        XCTAssertTrue(reopening.cameras[0].captures.isEmpty)
        XCTAssertEqual(try encoded(XCTUnwrap(restored.front)), try encoded(saved.front))
        restored.send(.hidden)
        await restored.waitUntilSettled()
    }

    func testPairedReopenPreservesIndependentOriginalDerivativeReadingAndPortraitLineage() async throws {
        let store = DocumentPersistenceProbe(), processing = DocumentPersistenceProcessing()
        let controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await controller.waitUntilSettled()
        let first = try XCTUnwrap(store.saved)
        controller.send(.capture)
        await controller.waitUntilSettled()
        let pair = try XCTUnwrap(store.saved)
        XCTAssertEqual(pair.workflowID, first.workflowID)
        XCTAssertEqual(pair.revision, first.revision + 1)
        XCTAssertEqual(try encoded(pair.front), try encoded(first.front))
        let back = try XCTUnwrap(pair.back)
        XCTAssertEqual(back.source.data, Data([21, 22, 23]))
        XCTAssertNotEqual(back.source.captureID, pair.front.source.captureID)
        XCTAssertEqual(back.prepared?.sourceSHA256, back.source.sha256)
        XCTAssertEqual(back.reading.sourceSHA256, back.source.sha256)
        XCTAssertTrue(back.portraits.isEmpty)
        XCTAssertEqual(pair.front.portraits[0].sourceSHA256, pair.front.prepared?.sha256)
        controller.send(.reset)
        await controller.waitUntilSettled()
        XCTAssertNil(controller.front)
        XCTAssertNil(controller.back)
        let reopening = DocumentPersistenceProcessing(), restored = idle(reopening, store: store)
        restored.send(.reopen)
        await restored.waitUntilSettled()
        XCTAssertEqual(restored.phase, .review)
        XCTAssertEqual(try encoded(XCTUnwrap(restored.front)), try encoded(pair.front))
        XCTAssertEqual(try encoded(XCTUnwrap(restored.back)), try encoded(back))
        XCTAssertEqual(restored.back?.reading.parsedPDF417.first?.status, .malformed)
        XCTAssertTrue(reopening.cameras.isEmpty)
        XCTAssertEqual(reopening.preparationCalls + reopening.extractionCalls + reopening.portraitCalls, 0)
    }

    func testStaleFrontCaptureIntentCannotCaptureOrSaveBackButExplicitBackCaptureCan() async throws {
        let store = DocumentPersistenceProbe(), processing = DocumentPersistenceProcessing()
        let controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.frontCapture)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        XCTAssertEqual(controller.persistenceState, .saved)
        XCTAssertNil(controller.failure)
        let first = try XCTUnwrap(store.saved)
        XCTAssertEqual(first.revision, 1)
        XCTAssertNil(first.back)
        let firstBytes = try encoded(first)

        // Model retained front-button events arriving after the front save has settled.
        // Await each event so acquisition coalescing cannot hide an incorrect second side.
        for _ in 0..<3 {
            controller.send(.frontCapture)
            await controller.waitUntilSettled()
            XCTAssertEqual(controller.phase, .back)
            XCTAssertNil(controller.back)
            XCTAssertEqual(store.saveCalls, 1)
            XCTAssertEqual(processing.cameras.flatMap(\.captures), [.front])
            XCTAssertEqual(processing.preparationCalls, 1)
            XCTAssertEqual(processing.extractionCalls, 1)
            XCTAssertEqual(processing.portraitCalls, 1)
            XCTAssertEqual(try encoded(XCTUnwrap(store.saved)), firstBytes)
        }

        controller.send(.capture)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .review)
        XCTAssertNil(controller.failure)
        XCTAssertEqual(processing.cameras.count, 2)
        XCTAssertEqual(processing.cameras.flatMap(\.captures), [.front, .back])
        XCTAssertEqual(processing.cameras[0].stops, 1)
        XCTAssertEqual(processing.cameras[1].stops, 1)
        XCTAssertEqual(store.saveCalls, 2)
        XCTAssertEqual(processing.preparationCalls, 2)
        XCTAssertEqual(processing.extractionCalls, 2)
        XCTAssertEqual(processing.portraitCalls, 1)
        let pair = try XCTUnwrap(store.saved)
        XCTAssertEqual(pair.workflowID, first.workflowID)
        XCTAssertEqual(pair.revision, 2)
        XCTAssertEqual(try encoded(pair.front), try encoded(first.front))
        XCTAssertEqual(pair.back?.source.side, .back)
        XCTAssertEqual(pair.back?.source.data, Data([21, 22, 23]))
    }

    func testFailedSaveCanRetryExactProcessedFrontWithoutAnotherCapture() async throws {
        let store = DocumentPersistenceProbe()
        store.configure(failedSaveCalls: [1])
        let processing = DocumentPersistenceProcessing(), controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.failure, .storageSave)
        XCTAssertEqual(controller.phase, .failure)
        XCTAssertNil(store.saved)
        let before = processing.preparationCalls + processing.extractionCalls + processing.portraitCalls
        controller.send(.retrySave)
        controller.send(.retrySave)
        await controller.waitUntilSettled()
        XCTAssertNil(controller.failure)
        XCTAssertEqual(controller.phase, .back)
        XCTAssertEqual(processing.cameras.count, 2)
        XCTAssertEqual(processing.cameras[0].captures, [.front])
        XCTAssertTrue(processing.cameras[1].captures.isEmpty)
        XCTAssertEqual(store.saveCalls, 2)
        XCTAssertEqual(processing.cameras.flatMap(\.captures), [.front])
        XCTAssertEqual(processing.preparationCalls + processing.extractionCalls + processing.portraitCalls, before)
        XCTAssertEqual(try XCTUnwrap(store.saved).front.source.data, Data([11, 12, 13]))
        controller.send(.hidden)
        await controller.waitUntilSettled()
    }

    func testFailedBackSaveKeepsPreviousFrontUntilExactRetrySucceeds() async throws {
        let store = DocumentPersistenceProbe()
        store.configure(failedSaveCalls: [2])
        let processing = DocumentPersistenceProcessing(), controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await controller.waitUntilSettled()
        let first = try XCTUnwrap(store.saved)
        controller.send(.capture)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.failure, .storageSave)
        XCTAssertEqual(try encoded(XCTUnwrap(store.saved)), try encoded(first))
        controller.send(.retakeBack)
        XCTAssertEqual(controller.phase, .failure)
        XCTAssertEqual(controller.failure, .storageSave)
        XCTAssertEqual(processing.cameras.count, 2)
        controller.send(.retrySave)
        await controller.waitUntilSettled()
        let pair = try XCTUnwrap(store.saved)
        XCTAssertEqual(pair.revision, 2)
        XCTAssertEqual(try encoded(pair.front), try encoded(first.front))
        XCTAssertEqual(pair.back?.source.data, Data([21, 22, 23]))
        XCTAssertEqual(processing.cameras.flatMap(\.captures), [.front, .back])
        XCTAssertEqual(processing.preparationCalls, 2)
        XCTAssertEqual(controller.phase, .review)
    }

    func testRetakeBackCannotReplaceAnAdmittedSaveOrReuseItsStaleRevision() async throws {
        let store = DocumentPersistenceProbe(), processing = DocumentPersistenceProcessing()
        let controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await controller.waitUntilSettled()
        XCTAssertEqual(store.saved?.revision, 1)
        let gate = DocumentPersistenceGate()
        store.configure(saveGate: gate)
        controller.send(.capture)
        await eventually { await gate.entered }
        XCTAssertEqual(controller.processingSide, .back)
        controller.send(.retakeBack)
        XCTAssertEqual(controller.phase, .processing)
        XCTAssertEqual(controller.processingSide, .back)
        XCTAssertEqual(processing.cameras.count, 2)
        XCTAssertEqual(store.saveCalls, 2)
        await gate.release()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .review)
        XCTAssertEqual(store.saved?.revision, 2)
        XCTAssertEqual(processing.cameras.count, 2)
        controller.send(.retakeBack)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        XCTAssertEqual(processing.cameras.count, 3)
        controller.send(.capture)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .review)
        XCTAssertNil(controller.failure)
        XCTAssertEqual(store.saved?.revision, 3)
        XCTAssertEqual(processing.cameras.flatMap(\.captures), [.front, .back, .back])
    }

    func testDuplicateCaptureAndRetryWhileSavingCannotDuplicatePersistenceOrAcquisition() async {
        let store = DocumentPersistenceProbe(), gate = DocumentPersistenceGate()
        store.configure(saveGate: gate)
        let processing = DocumentPersistenceProcessing(), controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await eventually { await gate.entered }
        controller.send(.capture)
        controller.send(.retrySave)
        controller.send(.retrySave)
        XCTAssertEqual(store.saveCalls, 1)
        XCTAssertEqual(processing.cameras.flatMap(\.captures), [.front])
        await gate.release()
        await controller.waitUntilSettled()
        XCTAssertEqual(store.saveCalls, 1)
        XCTAssertEqual(controller.phase, .back)
        controller.send(.hidden)
        await controller.waitUntilSettled()
    }

    func testAdmittedSaveDrainsAfterWithdrawalWithoutRepublishingOrStoppingReplacement() async throws {
        for action in Withdrawal.allCases {
            let store = DocumentPersistenceProbe(), gate = DocumentPersistenceGate()
            store.configure(saveGate: gate)
            let processing = DocumentPersistenceProcessing(), controller = active(processing, store: store)
            await controller.waitUntilSettled()
            controller.send(.capture)
            await eventually { await gate.entered }
            withdraw(action, controller: controller)
            if action == .replacement {
                await eventually { processing.cameras.count == 2 && controller.phase == .front }
            }
            await gate.release()
            await controller.waitUntilSettled()
            XCTAssertEqual(controller.phase, action == .replacement ? .front : .intro)
            XCTAssertNil(controller.front)
            XCTAssertNil(controller.back)
            XCTAssertNotNil(store.saved)
            XCTAssertEqual(store.saveCalls, 1)
            if action == .replacement { XCTAssertEqual(processing.cameras[1].stops, 0) }
            controller.send(.hidden)
            await controller.waitUntilSettled()
        }
    }

    func testLateReadAfterWithdrawalCannotRestoreOrStartCameraAndDuplicateReadCoalesces() async throws {
        for action in Withdrawal.allCases {
            let store = DocumentPersistenceProbe()
            try await seedFront(store)
            let gate = DocumentPersistenceGate()
            store.configure(loadGate: gate)
            let processing = DocumentPersistenceProcessing(), controller = idle(processing, store: store)
            controller.send(.reopen)
            await eventually { await gate.entered }
            XCTAssertEqual(controller.phase, .restoring)
            controller.send(.reopen)
            withdraw(action, controller: controller)
            if action == .replacement {
                await eventually { processing.cameras.count == 1 && controller.phase == .front }
            }
            await gate.release()
            await controller.waitUntilSettled()
            XCTAssertEqual(store.loadCalls, 1)
            XCTAssertNil(controller.front)
            XCTAssertNil(controller.back)
            XCTAssertEqual(controller.phase, action == .replacement ? .front : .intro)
            XCTAssertEqual(processing.cameras.count, action == .replacement ? 1 : 0)
            controller.send(.hidden)
            await controller.waitUntilSettled()
        }
    }

    func testMissingAndUnavailableSavedEvidenceAreDistinctWithoutInventedReview() async {
        let missing = DocumentPersistenceProbe(), processing = DocumentPersistenceProcessing()
        let controller = idle(processing, store: missing)
        controller.send(.reopen)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.failure, .noSavedCapture)
        missing.configure(loadFails: true)
        controller.send(.reopen)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.failure, .storageRead)
        XCTAssertNil(controller.front)
        XCTAssertNil(controller.back)
        XCTAssertTrue(processing.cameras.isEmpty)
    }

    func testDeleteFailurePreservesCommittedEvidenceAndExplicitRetryRemovesIt() async throws {
        let store = DocumentPersistenceProbe()
        try await seedFront(store)
        let first = try XCTUnwrap(store.saved)
        store.configure(deleteFails: true)
        let processing = DocumentPersistenceProcessing(), controller = idle(processing, store: store)
        controller.send(.reopen)
        await controller.waitUntilSettled()
        controller.send(.deleteSaved)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.failure, .storageDelete)
        XCTAssertEqual(try encoded(XCTUnwrap(store.saved)), try encoded(first))
        store.configure()
        controller.send(.deleteSaved)
        await controller.waitUntilSettled()
        XCTAssertNil(store.saved)
        XCTAssertNil(controller.front)
        XCTAssertNil(controller.back)
        XCTAssertEqual(controller.phase, .intro)
        controller.send(.reopen)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.failure, .noSavedCapture)
        XCTAssertTrue(processing.cameras.isEmpty)
    }

    func testReopenRefusesMisboundSourceDerivativeAndPortraitInsteadOfPartialPublication() async throws {
        let store = DocumentPersistenceProbe()
        try await seedFront(store)
        let good = try XCTUnwrap(store.saved)
        for component in ["source", "prepared", "reading", "portraits"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(good)) as? [String: Any])
            var front = try XCTUnwrap(object["front"] as? [String: Any])
            if component == "portraits" {
                var portraits = try XCTUnwrap(front[component] as? [[String: Any]])
                portraits[0]["sourceSHA256"] = "foreign-prepared-image"
                front[component] = portraits
            } else {
                var value = try XCTUnwrap(front[component] as? [String: Any])
                value[component == "source" ? "sha256" : "sourceSHA256"] = "foreign-source-image"
                front[component] = value
            }
            object["front"] = front
            let invalid = try JSONDecoder().decode(DocumentFlowSnapshot.self,
                from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            store.replaceSaved(invalid)
            let processing = DocumentPersistenceProcessing(), controller = idle(processing, store: store)
            controller.send(.reopen)
            await controller.waitUntilSettled()
            XCTAssertNotNil(controller.failure)
            XCTAssertEqual(controller.phase, .failure)
            XCTAssertNil(controller.front)
            XCTAssertNil(controller.back)
            XCTAssertTrue(processing.cameras.isEmpty)
        }
    }

    func testReentrantWithdrawalBeforeSaveOrReadAdmissionPerformsNoPersistenceIO() async {
        let store = DocumentPersistenceProbe(), processing = DocumentPersistenceProcessing()
        let controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.changed = {
            if controller.persistenceState == .saving { controller.send(.hidden) }
        }
        controller.send(.capture)
        await controller.waitUntilSettled()
        XCTAssertEqual(store.saveCalls, 0)
        XCTAssertNil(store.saved)
        XCTAssertEqual(controller.phase, .intro)
        XCTAssertNil(controller.front)
        let reopened = idle(DocumentPersistenceProcessing(), store: store)
        reopened.changed = {
            if reopened.phase == .restoring { reopened.send(.hidden) }
        }
        reopened.send(.reopen)
        await reopened.waitUntilSettled()
        XCTAssertEqual(store.loadCalls, 0)
        XCTAssertEqual(reopened.phase, .intro)
        XCTAssertNil(reopened.front)
    }

    func testFrontSaveFailureCannotStartBarcodeBackUntilExactRetryCommits() async throws {
        let store = DocumentPersistenceProbe(), processing = DocumentPersistenceProcessing()
        store.configure(failedSaveCalls: [1])
        let controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.failure, .storageSave)
        XCTAssertNil(store.saved)
        XCTAssertEqual(processing.cameras.count, 1)
        processing.cameras[0].livePDF417?("read-after-failed-front-save")
        controller.send(.barcodeCapture("explicit-read-after-failed-front-save"))
        await controller.waitUntilSettled()
        XCTAssertEqual(processing.cameras.flatMap(\.captures), [.front])
        XCTAssertEqual(store.saveCalls, 1)
        controller.send(.retrySave)
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        XCTAssertEqual(processing.cameras.count, 2)
        XCTAssertEqual(processing.cameras[0].stops, 1)
        XCTAssertEqual(processing.cameras[1].startedSides, [.back])
        XCTAssertEqual(store.saved?.revision, 1)
        XCTAssertEqual(processing.preparationCalls, 1)
        XCTAssertEqual(processing.extractionCalls, 1)
        controller.send(.hidden)
        await controller.waitUntilSettled()
    }

    func testLivePDF417BackCaptureCommitsPairWithOriginalFrontAndExactCandidate() async throws {
        let store = DocumentPersistenceProbe(), processing = DocumentPersistenceProcessing()
        let controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await controller.waitUntilSettled()
        let first = try XCTUnwrap(store.saved), raw = "SYNTHETIC\u{001e}RAW\r\nPDF417"
        let backCamera = try XCTUnwrap(processing.cameras.last)
        backCamera.livePDF417?(raw)
        backCamera.livePDF417?("duplicate")
        controller.send(.capture)
        await controller.waitUntilSettled()
        let pair = try XCTUnwrap(store.saved)
        XCTAssertEqual(controller.phase, .review)
        XCTAssertEqual(controller.persistenceState, .saved)
        XCTAssertEqual(pair.workflowID, first.workflowID)
        XCTAssertEqual(pair.revision, 2)
        XCTAssertEqual(try encoded(pair.front), try encoded(first.front))
        XCTAssertEqual(pair.back?.source.data, Data([21, 22, 23]))
        XCTAssertNil(pair.back?.prepared)
        XCTAssertEqual(pair.back?.reading.barcodeOrigin, .admittedLiveMetadata)
        XCTAssertEqual(pair.back?.reading.pdf417Payloads, [raw])
        XCTAssertEqual(backCamera.candidates, [raw])
        XCTAssertEqual(processing.cameras.flatMap(\.captures), [.front, .back])
        XCTAssertEqual(store.saveCalls, 2)
        XCTAssertEqual(processing.preparationCalls, 1)
        XCTAssertEqual(processing.extractionCalls, 1)
        XCTAssertEqual(processing.portraitCalls, 1)
    }

    func testBarcodeReadDuringFrontCommitCannotCreateBackOrPublishPartialPair() async throws {
        let store = DocumentPersistenceProbe(), processing = DocumentPersistenceProcessing(), gate = DocumentPersistenceGate()
        store.configure(saveGate: gate)
        let controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await eventually { await gate.entered }
        processing.cameras[0].livePDF417?("read-during-front-commit")
        controller.send(.barcodeCapture("another-early-read"))
        XCTAssertEqual(controller.phase, .processing)
        XCTAssertEqual(processing.cameras.count, 1)
        XCTAssertEqual(store.saveCalls, 1)
        XCTAssertNil(store.saved)
        await gate.release()
        await controller.waitUntilSettled()
        XCTAssertEqual(controller.phase, .back)
        XCTAssertEqual(processing.cameras.count, 2)
        XCTAssertEqual(processing.cameras[0].stops, 1)
        XCTAssertNil(store.saved?.back)
        XCTAssertTrue(processing.cameras[1].captures.isEmpty)
        controller.send(.hidden)
        await controller.waitUntilSettled()
    }

    func testLiveBarcodeRawOriginAndNoPreparedImageSurviveSavedReopen() async throws {
        let store = DocumentPersistenceProbe(), processing = DocumentPersistenceProcessing()
        processing.failBackPreparation = true; processing.failBackExtraction = true
        let controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await controller.waitUntilSettled()
        let front = try XCTUnwrap(store.saved)
        let raw = "SYNTHETIC\r\nRAW LIVE\u{001e}PDF417"
        processing.cameras[1].livePDF417?(raw)
        await controller.waitUntilSettled()
        let pair = try XCTUnwrap(store.saved), back = try XCTUnwrap(pair.back)
        XCTAssertEqual(controller.phase, .review)
        XCTAssertEqual(pair.revision, 2)
        XCTAssertEqual(try encoded(pair.front), try encoded(front.front))
        XCTAssertNil(back.prepared)
        XCTAssertEqual(back.reading.barcodeOrigin, .admittedLiveMetadata)
        XCTAssertEqual(back.reading.pdf417Payloads, [raw])
        XCTAssertTrue(back.reading.recognizedText.isEmpty)
        XCTAssertTrue(back.reading.parsedPDF417.isEmpty)
        XCTAssertNil(back.reading.licenseFront)
        XCTAssertTrue(back.portraits.isEmpty)
        XCTAssertEqual(processing.preparationCalls, 1)
        XCTAssertEqual(processing.extractionCalls, 1)
        controller.send(.hidden)
        await controller.waitUntilSettled()
        let reopening = DocumentPersistenceProcessing(), restored = idle(reopening, store: store)
        restored.send(.reopen)
        await restored.waitUntilSettled()
        XCTAssertEqual(restored.phase, .review)
        XCTAssertEqual(restored.persistenceState, .restored)
        XCTAssertEqual(try encoded(XCTUnwrap(restored.back)), try encoded(back))
        XCTAssertTrue(reopening.cameras.isEmpty)
        XCTAssertEqual(reopening.preparationCalls + reopening.extractionCalls + reopening.portraitCalls, 0)
    }

    func testReopenRefusesMissingFrontPreparationAndAmbiguousLiveBarcodeOrigin() async throws {
        let store = DocumentPersistenceProbe(), processing = DocumentPersistenceProcessing(), controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await controller.waitUntilSettled()
        processing.cameras[1].livePDF417?("synthetic-live-candidate")
        await controller.waitUntilSettled()
        let pair = try XCTUnwrap(store.saved)
        controller.send(.hidden)
        await controller.waitUntilSettled()
        for mutation in ["frontMissingPrepared", "missingOrigin", "fakeOCR", "parsedFields", "emptyCandidate", "twoCandidates", "portrait", "preparedWithLiveOrigin"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(pair)) as? [String: Any])
            var front = try XCTUnwrap(object["front"] as? [String: Any]), back = try XCTUnwrap(object["back"] as? [String: Any])
            var reading = try XCTUnwrap(back["reading"] as? [String: Any])
            switch mutation {
            case "frontMissingPrepared": front.removeValue(forKey: "prepared")
            case "missingOrigin": reading.removeValue(forKey: "barcodeOrigin")
            case "fakeOCR": reading["recognizedText"] = ["not actual still OCR"]
            case "parsedFields": reading["parsedPDF417"] = (front["reading"] as? [String: Any])?["parsedPDF417"]
            case "emptyCandidate": reading["pdf417Payloads"] = [""]
            case "twoCandidates": reading["pdf417Payloads"] = ["first", "second"]
            case "portrait": back["portraits"] = front["portraits"]
            default: back["prepared"] = front["prepared"]
            }
            back["reading"] = reading; object["front"] = front; object["back"] = back
            let invalid = try JSONDecoder().decode(DocumentFlowSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            store.replaceSaved(invalid)
            let restoring = idle(DocumentPersistenceProcessing(), store: store)
            restoring.send(.reopen)
            await restoring.waitUntilSettled()
            XCTAssertEqual(restoring.phase, .failure)
            XCTAssertEqual(restoring.failure, .sourceBinding)
            XCTAssertNil(restoring.front)
            XCTAssertNil(restoring.back)
        }
    }

    private enum Withdrawal: CaseIterable { case hidden, reset, background, replacement }

    private func withdraw(_ action: Withdrawal, controller: DocumentFlowController) {
        switch action {
        case .hidden: controller.send(.hidden)
        case .reset: controller.send(.reset)
        case .background: controller.setForeground(false)
        case .replacement: controller.send(.reset); controller.send(.start)
        }
    }

    private func idle(_ processing: DocumentPersistenceProcessing, store: DocumentPersistenceProbe) -> DocumentFlowController {
        let controller = DocumentFlowController(ports: processing.ports, persistence: store)
        controller.setForeground(true)
        controller.send(.visible)
        return controller
    }

    private func active(_ processing: DocumentPersistenceProcessing, store: DocumentPersistenceProbe) -> DocumentFlowController {
        let controller = idle(processing, store: store)
        controller.send(.start)
        return controller
    }

    private func seedFront(_ store: DocumentPersistenceProbe) async throws {
        let processing = DocumentPersistenceProcessing(), controller = active(processing, store: store)
        await controller.waitUntilSettled()
        controller.send(.capture)
        await controller.waitUntilSettled()
        _ = try XCTUnwrap(store.saved)
        controller.send(.hidden)
        await controller.waitUntilSettled()
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Synthetic persistence port did not reach its checkpoint")
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

/// Synthetic byte identity for controller tests; production ports supply SHA-256.
@MainActor private func persistenceDigest(_ bytes: Data) -> String { bytes.base64EncodedString() }
