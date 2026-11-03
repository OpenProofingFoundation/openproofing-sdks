import Foundation
import UIKit
@testable import PassportSDK
@testable import PassportMRZCapture
import XCTest
@testable import KenshikiReference

@MainActor private final class PassportFlowProbe {
    var cameraStarts = 0
    var cameraStops = 0
    var reads = 0
    var candidates: (@MainActor @Sendable ([[String]]) -> Void)?
    var cameraFailure: (@MainActor @Sendable () -> Void)?
    var readEvent: (@MainActor @Sendable (PassportReadEvent) -> Void)?
    var pendingRead: CheckedContinuation<PassportReadObservation, Error>?
    var order: [String] = []
    var effects: PassportFlowEffects {
        PassportFlowEffects(startCamera: { candidates, failure in
            self.cameraStarts += 1
            self.candidates = candidates
            self.cameraFailure = failure
            self.order.append("camera-start")
        }, stopCamera: {
            self.cameraStops += 1
            self.order.append("camera-stop")
        }, read: { _, _, event in
            self.reads += 1
            self.readEvent = event
            self.order.append("nfc-read")
            return try await withCheckedThrowingContinuation { self.pendingRead = $0 }
        })
    }
    func finish(_ read: PassportReadObservation) { pendingRead?.resume(returning: read); pendingRead = nil }
    func fail(_ error: PassportReadFailure) { pendingRead?.resume(throwing: error); pendingRead = nil }
}

final class PassportFlowControllerTests: XCTestCase {
    @MainActor func testDiagnosticCheckpointObserversCannotResurrectRetiredSuccessOrFailure() async {
        for persistenceFails in [false, true] {
            for cancel in [false, true] {
                let probe = PassportFlowProbe()
                let controller = ready(probe)
                let diagnostics = PassportDiagnosticProbe()
                let marker = "flowCheck=checkpoint passed=\(!persistenceFails)"
                controller.persistCompletedRead = { _ in
                    if persistenceFails { throw PassportCaptureStorageFailure.unavailable }
                }
                controller.diagnosticObserver = { value in
                    diagnostics.append(value)
                    if value.message == marker { MainActor.assumeIsolated { controller.send(cancel ? .cancel : .restart) } }
                }
                controller.send(.scan)
                await settle()
                let retiredAttempt = controller.attemptID
                probe.finish(observation())
                await settle()
                XCTAssertTrue(diagnostics.messages.contains(marker))
                XCTAssertNotEqual(controller.attemptID, retiredAttempt)
                XCTAssertEqual(controller.phase, .start)
                XCTAssertNil(controller.failure)
                XCTAssertNil(controller.result)
                XCTAssertNil(controller.resultServerVerification)
                XCTAssertNil(controller.accessFields)
                controller.send(.cancel)
                await controller.waitForRetirement()
            }
        }
    }

    @MainActor func testDiagnosticReadObserversCannotOverwriteRetiredFlowOrStartPersistence() async {
        let cases: [(String, Int, Int, Bool)] = [
            ("flowCheck=returnedBinding passed=true", -1, -1, true),
            ("flowCheck=evidenceIntegrity passed=true", -1, -1, false),
            ("flowCheck=evidenceIntegrity passed=false", 3, -1, false),
            ("flow=correspondence ", -1, -1, false),
            ("flow=correspondence ", -1, 0, false)
        ]
        for (marker, variant, substitution, server) in cases {
            for cancel in [false, true] {
                let probe = PassportFlowProbe()
                let read = observation(variant: variant, substitution: substitution)
                var effects = probe.effects
                if server { effects.serverRead = { _, _, _, _, _ in .init(read: read, verification: self.verification(read)) } }
                let controller = PassportFlowController(effects: effects)
                let diagnostics = PassportDiagnosticProbe()
                var writes = 0
                controller.persistCompletedRead = { _ in writes += 1 }
                controller.diagnosticObserver = { value in
                    diagnostics.append(value)
                    if value.message.hasPrefix(marker) { MainActor.assumeIsolated { controller.send(cancel ? .cancel : .restart) } }
                }
                controller.send(.visible)
                controller.send(.manualKey(fields()))
                controller.send(.confirmKey)
                controller.supplyTrustAnchors(trust())
                controller.send(.scan)
                let retiredAttempt = controller.attemptID
                await settle()
                if !server { probe.finish(read) }
                await settle()
                XCTAssertTrue(diagnostics.messages.contains { $0.hasPrefix(marker) })
                XCTAssertNotEqual(controller.attemptID, retiredAttempt)
                XCTAssertEqual(controller.phase, .start)
                XCTAssertNil(controller.failure)
                XCTAssertNil(controller.result)
                XCTAssertNil(controller.accessFields)
                XCTAssertEqual(controller.correspondenceMismatchedFields, [])
                XCTAssertEqual(writes, 0)
                controller.send(.cancel)
                await controller.waitForRetirement()
            }
        }
    }

    @MainActor func testCorrespondenceRecoveryRescansPageBeforeFreshConfirmationAndRead() async throws {
        let probe = PassportFlowProbe()
        let host = PassportFlowHost(effects: probe.effects)
        host.journeyMode = true
        let page = host.makeRenderer()
        page.loadViewIfNeeded()
        let controller = host.controller
        controller.send(.visible)
        controller.send(.startMRZ)
        await settle()
        let oldCandidates = try XCTUnwrap(probe.candidates)
        oldCandidates(mrz())
        controller.send(.confirmKey)
        controller.supplyTrustAnchors(trust())
        controller.send(.scan)
        await settle()
        let oldEvent = probe.readEvent
        probe.finish(observation(substitution: 3))
        await settle()
        XCTAssertEqual(controller.failure, .correspondence)
        XCTAssertNil(passportButton("passport.retry", in: page.view))
        XCTAssertNil(passportButton("passport.manual", in: page.view))
        let oldAttempt = controller.attemptID
        try XCTUnwrap(passportButton("passport.restart", in: page.view)).sendActions(for: .touchUpInside)
        await settle()
        XCTAssertNotEqual(controller.attemptID, oldAttempt)
        XCTAssertEqual(controller.phase, .mrz)
        XCTAssertEqual(probe.cameraStarts, 2)
        XCTAssertEqual(probe.reads, 1)
        XCTAssertNil(controller.printedMRZ)
        XCTAssertNil(controller.accessFields)
        oldCandidates(mrz())
        oldEvent?(.failure(.readFailed))
        XCTAssertEqual(controller.phase, .mrz)
        XCTAssertNil(controller.failure)
        try XCTUnwrap(probe.candidates)(mrz())
        XCTAssertEqual(controller.phase, .confirm)
        controller.send(.scan)
        await settle()
        XCTAssertEqual(probe.reads, 1, "A new page scan still requires explicit key confirmation")
        controller.send(.confirmKey)
        controller.send(.scan)
        await settle()
        XCTAssertEqual(probe.reads, 2)
        probe.finish(observation())
        await settle()
        XCTAssertEqual(controller.phase, .result)
        controller.send(.cancel)
        await controller.waitForRetirement()
    }

    @MainActor func testVerifiedServerMismatchUsesPulseFieldSpecificRecoveryAndRetainsRefusal() async throws {
        let cases: [(Int, PassportCorrespondenceObservation.Field, String)] = [
            (0, .documentNumber, "passport.failure.correspondence.key"),
            (1, .birthDate, "passport.failure.correspondence.key"),
            (2, .expiryDate, "passport.failure.correspondence.key"),
            (3, .surname, "passport.failure.correspondence.surname"),
            (4, .givenNames, "passport.failure.correspondence.givenNames")
        ]
        for (substitution, field, copyKey) in cases {
            let probe = PassportFlowProbe()
            let read = observation(substitution: substitution)
            var effects = probe.effects
            effects.serverRead = { _, _, _, _, _ in
                .init(read: read, verification: self.verification(read))
            }
            let diagnostics = PassportDiagnosticProbe()
            let host = PassportFlowHost(effects: effects)
            let page = host.makeRenderer()
            page.loadViewIfNeeded()
            let controller = host.controller
            controller.diagnosticObserver = { diagnostics.append($0) }
            var writes = 0
            controller.persistCompletedRead = { _ in writes += 1 }
            controller.send(.visible)
            controller.send(.startMRZ)
            await settle()
            try XCTUnwrap(probe.candidates)(mrz())
            controller.send(.confirmKey)
            controller.supplyTrustAnchors(trust())
            controller.send(.scan)
            await settle()
            XCTAssertEqual(controller.failure, .correspondence)
            XCTAssertEqual(controller.correspondenceMismatchedFields, [field])
            XCTAssertNil(controller.result)
            XCTAssertEqual(writes, 0)
            XCTAssertTrue(diagnostics.messages.contains("flowCheck=returnedBinding passed=true"))
            XCTAssertTrue(diagnostics.messages.contains("flowCheck=evidenceIntegrity passed=true"))
            XCTAssertTrue(diagnostics.messages.contains { $0.hasPrefix("flow=correspondence ") && $0.contains(field.rawValue + "=differs") })
            func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
            let message = try XCTUnwrap(descendants(page.view).first { $0.accessibilityIdentifier == "passport.message" } as? UILabel)
            XCTAssertEqual(message.text, KenshikiCopy.text(copyKey))
            XCTAssertNotEqual(message.text, KenshikiCopy.text("passport.failure.integrity"))
            for secret in ["L898902C3", "ERIKSSON", "SUBSTITUTED", "ANNA MARIA", "session-secret", "nonce-secret"] {
                XCTAssertFalse(diagnostics.messages.contains { $0.contains(secret) })
            }
            controller.send(.cancel)
            await controller.waitForRetirement()
        }
    }

    @MainActor func testVerifiedServerReadReportsCheckpointFailureSeparatelyFromProofFailure() async {
        let read = observation()
        var effects = PassportFlowProbe().effects
        effects.serverRead = { _, _, _, _, _ in .init(read: read, verification: self.verification(read)) }
        let diagnostics = PassportDiagnosticProbe()
        let controller = PassportFlowController(effects: effects)
        controller.diagnosticObserver = { diagnostics.append($0) }
        controller.persistCompletedRead = { _ in throw PassportCaptureStorageFailure.unavailable }
        controller.send(.visible)
        controller.send(.manualKey(fields()))
        controller.send(.confirmKey)
        controller.supplyTrustAnchors(trust())
        controller.send(.scan)
        await settle()
        XCTAssertEqual(controller.phase, .saveFailure)
        XCTAssertNil(controller.failure)
        XCTAssertNil(controller.result)
        XCTAssertTrue(diagnostics.messages.contains("flowCheck=returnedBinding passed=true"))
        XCTAssertTrue(diagnostics.messages.contains("flowCheck=evidenceIntegrity passed=true"))
        XCTAssertTrue(diagnostics.messages.contains("flow=correspondence documentNumber=matches birthDate=matches expiryDate=matches surname=notCompared givenNames=notCompared"))
        XCTAssertTrue(diagnostics.messages.contains("flowCheck=checkpoint passed=false"))
        XCTAssertFalse(diagnostics.messages.contains { $0.contains("passed=false") && !$0.contains("checkpoint") })
        controller.send(.cancel)
        await controller.waitForRetirement()
    }

    private func verification(_ read: PassportReadObservation) -> PassportServerVerification {
        .init(sessionID: "session-secret", nonceID: "nonce-secret", verifiedAt: Date(), validator: "passport_validator",
            activeAuthentication: false, chipAuthentication: false, assurance: "passive_authentication_only",
            trustBundleVersion: nil, securityObjectSHA256: SavedPassportCapture.digest(read.securityObject))
    }

    @MainActor func testNativeMRZFramesReachConfirmationWithoutTemporalGuideGateAndFenceRetiredFrames() async throws {
        var frames: [@MainActor @Sendable (MRZOCRFrame) -> Void] = []
        var sessions: [NativeMRZSession] = []
        var stops = 0
        let native = PassportNativeEffects(makeMRZSession: {
            let session = NativeMRZSession(effects: .init(previewSession: nil, authorize: { true },
                start: { frame, _ in frames.append(frame) }, stop: { stops += 1 }))
            sessions.append(session)
            return session
        })
        let controller = PassportFlowController(effects: native.effects)
        controller.send(.visible)
        controller.send(.startMRZ)
        await settle()
        XCTAssertEqual(sessions.first?.state, .running)
        let deliver = try XCTUnwrap(frames.first)
        let lines = mrz()
        let otherName = "P<UTODOE<<JANE".padding(toLength: 44, withPad: "<", startingAt: 0)
        deliver(.init(candidates: [lines[1]], timestamp: 1, policy: .engineeringV1))
        deliver(.init(candidates: [lines[0], [otherName], lines[1]], timestamp: 10, policy: .engineeringV1))
        XCTAssertEqual(controller.phase, .mrz)
        XCTAssertNil(controller.printedMRZ)
        XCTAssertNil(controller.accessFields)
        deliver(.init(candidates: lines, timestamp: 100, policy: .engineeringV1))
        XCTAssertEqual(controller.phase, .confirm)
        XCTAssertEqual(controller.accessFields, fields())
        XCTAssertEqual(controller.printedMRZ?.normalizedLines, lines.compactMap(\.first))
        controller.send(.scan)
        XCTAssertEqual(controller.phase, .confirm, "OCR never replaces explicit key confirmation")
        await controller.waitForRetirement()
        XCTAssertGreaterThan(stops, 0)
        controller.send(.restart)
        controller.send(.startMRZ)
        await settle()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.last?.state, .running)
        deliver(.init(candidates: [[otherName], lines[1]], timestamp: 200, policy: .engineeringV1))
        XCTAssertEqual(controller.phase, .mrz)
        XCTAssertNil(controller.printedMRZ)
        XCTAssertNil(controller.accessFields)
        let current = try XCTUnwrap(frames.last)
        current(.init(candidates: lines, timestamp: 1000, policy: .engineeringV1))
        XCTAssertEqual(controller.phase, .confirm)
        XCTAssertEqual(controller.accessFields, fields())
        controller.send(.cancel)
        await controller.waitForRetirement()
    }

    @MainActor func testChipAndServerFailuresKeepReadRecoveryWithoutManualEntry() async throws {
        let failures: [(any Error, PassportFlowController.Failure)] = [
            (PassportReadFailure.connectionLost, .read(.connectionLost)),
            (PassportServerFailure.rejected, .server(.rejected)),
            (PassportServerFailure.invalidResponse, .server(.invalidResponse))
        ]
        for (error, expected) in failures {
            var keys: [PassportAccessKey] = []
            var effects = PassportFlowProbe().effects
            effects.serverRead = { key, _, _, _, _ in keys.append(key); throw error }
            let host = PassportFlowHost(effects: effects)
            let page = host.makeRenderer()
            page.loadViewIfNeeded()
            host.controller.send(.visible)
            let staleManual = try XCTUnwrap(passportButton("passport.manual", in: page.view))
            host.controller.send(.manualKey(fields()))
            host.controller.send(.confirmKey)
            host.controller.supplyTrustAnchors(trust())
            XCTAssertFalse(host.controller.canEnterManualAccessKey)
            host.controller.send(.scan)
            await settle()
            XCTAssertEqual(host.controller.failure, expected)
            XCTAssertFalse(host.controller.canEnterManualAccessKey)
            XCTAssertNil(passportButton("passport.manual", in: page.view))
            let attempt = host.controller.attemptID
            staleManual.sendActions(for: .touchUpInside)
            host.controller.send(.manualKey(.init(documentNumber: "OTHER", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415")))
            XCTAssertEqual(host.controller.attemptID, attempt)
            XCTAssertEqual(host.controller.phase, .failure)
            XCTAssertEqual(host.controller.failure, expected)
            XCTAssertEqual(host.controller.accessFields, fields())
            XCTAssertNil(host.controller.result)
            try XCTUnwrap(passportButton("passport.retry", in: page.view)).sendActions(for: .touchUpInside)
            XCTAssertEqual(host.controller.phase, .ready)
            host.controller.send(.scan)
            await settle()
            XCTAssertEqual(keys.count, 2)
            XCTAssertEqual(keys.first, keys.last)
            XCTAssertEqual(host.controller.failure, expected)
            host.controller.send(.cancel)
            await host.controller.waitForRetirement()
        }
    }

    @MainActor func testCameraAndInvalidKeyFailuresStillAllowManualEntryBeforeNFC() async throws {
        let probe = PassportFlowProbe()
        let host = PassportFlowHost(effects: probe.effects)
        let page = host.makeRenderer()
        page.loadViewIfNeeded()
        host.controller.send(.visible)
        host.controller.send(.startMRZ)
        await settle()
        try XCTUnwrap(probe.cameraFailure)()
        XCTAssertEqual(host.controller.failure, .camera)
        XCTAssertTrue(host.controller.canEnterManualAccessKey)
        try XCTUnwrap(passportButton("passport.manual", in: page.view)).sendActions(for: .touchUpInside)
        XCTAssertEqual(host.controller.phase, .start)
        host.controller.send(.manualKey(.init(documentNumber: "lowercase", birthDateYYMMDD: "ABC", expiryDateYYMMDD: "bad")))
        XCTAssertEqual(host.controller.failure, .invalidAccessKey)
        XCTAssertTrue(host.controller.canEnterManualAccessKey)
        XCTAssertNotNil(passportButton("passport.manual", in: page.view))
        host.controller.send(.manualKey(fields()))
        XCTAssertEqual(host.controller.phase, .confirm)
        XCTAssertEqual(host.controller.accessFields, fields())
        XCTAssertEqual(probe.reads, 0)
        host.controller.send(.cancel)
        await host.controller.waitForRetirement()
    }

    @MainActor private func passportButton(_ identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        return view.subviews.lazy.compactMap { self.passportButton(identifier, in: $0) }.first
    }

    @MainActor func testRetiredNFCCompletionCannotStartPersistence() async {
        let probe = PassportFlowProbe()
        let controller = ready(probe)
        var writes = 0
        controller.persistCompletedRead = { _ in writes += 1 }
        controller.send(.scan)
        await settle()
        controller.send(.cancel)
        probe.finish(observation())
        await settle()
        XCTAssertEqual(writes, 0)
        XCTAssertNil(controller.result)
    }

    @MainActor func testConsentVisibilityAndConfirmationPrecedeAcquisition() async {
        let probe = PassportFlowProbe()
        let controller = PassportFlowController(effects: probe.effects)
        controller.send(.startMRZ)
        controller.send(.scan)
        XCTAssertEqual(probe.cameraStarts, 0)
        controller.send(.visible)
        controller.send(.scan)
        XCTAssertEqual(probe.reads, 0)
        controller.send(.startMRZ)
        await settle()
        XCTAssertEqual(probe.cameraStarts, 1)
        controller.send(.discard)
        await settle()
    }

    @MainActor func testIncompleteTruncatedAndAmbiguousMRZStayCapturingUntilComplete() async throws {
        let probe = PassportFlowProbe()
        let controller = PassportFlowController(effects: probe.effects)
        controller.send(.visible)
        controller.send(.startMRZ)
        let deadline = ContinuousClock.now + .seconds(3)
        while probe.candidates == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let deliver = try XCTUnwrap(probe.candidates)
        let stopsBeforeReads = probe.cameraStops
        let lines = mrz()
        let first = try XCTUnwrap(lines[0].first)
        let second = try XCTUnwrap(lines[1].first)
        let otherName = "P<UTODOE<<JANE".padding(toLength: 44, withPad: "<", startingAt: 0)
        let incompleteOrAmbiguous = [
            [[second]],
            [[first]],
            [[String(first.dropLast())], [second]],
            [[first], [String(second.dropLast())]],
            [[first], [otherName], [second]]
        ]
        for candidates in incompleteOrAmbiguous {
            deliver(candidates)
            XCTAssertEqual(controller.phase, .mrz)
            XCTAssertNil(controller.printedMRZ)
            XCTAssertNil(controller.accessFields)
            XCTAssertEqual(probe.cameraStops, stopsBeforeReads)
            XCTAssertEqual(probe.reads, 0)
        }
        deliver([[first, otherName], [second]])
        XCTAssertEqual(controller.phase, .confirm)
        XCTAssertEqual(controller.accessFields, fields())
        XCTAssertEqual(controller.printedMRZ?.normalizedLines, [first, second])
        deliver([[otherName], [second]])
        XCTAssertEqual(controller.printedMRZ?.surname, "ERIKSSON")
        controller.send(.cancel)
        await settle()
    }

    @MainActor func testManualKeyRequiresExplicitConfirmationAndTrust() {
        let controller = PassportFlowController(effects: PassportFlowProbe().effects)
        controller.send(.visible)
        controller.send(.manualKey(fields()))
        XCTAssertEqual(controller.phase, .confirm)
        controller.send(.scan)
        XCTAssertEqual(controller.phase, .confirm)
        controller.send(.confirmKey)
        XCTAssertEqual(controller.phase, .ready)
        controller.supplyTrustAnchors(URL(string: "https://example.invalid/trust.pem"))
        controller.send(.scan)
        XCTAssertEqual(controller.failure, .trustAnchorsRequired)
        XCTAssertNil(controller.trustAnchorsURL)
    }

    @MainActor func testInvalidManualKeyCannotBecomeReady() {
        let controller = PassportFlowController(effects: PassportFlowProbe().effects)
        controller.send(.visible)
        controller.send(.manualKey(.init(documentNumber: "lowercase", birthDateYYMMDD: "ABC", expiryDateYYMMDD: "bad")))
        controller.send(.confirmKey)
        XCTAssertEqual(controller.phase, .failure)
        XCTAssertEqual(controller.failure, .invalidAccessKey)
    }

    @MainActor func testCameraStopsBeforeNFCAndOldCandidatesCannotReplaceConfirmedSource() async throws {
        let probe = PassportFlowProbe()
        let controller = PassportFlowController(effects: probe.effects)
        controller.send(.visible)
        controller.send(.startMRZ)
        await settle()
        let stale = try XCTUnwrap(probe.candidates)
        stale(mrz())
        XCTAssertEqual(controller.phase, .confirm)
        XCTAssertNotNil(controller.printedMRZ)
        controller.send(.confirmKey)
        controller.supplyTrustAnchors(trust())
        controller.send(.scan)
        await settle()
        XCTAssertEqual(probe.order.last, "nfc-read")
        XCTAssertTrue(probe.order.dropLast().contains("camera-stop"))
        stale([])
        XCTAssertEqual(controller.phase, .scanning)
        probe.fail(.cancelled)
        await settle()
    }

    @MainActor func testResignActiveDoesNotRequireForegroundMutationWhileTrueBackgroundRejectsLateRead() async throws {
        let probe = PassportFlowProbe()
        let controller = ready(probe)
        controller.send(.scan)
        await settle()
        XCTAssertEqual(controller.phase, .scanning)
        // CoreNFC presenting a system sheet calls no background transition in the host.
        probe.readEvent?(.reading(group: "DG2", progress: 50))
        XCTAssertEqual(controller.phase, .scanning)
        controller.setBackgrounded(true)
        probe.finish(observation())
        await settle()
        XCTAssertEqual(controller.phase, .start)
        XCTAssertNil(controller.result)
        XCTAssertNil(controller.accessFields)
    }

    @MainActor func testCancelScanPreservesConfirmedKeyAndFencesLateEventsAndResult() async {
        let probe = PassportFlowProbe()
        let controller = ready(probe)
        controller.send(.scan)
        await settle()
        let stale = probe.readEvent
        controller.send(.cancelScan)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.accessFields, fields())
        stale?(.failure(.readFailed))
        probe.finish(observation())
        await settle()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertNil(controller.result)
        XCTAssertNil(controller.event)
    }

    @MainActor func testVerifiedResultRetainsOriginalPortraitWithoutDisplayDecodeAndDeliversOnce() async throws {
        let probe = PassportFlowProbe()
        let controller = ready(probe)
        var accepted: AcceptedPassportPortrait?
        var deliveries = 0
        controller.onAccepted = { accepted = $0; deliveries += 1; controller.send(.usePortrait) }
        controller.send(.scan)
        await settle()
        let id = controller.attemptID
        let read = observation()
        probe.finish(read)
        await settle()
        XCTAssertEqual(controller.phase, .result)
        XCTAssertEqual(controller.result?.portrait, Data([0xFF, 0x4F, 1]))
        controller.send(.usePortrait)
        controller.send(.usePortrait)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(accepted?.attemptID, id)
        XCTAssertEqual(accepted?.read.portrait, read.portrait)
        XCTAssertEqual(accepted?.read.dg2, read.dg2)
        XCTAssertNil(controller.result)
    }

    @MainActor func testInjectedFailedOrMissingProofsNeverBecomeResult() async {
        for variant in 0..<6 {
            let probe = PassportFlowProbe()
            let controller = ready(probe)
            var writes = 0
            controller.persistCompletedRead = { _ in writes += 1 }
            controller.send(.scan)
            await settle()
            probe.finish(observation(variant: variant))
            await settle()
            XCTAssertEqual(controller.phase, .failure)
            XCTAssertEqual(controller.failure, .unverifiedEvidence)
            XCTAssertNil(controller.result)
            XCTAssertEqual(writes, 0)
        }
    }

    @MainActor func testMissingPortraitStillReturnsVerifiedReadButCannotDeliverPortrait() async {
        let probe = PassportFlowProbe()
        let controller = ready(probe)
        var delivered = false
        controller.onAccepted = { _ in delivered = true }
        controller.send(.scan)
        await settle()
        probe.finish(observation(portrait: nil))
        await settle()
        XCTAssertEqual(controller.phase, .result)
        XCTAssertNotNil(controller.result)
        XCTAssertFalse(controller.hasPortrait)
        controller.send(.usePortrait)
        XCTAssertFalse(delivered)
    }

    @MainActor func testHiddenAndDiscardClearEvidenceAndCancelCannotReopen() async {
        for action in [PassportFlowIntent.hidden, .discard, .cancel] {
            let probe = PassportFlowProbe()
            let controller = ready(probe)
            controller.send(.scan)
            await settle()
            controller.send(action)
            probe.finish(observation())
            await settle()
            XCTAssertNil(controller.result)
            XCTAssertNil(controller.accessFields)
            XCTAssertEqual(controller.phase, .start)
        }
    }

    @MainActor func testReentrantScanRenderCancellationPreventsReadConstruction() async {
        let probe = PassportFlowProbe()
        let controller = ready(probe)
        controller.onChange = { if controller.phase == .scanning { controller.send(.cancelScan) } }
        controller.send(.scan)
        await settle()
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(controller.phase, .ready)
    }

    @MainActor func testChangingTrustDuringReadRejectsItsResult() async {
        let probe = PassportFlowProbe()
        let controller = ready(probe)
        controller.send(.scan)
        await settle()
        controller.supplyTrustAnchors(URL(fileURLWithPath: "/new-trust.pem"))
        probe.finish(observation())
        await settle()
        XCTAssertNil(controller.result)
        XCTAssertEqual(controller.phase, .start)
    }

    @MainActor func testUnsupportedNFCPrecedesMissingTrustAndDoesNotConstructRead() {
        let probe = PassportFlowProbe()
        var effects = probe.effects
        effects.available = false
        let controller = PassportFlowController(effects: effects)
        controller.send(.visible)
        controller.send(.manualKey(fields()))
        controller.send(.confirmKey)
        controller.send(.scan)
        XCTAssertEqual(controller.failure, .unavailable)
        XCTAssertEqual(probe.reads, 0)
    }

    @MainActor func testNativeSheetCancelReturnsReadyAndRetryCanReadAgain() async {
        let probe = PassportFlowProbe()
        let controller = ready(probe)
        controller.send(.scan)
        await settle()
        probe.fail(.cancelled)
        await settle()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertNil(controller.failure)
        controller.send(.scan)
        await settle()
        XCTAssertEqual(probe.reads, 2)
        probe.fail(.readFailed)
        await settle()
        XCTAssertEqual(controller.phase, .failure)
        controller.send(.retryRead)
        XCTAssertEqual(controller.phase, .ready)
    }

    @MainActor func testCancelledReadMustSettleBeforeReplacementReadStarts() async {
        let probe = PassportFlowProbe()
        let controller = ready(probe)
        controller.send(.scan)
        await settle()
        controller.send(.cancelScan)
        controller.send(.scan)
        await settle()
        XCTAssertEqual(probe.reads, 1)
        probe.finish(observation())
        await settle()
        XCTAssertEqual(probe.reads, 2)
        XCTAssertNil(controller.result)
        probe.fail(.cancelled)
        await settle()
    }

    @MainActor func testTerminalRenderBackgroundWithdrawalPreventsAcceptedDelivery() async {
        let probe = PassportFlowProbe()
        let controller = ready(probe)
        controller.send(.scan)
        await settle()
        probe.finish(observation())
        await settle()
        var delivered = false
        controller.onAccepted = { _ in delivered = true }
        controller.onChange = { if controller.phase == .start { controller.setBackgrounded(true) } }
        controller.send(.usePortrait)
        XCTAssertFalse(delivered)
        XCTAssertNil(controller.result)
    }

    @MainActor func testManualConfirmedFieldsMustCorrespondToChipEvenWithVerifiedProofs() async {
        for substitution in 0..<3 {
            let probe = PassportFlowProbe()
            let controller = ready(probe)
            controller.send(.scan)
            await settle()
            probe.finish(observation(substitution: substitution))
            await settle()
            XCTAssertEqual(controller.failure, .correspondence)
            XCTAssertNil(controller.result)
        }
    }

    @MainActor func testPrintedFieldsMustCorrespondToVerifiedChip() async {
        for substitution in 0..<5 {
            let probe = PassportFlowProbe()
            let controller = PassportFlowController(effects: probe.effects)
            controller.send(.visible)
            controller.send(.startMRZ)
            await settle()
            probe.candidates?(mrz())
            controller.send(.confirmKey)
            controller.supplyTrustAnchors(trust())
            controller.send(.scan)
            await settle()
            probe.finish(observation(substitution: substitution))
            await settle()
            XCTAssertEqual(controller.failure, .correspondence)
            XCTAssertNil(controller.result)
        }
    }

    @MainActor func testAbsentPrintedGivenNamesRemainNotCompared() async {
        let probe = PassportFlowProbe()
        let controller = PassportFlowController(effects: probe.effects)
        controller.send(.visible)
        controller.send(.startMRZ)
        await settle()
        let surnameOnly = "P<UTOERIKSSON".padding(toLength: 44, withPad: "<", startingAt: 0)
        probe.candidates?([[surnameOnly], mrz()[1]])
        XCTAssertEqual(controller.printedMRZ?.givenNames, "")
        controller.send(.confirmKey)
        controller.supplyTrustAnchors(trust())
        controller.send(.scan)
        await settle()
        probe.finish(observation())
        await settle()
        XCTAssertEqual(controller.phase, .result)
    }

    @MainActor func testOpticalMRZCannotReachConfirmationBeforeCommitAndRetriesSameCapture() async throws {
        let probe = PassportFlowProbe()
        let controller = PassportFlowController(effects: probe.effects)
        var attempts: [UUID] = []
        var continuation: CheckedContinuation<Void, Error>?
        controller.persistMRZ = { value in
            attempts.append(value.id)
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        controller.send(.visible); controller.send(.startMRZ)
        await settle()
        probe.candidates?(mrz())
        await settle()
        XCTAssertEqual(controller.phase, .savingMRZ)
        controller.send(.confirmKey); controller.send(.scan)
        XCTAssertEqual(probe.reads, 0)
        continuation?.resume(throwing: FaceWorkflowStorageFailure.unavailable)
        await settle()
        XCTAssertEqual(controller.phase, .mrzSaveFailure)
        controller.send(.retryMRZSave); controller.send(.retryMRZSave)
        await settle()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first, attempts.last)
        XCTAssertEqual(probe.cameraStarts, 1)
        continuation?.resume()
        await settle()
        XCTAssertEqual(controller.phase, .confirm)
        controller.send(.cancel)
        await controller.waitForRetirement()
    }

    @MainActor func testManualMRZCommitGatesAutomaticNFCAndCancellationFencesLateCommit() async throws {
        for cancel in [false, true] {
            let probe = PassportFlowProbe()
            let controller = PassportFlowController(effects: probe.effects)
            var continuation: CheckedContinuation<Void, Error>?
            controller.persistMRZ = { value in
                XCTAssertEqual(value.source, .manual)
                XCTAssertNil(value.normalizedLines)
                try await withCheckedThrowingContinuation { continuation = $0 }
            }
            controller.scanAfterMRZCommit = true
            controller.send(.visible)
            controller.send(.manualKey(fields()))
            controller.supplyTrustAnchors(trust())
            controller.send(.confirmKey)
            controller.send(.scan)
            await settle()
            XCTAssertEqual(probe.reads, 0)
            if cancel { controller.send(.cancel) }
            continuation?.resume()
            await settle()
            XCTAssertEqual(probe.reads, cancel ? 0 : 1)
            if !cancel { controller.send(.cancel); probe.fail(.invalidAccessKey) }
            await controller.waitForRetirement()
        }
    }

    @MainActor func testRestoredMRZSkipsCameraAndRequiresFreshConfirmation() async throws {
        let probe = PassportFlowProbe()
        let controller = PassportFlowController(effects: probe.effects)
        let capture = try SavedMRZCapture(fields: fields(), lines: mrz().compactMap(\.first))
        try controller.restoreMRZ(capture)
        controller.send(.visible)
        controller.send(.beginJourney)
        controller.send(.scan)
        await settle()
        XCTAssertEqual(probe.cameraStarts, 0)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(controller.phase, .confirm)
        XCTAssertEqual(controller.accessFields, capture.fields)
        controller.send(.cancel)
        await controller.waitForRetirement()
    }

    @MainActor private func ready(_ probe: PassportFlowProbe) -> PassportFlowController {
        let controller = PassportFlowController(effects: probe.effects)
        controller.send(.visible)
        controller.send(.manualKey(fields()))
        controller.send(.confirmKey)
        controller.supplyTrustAnchors(trust())
        return controller
    }
    private func fields() -> PassportManualAccessFields {
        .init(documentNumber: "L898902C3", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415")
    }
    private func trust() -> URL { URL(fileURLWithPath: "/synthetic-trust.pem") }
    private func mrz() -> [[String]] {
        [["P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<"],
         ["L898902C36UTO7408122F1204159ZE184226B<<<<<10"]]
    }
    @MainActor private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }
    private func observation(variant: Int = -1, portrait: Data? = Data([0xFF, 0x4F, 1]), substitution: Int = -1) -> PassportReadObservation {
        PassportReadObservation(documentNumber: substitution == 0 ? "OTHER" : "L898902C3",
            surname: substitution == 3 ? "SUBSTITUTED" : "ERIKSSON",
            givenNames: substitution == 4 ? "SUBSTITUTED" : "ANNA MARIA",
            nationality: "UTO", issuingState: "UTO", birthDateYYMMDD: substitution == 1 ? "740813" : "740812",
            expiryDateYYMMDD: substitution == 2 ? "120416" : "120415",
            sex: "F", personalNumber: nil, dateOfIssue: nil, issuingAuthority: nil, placeOfBirth: nil,
            basicAccessControl: variant == 0 ? .notPerformed : .succeeded, pace: .notPerformed,
            activeAuthentication: variant == 1 ? .failed : .notPerformed,
            chipAuthentication: variant == 2 ? .failed : .notPerformed,
            countrySigningChain: variant == 3 ? .notPerformed : .succeeded,
            documentSignature: variant == 4 ? .failed : .succeeded,
            dataGroupHashes: variant == 5 ? .failed : .succeeded,
            documentSigningCertificateDER: nil, activeAuthenticationChallenge: nil, activeAuthenticationSignature: nil,
            securityObject: Data([1]), dataGroups: [:], declaredDataGroups: ["DG1", "DG2"],
            dg2: Data([0x75, 1, 1]), portrait: portrait, dg2Digest: String(repeating: "a", count: 64),
            dg2DigestAlgorithm: "SHA-256", chipAuthenticationResponse: nil)
    }
}
