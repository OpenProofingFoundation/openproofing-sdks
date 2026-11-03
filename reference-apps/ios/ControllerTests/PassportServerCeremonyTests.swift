import CryptoKit
import Foundation
@testable import PassportSDK
import XCTest
@testable import KenshikiReference

final class PassportDiagnosticProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PassportServerDiagnostic] = []
    func append(_ value: PassportServerDiagnostic) { lock.lock(); defer { lock.unlock() }; events.append(value) }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return events.map(\.message) }
}

private actor PassportWorkerProbe: PulseBoundedHTTPTransport {
    enum Behavior: Equatable {
        case success, wrongNonceSession, wrongVerificationSession, wrongVerificationNonce, missingVerificationIDs, unauthorizedFirstVerification, unsupportedCA, rejected, lostVerification, lostFirstSession
        case rejectedReason(String)
    }
    let behavior: Behavior
    private var pauseVerification = false
    private var verificationReply: CheckedContinuation<Void, Never>?
    private var verificationObserver: CheckedContinuation<Void, Never>?
    func pauseAtVerification() { pauseVerification = true }
    func waitForVerification() async { if verificationReply != nil { return }; await withCheckedContinuation { verificationObserver = $0 } }
    func releaseVerification() { verificationReply?.resume(); verificationReply = nil }
    private(set) var requests: [(String, Data, [String: String])] = []
    init(_ behavior: Behavior = .success) { self.behavior = behavior }
    func post(to url: URL, headers: [String: String], body: Data, maxResponseBytes: Int) async throws -> PulseBoundedHTTPResponse {
        requests.append((url.path, body, headers))
        let object: [String: Any]
        var status = 200
        switch url.path {
        case "/identity/sessions":
            if behavior == .lostFirstSession, requests.filter({ $0.0 == url.path }).count == 1 { throw URLError(.networkConnectionLost) }
            object = ["session_id": "session", "nonce": "session-secret", "expires_at": "2099-01-01T00:00:00Z"]
        case "/passport/nonce":
            object = ["session_id": behavior == .wrongNonceSession ? "other-session" : "session", "nonce_id": "nonce-id",
                "nonce": "server-nonce", "expires_at": "2099-01-01T00:00:00Z", "iac_key_id": "iac", "workflow": "passport_identity",
                "payload_commitment_hash": NSNull()]
        case "/passport/chip-authentication":
            if behavior == .unsupportedCA {
                status = 400; object = ["error": ["details": ["reason": "chip_authentication_unsupported"]]]
            } else {
                object = ["protocol": "pulse.passport-ca.v1", "nonce_id": "nonce-id", "ca_protocol_oid": "0.4.0.127.0.7.2.2.3.2.2",
                    "ephemeral_public_key": "AQID", "protected_command": "BAUG"]
            }
        case "/passport/verify":
            if pauseVerification {
                pauseVerification = false
                await withCheckedContinuation { verificationReply = $0; verificationObserver?.resume(); verificationObserver = nil }
            }
            if behavior == .unauthorizedFirstVerification, requests.filter({ $0.0 == url.path }).count == 1 {
                return .init(statusCode: 401, body: Data("{\"error\":{\"code\":\"unauthorized\"}}".utf8), responseURL: url, mimeType: "application/json")
            }
            if behavior == .lostVerification { throw URLError(.networkConnectionLost) }
            let failureReason: String?
            switch behavior {
            case .rejected: failureReason = "data_group_hash_mismatch"
            case .rejectedReason(let reason): failureReason = reason
            default: failureReason = nil
            }
            let result = failureReason == nil ? "verified" : "failed"
            status = failureReason == nil ? 200 : 403
            var reply: [String: Any] = ["status": result, "validation": ["result": result, "validator": "passport_validator",
                "failureReason": failureReason as Any? ?? NSNull(),
                "sodVerified": failureReason == nil, "dscVerified": failureReason == nil, "cscaVerified": failureReason == nil,
                "dataGroupHashesVerified": failureReason == nil, "crlChecked": failureReason == nil,
                "chipAuthenticated": true, "activeAuthentication": true, "chipAuthentication": true,
                "documentExpired": false, "trustBundleVersion": "synthetic-test",
                "trustManifestSha256": String(repeating: "a", count: 64),
                "assurance": failureReason == nil ? "chip_authenticated" : "unverified"],
                "holder_binding": failureReason == nil ? String(repeating: "b", count: 43) as Any : NSNull()]
            if case .rejectedReason(let reason) = behavior {
                reply["validation"] = ["result": "failed", "validator": "passport_validator", "receiptId": "receipt_test",
                    "failureReason": reason, "sodVerified": false, "dscVerified": false, "cscaVerified": false,
                    "dataGroupHashesVerified": false, "chipAuthenticated": false, "activeAuthentication": false,
                    "chipAuthentication": false, "crlChecked": false, "documentExpired": NSNull(),
                    "trustBundleVersion": NSNull(), "trustManifestSha256": NSNull(), "assurance": "unverified"]
                reply["holder_binding"] = NSNull()
            }
            if behavior != .missingVerificationIDs {
                reply["session_id"] = behavior == .wrongVerificationSession ? "other-session" : "session"
                reply["nonce_id"] = behavior == .wrongVerificationNonce ? "other-nonce" : "nonce-id"
            }
            object = reply
        default: throw PulsePassportFailure.invalidRequest
        }
        return .init(statusCode: status, body: try JSONSerialization.data(withJSONObject: object), responseURL: url, mimeType: "application/json")
    }
}

final class PassportServerCeremonyTests: XCTestCase {
    @MainActor func testReviewedPageMismatchRefusesBeforeAnyRemoteVerification() async throws {
        for name in ["DIFFERENT", "ERIKSSON"] {
            let worker = PassportWorkerProbe()
            let client = client(worker)
            let ceremony = PassportServerCeremony(ports: .init(client: { client }, read: { _, _, nonce, _, _ in
                self.read(challenge: nonce.activeAuthenticationChallenge, surname: name,
                    givenNames: name == "ERIKSSON" ? "DIFFERENT" : "ANNA MARIA")
            }))
            var candidates: (@MainActor @Sendable ([[String]]) -> Void)?
            let cameraStarted = XCTestExpectation(description: "MRZ camera callback installed")
            let effects = PassportFlowEffects(serverRead: { key, trust, event, stage, admit in
                try await ceremony.read(key: key, trust: trust, event: event, stage: stage, admit: admit)
            }, startCamera: { receive, _ in candidates = receive; cameraStarted.fulfill() }, stopCamera: {},
                read: { _, _, _ in XCTFail("Production may not downgrade to local-only"); throw PassportServerFailure.configuration })
            let controller = PassportFlowController(effects: effects)
            var writes = 0
            controller.persistCompletedRead = { _ in writes += 1 }
            controller.send(.visible); controller.send(.startMRZ)
            let cameraReady = await XCTWaiter.fulfillment(of: [cameraStarted], timeout: 5)
            XCTAssertEqual(cameraReady, .completed)
            try XCTUnwrap(candidates)([["P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<"],
                ["L898902C36UTO7408122F1204159ZE184226B<<<<<10"]])
            controller.send(.confirmKey); controller.supplyTrustAnchors(trust())
            await scanUntilFailure(controller)
            XCTAssertEqual(controller.failure, .correspondence)
            XCTAssertNil(controller.result); XCTAssertEqual(writes, 0)
            let requests = await worker.requests
            XCTAssertEqual(requests.filter { $0.0 == "/passport/nonce" }.count, 1)
            XCTAssertFalse(requests.contains { $0.0 == "/passport/verify" })
            controller.send(.cancel); await controller.waitForRetirement()
        }
    }

    @MainActor func testKnownTrustConfigurationVerdictsRequireServerRepairInsteadOfChipRetry() async throws {
        for reason in ["trust_publisher_key_not_configured", "trust_publisher_key_invalid", "trust_bundle_override_incomplete",
            "trust_bundle_signature_missing", "trust_bundle_signature_invalid", "trust_bundle_manifest_invalid",
            "trust_bundle_digest_mismatch", "trust_bundle_not_active", "trust_bundle_expired",
            "csca_trust_store_not_configured", "crl_not_configured", "issuer_crl_not_found"] {
            let worker = PassportWorkerProbe(.rejectedReason(reason))
            let diagnostics = PassportDiagnosticProbe()
            let client = client(worker, diagnostic: { diagnostics.append($0) })
            var ports = PassportServerCeremony.Ports(client: { client }, read: { _, _, nonce, _, _ in
                self.read(challenge: nonce.activeAuthenticationChallenge)
            })
            ports.diagnostic = { diagnostics.append($0) }
            await expect(.configuration, PassportServerCeremony(ports: ports))
            XCTAssertTrue(diagnostics.messages.contains("verdict=failed validator=passport_validator failureReason=\(reason) aa=false ca=false"))
            XCTAssertTrue(diagnostics.messages.contains("step=verify failure=configuration"))
            let requests = await worker.requests
            XCTAssertEqual(requests.filter { $0.0 == "/passport/verify" }.count, 1)
        }
    }

    @MainActor func testUnknownTrustTextAndPassportIntegrityVerdictsRemainRejected() async throws {
        for reason in ["sod_encoding_invalid", "data_group_hash_mismatch", "dsc_csca_chain_invalid", "dsc_certificate_revoked",
            "trust_bundle_future_unknown", "trust_publisher_key_not_configured:unknown", ""] {
            let worker = PassportWorkerProbe(.rejectedReason(reason))
            let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, nonce, _, _ in
                self.read(challenge: nonce.activeAuthenticationChallenge)
            }))
            await expect(.rejected, ceremony)
        }
        XCTAssertEqual(PassportServerFailure.verificationFailure(reason: nil), .rejected)
    }

    @MainActor func testDiagnosticsDistinguishLocalRefusalFromServerVerdictAndHTTPStatus() async throws {
        for localFailure in [true, false] {
            let worker = PassportWorkerProbe(localFailure ? .success : .rejected)
            let diagnostics = PassportDiagnosticProbe()
            let client = client(worker, diagnostic: { diagnostics.append($0) })
            var ports = PassportServerCeremony.Ports(client: { client }, read: { _, _, nonce, _, _ in
                self.read(challenge: nonce.activeAuthenticationChallenge, localFailure: localFailure)
            })
            ports.diagnostic = { diagnostics.append($0) }
            await expect(.rejected, PassportServerCeremony(ports: ports))
            let messages = diagnostics.messages
            #if DEBUG
            let framing = messages.filter { $0.hasPrefix("sodFraming ") }
            XCTAssertEqual(framing.count, localFailure ? 1 : 2)
            XCTAssertTrue(framing.allSatisfy { $0.contains("sha256=" + SavedPassportCapture.digest(read().securityObject)) })
            if !localFailure {
                XCTAssertLessThan(try XCTUnwrap(messages.firstIndex(of: framing[0])), try XCTUnwrap(messages.firstIndex(of: "step=verify")))
            }
            #endif
            if localFailure {
                XCTAssertTrue(messages.contains("local bac=succeeded pace=notPerformed chain=succeeded signature=succeeded groups=failed aa=succeeded ca=notPerformed"))
                XCTAssertTrue(messages.contains("endpoint=unknown check=integrity passed=false"))
                XCTAssertTrue(messages.contains("step=localIntegrity failure=rejected"))
                XCTAssertFalse(messages.contains { $0.contains("endpoint=/passport/verify") || $0.contains("verdict=") })
            } else {
                XCTAssertTrue(messages.contains("endpoint=/passport/verify http=403 reason=none"))
                XCTAssertTrue(messages.contains("verdict=failed validator=passport_validator failureReason=data_group_hash_mismatch aa=true ca=true"))
                XCTAssertTrue(messages.contains("step=verify failure=rejected"))
            }
            for secret in ["L898902C3", "ERIKSSON", "ANNA MARIA", "installation-token", "session-secret", "server-nonce", "nonce-id"] {
                XCTAssertFalse(messages.contains { $0.contains(secret) }, "Diagnostic disclosed fixture secret")
            }
        }
    }

    @MainActor func testDiagnosticsLocateMalformedVerificationBindingWithoutReportingServerRejection() async throws {
        let worker = PassportWorkerProbe(.wrongVerificationNonce)
        let diagnostics = PassportDiagnosticProbe()
        let client = client(worker, diagnostic: { diagnostics.append($0) })
        var ports = PassportServerCeremony.Ports(client: { client }, read: { _, _, nonce, _, _ in
            self.read(challenge: nonce.activeAuthenticationChallenge)
        })
        ports.diagnostic = { diagnostics.append($0) }
        await expect(.invalidResponse, PassportServerCeremony(ports: ports))
        XCTAssertTrue(diagnostics.messages.contains("endpoint=/passport/verify http=200 reason=none"))
        XCTAssertTrue(diagnostics.messages.contains("endpoint=/passport/verify check=binding passed=false"))
        XCTAssertTrue(diagnostics.messages.contains("step=verify failure=invalidResponse"))
        XCTAssertFalse(diagnostics.messages.contains { $0.contains("verdict=") || $0.contains("other-nonce") })
    }

    func testDiagnosticsHashUnknownServerTextWithoutAcceptingKnownPrefixOrRetainingCredentials() {
        let unsafeReason = "chip_authentication_failed: passport L898902C3 bearer secret-token"
        let unsafeValidator = "validator holder-binding-secret"
        let verdict = PulsePassportVerification(status: .failed, validator: unsafeValidator, failureReason: unsafeReason,
            activeAuthentication: false, chipAuthentication: false, documentExpired: nil, trustBundleVersion: nil,
            assurance: nil, holderBinding: "never-log-this-holder-binding")
        let message = PassportServerDiagnostic.verdict(verdict).message
        func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(message, "verdict=failed validator=unknown:sha256:\(digest(unsafeValidator)) failureReason=unknown:sha256:\(digest(unsafeReason)) aa=false ca=false")
        for secret in [unsafeReason, unsafeValidator, "L898902C3", "secret-token", "never-log-this-holder-binding"] {
            XCTAssertFalse(message.contains(secret))
        }
        XCTAssertEqual(PassportServerDiagnostic.http(.verify, status: 403, reason: unsafeReason).message,
            "endpoint=/passport/verify http=403 reason=unknown:sha256:" + digest(unsafeReason))
    }

    @MainActor func testActualServerReportAndPrivateCapabilityRoundTripWithoutDisclosureOrSourceSubstitution() async throws {
        let worker = PassportWorkerProbe()
        let client = client(worker)
        let ceremony = PassportServerCeremony(ports: .init(client: { client }, read: { _, _, nonce, _, _ in
            self.read(challenge: nonce.activeAuthenticationChallenge)
        }))
        let returned = try await ceremony.read(key: key(), trust: trust(), event: { _ in }, stage: { _ in })
        let value = AcceptedPassportPortrait(attemptID: UUID(), read: returned.read, printedMRZ: nil,
            capturedAt: Date(), serverVerification: returned.verification)
        let capture = try SavedPassportCapture(value)
        let restored = try SavedPassportCapture.decode(capture.encoded())
        XCTAssertEqual(restored.serverVerification?.validationReport, returned.verification.validationReport)
        XCTAssertEqual(restored.serverVerification?.origin, URL(string: "https://worker.test"))
        XCTAssertEqual(restored.serverVerification?.installationID, "installation")
        let exported = try JSONSerialization.data(withJSONObject: returned.verification.exportObject)
        let text = String(decoding: exported, as: UTF8.self)
        XCTAssertFalse(text.contains(String(repeating: "b", count: 43)))
        XCTAssertFalse(text.contains("protectedHolderCapability"))
        var object = try XCTUnwrap(PropertyListSerialization.propertyList(from: capture.encoded(), format: nil) as? [String: Any])
        var receipt = try XCTUnwrap(object["serverVerification"] as? [String: Any])
        receipt["installationID"] = "substituted-installation"
        object["serverVerification"] = receipt
        XCTAssertThrowsError(try SavedPassportCapture.decode(PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)))
        receipt["installationID"] = "installation"; receipt["origin"] = "https://other-worker.test"
        object["serverVerification"] = receipt
        XCTAssertThrowsError(try SavedPassportCapture.decode(PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)))
    }

    @MainActor func testServerChallengeRelayAndVerificationUseExactReadWithoutDG2Upload() async throws {
        let worker = PassportWorkerProbe()
        let client = client(worker)
        var stages: [String] = []
        var supplied: Data?
        var relay: PassportChipAuthenticationChallenge?
        let ceremony = PassportServerCeremony(ports: .init(client: { client }, read: { _, _, nonce, terminal, event in
            supplied = nonce.activeAuthenticationChallenge
            relay = try await terminal(Data([14]))
            event(.reading(group: "DG2", progress: 75)); event(.transportComplete)
            return self.read(challenge: nonce.activeAuthenticationChallenge)
        }))
        let result = try await ceremony.read(key: key(), trust: trust(), event: { _ in }, stage: {
            switch $0 { case .preparing: stages.append("preparing"); case .reading: stages.append("reading"); case .verifying: stages.append("verifying") }
        })
        XCTAssertEqual(stages, ["preparing", "reading", "verifying"])
        XCTAssertEqual(supplied, Data(SHA256.hash(data: Data("server-nonce".utf8)).prefix(8)))
        XCTAssertEqual(relay?.protectedCommand, Data([4, 5, 6]))
        XCTAssertEqual(result.verification.securityObjectSHA256, SavedPassportCapture.digest(result.read.securityObject))
        XCTAssertTrue(result.verification.chipAuthentication)
        let requests = await worker.requests
        XCTAssertEqual(requests.map(\.0), ["/identity/sessions", "/passport/nonce", "/passport/chip-authentication", "/passport/verify"])
        let submission = try XCTUnwrap(requests.last)
        XCTAssertEqual(submission.2["Authorization"], "Bearer installation-token")
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: submission.1) as? [String: Any])
        let payload = try XCTUnwrap(envelope["payload_json"] as? String)
        let proof = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let chip = try XCTUnwrap(proof["nfc_passport"] as? [String: Any])
        let groups = try XCTUnwrap(chip["data_groups"] as? [String: String])
        XCTAssertEqual(Set(groups.keys), ["DG1", "DG14"])
        XCTAssertEqual(proof["nonce_id"] as? String, "nonce-id")
        let assertion = try XCTUnwrap(envelope["app_attest"] as? [String: String])
        XCTAssertEqual(assertion["client_data_hash"], PulsePassportClient.verifyClientDataHash(payloadJSON: payload).base64EncodedString())
    }

    @MainActor func testMissingOrMismatchedVerificationIDsNeverAcceptServerSuccess() async throws {
        for behavior in [PassportWorkerProbe.Behavior.wrongVerificationSession, .wrongVerificationNonce, .missingVerificationIDs] {
            let worker = PassportWorkerProbe(behavior)
            let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, nonce, _, _ in
                self.read(challenge: nonce.activeAuthenticationChallenge)
            }))
            await expect(.invalidResponse, ceremony)
        }
    }

    @MainActor func testKnownBearerRefusalRecoversOnceAndResubmitsSameProofWithFreshAssertion() async throws {
        let worker = PassportWorkerProbe(.unauthorizedFirstVerification)
        let client = PulsePassportClient(baseURL: URL(string: "https://worker.test")!, deviceID: "installation",
            attestation: .init(installationToken: { "stale-token" }, assert: {
                .init(keyID: "same-key", clientDataHash: $0.base64EncodedString(), assertionObject: "proof")
            }, recoverInstallationToken: { "recovered-token" }), transport: worker)
        let ceremony = PassportServerCeremony(ports: .init(client: { client }, read: { _, _, nonce, _, _ in self.read(challenge: nonce.activeAuthenticationChallenge) }))
        _ = try await ceremony.read(key: key(), trust: trust(), event: { _ in }, stage: { _ in })
        let requests = await worker.requests
        let submitted = requests.filter { $0.0 == "/passport/verify" }
        XCTAssertEqual(submitted.count, 2)
        XCTAssertEqual(submitted[0].2["Authorization"], "Bearer stale-token")
        XCTAssertEqual(submitted[1].2["Authorization"], "Bearer recovered-token")
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: submitted[0].1) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: submitted[1].1) as? [String: Any])
        XCTAssertEqual(first["payload_json"] as? String, second["payload_json"] as? String)
        XCTAssertEqual(requests.filter { $0.0 == "/identity/sessions" }.count, 1)
    }

    @MainActor func testWrongSessionNonceRefusesBeforeNFC() async throws {
        let worker = PassportWorkerProbe(.wrongNonceSession)
        var reads = 0
        let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, _, _, _ in
            reads += 1; return self.read()
        }))
        await expect(.invalidResponse, ceremony)
        XCTAssertEqual(reads, 0)
    }

    @MainActor func testServerCARefusalSurvivesReaderFailureMapping() async throws {
        let worker = PassportWorkerProbe(.unsupportedCA)
        let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, _, terminal, _ in
            do { _ = try await terminal(Data([14])) } catch { throw PassportReadFailure.readFailed }
            return self.read()
        }))
        await expect(.unsupportedChip, ceremony)
        let requests = await worker.requests
        XCTAssertFalse(requests.contains { $0.0 == "/passport/verify" })
    }

    @MainActor func testEveryDeliveredLocalGuardRetiresItsNonceBeforeRetryWithoutVerification() async throws {
        for defect in ["certificateMissing", "certificateEmpty", "sod", "challenge", "access", "chain", "signature", "hashes", "aa", "ca"] {
            let worker = PassportWorkerProbe()
            let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, nonce, _, _ in
                self.read(challenge: defect == "challenge" ? Data(repeating: 9, count: 8) : nonce.activeAuthenticationChallenge, defect: defect)
            }))
            let expected: PassportServerFailure = ["certificateMissing", "certificateEmpty", "sod", "challenge"].contains(defect) ? .invalidResponse : .rejected
            await expect(expected, ceremony); await expect(expected, ceremony)
            let requests = await worker.requests
            XCTAssertEqual(requests.filter { $0.0 == "/identity/sessions" }.count, 2, defect)
            XCTAssertEqual(requests.filter { $0.0 == "/passport/nonce" }.count, 2, defect)
            XCTAssertFalse(requests.contains { $0.0 == "/passport/verify" }, defect)
        }
    }

    @MainActor func testLocalIntegrityFailureNeverSubmitsRemoteProof() async throws {
        let worker = PassportWorkerProbe()
        let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, _, _, _ in self.read(localFailure: true) }))
        await expect(.rejected, ceremony)
        let requests = await worker.requests
        XCTAssertFalse(requests.contains { $0.0 == "/passport/verify" })
    }

    @MainActor func testActiveChallengeSubstitutionNeverSubmits() async throws {
        let worker = PassportWorkerProbe()
        let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, _, _, _ in self.read(challenge: Data(repeating: 9, count: 8)) }))
        await expect(.invalidResponse, ceremony)
        let requests = await worker.requests
        XCTAssertFalse(requests.contains { $0.0 == "/passport/verify" })
    }

    @MainActor func testFailedWorkerReportRemainsExactCurrentAttemptDetailsWithoutPersistingPortraitOrCapability() async throws {
        let worker = PassportWorkerProbe(.rejectedReason("data_group_hash_mismatch"))
        let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, nonce, _, _ in
            self.read(challenge: nonce.activeAuthenticationChallenge)
        }))
        let effects = PassportFlowEffects(serverRead: { key, trust, event, stage, admit in
            try await ceremony.read(key: key, trust: trust, event: event, stage: stage, admit: admit)
        }, startCamera: { _, _ in }, stopCamera: {}, read: { _, _, _ in XCTFail("No fallback"); throw PassportServerFailure.configuration })
        let controller = PassportFlowController(effects: effects)
        var persisted = 0, accepted = 0
        controller.persistCompletedRead = { _ in persisted += 1 }
        controller.onAccepted = { _ in accepted += 1 }
        prepare(controller); await scanUntilFailure(controller)
        let rejection = try XCTUnwrap(controller.serverRejection)
        XCTAssertEqual(controller.failure, .server(.rejected)); XCTAssertEqual(rejection.report.result, .failed)
        XCTAssertEqual(rejection.report.failureReason, "data_group_hash_mismatch")
        #if DEBUG
        XCTAssertTrue(rejection.sodFramingDiagnostic.isFailure)
        XCTAssertTrue(rejection.sodFramingDiagnostic.message.contains("sha256=" + rejection.securityObjectSHA256))
        #endif
        XCTAssertEqual(rejection.report.receiptId, "receipt_test"); XCTAssertFalse(rejection.report.dataGroupHashesVerified)
        XCTAssertNil(rejection.report.documentExpired)
        XCTAssertEqual(rejection.sessionID, "session"); XCTAssertEqual(rejection.nonceID, "nonce-id")
        XCTAssertEqual(rejection.origin.absoluteString, "https://worker.test"); XCTAssertEqual(rejection.installationID, "installation")
        XCTAssertEqual(rejection.securityObjectSHA256, SavedPassportCapture.digest(read().securityObject))
        let rows = PassportServerPresentation.rows(rejection)
        XCTAssertEqual(rows.first?.value, KenshikiCopy.text("passport.server.failed"))
        XCTAssertTrue(rows.contains { $0.identifier == "passport.server.hashes" && $0.value == KenshikiCopy.text("passport.result.failed") })
        XCTAssertTrue(rows.contains { $0.identifier == "passport.server.expiry" && $0.value == KenshikiCopy.text("telemetry.unavailable") })
        XCTAssertTrue(rows.contains { $0.identifier == "passport.server.failureReason" && $0.value == "data_group_hash_mismatch" })
        XCTAssertFalse(rows.contains { ["passport.server.aa", "passport.server.ca"].contains($0.identifier) })
        XCTAssertFalse(String(describing: rejection).contains("holder_binding"))
        XCTAssertNil(controller.result); XCTAssertNil(controller.resultServerVerification)
        XCTAssertEqual(persisted, 0); controller.send(.usePortrait); XCTAssertEqual(accepted, 0)
        controller.send(.retryRead); XCTAssertNil(controller.serverRejection)
        await scanUntilFailure(controller)
        XCTAssertNotNil(controller.serverRejection)
        controller.send(.cancel); XCTAssertNil(controller.serverRejection); await controller.waitForRetirement()
    }

    @MainActor func testLateFailedResponseAfterRetirementCannotRestoreReportOrPersistEvidence() async throws {
        let worker = PassportWorkerProbe(.rejectedReason("data_group_hash_mismatch")); await worker.pauseAtVerification()
        let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, nonce, _, _ in self.read(challenge: nonce.activeAuthenticationChallenge) }))
        let controller = PassportFlowController(effects: .init(serverRead: { key, trust, event, stage, admit in
            try await ceremony.read(key: key, trust: trust, event: event, stage: stage, admit: admit)
        }, startCamera: { _, _ in }, stopCamera: {}, read: { _, _, _ in self.read() }))
        var persisted = 0; controller.persistCompletedRead = { _ in persisted += 1 }
        prepare(controller); controller.send(.scan); await worker.waitForVerification()
        controller.send(.cancelScan); await worker.releaseVerification(); await controller.waitForRetirement()
        XCTAssertEqual(controller.phase, .ready); XCTAssertNil(controller.serverRejection)
        XCTAssertNil(controller.result); XCTAssertEqual(persisted, 0)
        controller.send(.cancel)
    }

    @MainActor func testLocalAndTransportFailuresDoNotFabricateCanonicalServerRejections() async throws {
        for behavior in [PassportWorkerProbe.Behavior.success, .lostVerification] {
            let worker = PassportWorkerProbe(behavior)
            let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, nonce, _, _ in
                self.read(challenge: nonce.activeAuthenticationChallenge, localFailure: behavior == .success)
            }))
            let controller = PassportFlowController(effects: .init(serverRead: { key, trust, event, stage, admit in
                try await ceremony.read(key: key, trust: trust, event: event, stage: stage, admit: admit)
            }, startCamera: { _, _ in }, stopCamera: {}, read: { _, _, _ in self.read() }))
            prepare(controller); await scanUntilFailure(controller)
            XCTAssertEqual(controller.phase, .failure); XCTAssertNil(controller.serverRejection); XCTAssertNil(controller.result)
            controller.send(.cancel); await controller.waitForRetirement()
        }
    }

    @MainActor private func scanUntilFailure(_ controller: PassportFlowController,
        file: StaticString = #filePath, line: UInt = #line) async {
        let settled = XCTestExpectation(description: "Current passport operation reached terminal failure")
        let previous = controller.onChange
        var completed = false
        controller.onChange = {
            previous?()
            if controller.phase == .failure, !completed { completed = true; settled.fulfill() }
        }
        defer { controller.onChange = previous }
        controller.send(.scan)
        let result = await XCTWaiter.fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(result, .completed, "Wait for actual terminal callback, not an executor yield budget", file: file, line: line)
    }

    @MainActor private func prepare(_ controller: PassportFlowController) {
        controller.send(.visible)
        controller.send(.manualKey(.init(documentNumber: "L898902C3", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415")))
        controller.send(.confirmKey); controller.supplyTrustAnchors(trust())
    }

    @MainActor func testFailedServerVerdictNeverReturnsVerifiedRead() async throws {
        let worker = PassportWorkerProbe(.rejected)
        let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, nonce, _, _ in self.read(challenge: nonce.activeAuthenticationChallenge) }))
        await expect(.rejected, ceremony)
    }

    @MainActor func testAmbiguousSessionFailureRetriesIdenticalOperationBytes() async throws {
        let worker = PassportWorkerProbe(.lostFirstSession)
        let client = client(worker)
        let ceremony = PassportServerCeremony(ports: .init(client: { client }, read: { _, _, nonce, _, _ in self.read(challenge: nonce.activeAuthenticationChallenge) }))
        await expect(.unavailable, ceremony)
        _ = try await ceremony.read(key: key(), trust: trust(), event: { _ in }, stage: { _ in })
        let sessions = await worker.requests.filter { $0.0 == "/identity/sessions" }
        XCTAssertEqual(sessions.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: sessions[0].1) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: sessions[1].1) as? [String: Any])
        XCTAssertEqual(first["operation_id"] as? String, second["operation_id"] as? String)
        XCTAssertEqual(first["issued_at"] as? String, second["issued_at"] as? String)
    }

    @MainActor func testAmbiguousVerificationRetiresPossiblyConsumedNonceBeforeRetry() async throws {
        let worker = PassportWorkerProbe(.lostVerification)
        let client = client(worker)
        let ceremony = PassportServerCeremony(ports: .init(client: { client }, read: { _, _, nonce, _, _ in self.read(challenge: nonce.activeAuthenticationChallenge) }))
        await expect(.unavailable, ceremony); await expect(.unavailable, ceremony)
        let sessions = await worker.requests.filter { $0.0 == "/identity/sessions" }
        XCTAssertEqual(sessions.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: sessions[0].1) as? [String: Any])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: sessions[1].1) as? [String: Any])
        XCTAssertNotEqual(first["operation_id"] as? String, second["operation_id"] as? String)
    }

    @MainActor func testCancellationAfterReturnedReadRetiresDeliveredNonceBeforeNextRead() async throws {
        let worker = PassportWorkerProbe()
        var delivered = 0
        let ceremony = PassportServerCeremony(ports: .init(client: { self.client(worker) }, read: { _, _, nonce, _, _ in
            delivered += 1
            if delivered == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            return self.read(challenge: nonce.activeAuthenticationChallenge)
        }))
        let cancelled = Task { try await ceremony.read(key: self.key(), trust: self.trust(), event: { _ in }, stage: { _ in }) }
        do { _ = try await cancelled.value; XCTFail("Cancelled returned read accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await ceremony.read(key: key(), trust: trust(), event: { _ in }, stage: { _ in })
        let requests = await worker.requests
        XCTAssertEqual(requests.filter { $0.0 == "/identity/sessions" }.count, 2)
        XCTAssertEqual(requests.filter { $0.0 == "/passport/nonce" }.count, 2)
        XCTAssertEqual(requests.filter { $0.0 == "/passport/verify" }.count, 1)
    }

    @MainActor func testCancelledReadDoesNotSubmitAndCanRetryWithUnconsumedSession() async throws {
        let worker = PassportWorkerProbe()
        let client = client(worker)
        var reads = 0
        let ceremony = PassportServerCeremony(ports: .init(client: { client }, read: { _, _, nonce, _, _ in
            reads += 1
            if reads == 1 { throw PassportReadFailure.cancelled }
            return self.read(challenge: nonce.activeAuthenticationChallenge)
        }))
        do { _ = try await ceremony.read(key: key(), trust: trust(), event: { _ in }, stage: { _ in }); XCTFail("Expected cancellation") }
        catch let failure as PassportReadFailure { XCTAssertEqual(failure, .cancelled) }
        _ = try await ceremony.read(key: key(), trust: trust(), event: { _ in }, stage: { _ in })
        let requests = await worker.requests
        XCTAssertEqual(requests.filter { $0.0 == "/identity/sessions" }.count, 1)
        XCTAssertEqual(requests.filter { $0.0 == "/passport/nonce" }.count, 1)
        XCTAssertEqual(requests.filter { $0.0 == "/passport/verify" }.count, 1)
    }

    @MainActor func testNFCPercentUsesBoundedRealStageValuesAndCompletion() {
        let copy = PassportNFCText(present: "present", authenticating: "auth", reading: "read", active: "active", finishing: "finish", verifying: "verify", complete: "complete", failed: "failed")
        let percent: (Int) -> String = { (Double($0) / 100).formatted(.percent.precision(.fractionLength(0))) }
        XCTAssertEqual(copy.message(.authenticating(progress: -2)), "auth — " + percent(0))
        XCTAssertEqual(copy.message(.reading(group: "DG2", progress: 47)), "read DG2 — " + percent(47))
        XCTAssertEqual(copy.message(.reading(group: "DG1", progress: 1000)), "read DG1 — " + percent(100))
        XCTAssertEqual(copy.message(.transportFinishing), "complete — " + percent(100))
        XCTAssertEqual(copy.message(.transportComplete), "complete — " + percent(100))
        XCTAssertEqual(copy.message(.passiveAuthentication), "verify")
    }

    @MainActor func testServerFailureCannotDowngradeToLocalReadOrPersistPortrait() async throws {
        var localReads = 0, writes = 0
        let effects = PassportFlowEffects(serverRead: { _, _, _, _, _ in throw PassportServerFailure.rejected },
            startCamera: { _, _ in }, stopCamera: {}, read: { _, _, _ in localReads += 1; return self.read() })
        let controller = PassportFlowController(effects: effects)
        controller.persistCompletedRead = { _ in writes += 1 }
        controller.send(.visible)
        controller.send(.manualKey(.init(documentNumber: "L898902C3", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415")))
        controller.send(.confirmKey); controller.supplyTrustAnchors(trust()); controller.send(.scan)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(controller.failure, .server(.rejected)); XCTAssertNil(controller.result)
        XCTAssertEqual(localReads, 0); XCTAssertEqual(writes, 0)
    }

    func testHistoricalLocalCheckpointRemainsWithoutServerVerification() throws {
        let local = try CaptureStoreFixture.capture()
        let restored = try SavedPassportCapture.decode(local.encoded())
        XCTAssertNil(restored.serverVerification)
        let raw = try XCTUnwrap(PropertyListSerialization.propertyList(from: local.encoded(), format: nil) as? [String: Any])
        XCTAssertNil(raw["serverVerification"])
    }

    func testServerObservationRoundTripsThroughEncryptedCheckpointAndRejectsSubstitutedSOD() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let base = CaptureStoreFixture.accepted()
        let receipt = PassportServerVerification(sessionID: "session", nonceID: "nonce", verifiedAt: base.capturedAt,
            validator: "validator", activeAuthentication: false, chipAuthentication: true, assurance: nil, trustBundleVersion: "test",
            securityObjectSHA256: SavedPassportCapture.digest(base.read.securityObject))
        let accepted = AcceptedPassportPortrait(attemptID: base.attemptID, read: base.read, printedMRZ: base.printedMRZ,
            capturedAt: base.capturedAt, serverVerification: receipt)
        let capture = try SavedPassportCapture(accepted)
        try await fixture.repository().save(capture)
        let restored = try await fixture.repository().load()
        XCTAssertEqual(restored?.serverVerification, receipt)
        XCTAssertEqual(receipt.exportObject["status"] as? String, "verified")
        XCTAssertNil(receipt.exportObject["holder_binding"])
        XCTAssertThrowsError(try receipt.validate(securityObject: Data([99]), capturedAt: base.capturedAt))
    }

    #if DEBUG
    func testSODFramingDiagnosticsExposeOnlyBoundedMetadataAcrossEnvelopeShapes() throws {
        // These vectors qualify framing diagnostics, never CMS signature verification.
        let vectors: [(Data, String, String, String, String, String, String)] = [
            (Data([0x77, 5, 0x30, 3, 2, 1, 0]), "119", "5", "true", "48", "3", "true"),
            (Data([0x30, 3, 2, 1, 0]), "48", "3", "true", "48", "3", "true"),
            (Data([0x77, 0x80, 0x30, 0, 0, 0]), "119", "indefinite", "false", "unavailable", "unavailable", "false"),
            (Data([0x77, 0x82, 1]), "119", "truncated", "false", "unavailable", "unavailable", "false"),
            (Data([0x77, 5, 0x30, 3, 2, 1]), "119", "5", "false", "48", "3", "false"),
            (Data([0x77, 5, 0x30, 3, 2, 1, 0, 0]), "119", "5", "false", "48", "3", "true"),
            (Data([0x77, 6, 0x30, 3, 2, 1, 0, 0]), "119", "6", "true", "48", "3", "false"),
            (Data([0x76, 5, 0x30, 3, 2, 1, 0]), "118", "5", "true", "118", "5", "true"),
            (Data([0x77, 6, 0x30, 0x80, 2, 0, 0, 0]), "119", "6", "true", "48", "indefinite", "false"),
            (Data([0x77, 0x84, 0, 0, 0, 1, 0x30]), "119", "overwide", "false", "unavailable", "unavailable", "false")
        ]
        let keys: Set<String> = ["byteCount", "sha256", "outerTag", "outerHeaderWidth", "outerDeclaredLength", "outerExactFit",
            "innerCMSTag", "innerCMSHeaderWidth", "innerCMSDeclaredLength", "innerCMSExactFit"]
        let outerWidths = ["2", "2", "2", "4", "2", "2", "2", "2", "2", "6"]
        let innerWidths = ["2", "2", "unavailable", "unavailable", "2", "2", "2", "2", "2", "unavailable"]
        for (index, vector) in vectors.enumerated() {
            let (bytes, outerTag, outerLength, outerFit, innerTag, innerLength, innerFit) = vector
            let diagnostic = PassportServerDiagnostic.sodFraming(bytes)
            let fields = Dictionary(uniqueKeysWithValues: diagnostic.message.split(separator: " ").dropFirst().map {
                let pair = $0.split(separator: "=", maxSplits: 1); return (String(pair[0]), String(pair[1]))
            })
            XCTAssertEqual(Set(fields.keys), keys)
            XCTAssertEqual(fields["outerHeaderWidth"], outerWidths[index])
            XCTAssertEqual(fields["innerCMSHeaderWidth"], innerWidths[index])
            XCTAssertEqual(fields["byteCount"], String(bytes.count))
            XCTAssertEqual(fields["sha256"], SavedPassportCapture.digest(bytes))
            XCTAssertEqual(fields["outerTag"], outerTag); XCTAssertEqual(fields["outerDeclaredLength"], outerLength)
            XCTAssertEqual(fields["outerExactFit"], outerFit); XCTAssertEqual(fields["innerCMSTag"], innerTag)
            XCTAssertEqual(fields["innerCMSDeclaredLength"], innerLength); XCTAssertEqual(fields["innerCMSExactFit"], innerFit)
            XCTAssertFalse(diagnostic.isFailure)
            XCTAssertTrue(PassportServerDiagnostic.sodFraming(bytes, rejected: true).isFailure)
        }
        let secret = "passport L898902C3 bearer secret-token\ncertificate holder portrait"
        let bounded = PassportServerDiagnostic.sodFraming(Data(secret.utf8)).message
        XCTAssertLessThan(bounded.utf8.count, 512)
        for value in [secret, "L898902C3", "secret-token", "certificate", "portrait", Data(secret.utf8).base64EncodedString(), "\n"] {
            XCTAssertFalse(bounded.contains(value))
        }
        XCTAssertTrue(PassportServerDiagnostic.http(.verify, status: 403, reason: "sod_encoding_invalid").message.contains("reason=sod_encoding_invalid"))
        XCTAssertFalse(PassportServerDiagnostic.http(.verify, status: 403, reason: "sod_encoding_invalid " + secret).message.contains(secret))
    }
    #endif

    @MainActor private func expect(_ expected: PassportServerFailure, _ ceremony: PassportServerCeremony, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await ceremony.read(key: key(), trust: trust(), event: { _ in }, stage: { _ in }); XCTFail("Expected server refusal", file: file, line: line) }
        catch let error as PassportServerFailure { XCTAssertEqual(error, expected, file: file, line: line) }
        catch let rejection as PassportServerRejection { XCTAssertEqual(rejection.failure, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error type", file: file, line: line) }
    }
    private func client(_ transport: any PulseBoundedHTTPTransport,
                        diagnostic: @escaping @Sendable (PassportServerDiagnostic) -> Void = { _ in
                            // Tests can omit an observer; persistent diagnostic OSLog recording still runs.
                        }) -> PulsePassportClient {
        PulsePassportClient(baseURL: URL(string: "https://worker.test")!, deviceID: "installation", attestation: .init(
            installationToken: { "installation-token" }, assert: { .init(keyID: "key", clientDataHash: $0.base64EncodedString(), assertionObject: "proof") }), transport: transport, diagnostic: { PassportServerDiagnostic.service($0).record(observer: diagnostic) })
    }
    private func key() -> PassportAccessKey { try! .init(documentNumber: "L898902C3", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415") }
    private func trust() -> URL { URL(fileURLWithPath: "/synthetic-trust.pem") }
    private func read(challenge: Data? = nil, localFailure: Bool = false, surname: String = "ERIKSSON", givenNames: String = "ANNA MARIA", defect: String? = nil) -> PassportReadObservation {
        .init(documentNumber: "L898902C3", surname: surname, givenNames: givenNames, nationality: "UTO", issuingState: "UTO",
            birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415", sex: "F", personalNumber: nil, dateOfIssue: nil,
            issuingAuthority: nil, placeOfBirth: nil, basicAccessControl: defect == "access" ? .failed : .succeeded, pace: .notPerformed,
            activeAuthentication: defect == "aa" ? .failed : (challenge == nil ? .notPerformed : .succeeded),
            chipAuthentication: defect == "ca" ? .failed : .notPerformed,
            countrySigningChain: defect == "chain" ? .failed : .succeeded,
            documentSignature: defect == "signature" ? .failed : .succeeded,
            dataGroupHashes: localFailure || defect == "hashes" ? .failed : .succeeded,
            documentSigningCertificateDER: defect == "certificateMissing" ? nil : (defect == "certificateEmpty" ? Data() : Data([3])), activeAuthenticationChallenge: challenge, activeAuthenticationSignature: challenge.map { _ in Data([4]) },
            securityObject: defect == "sod" ? Data() : Data([5]), dataGroups: ["DG1": Data([1]), "DG14": Data([14]), "DG2": Data([2]), "SOD": Data([5])],
            declaredDataGroups: ["DG1", "DG2", "DG14"], dg2: Data([2]), portrait: Data([2]), dg2Digest: SavedPassportCapture.digest(Data([2])),
            dg2DigestAlgorithm: "SHA-256", chipAuthenticationResponse: Data([0x90, 0x00]))
    }
}
