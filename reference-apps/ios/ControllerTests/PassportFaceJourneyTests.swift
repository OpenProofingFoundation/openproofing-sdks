import XCTest
import UIKit
@testable import BiometricCapture
@testable import PassportSDK
@testable import KenshikiReference

final class PassportFaceJourneyTests: XCTestCase {
    @MainActor func testRetiredRetakeFailureCannotClearNewJourneyAdmissionTask() async throws {
        let writer = RetakeFailureAdmissionWriter()
        let persistence = FaceWorkflowPersistence(saveCapture: { _ in }, loadCapture: { _ in throw FaceWorkflowStorageFailure.unavailable },
            saveStage: { _ in }, loadStage: { _, _ in nil }, latestCaptureID: { nil },
            appendEvent: { try await writer.append($0) }, loadEvents: { _, _ in [] })
        let recorder = WorkflowEvidenceRecorder(sensors: .init(start: { _ in }, stop: {}, motion: { nil },
            motionPermission: { "denied" }, location: {
                .init(permission: .denied, accuracy: .unavailable, observedAt: Date(), fix: nil, providerErrorCode: nil)
            }), persistence: persistence)
        let engine = JourneyComparisonProbe()
        let journey = PassportFaceJourneyController(comparison: FaceComparisonController { try await engine.compare($0) }, evidence: recorder)
        var replaceOnFailure = false
        var replacementSession: UUID?
        journey.onEvidenceChange = {
            // Force the real race at publication of the old write failure, before
            // the suspended retake task can execute its catch on the same actor.
            guard replaceOnFailure, case .failed = recorder.status else { return }
            replaceOnFailure = false
            journey.send(.done)
            journey.send(.begin)
            replacementSession = journey.sessionID
        }
        journey.send(.begin)
        try await wait { journey.phase == .passport }
        XCTAssertTrue(journey.acceptPassport(JourneyFixtures.reference(), session: journey.sessionID))
        XCTAssertTrue(journey.acceptSelfie(try JourneyFixtures.selfie(), token: try XCTUnwrap(journey.captureToken)))
        try await engine.waitForCall()
        await engine.complete(score: 0.75)
        try await wait { journey.phase == .result }
        replaceOnFailure = true
        journey.send(.retake)
        try await writer.waitForRetake()
        await writer.failRetake()
        try await writer.waitForNewStart()
        let replacement = try XCTUnwrap(replacementSession)
        XCTAssertEqual(journey.sessionID, replacement)
        XCTAssertEqual(journey.phase, .introduction)
        journey.send(.begin)
        XCTAssertEqual(journey.sessionID, replacement,
            "The old retake catch must retain the newer admission task's duplicate-Begin guard")
        await writer.releaseStarts()
        try await wait { journey.phase == .passport }
        let starts = await writer.startedWorkflows
        XCTAssertEqual(starts.count, 2, "Only the original workflow and its one replacement may be admitted")
        journey.send(.cancel)
    }

    @MainActor func testWorkflowMotionLoadKeepsDetailsSheetStableAndLateLoadCannotRestoreRetiredSession() async throws {
        let events = HeldMotionProjectionEvents()
        let persistence = FaceWorkflowPersistence(saveCapture: { _ in }, loadCapture: { _ in throw FaceWorkflowStorageFailure.unavailable },
            saveStage: { _ in }, loadStage: { _, _ in nil }, latestCaptureID: { nil },
            appendEvent: { await events.append($0) }, loadEvents: { await events.load($0, $1) })
        var started = false
        var stops = 0
        let recorder = WorkflowEvidenceRecorder(sensors: .init(start: { _ in started = true }, stop: { stops += 1 }, motion: { nil },
            motionPermission: { "denied" }, location: {
                .init(permission: .denied, accuracy: .unavailable, observedAt: Date(), fix: nil, providerErrorCode: nil)
            }), persistence: persistence)
        let engine = JourneyComparisonProbe()
        let journey = PassportFaceJourneyController(comparison: FaceComparisonController { try await engine.compare($0) }, evidence: recorder)
        let host = PassportFaceJourneyHost(controller: journey, makePassport: {
            XCTAssertTrue(started, "Workflow sensors must be admitted before the MRZ acquisition host is created")
            return PassportFlowHost(effects: PassportFlowEffects(startCamera: { _, _ in }, stopCamera: {},
                read: { _, _, _ in throw PassportReadFailure.unsupported }))
        }, makeCapture: { BiometricCaptureHost(controller: BiometricCaptureController { JourneyCaptureDriver() }) })
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host.navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; journey.send(.cancel) }
        journey.send(.begin)
        try await wait { journey.phase == .passport }
        XCTAssertTrue(journey.acceptPassport(JourneyFixtures.reference(), session: journey.sessionID))
        XCTAssertTrue(journey.acceptSelfie(try JourneyFixtures.selfie(), token: try XCTUnwrap(journey.captureToken)))
        try await engine.waitForCall()
        await engine.complete(score: 0.75)
        try await wait { journey.phase == .result }
        XCTAssertEqual(stops, 1, "The pre-start reset is the only stop before result; NFC and selfie transitions must retain workflow acquisition")
        journey.send(.details)
        try await events.waitForRead(1)
        XCTAssertEqual(journey.motionProjectionState, .loading)
        let sheet = try XCTUnwrap(host.navigation.presentedViewController as? UINavigationController)
        let renderer = try XCTUnwrap(sheet.topViewController as? ReferenceRenderer)
        await events.release()
        try await wait { journey.motionProjectionState == .ready }
        XCTAssertTrue(host.navigation.presentedViewController === sheet)
        XCTAssertTrue(sheet.topViewController === renderer)
        XCTAssertFalse(descendants(renderer.view).contains { $0.accessibilityIdentifier?.hasPrefix("telemetry.motion.windowStart.value") == true })
        let heading = renderer.accessibilityElement(identifier: "workflow.step")
        let boundary = journey.workflowMotion?.throughEventID
        for _ in 0..<4 { _ = try await recorder.record("sensor.window") }
        XCTAssertTrue(renderer.accessibilityElement(identifier: "workflow.step") === heading,
            "Sensor heartbeats must not recreate sheet content or move accessibility focus")
        XCTAssertEqual(journey.workflowMotion?.throughEventID, boundary)
        journey.send(.details)
        try await wait { host.navigation.presentedViewController == nil }
        await events.hold()
        journey.send(.details)
        try await events.waitForRead(2)
        journey.send(.done)
        XCTAssertEqual(stops, 2)
        await events.release()
        try await wait { host.navigation.presentedViewController == nil }
        XCTAssertEqual(journey.motionProjectionState, .idle)
        XCTAssertNil(journey.workflowMotion)
        XCTAssertFalse(journey.detailsExpanded)
    }

    @MainActor func testResultSummaryKeepsExactScoreAndMovesImplementationAndRangesToDetails() throws {
        let score = 0.612912746983194
        let summary = FaceComparisonPresentation.summary(phase: .completed(score))
        let scoreRow = try XCTUnwrap(summary.first { $0.identifier == "comparison.score" })
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 17
        XCTAssertEqual(scoreRow.text, formatter.string(from: NSNumber(value: score)))
        XCTAssertEqual(summary.first { $0.identifier == "comparison.status" }?.text,
            KenshikiCopy.text("comparison.observation.summary"))
        XCTAssertFalse(summary.contains { $0.identifier == "comparison.aura.duration" || $0.identifier == "comparison.telemetry.title" })
        let fields = [FaceTelemetryField(key: "telemetry.workflowMotion.accelerationX", value: .range(-0.2, 0.8)),
            FaceTelemetryField(key: "telemetry.workflowMotion.rotationX", value: .range(2, 1)),
            FaceTelemetryField(key: "telemetry.workflowMotion.gravityX", value: .range(.nan, 1))]
        let details = FaceComparisonPresentation.telemetry(fields)
        XCTAssertEqual(details.filter { $0.text == KenshikiCopy.text("telemetry.invalid") }.count, 2)
        XCTAssertFalse(details.contains { $0.text.contains("nan") })
    }

    @MainActor func testJourneyCopyReportUsesCurrentResultAndRejectsRetiredButton() async throws {
        let engine = JourneyComparisonProbe()
        let journey = make(engine)
        var copied: [String] = []
        let host = PassportFaceJourneyHost(controller: journey, makePassport: {
            PassportFlowHost(effects: PassportFlowEffects(startCamera: { _, _ in }, stopCamera: {},
                read: { _, _, _ in throw PassportReadFailure.unsupported }))
        }, makeCapture: { BiometricCaptureHost(controller: BiometricCaptureController { JourneyCaptureDriver() }) },
            writeClipboard: { copied.append($0) })
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host.navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; journey.send(.cancel) }
        journey.send(.copyReport)
        XCTAssertTrue(copied.isEmpty)
        journey.send(.begin)
        XCTAssertTrue(journey.acceptPassport(JourneyFixtures.reference(), session: journey.sessionID))
        XCTAssertTrue(journey.acceptSelfie(try JourneyFixtures.selfie(), token: try XCTUnwrap(journey.captureToken)))
        try await engine.waitForCall()
        await engine.complete(score: 0.75)
        try await wait { journey.phase == .result }
        XCTAssertFalse(hasButton("comparison.export.copy", host))
        try button("journey.viewDetails", host).sendActions(for: .touchUpInside)
        try await wait { self.hasButton("comparison.export.copy", host) && host.navigation.presentedViewController?.isBeingPresented == false }
        let copy = try button("comparison.export.copy", host)
        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(copied.count, 1)
        let report = try XCTUnwrap(copied.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        XCTAssertEqual((json["aura"] as? [String: Any])?["cosineSimilarity"] as? Double, 0.75)
        XCTAssertTrue(journey.detailsExpanded)
        journey.send(.done)
        XCTAssertFalse(journey.detailsExpanded)
        try await wait { host.navigation.presentedViewController == nil }
        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(copied.count, 1)
    }

    @MainActor func testNewJourneyWaitsForCancelledNFCReadToSettle() async throws {
        let journey = make(JourneyComparisonProbe())
        var starts = 0
        var reads = 0
        var passports: [PassportFlowHost] = []
        var pending: CheckedContinuation<PassportReadObservation, Error>?
        let host = PassportFaceJourneyHost(controller: journey, makePassport: {
            let passport = PassportFlowHost(effects: PassportFlowEffects(startCamera: { _, _ in starts += 1 },
                stopCamera: {}, read: { _, _, _ in
                    reads += 1
                    return try await withCheckedThrowingContinuation { pending = $0 }
                }))
            passport.controller.supplyTrustAnchors(URL(fileURLWithPath: "/synthetic-trust.pem"))
            passports.append(passport)
            return passport
        }, makeCapture: { BiometricCaptureHost(controller: BiometricCaptureController { JourneyCaptureDriver() }) })
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host.navigation
        window.makeKeyAndVisible()
        defer { pending?.resume(throwing: PassportReadFailure.cancelled); window.isHidden = true; journey.send(.cancel) }
        journey.send(.begin)
        try await wait { starts == 1 }
        let first = try XCTUnwrap(passports.first).controller
        first.send(.manualKey(.init(documentNumber: "L898902C3", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415")))
        first.send(.confirmKey)
        first.send(.scan)
        try await wait { reads == 1 }
        journey.send(.cancel)
        journey.send(.begin)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(passports.count, 1)
        XCTAssertEqual(journey.phase, .passport)
        journey.send(.cancel)
        journey.send(.begin)
        pending?.resume(throwing: PassportReadFailure.cancelled)
        pending = nil
        try await wait { starts == 2 }
        XCTAssertEqual(passports.count, 2)
        XCTAssertNil(journey.reference)
        XCTAssertEqual(reads, 1)
    }
    @MainActor func testCameraRetryDoesNotIntroduceAnotherStartScreen() async throws {
        let journey = make(JourneyComparisonProbe())
        var starts = 0
        let host = PassportFaceJourneyHost(controller: journey, makePassport: {
            PassportFlowHost(effects: PassportFlowEffects(startCamera: { _, _ in
                starts += 1
                throw PassportReadFailure.readFailed
            }, stopCamera: {}, read: { _, _, _ in throw PassportReadFailure.unsupported }))
        }, makeCapture: { BiometricCaptureHost(controller: BiometricCaptureController { JourneyCaptureDriver() }) })
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host.navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; journey.send(.cancel) }
        journey.send(.begin)
        try await wait { starts == 1 && self.hasButton("passport.retry", host) }
        try button("passport.retry", host).sendActions(for: .touchUpInside)
        try await wait { starts == 2 }
        XCTAssertFalse(hasButton("passport.start", host))
        XCTAssertEqual(journey.phase, .passport)
    }
    @MainActor func testRetiredPassportFactoryCannotMountOrStartAcquisition() {
        let journey = make(JourneyComparisonProbe())
        let host = PassportFaceJourneyHost(controller: journey, makePassport: {
            journey.send(.cancel)
            return PassportFlowHost(effects: PassportFlowEffects(startCamera: { _, _ in XCTFail("Retired camera") },
                stopCamera: {}, read: { _, _, _ in throw PassportReadFailure.unsupported }))
        }, makeCapture: { BiometricCaptureHost(controller: BiometricCaptureController { JourneyCaptureDriver() }) })
        journey.send(.begin)
        XCTAssertEqual(journey.phase, .introduction)
        XCTAssertTrue(host.navigation.topViewController is ReferenceRenderer)
    }

    @MainActor func testRetiredSelfieFactoryCannotMountOrRestartCapture() {
        let journey = make(JourneyComparisonProbe())
        let capture = BiometricCaptureController { XCTFail("Retired capture"); return JourneyCaptureDriver() }
        let host = PassportFaceJourneyHost(controller: journey, makePassport: {
            PassportFlowHost(effects: PassportFlowEffects(startCamera: { _, _ in }, stopCamera: {},
                read: { _, _, _ in throw PassportReadFailure.unsupported }))
        }, makeCapture: {
            journey.send(.cancel)
            return BiometricCaptureHost(controller: capture)
        })
        journey.send(.begin)
        journey.acceptPassport(JourneyFixtures.reference(), session: journey.sessionID)
        XCTAssertEqual(journey.phase, .introduction)
        XCTAssertNil(journey.reference)
        XCTAssertEqual(capture.phase, .finished)
        XCTAssertTrue(host.navigation.topViewController is ReferenceRenderer)
    }
    @MainActor func testExplicitSelfieAdmissionWaitsForVisibilityAndCannotSurviveWithdrawal() {
        for withdrawal in [0, 1, 2] {
            var creations = 0
            let controller = BiometricCaptureController { creations += 1; return JourneyCaptureDriver() }
            controller.send(.allowWhenVisible)
            XCTAssertEqual(creations, 0)
            switch withdrawal {
            case 0: controller.send(.hidden)
            case 1: controller.setForeground(false); controller.setForeground(true)
            default: controller.send(.cancel)
            }
            controller.send(.visible)
            XCTAssertEqual(creations, 0)
        }
    }

    @MainActor func testExplicitPassportBeginWaitsForVisibilityAndCannotSurviveWithdrawal() async {
        var starts = 0
        let controller = PassportFlowController(effects: PassportFlowEffects(startCamera: { _, _ in starts += 1 },
            stopCamera: {}, read: { _, _, _ in throw PassportReadFailure.unsupported }))
        controller.send(.beginJourney)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(starts, 0)
        controller.send(.hidden)
        controller.send(.visible)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(starts, 0)
        controller.send(.beginJourney)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(starts, 1)
        controller.send(.cancel)
    }
    @MainActor func testOrderedJourneyConsumesEachHandoffOnceAndRetakeKeepsPassport() async throws {
        let engine = JourneyComparisonProbe()
        let journey = make(engine)
        XCTAssertEqual(journey.phase, .introduction)
        journey.send(.begin)
        let reference = JourneyFixtures.reference()
        XCTAssertTrue(journey.acceptPassport(reference, session: journey.sessionID))
        XCTAssertFalse(journey.acceptPassport(reference, session: journey.sessionID))
        let token = try XCTUnwrap(journey.captureToken)
        let selfie = try JourneyFixtures.selfie()
        XCTAssertTrue(journey.acceptSelfie(selfie, token: token))
        XCTAssertFalse(journey.acceptSelfie(selfie, token: token))
        try await engine.waitForCall()
        await engine.complete(score: 0.5)
        try await wait { journey.phase == .result }
        journey.send(.details)
        XCTAssertTrue(journey.detailsExpanded)
        journey.send(.retake)
        XCTAssertEqual(journey.reference?.attemptID, reference.attemptID)
        XCTAssertNotEqual(journey.captureToken, token)
        XCTAssertFalse(journey.detailsExpanded)
        XCTAssertFalse(journey.acceptSelfie(selfie, token: token))
        journey.cancelCapture(token)
        XCTAssertEqual(journey.phase, .selfie)
        journey.send(.cancel)
        XCTAssertNil(journey.reference)
        XCTAssertNil(journey.captureToken)
    }

    @MainActor func testCancelledPassportCannotEnterAnotherSession() {
        let journey = make(JourneyComparisonProbe())
        journey.send(.begin)
        let retired = journey.sessionID
        journey.send(.cancel)
        journey.send(.begin)
        XCTAssertFalse(journey.acceptPassport(JourneyFixtures.reference(), session: retired))
        XCTAssertNil(journey.reference)
        XCTAssertEqual(journey.phase, .passport)
    }

    @MainActor func testBackgroundClearsEvidenceAndFencesNonCooperativeComparison() async throws {
        let engine = JourneyComparisonProbe()
        let journey = make(engine)
        journey.send(.begin)
        journey.acceptPassport(JourneyFixtures.reference(), session: journey.sessionID)
        let token = try XCTUnwrap(journey.captureToken)
        journey.acceptSelfie(try JourneyFixtures.selfie(), token: token)
        try await engine.waitForCall()
        journey.interrupt()
        XCTAssertEqual(journey.phase, .interrupted)
        XCTAssertNil(journey.reference)
        XCTAssertNil(journey.captureToken)
        await engine.complete(score: 1)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(journey.phase, .interrupted)
        journey.send(.begin)
        XCTAssertEqual(journey.phase, .passport)
        XCTAssertFalse(journey.acceptSelfie(try JourneyFixtures.selfie(), token: token))
    }

    @MainActor func testReentrantCancellationBeforeInferencePreventsExecution() async throws {
        let engine = JourneyComparisonProbe()
        let journey = make(engine)
        journey.send(.begin)
        journey.acceptPassport(JourneyFixtures.reference(), session: journey.sessionID)
        let token = try XCTUnwrap(journey.captureToken)
        journey.onChange = { if journey.phase == .comparing { journey.send(.cancel) } }
        XCTAssertFalse(journey.acceptSelfie(try JourneyFixtures.selfie(), token: token))
        let count = await engine.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(journey.phase, .introduction)
        XCTAssertNil(journey.reference)
    }

    @MainActor func testUnverifiedOrMissingPortraitCannotAdvance() {
        let journey = make(JourneyComparisonProbe())
        journey.send(.begin)
        for reference in [JourneyFixtures.reference(verified: false), JourneyFixtures.reference(photo: nil)] {
            XCTAssertFalse(journey.acceptPassport(reference, session: journey.sessionID))
            XCTAssertEqual(journey.phase, .passport)
        }
    }

    @MainActor func testExamplesCannotInterruptAnActiveJourneyAndDoneClearsResults() async throws {
        let engine = JourneyComparisonProbe()
        let journey = make(engine)
        var openings = 0
        journey.onExamples = { openings += 1 }
        journey.send(.developerTools)
        journey.send(.examples)
        journey.send(.homeBack)
        journey.send(.begin)
        journey.send(.examples)
        XCTAssertEqual(openings, 1)
        journey.acceptPassport(JourneyFixtures.reference(), session: journey.sessionID)
        journey.acceptSelfie(try JourneyFixtures.selfie(), token: try XCTUnwrap(journey.captureToken))
        try await engine.waitForCall()
        await engine.complete(score: 0.5)
        try await wait { journey.phase == .result }
        journey.send(.done)
        XCTAssertEqual(journey.phase, .introduction)
        XCTAssertEqual(journey.comparisonPhase, .idle)
        XCTAssertNil(journey.reference)
    }

    @MainActor func testNativeJourneyReadsOnceReviewsSelfieAndShowsCombinedResultWithoutTabs() async throws {
        let engine = JourneyComparisonProbe()
        let journey = make(engine)
        let selfie = try JourneyFixtures.selfie()
        let reference = JourneyFixtures.reference(photo: selfie.capture.encodedPNG)
        var reads = 0
        var cameraStarts = 0
        var passport: PassportFlowHost?
        var captures: [BiometricCaptureController] = []
        var drivers: [JourneyCaptureDriver] = []
        let host = PassportFaceJourneyHost(controller: journey, makePassport: {
            let host = PassportFlowHost(effects: PassportFlowEffects(startCamera: { _, _ in cameraStarts += 1 }, stopCamera: {}, read: { _, _, _ in
                reads += 1
                return reference.read
            }))
            host.controller.supplyTrustAnchors(URL(fileURLWithPath: "/synthetic-trust.pem"))
            passport = host
            return host
        }, makeCapture: {
            let driver = JourneyCaptureDriver()
            drivers.append(driver)
            let capture = BiometricCaptureController { driver }
            captures.append(capture)
            return BiometricCaptureHost(controller: capture)
        })
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host.navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; journey.send(.cancel) }
        try button("journey.begin", host).sendActions(for: .touchUpInside)
        try await wait { cameraStarts == 1 }
        try button("passport.manual", host).sendActions(for: .touchUpInside)
        for (id, text) in [("passport.field.document", "L898902C3"), ("passport.field.birth", "740812"), ("passport.field.expiry", "120415")] {
            let field = try XCTUnwrap(descendants(try XCTUnwrap(host.navigation.topViewController).view)
                .first { $0.accessibilityIdentifier == id } as? UITextField)
            field.text = text
            field.sendActions(for: .editingChanged)
        }
        try button("journey.readChip", host).sendActions(for: .touchUpInside)
        try await wait { reads == 1 && self.hasButton("journey.continueSelfie", host) }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(passport?.controller.phase, .result)
        XCTAssertNil(passport?.controller.failure)
        XCTAssertEqual(host.navigation.topViewController?.title, KenshikiCopy.text("journey.progress.passport"))
        try button("journey.continueSelfie", host).sendActions(for: .touchUpInside)
        try await wait { captures.first?.phase == .capturing }
        XCTAssertEqual(host.navigation.topViewController?.title, KenshikiCopy.text("journey.progress.selfie"))
        drivers[0].onCapture?(selfie.capture)
        try await wait { captures[0].phase == .captured }
        try button("comparison.compare", host).sendActions(for: .touchUpInside)
        try await engine.waitForCall()
        let input = await engine.input
        XCTAssertEqual(input?.reference, reference.read.portrait)
        XCTAssertEqual(input?.selfie, selfie.capture.encodedPNG)
        XCTAssertEqual(input?.captureContext?.receipt, selfie.capture.admissionReceipt)
        XCTAssertEqual(input?.captureContext?.captureID, selfie.capture.id)
        await engine.complete(score: 0.5)
        try await wait { journey.phase == .result }
        XCTAssertEqual(host.navigation.viewControllers.count, 1)
        XCTAssertFalse(host.navigation.topViewController is UITabBarController)
        XCTAssertEqual(host.navigation.topViewController?.title, KenshikiCopy.text("journey.progress.result"))
        let result = try XCTUnwrap(host.navigation.topViewController as? ReferenceRenderer)
        XCTAssertNotNil(result.accessibilityElement(identifier: "comparison.score"))
        XCTAssertNotNil(result.accessibilityElement(identifier: "journey.passportPassed"))
        XCTAssertEqual(result.primaryRegion.arrangedSubviews.map(\.accessibilityIdentifier), ["journey.done"])
        XCTAssertFalse(hasButton("journey.retake", host))
        XCTAssertNil(result.accessibilityElement(identifier: "comparison.aura.duration"))
        XCTAssertNil(result.accessibilityElement(identifier: "comparison.observation"))
        let menu = try XCTUnwrap(result.navigationItem.rightBarButtonItem?.menu)
        XCTAssertEqual(menu.children.compactMap { ($0 as? UIAction)?.identifier.rawValue },
            ["journey.retake", "journey.viewDetails"])
        try button("journey.viewDetails", host).sendActions(for: .touchUpInside)
        XCTAssertTrue(journey.detailsExpanded)
        let sheet = try XCTUnwrap(host.navigation.presentedViewController as? UINavigationController)
        try await wait { !sheet.isBeingPresented }
        let details = try XCTUnwrap(sheet.topViewController as? ReferenceRenderer)
        XCTAssertTrue(details.view.accessibilityViewIsModal)
        XCTAssertTrue(details.primaryRegion.arrangedSubviews.isEmpty)
        XCTAssertNotNil(details.accessibilityElement(identifier: "passport.result.ca"))
        XCTAssertNotNil(details.accessibilityElement(identifier: "comparison.telemetry.title"))
        XCTAssertEqual(details.navigationItem.rightBarButtonItem?.accessibilityIdentifier, "journey.details.close")
        journey.send(.details)
        XCTAssertFalse(journey.detailsExpanded)
        try await wait { host.navigation.presentedViewController == nil }
        XCTAssertNotNil(result.accessibilityElement(identifier: "comparison.score"))
        journey.send(.retake)
        try await wait { captures.count == 2 && captures[1].phase == .capturing }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(journey.reference?.read.portrait, reference.read.portrait)
        try button("capture.cancel", host).sendActions(for: .touchUpInside)
        XCTAssertEqual(journey.phase, .introduction)
        XCTAssertNil(journey.reference)
    }







    @MainActor private func dualHost(_ journey: PassportFaceJourneyController) -> PassportFaceJourneyHost {
        PassportFaceJourneyHost(controller: journey, makePassport: {
            PassportFlowHost(effects: PassportFlowEffects(startCamera: { _, _ in }, stopCamera: {},
                read: { _, _, _ in throw PassportReadFailure.unsupported }))
        }, makeCapture: { BiometricCaptureHost(controller: BiometricCaptureController { JourneyCaptureDriver() }) })
    }

    @MainActor private func make(_ engine: JourneyComparisonProbe) -> PassportFaceJourneyController {
        PassportFaceJourneyController(comparison: FaceComparisonController { try await engine.compare($0) })
    }
    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    @MainActor private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func hasButton(_ id: String, _ host: PassportFaceJourneyHost) -> Bool {
        let navigation = (host.navigation.presentedViewController as? UINavigationController) ?? host.navigation
        guard let view = navigation.topViewController?.view else { return false }
        return descendants(view).contains { $0 is UIButton && $0.accessibilityIdentifier == id }
    }
    @MainActor private func button(_ id: String, _ host: PassportFaceJourneyHost) throws -> UIButton {
        let navigation = (host.navigation.presentedViewController as? UINavigationController) ?? host.navigation
        let view = try XCTUnwrap(navigation.topViewController).view!
        return try XCTUnwrap(descendants(view).first { $0 is UIButton && $0.accessibilityIdentifier == id } as? UIButton)
    }
}

private actor RetakeFailureAdmissionWriter {
    private var retake: CheckedContinuation<Void, Error>?
    private var starts: [CheckedContinuation<Void, Never>] = []
    private var failFirstRetake = true
    private var holdStarts = true
    private(set) var startedWorkflows: [UUID] = []
    func append(_ event: SavedWorkflowEvent) async throws {
        if event.action == "selfie.retake", failFirstRetake {
            failFirstRetake = false
            try await withCheckedThrowingContinuation { retake = $0 }
        }
        if event.action == "workflow.started" {
            startedWorkflows.append(event.workflowID)
            if startedWorkflows.count > 1, holdStarts {
                await withCheckedContinuation { starts.append($0) }
            }
        }
    }
    func failRetake() { retake?.resume(throwing: FaceWorkflowStorageFailure.unavailable); retake = nil }
    func releaseStarts() {
        holdStarts = false
        let pending = starts; starts.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func waitForRetake() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while retake == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(retake)
    }
    func waitForNewStart() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while starts.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(starts.isEmpty)
    }
}

private actor HeldMotionProjectionEvents {
    private var events: [SavedWorkflowEvent] = []
    private var held = true
    private var readCount = 0
    private var waiting: CheckedContinuation<Void, Never>?
    func append(_ event: SavedWorkflowEvent) { events.append(event) }
    func load(_ workflow: UUID, _ cursor: Int) async -> [SavedWorkflowEvent] {
        readCount += 1
        if held { await withCheckedContinuation { waiting = $0 } }
        return Array(events.filter { $0.workflowID == workflow }.dropFirst(cursor))
    }
    func hold() { held = true }
    func release() { held = false; waiting?.resume(); waiting = nil }
    func waitForRead(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while readCount < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertGreaterThanOrEqual(readCount, count)
    }
}

private actor JourneyComparisonProbe {
    var input: FaceComparisonInput?
    var count = 0
    private var completion: CheckedContinuation<FaceComparisonCompletion, Error>?
    func compare(_ value: FaceComparisonInput) async throws -> FaceComparisonCompletion {
        input = value
        count += 1
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func waitForCall() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while count == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(count, 1)
    }
    func complete(score: Double) {
        guard let input else { return }
        completion?.resume(returning: FaceComparisonCompletion(operationID: input.operationID,
            referenceSHA256: input.referenceSHA256, selfieSHA256: input.selfieSHA256, score: score))
        completion = nil
    }
}

@MainActor private final class JourneyCaptureDriver: BiometricCaptureDriver {
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

private enum JourneyFixtures {
    static func selfie() throws -> AcceptedSelfie {
        let capture = try CaptureTestFixtures.capture()
        return AcceptedSelfie(capture: capture, snapshot: try SelfiePixelBridge.decodeOrientedPNG(
            capture.encodedPNG, expectedSourceSHA256: capture.sha256))
    }
    static func reference(photo: Data? = Data([1]), verified: Bool = true) -> AcceptedPassportPortrait {
        let read = PassportReadObservation(documentNumber: "L898902C3", surname: "ERIKSSON", givenNames: "ANNA MARIA",
            nationality: "UTO", issuingState: "UTO", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415",
            sex: "F", personalNumber: nil, dateOfIssue: nil, issuingAuthority: nil, placeOfBirth: nil,
            basicAccessControl: .succeeded, pace: .notPerformed, activeAuthentication: .notPerformed,
            chipAuthentication: .notPerformed, countrySigningChain: .succeeded,
            documentSignature: verified ? .succeeded : .failed, dataGroupHashes: .succeeded,
            documentSigningCertificateDER: nil, activeAuthenticationChallenge: nil, activeAuthenticationSignature: nil,
            securityObject: Data([1]), dataGroups: [:], declaredDataGroups: ["DG2"], dg2: Data([0x75, 1, 1]),
            portrait: photo, dg2Digest: String(repeating: "a", count: 64), dg2DigestAlgorithm: "SHA-256", chipAuthenticationResponse: nil)
        return AcceptedPassportPortrait(attemptID: UUID(), read: read, printedMRZ: nil)
    }
}

private actor JourneyVisualProbe {
    private var input: FaceVisualAssessmentInput?
    private var completion: CheckedContinuation<FaceVisualAssessmentCompletion, Error>?
    func assess(_ input: FaceVisualAssessmentInput) async throws -> FaceVisualAssessmentCompletion {
        self.input = input
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func waitForCall() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while completion == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(completion)
    }
    func complete() {
        guard let input else { return }
        completion?.resume(returning: FaceVisualAssessmentCompletion(operationID: input.operationID,
            referenceSHA256: input.referenceSHA256, selfieSHA256: input.selfieSHA256,
            consistency: .uncertain, issues: [.pose], durationMilliseconds: 125))
        completion = nil
    }
}
