import Foundation
import UIKit
import BiometricCapture
import PassportSDK
@testable import KenshikiReference
import XCTest

@MainActor final class SavedPassportJourneyTests: XCTestCase {
    func testRestoredCaptureStartsSelfieWithoutOpeningPassportAndUsesOriginalBytes() async throws {
        let capture = try CaptureStoreFixture.capture()
        let probe = SavedCaptureProbe(record: capture)
        let controller = make(probe)
        var passportStarts = 0
        let host = PassportFaceJourneyHost(controller: controller, makePassport: {
            passportStarts += 1
            return PassportFlowHost(effects: nil)
        }, makeCapture: {
            BiometricCaptureHost(controller: BiometricCaptureController { StoredCaptureDriver() })
        })
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host.navigation
        window.makeKeyAndVisible()
        defer { controller.send(.cancel); window.isHidden = true }
        try await wait { controller.storageState == .ready }
        XCTAssertEqual(controller.savedPassport?.id, capture.id)
        XCTAssertTrue(controller.canUseSavedPassport)
        controller.send(.savedWork)
        try await wait { self.findButton("journey.saved.use", in: host.navigation.view) != nil }
        let button = try XCTUnwrap(findButton("journey.saved.use", in: host.navigation.view))
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(controller.phase, .selfie)
        XCTAssertEqual(passportStarts, 0)
        XCTAssertEqual(controller.referencePortrait, capture.nfc.portrait)
        XCTAssertEqual(controller.restoredPassport?.capturedAt, capture.capturedAt)
        XCTAssertNil(controller.reference)
        XCTAssertNotNil(controller.captureToken)
        controller.interrupt()
        XCTAssertNil(controller.referencePortrait)
        XCTAssertNotNil(controller.savedPassport)
    }

    func testCompletedLivePassportPersistsAcrossFreshControllerAndDone() async throws {
        let probe = SavedCaptureProbe()
        let original = CaptureStoreFixture.accepted()
        let first = make(probe)
        try await wait { first.storageState == .ready }
        first.send(.begin)
        try await first.checkpointPassport(original, session: first.sessionID)
        XCTAssertTrue(first.acceptPassport(original, session: first.sessionID))
        first.send(.done)
        try await wait { first.storageState == .ready && first.savedPassport != nil }
        XCTAssertNil(first.reference)
        let second = make(probe)
        try await wait { second.storageState == .ready }
        second.send(.useSavedPassport)
        XCTAssertEqual(second.referencePortrait, original.read.portrait)
        XCTAssertEqual(second.restoredPassport?.id, original.attemptID)
        XCTAssertNil(second.reference)
    }

    func testDeletionWaitsForNonCooperativeSaveAndNeverResurrectsIt() async throws {
        let probe = SavedCaptureProbe(blockSave: true)
        let controller = make(probe)
        try await wait { controller.storageState == .ready }
        controller.send(.begin)
        let session = controller.sessionID
        let write = Task { try await controller.checkpointPassport(CaptureStoreFixture.accepted(), session: session) }
        try await probe.waitForSave()
        controller.send(.done)
        controller.send(.savedWork)
        controller.send(.reviewDeletion)
        controller.send(.deleteSavedPassport)
        controller.send(.begin)
        XCTAssertEqual(controller.phase, .introduction)
        XCTAssertEqual(controller.storageState, .deleting)
        await probe.releaseSave()
        _ = try? await write.value
        try await wait { controller.storageState == .ready }
        XCTAssertNil(controller.savedPassport)
        let stored = await probe.record
        XCTAssertNil(stored)
        let relaunched = make(probe)
        try await wait { relaunched.storageState == .ready }
        XCTAssertFalse(relaunched.canUseSavedPassport)
    }

    func testLateLoadCannotRestoreDeletedCapture() async throws {
        let probe = SavedCaptureProbe(record: try CaptureStoreFixture.capture(), blockLoad: true)
        let controller = make(probe)
        try await probe.waitForLoad()
        controller.send(.savedWork)
        controller.send(.reviewDeletion)
        controller.send(.deleteSavedPassport)
        try await wait { controller.storageState == .ready }
        await probe.releaseLoad()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(controller.savedPassport)
        XCTAssertFalse(controller.canUseSavedPassport)
        controller.send(.useSavedPassport)
        XCTAssertEqual(controller.phase, .introduction)
    }

    func testStorageFailureCannotAdvanceToSelfieOrMasqueradeAsSaved() async throws {
        let persistence = PassportCapturePersistence(load: { nil },
            save: { _ in throw PassportCaptureStorageFailure.unavailable }, delete: {})
        let controller = PassportFaceJourneyController(comparison: comparison(), persistence: persistence)
        try await wait { controller.storageState == .ready }
        controller.send(.begin)
        let capture = CaptureStoreFixture.accepted()
        do { try await controller.checkpointPassport(capture, session: controller.sessionID); XCTFail("Failed save accepted") }
        catch { }
        XCTAssertEqual(controller.storageState, .failed)
        XCTAssertFalse(controller.acceptPassport(capture, session: controller.sessionID))
        XCTAssertEqual(controller.phase, .passport)
        XCTAssertNil(controller.referencePortrait)
        XCTAssertFalse(controller.canUseSavedPassport)
    }

    func testNFCCompletionCommitsRealDatabaseBeforeResultWithoutContinueOrSelfie() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let journey = PassportFaceJourneyController(comparison: comparison(), persistence: fixture.repository().effects)
        try await wait { journey.storageState == .ready }
        let read = CaptureStoreFixture.accepted().read
        let (host, flow) = wiredPassport(journey, read: read)
        defer { withExtendedLifetime(host) {} }
        start(flow, read: read)
        try await wait { flow.phase == .result }
        XCTAssertEqual(journey.phase, .passport)
        XCTAssertNil(journey.reference)
        XCTAssertNil(journey.captureToken)
        let stored = try await fixture.repository().load()
        XCTAssertEqual(stored?.nfc.portrait, read.portrait)
        XCTAssertEqual(stored?.nfc.securityObject, read.securityObject)
        XCTAssertEqual(stored?.nfc.documentNumber, read.documentNumber)
        flow.send(.cancel)
        let relaunched = PassportFaceJourneyController(comparison: comparison(), persistence: fixture.repository().effects)
        try await wait { relaunched.canUseSavedPassport }
        relaunched.send(.useSavedPassport)
        XCTAssertEqual(relaunched.phase, .selfie)
        XCTAssertEqual(relaunched.referencePortrait, read.portrait)
    }

    func testBlockedCommitCannotPublishResultOrAcceptRepeatedContinue() async throws {
        let probe = SavedCaptureProbe(blockSave: true)
        let journey = make(probe)
        try await wait { journey.storageState == .ready }
        let read = CaptureStoreFixture.accepted().read
        let (host, flow) = wiredPassport(journey, read: read)
        defer { withExtendedLifetime(host) {} }
        start(flow, read: read)
        try await probe.waitForSave()
        XCTAssertEqual(flow.phase, .saving)
        XCTAssertNil(flow.result)
        flow.send(.usePortrait)
        flow.send(.usePortrait)
        XCTAssertEqual(journey.phase, .passport)
        XCTAssertNil(journey.captureToken)
        XCTAssertFalse(journey.canUseSavedPassport)
        await probe.releaseSave()
        try await wait { flow.phase == .result }
        flow.send(.usePortrait)
        XCTAssertEqual(journey.phase, .selfie)
    }

    func testLeavingAfterNFCCompletionKeepsAdmittedCommitButCannotPublishOldResult() async throws {
        let probe = SavedCaptureProbe(blockSave: true)
        let journey = make(probe)
        try await wait { journey.storageState == .ready }
        let read = CaptureStoreFixture.accepted().read
        let (host, flow) = wiredPassport(journey, read: read)
        defer { withExtendedLifetime(host) {} }
        start(flow, read: read)
        try await probe.waitForSave()
        flow.send(.cancel)
        XCTAssertEqual(journey.phase, .introduction)
        await probe.releaseSave()
        try await wait { journey.canUseSavedPassport }
        XCTAssertNil(flow.result)
        XCTAssertNil(journey.captureToken)
        let restored = make(probe)
        try await wait { restored.canUseSavedPassport }
        XCTAssertEqual(restored.savedPassport?.nfc.portrait, read.portrait)
    }

    func testFailedCommitRetriesSameReadWithoutRepeatingNFC() async throws {
        let probe = SavedCaptureProbe(saveFailures: 1)
        let journey = make(probe)
        try await wait { journey.storageState == .ready }
        let read = CaptureStoreFixture.accepted().read
        var reads = 0
        let (host, flow) = wiredPassport(journey, read: read, didRead: { reads += 1 })
        defer { withExtendedLifetime(host) {} }
        start(flow, read: read)
        try await wait { flow.phase == .saveFailure }
        XCTAssertNil(flow.result)
        flow.send(.usePortrait)
        XCTAssertEqual(journey.phase, .passport)
        XCTAssertNil(journey.captureToken)
        flow.send(.retrySave)
        flow.send(.retrySave)
        try await wait { flow.phase == .result }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(journey.savedPassport?.nfc.portrait, read.portrait)
        let attempts = await probe.attempts
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].id, attempts[1].id)
        XCTAssertEqual(attempts[0].capturedAt, attempts[1].capturedAt)
    }

    func testFailedDeletionCannotReuseCachedPassportAndRequiresDeletionRetry() async throws {
        let probe = SavedCaptureProbe(record: try CaptureStoreFixture.capture(), deleteFailures: 1)
        let controller = make(probe)
        try await wait { controller.storageState == .ready }
        controller.send(.savedWork)
        controller.send(.reviewDeletion)
        controller.send(.deleteSavedPassport)
        try await wait { controller.storageState == .deleteFailed }
        XCTAssertNil(controller.savedPassport)
        controller.send(.useSavedPassport)
        controller.send(.begin)
        XCTAssertEqual(controller.phase, .introduction)
        XCTAssertFalse(controller.canUseSavedPassport)
        controller.send(.retryStorage)
        try await wait { controller.storageState == .ready }
        let remaining = await probe.record
        XCTAssertNil(remaining)
    }

    func testRestoredComparisonReportKeepsHistoricalSourceAndNoServerVerdict() async throws {
        let record = try CaptureStoreFixture.capture()
        let probe = SavedCaptureProbe(record: record)
        let comparison = FaceComparisonController(compare: { input in
            FaceComparisonCompletion(operationID: input.operationID, referenceSHA256: input.referenceSHA256,
                selfieSHA256: input.selfieSHA256, score: 0.6)
        })
        let controller = PassportFaceJourneyController(comparison: comparison, persistence: probe.effects)
        try await wait { controller.storageState == .ready }
        controller.send(.useSavedPassport)
        let token = try XCTUnwrap(controller.captureToken)
        let selfie = try CaptureTestFixtures.capture()
        let snapshot = try SelfiePixelBridge.decodeOrientedPNG(selfie.encodedPNG, expectedSourceSHA256: selfie.sha256)
        XCTAssertTrue(controller.acceptSelfie(AcceptedSelfie(capture: selfie, snapshot: snapshot), token: token))
        try await wait { controller.phase == .result }
        var exported: String?
        controller.onCopyReport = { exported = $0 }
        controller.send(.copyReport)
        let text = try XCTUnwrap(exported)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let reference = try XCTUnwrap(report["passportReference"] as? [String: Any])
        XCTAssertEqual(reference["source"] as? String, "stored_nfc")
        XCTAssertEqual(reference["captureID"] as? String, record.id.uuidString)
        XCTAssertEqual(reference["serverVerification"] as? String, "not_requested")
        XCTAssertEqual(reference["capturedAt"] as? String, record.capturedAt.formatted(.iso8601))
        XCTAssertEqual(controller.referencePortrait, record.nfc.portrait)
    }

    func testHomeHasOnePrimaryStartAndKeepsSavedActionsInTheirDestination() async throws {
        let probe = SavedCaptureProbe(record: try CaptureStoreFixture.capture())
        let controller = make(probe)
        let host = PassportFaceJourneyHost(controller: controller,
            makePassport: { XCTFail("Home navigation must not acquire a passport"); return PassportFlowHost(effects: nil) },
            makeCapture: { XCTFail("Home navigation must not acquire a selfie"); return BiometricCaptureHost(controller: BiometricCaptureController { StoredCaptureDriver() }) })
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host.navigation
        window.makeKeyAndVisible()
        defer { controller.send(.cancel); window.isHidden = true }
        try await wait { controller.canUseSavedPassport }
        let renderer = try XCTUnwrap(host.navigation.topViewController as? ReferenceRenderer)
        window.layoutIfNeeded()
        XCTAssertEqual(renderer.primaryRegion.arrangedSubviews.map(\.accessibilityIdentifier), ["journey.begin"])
        XCTAssertNotNil(findButton("journey.saved.open", in: renderer.view))
        for id in ["journey.saved.use", "journey.saved.comparison", "journey.saved.delete", "journey.examples"] {
            XCTAssertNil(findButton(id, in: renderer.view), id)
        }
        XCTAssertNil(renderer.accessibilityElement(identifier: "journey.saved.available"))
        XCTAssertNil(renderer.accessibilityElement(identifier: "journey.evidence.idle"))
        XCTAssertNotEqual(renderer.title, (renderer.accessibilityElement(identifier: "workflow.step") as? UILabel)?.text)
        try await attach(window, name: "home-with-saved-passport-dark")
        controller.send(.savedWork)
        XCTAssertEqual(controller.homePage, .savedWork)
        XCTAssertEqual(controller.phase, .introduction)
        XCTAssertNotNil(findButton("journey.saved.use", in: renderer.view))
        XCTAssertNotNil(findButton("journey.saved.manageDelete", in: renderer.view))
        XCTAssertNotNil(renderer.accessibilityElement(identifier: "journey.saved.available"))
        XCTAssertTrue(renderer.primaryRegion.arrangedSubviews.isEmpty)
        window.layoutIfNeeded()
        try await attach(window, name: "saved-work-dark")
        controller.send(.homeBack)
        renderer.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.layoutIfNeeded()
        let start = try XCTUnwrap(findButton("journey.begin", in: renderer.view))
        XCTAssertGreaterThanOrEqual(start.bounds.height, KenshikiDesign.minimumTargetIOS)
        let title = try XCTUnwrap(start.titleLabel)
        XCTAssertGreaterThanOrEqual(start.bounds.height, title.sizeThatFits(CGSize(width: title.bounds.width,
            height: .greatestFiniteMagnitude)).height)
        XCTAssertLessThanOrEqual(start.convert(start.bounds, to: window).maxY, window.bounds.maxY)
        try await attach(window, name: "home-with-saved-passport-largest-text-dark")
    }

    func testSavedWorkDeletionRequiresReviewAndCancellationKeepsRecord() async throws {
        let record = try CaptureStoreFixture.capture()
        let probe = SavedCaptureProbe(record: record)
        let controller = make(probe)
        try await wait { controller.storageState == .ready }
        controller.send(.deleteSavedPassport)
        controller.send(.reviewDeletion)
        XCTAssertEqual(controller.homePage, .overview)
        XCTAssertEqual(controller.savedPassport?.id, record.id)
        controller.send(.savedWork)
        controller.send(.reviewDeletion)
        XCTAssertEqual(controller.homePage, .deletionConfirmation)
        controller.send(.homeBack)
        XCTAssertEqual(controller.homePage, .savedWork)
        XCTAssertEqual(controller.savedPassport?.id, record.id)
        let retained = await probe.record
        XCTAssertEqual(retained?.id, record.id)
        controller.send(.deleteSavedPassport)
        XCTAssertEqual(controller.savedPassport?.id, record.id)
        controller.send(.reviewDeletion)
        controller.send(.deleteSavedPassport)
        try await wait { controller.storageState == .ready && !controller.hasSavedWork }
        XCTAssertEqual(controller.homePage, .savedWork)
        let deleted = await probe.record
        XCTAssertNil(deleted)
    }

    func testDeveloperToolsNavigationCannotStartCaptureOrInterruptActiveJourney() async throws {
        let controller = make(SavedCaptureProbe())
        try await wait { controller.storageState == .ready }
        var examples = 0
        controller.onExamples = { examples += 1 }
        controller.send(.examples)
        XCTAssertEqual(examples, 0)
        controller.send(.developerTools)
        controller.send(.examples)
        XCTAssertEqual(examples, 1)
        controller.send(.homeBack)
        XCTAssertEqual(controller.homePage, .overview)
        controller.send(.begin)
        controller.send(.savedWork)
        controller.send(.developerTools)
        controller.send(.reviewDeletion)
        XCTAssertEqual(controller.phase, .passport)
        XCTAssertEqual(controller.homePage, .overview)
        controller.interrupt()
        controller.send(.developerTools)
        controller.send(.examples)
        XCTAssertEqual(examples, 2)
        XCTAssertEqual(controller.phase, .interrupted)
        controller.send(.cancel)
    }

    private func attach(_ window: UIWindow, name: String) async throws {
        // Let native navigation-bar transitions settle before recording their visible state.
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func make(_ probe: SavedCaptureProbe) -> PassportFaceJourneyController {
        PassportFaceJourneyController(comparison: comparison(), persistence: probe.effects)
    }
    private func wiredPassport(_ journey: PassportFaceJourneyController, read: PassportReadObservation,
                               didRead: @escaping () -> Void = {}) -> (PassportFaceJourneyHost, PassportFlowController) {
        var passport: PassportFlowHost?
        let host = PassportFaceJourneyHost(controller: journey, makePassport: {
            let child = PassportFlowHost(effects: PassportFlowEffects(startCamera: { _, _ in }, stopCamera: {}, read: { _, _, _ in didRead(); return read }))
            passport = child
            return child
        }, makeCapture: { BiometricCaptureHost(controller: BiometricCaptureController { StoredCaptureDriver() }) })
        journey.send(.begin)
        return (host, passport!.controller)
    }
    private func start(_ flow: PassportFlowController, read: PassportReadObservation) {
        flow.send(.visible)
        flow.send(.manualKey(.init(documentNumber: read.documentNumber, birthDateYYMMDD: read.birthDateYYMMDD, expiryDateYYMMDD: read.expiryDateYYMMDD)))
        flow.send(.confirmKey)
        flow.supplyTrustAnchors(URL(fileURLWithPath: "/synthetic-trust.pem"))
        flow.send(.scan)
    }
    private func comparison() -> FaceComparisonController {
        FaceComparisonController(compare: { _ in throw FaceVisualAssessmentFailure.engine })
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition())
    }
    private func findButton(_ id: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == id { return button }
        return view.subviews.lazy.compactMap { self.findButton(id, in: $0) }.first
    }
}

private actor SavedCaptureProbe {
    var record: SavedPassportCapture?
    private let blockSave: Bool
    private let blockLoad: Bool
    private var deleteFailures: Int
    private var saveFailures: Int
    private(set) var attempts: [SavedPassportCapture] = []
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var loadContinuation: CheckedContinuation<Void, Never>?
    init(record: SavedPassportCapture? = nil, blockSave: Bool = false, blockLoad: Bool = false, deleteFailures: Int = 0, saveFailures: Int = 0) {
        self.record = record
        self.blockSave = blockSave
        self.blockLoad = blockLoad
        self.deleteFailures = deleteFailures
        self.saveFailures = saveFailures
    }
    nonisolated var effects: PassportCapturePersistence {
        PassportCapturePersistence(load: { await self.load() }, save: { try await self.save($0) }, delete: { try await self.delete() })
    }
    func load() async -> SavedPassportCapture? {
        let captured = record
        if blockLoad { await withCheckedContinuation { loadContinuation = $0 } }
        return captured
    }
    func save(_ value: SavedPassportCapture) async throws {
        attempts.append(value)
        if saveFailures > 0 { saveFailures -= 1; throw PassportCaptureStorageFailure.unavailable }
        if blockSave { await withCheckedContinuation { saveContinuation = $0 } }
        record = value
    }
    func delete() throws {
        if deleteFailures > 0 { deleteFailures -= 1; throw PassportCaptureStorageFailure.unavailable }
        record = nil
    }
    func releaseSave() { saveContinuation?.resume(); saveContinuation = nil }
    func releaseLoad() { loadContinuation?.resume(); loadContinuation = nil }
    func waitForSave() async throws {
        let end = ContinuousClock.now + .seconds(5)
        while saveContinuation == nil, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(saveContinuation)
    }
    func waitForLoad() async throws {
        let end = ContinuousClock.now + .seconds(5)
        while loadContinuation == nil, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(loadContinuation)
    }
}

@MainActor private final class StoredCaptureDriver: BiometricCaptureDriver {
    var onState: ((CaptureDriverState) -> Void)?
    var onReadiness: ((SelfieAdmissionGate.Readiness) -> Void)?
    var onCapture: ((CapturedSelfie) -> Void)?
    func setConsent(_: SelfieCaptureConsent) {}
    func setActive(_: Bool) {}
    func stop() {}
    func capture() {}
    func retry() -> Bool { false }
    func updateViewport(_: CaptureViewport) {}
}
