import CryptoKit
import Foundation
import PassportSDK
import KenshikiPulsePassport
import KenshikiOperationBinding
import OSLog

/// Only fixed protocol vocabulary and redacted server classifications enter persistent logs.
/// In particular, this does not retain the evidence, installation, session, nonce or bearer.
struct PassportServerDiagnostic: Equatable, Sendable {
    enum Step: String, Sendable { case credentials, session, nonce, chipRead, localProof, localIntegrity, verify, checkpoint, completed }
    enum Endpoint: String, Sendable {
        case session = "/identity/sessions", nonce = "/passport/nonce"
        case chipAuthentication = "/passport/chip-authentication", verify = "/passport/verify", unknown
        init(path: String) { self = Self(rawValue: "/" + path) ?? .unknown }
    }
    enum Check: String, Sendable { case responseURL, status, mime, json, body, binding, proof, integrity }
    enum FlowCheck: String, Sendable { case returnedBinding, evidenceIntegrity, checkpoint }
    let message: String
    let isFailure: Bool
    private init(message: String, isFailure: Bool) { self.message = message; self.isFailure = isFailure }
    private static let logger = Logger(subsystem: "com.kenshiki.reference", category: "passport-server")
    private static let reasons: Set<String> = [
        "csca_trust_store_not_configured", "sod_encoding_invalid", "sod_unexpected_content_type", "sod_signature_invalid",
        "data_group_hash_mismatch", "dsc_csca_chain_invalid", "crl_not_configured", "issuer_crl_not_found",
        "dsc_certificate_revoked", "document_expired_or_unreadable", "active_authentication_failed",
        "active_authentication_required", "active_authentication_not_declared_in_sod", "dg15_missing_for_active_authentication",
        "active_authentication_signature_malformed", "chip_authentication_not_declared_in_sod",
        "dg14_missing_for_chip_authentication", "chip_authentication_not_declared_in_dg14", "chip_authentication_required",
        "chip_authentication_key_missing", "chip_authentication_failed", "nfc_challenge_nonce_mismatch",
        "missing_passport_proof", "trust_bundle_override_incomplete", "trust_publisher_key_not_configured",
        "trust_publisher_key_invalid", "trust_bundle_signature_missing", "trust_bundle_signature_invalid",
        "trust_bundle_manifest_invalid", "trust_bundle_digest_mismatch", "trust_bundle_not_active", "trust_bundle_expired",
        "app_attest_assertion_reused", "face_attempt_recorded", "face_passport_unbound",
        "chip_authentication_unavailable", "chip_authentication_unsupported",
    ]
    private static func classification(_ value: String?, allowing known: Set<String>) -> String {
        guard let value else { return "none" }
        if known.contains(value) { return value }
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return "unknown:sha256:" + digest
    }
    static func service(_ value: PulsePassportDiagnostic) -> Self { .init(message: value.message, isFailure: value.isFailure) }
    static func step(_ step: Step) -> Self { .init(message: "step=" + step.rawValue, isFailure: false) }
    static func http(_ endpoint: Endpoint, status: Int, reason: String?) -> Self {
        .init(message: "endpoint=\(endpoint.rawValue) http=\(status) reason=\(classification(reason, allowing: reasons))", isFailure: status >= 400)
    }
    static func transport(_ endpoint: Endpoint, reason: PulsePassportFailure) -> Self {
        .init(message: "endpoint=\(endpoint.rawValue) transportFailure=\(reason.rawValue)", isFailure: true)
    }
    static func check(_ check: Check, endpoint: Endpoint = .unknown, passed: Bool) -> Self {
        .init(message: "endpoint=\(endpoint.rawValue) check=\(check.rawValue) passed=\(passed)", isFailure: !passed)
    }
    static func flow(_ check: FlowCheck, passed: Bool) -> Self {
        .init(message: "flowCheck=\(check.rawValue) passed=\(passed)", isFailure: !passed)
    }
    static func correspondence(_ fields: [PassportCorrespondenceObservation.Field: PassportCorrespondenceObservation.Comparison]) -> Self {
        let values = PassportCorrespondenceObservation.Field.allCases.map {
            $0.rawValue + "=" + (fields[$0] ?? .notCompared).rawValue
        }.joined(separator: " ")
        return .init(message: "flow=correspondence " + values, isFailure: fields.values.contains(.differs))
    }
    static func local(_ read: PassportReadObservation) -> Self {
        .init(message: "local bac=\(read.basicAccessControl.rawValue) pace=\(read.pace.rawValue) chain=\(read.countrySigningChain.rawValue) signature=\(read.documentSignature.rawValue) groups=\(read.dataGroupHashes.rawValue) aa=\(read.activeAuthentication.rawValue) ca=\(read.chipAuthentication.rawValue)", isFailure: false)
    }
    static func verdict(_ value: PulsePassportVerification) -> Self {
        .init(message: "verdict=\(value.status.rawValue) validator=\(classification(value.validator, allowing: ["passport_validator"])) failureReason=\(classification(value.failureReason, allowing: reasons)) aa=\(value.activeAuthentication) ca=\(value.chipAuthentication)", isFailure: value.status == .failed)
    }
    static func failure(_ step: Step, reason: PassportServerFailure) -> Self {
        .init(message: "step=\(step.rawValue) failure=\(reason.rawValue)", isFailure: true)
    }
    static func cancelled(_ step: Step) -> Self { .init(message: "step=\(step.rawValue) cancelled", isFailure: false) }
    static func readerFailure(_ step: Step, reason: PassportReadFailure) -> Self {
        .init(message: "step=\(step.rawValue) readerFailure=\(reason.rawValue)", isFailure: reason != .cancelled)
    }
    #if DEBUG
    /// Framing metadata only; this neither verifies CMS nor changes the submitted evidence.
    static func sodFraming(_ data: Data, rejected: Bool = false) -> Self {
        let outer = SODFrame(data, 0..<data.count)
        let inner = SODFrame(data, outer.tag == 0x77 ? outer.body : 0..<data.count)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(message: "sodFraming byteCount=\(data.count) sha256=\(digest) " +
            outer.fields("outer") + " " + inner.fields("innerCMS"), isFailure: rejected)
    }
    private struct SODFrame {
        var tag: Int? = nil, headerWidth: Int? = nil
        var declaredLength = "unavailable", exactFit = false
        var body: Range<Int>? = nil
        init(_ data: Data, _ range: Range<Int>?) {
            guard let range, !range.isEmpty else { return }
            func byte(_ offset: Int) -> Int { Int(data[data.startIndex + range.lowerBound + offset]) }
            tag = byte(0)
            guard range.count >= 2 else { return }
            let first = byte(1), octets = first & 0x7f
            headerWidth = first < 0x80 ? 2 : 2 + octets
            if first == 0x80 { declaredLength = "indefinite"; return }
            if first > 0x80 && octets > 3 { declaredLength = "overwide"; return }
            guard let width = headerWidth, range.count >= width else { declaredLength = "truncated"; return }
            var length = first
            if first > 0x80 {
                length = 0
                for offset in 2..<width { length = length << 8 | byte(offset) }
            }
            declaredLength = String(length)
            exactFit = length == range.count - width
            let start = range.lowerBound + width
            body = start..<(start + min(length, range.count - width))
        }
        func fields(_ name: String) -> String {
            let tagText = tag.map { String($0) } ?? "unavailable"
            let widthText = headerWidth.map { String($0) } ?? "unavailable"
            return "\(name)Tag=\(tagText) \(name)HeaderWidth=\(widthText) \(name)DeclaredLength=\(declaredLength) \(name)ExactFit=\(exactFit)"
        }
    }
    #endif
    func record(observer: @Sendable (Self) -> Void) {
        if isFailure { Self.logger.error("passport_server \(message, privacy: .public)") }
        else { Self.logger.notice("passport_server \(message, privacy: .public)") }
        observer(self)
    }
}

typealias PassportServerValidationReport = KenshikiPulsePassport.PulsePassportValidationReport

/// The server's recorded observation, bound to the exact locally retained Security Object.
/// Tokens and holder-binding credentials never enter saved passport evidence or presentation.
struct PassportServerVerification: Codable, Equatable, Sendable {
    let sessionID: String
    let nonceID: String
    let verifiedAt: Date
    let validator: String
    let activeAuthentication: Bool
    let chipAuthentication: Bool
    let assurance: String?
    let trustBundleVersion: String?
    let securityObjectSHA256: String
    let validationReport: PassportServerValidationReport?
    let origin: URL?
    let installationID: String?
    private let protectedHolderCapability: Data?

    init(sessionID: String, nonceID: String, verifiedAt: Date, validator: String,
         activeAuthentication: Bool, chipAuthentication: Bool, assurance: String?,
         trustBundleVersion: String?, securityObjectSHA256: String,
         validationReport: PassportServerValidationReport? = nil, origin: URL? = nil,
         installationID: String? = nil, protectedHolderCapability: Data? = nil) {
        self.sessionID = sessionID; self.nonceID = nonceID; self.verifiedAt = verifiedAt
        self.validator = validator; self.activeAuthentication = activeAuthentication
        self.chipAuthentication = chipAuthentication; self.assurance = assurance
        self.trustBundleVersion = trustBundleVersion; self.securityObjectSHA256 = securityObjectSHA256
        self.validationReport = validationReport
        self.origin = origin; self.installationID = installationID
        self.protectedHolderCapability = protectedHolderCapability
    }

    init(_ accepted: PulsePassportAcceptance) throws {
        self.init(sessionID: accepted.sessionID, nonceID: accepted.nonceID, verifiedAt: accepted.clientReceivedAt,
            validator: accepted.report.validator, activeAuthentication: accepted.report.activeAuthentication,
            chipAuthentication: accepted.report.chipAuthentication, assurance: accepted.report.assurance.rawValue,
            trustBundleVersion: accepted.report.trustBundleVersion, securityObjectSHA256: accepted.securityObjectSHA256,
            validationReport: accepted.report, origin: accepted.origin, installationID: accepted.installationID,
            protectedHolderCapability: try accepted.holderCapability?.protectedRepresentation())
    }

    var exportObject: [String: Any] {
        var value: [String: Any] = ["status": "verified", "sessionID": sessionID, "nonceID": nonceID,
            "verifiedAt": verifiedAt.formatted(.iso8601), "validator": validator,
            "activeAuthentication": activeAuthentication, "chipAuthentication": chipAuthentication,
            "securityObjectSHA256": securityObjectSHA256]
        value["assurance"] = assurance; value["trustBundleVersion"] = trustBundleVersion
        value["validationReport"] = validationReport?.exportObject
        return value
    }

    func validate(securityObject: Data, capturedAt: Date) throws {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 256,
              !nonceID.isEmpty, nonceID.utf8.count <= 256,
              !validator.isEmpty, validator.utf8.count <= 256,
              verifiedAt.timeIntervalSince1970.isFinite,
              abs(verifiedAt.timeIntervalSince(capturedAt)) <= 600,
              assurance.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              trustBundleVersion.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              SavedPassportCapture.digest(securityObject) == securityObjectSHA256 else {
            throw PassportServerFailure.invalidResponse
        }
        if let protectedHolderCapability {
            guard let origin, let installationID, !installationID.isEmpty else { throw PassportServerFailure.invalidResponse }
            do {
                _ = try PulsePassportHolderCapability.restore(protectedHolderCapability, expectedOrigin: origin,
                    installationID: installationID, securityObjectSHA256: securityObjectSHA256)
            } catch { throw PassportServerFailure.invalidResponse }
        }
        if let report = validationReport {
            do { try report.validate() } catch { throw PassportServerFailure.invalidResponse }
            guard report.result == .verified, report.validator == validator,
                  report.activeAuthentication == activeAuthentication,
                  report.chipAuthentication == chipAuthentication,
                  report.assurance.rawValue == assurance,
                  report.trustBundleVersion == trustBundleVersion else {
                throw PassportServerFailure.invalidResponse
            }
        }
    }
}

/// Current-attempt server refusal. It retains public check facts and exact request lineage only;
/// it has no holder credential, checkpoint encoding, portrait or accepted-read conformance.
struct PassportServerRejection: Error, Sendable {
    let report: PassportServerValidationReport
    let sessionID: String
    let nonceID: String
    let origin: URL
    let installationID: String
    let securityObjectSHA256: String
    #if DEBUG
    let sodFramingDiagnostic: PassportServerDiagnostic
    #endif
    let receivedAt: Date
    var failure: PassportServerFailure { .verificationFailure(reason: report.failureReason) }

    init(verdict: PulsePassportVerification, prepared: PulsePreparedPassport,
         securityObject: Data, receivedAt: Date) throws {
        guard verdict.status == .failed, let report = verdict.validationReport,
              report.result == .failed, !securityObject.isEmpty else { throw PassportServerFailure.invalidResponse }
        try report.validate()
        self.report = report; sessionID = prepared.nonce.sessionID; nonceID = prepared.nonce.nonceID
        origin = prepared.origin; installationID = prepared.installationID
        securityObjectSHA256 = SavedPassportCapture.digest(securityObject); self.receivedAt = receivedAt
        #if DEBUG
        sodFramingDiagnostic = .sodFraming(securityObject, rejected: true)
        #endif
    }
}

struct PassportServerRead: Sendable {
    let read: PassportReadObservation
    let verification: PassportServerVerification
}

enum PassportServerStage: Sendable { case preparing, reading, verifying }
enum PassportServerFailure: String, Error, Equatable, Sendable {
    case configuration, credentials, registration, unavailable, timedOut, invalidResponse
    case unauthorized, expired, unsupportedChip, chipAuthenticationUnavailable, rejected

    static func verificationFailure(reason: String?) -> Self {
        switch reason {
        case "trust_bundle_override_incomplete", "trust_publisher_key_not_configured", "trust_publisher_key_invalid",
             "trust_bundle_signature_missing", "trust_bundle_signature_invalid", "trust_bundle_manifest_invalid",
             "trust_bundle_digest_mismatch", "trust_bundle_not_active", "trust_bundle_expired",
             "csca_trust_store_not_configured", "crl_not_configured", "issuer_crl_not_found":
            return .configuration
        default: return .rejected
        }
    }

    static func mapped(_ error: Error) -> Self {
        if let value = error as? Self { return value }
        if let http = error as? PulsePassportHTTPFailure { return mapped(http.classification) }
        if let value = error as? PulsePassportFailure {
            switch value {
            case .unauthorized, .forbidden: return .unauthorized
            case .challengeExpired: return .expired
            case .chipAuthenticationUnsupported: return .unsupportedChip
            case .chipAuthenticationUnavailable: return .chipAuthenticationUnavailable
            case .timedOut: return .timedOut
            case .invalidResponse, .incompleteProof, .invalidRequest: return .invalidResponse
            default: return .unavailable
            }
        }
        if error is RegisteredKeyEnrollmentError || error is PulsePassportRegistrationFailure {
            return .credentials
        }
        if let error = error as? URLError, error.code == .timedOut { return .timedOut }
        return .unavailable
    }
}

/// Host-only read/admission bridge. The optional shared service owns every server lifecycle.
@MainActor final class PassportServerCeremony {
    struct Ports {
        let client: @MainActor () async throws -> PulsePassportClient
        let read: @MainActor (PassportAccessKey, URL, PulsePassportNonce,
                   @escaping @Sendable (Data) async throws -> PassportChipAuthenticationChallenge,
                   @escaping @MainActor @Sendable (PassportReadEvent) -> Void) async throws -> PassportReadObservation
        var recoverDeadKey: (@MainActor (Error) async throws -> PulsePassportClient)?
        var now: @MainActor () -> Date
        var operationID: @MainActor () -> String
        var diagnostic: @Sendable (PassportServerDiagnostic) -> Void = { _ in
            // Observers are optional; PassportServerDiagnostic.record always writes persistent OSLog.
        }
        init(client: @escaping @MainActor () async throws -> PulsePassportClient,
             read: @escaping @MainActor (PassportAccessKey, URL, PulsePassportNonce,
                 @escaping @Sendable (Data) async throws -> PassportChipAuthenticationChallenge,
                 @escaping @MainActor @Sendable (PassportReadEvent) -> Void) async throws -> PassportReadObservation) {
            self.client = client; self.read = read
            now = { Date() }; operationID = { UUID().uuidString.lowercased() }
        }
    }
    private let ports: Ports
    private let service: PulsePassportService
    init(ports: Ports) {
        self.ports = ports
        service = PulsePassportService(client: ports.client, recoverDeadKey: ports.recoverDeadKey,
            now: ports.now, operationID: ports.operationID)
    }

    func read(key: PassportAccessKey, trust: URL,
              event: @escaping @MainActor @Sendable (PassportReadEvent) -> Void,
              stage: @escaping @MainActor @Sendable (PassportServerStage) -> Void,
              admit: @escaping @MainActor @Sendable (PassportReadObservation) throws -> Void = { _ in }) async throws -> PassportServerRead {
        stage(.preparing)
        var currentStep = PassportServerDiagnostic.Step.credentials
        func step(_ value: PassportServerDiagnostic.Step) {
            currentStep = value
            PassportServerDiagnostic.step(value).record(observer: ports.diagnostic)
        }
        step(.credentials)
        var expectedChallenge: Data?
        var deliveredContext: (prepared: PulsePreparedPassport, securityObject: Data)?
        do {
            let accepted = try await service.runRead(
                binding: SavedPassportCapture.digest(Data(key.value.utf8)) + ":" + trust.absoluteString,
                read: { prepared, terminal in
                    stage(.reading); step(.chipRead)
                    expectedChallenge = prepared.nonce.activeAuthenticationChallenge
                    let relay = PassportServerRelayOutcome()
                    let read: PassportReadObservation
                    do {
                        read = try await self.ports.read(key, trust, prepared.nonce, { dg14 in
                            do {
                                let challenge = try await terminal(dg14)
                                return .init(protocolOID: challenge.caProtocolOID, keyID: challenge.keyID,
                                    terminalPublicKey: challenge.ephemeralPublicKey, protectedCommand: challenge.protectedCommand)
                            } catch { await relay.failed(error); throw error }
                        }, event)
                    } catch {
                        if let failure = await relay.failure { throw failure }
                        throw error
                    }
                    if Task.isCancelled {
                        try? self.service.discardDeliveredRead(prepared: prepared)
                        throw CancellationError()
                    }
                    #if DEBUG
                    PassportServerDiagnostic.sodFraming(read.securityObject).record(observer: self.ports.diagnostic)
                    #endif
                    deliveredContext = (prepared, read.securityObject)
                    return PulsePassportRead(read: read,
                        proof: .init(securityObject: read.securityObject, documentSigningCertificate: read.documentSigningCertificateDER ?? Data(),
                            dataGroups: read.dataGroups, activeAuthenticationChallenge: read.activeAuthenticationChallenge,
                            activeAuthenticationSignature: read.activeAuthenticationSignature),
                        chipAuthenticationResponse: read.chipAuthenticationResponse)
                }, admit: { read in
                    PassportServerDiagnostic.local(read).record(observer: self.ports.diagnostic)
                    step(.localProof)
                    let proofValid = read.documentSigningCertificateDER?.isEmpty == false && !read.securityObject.isEmpty &&
                        ((read.activeAuthentication != .succeeded && read.activeAuthenticationChallenge == nil)
                            || read.activeAuthenticationChallenge == expectedChallenge)
                    PassportServerDiagnostic.check(.proof, passed: proofValid).record(observer: self.ports.diagnostic)
                    guard proofValid else { throw PassportServerFailure.invalidResponse }
                    step(.localIntegrity)
                    let integrityValid = (read.basicAccessControl == .succeeded || read.pace == .succeeded) &&
                        read.countrySigningChain == .succeeded && read.documentSignature == .succeeded &&
                        read.dataGroupHashes == .succeeded && read.activeAuthentication != .failed && read.chipAuthentication != .failed
                    PassportServerDiagnostic.check(.integrity, passed: integrityValid).record(observer: self.ports.diagnostic)
                    guard integrityValid else { throw PassportServerFailure.rejected }
                    try admit(read)
                    try Task.checkCancellation()
                    stage(.verifying); step(.verify)
                })
            step(.checkpoint)
            let verification = try PassportServerVerification(accepted.acceptance)
            try verification.validate(securityObject: accepted.read.securityObject, capturedAt: ports.now())
            step(.completed)
            return .init(read: accepted.read, verification: verification)
        } catch is CancellationError {
            PassportServerDiagnostic.cancelled(currentStep).record(observer: ports.diagnostic)
            throw CancellationError()
        } catch let failure as PassportLocalAdmissionFailure {
            throw failure
        } catch let failure as PassportReadFailure {
            PassportServerDiagnostic.readerFailure(currentStep, reason: failure).record(observer: ports.diagnostic)
            throw failure
        } catch PulsePassportServiceFailure.verificationFailed(let verdict) {
            let failure = PassportServerFailure.verificationFailure(reason: verdict.failureReason)
            PassportServerDiagnostic.failure(currentStep, reason: failure).record(observer: ports.diagnostic)
            guard let deliveredContext else { throw PassportServerFailure.invalidResponse }
            let rejection = try PassportServerRejection(verdict: verdict, prepared: deliveredContext.prepared,
                securityObject: deliveredContext.securityObject, receivedAt: ports.now())
            #if DEBUG
            rejection.sodFramingDiagnostic.record(observer: ports.diagnostic)
            #endif
            throw rejection
        } catch {
            let failure = PassportServerFailure.mapped(error)
            PassportServerDiagnostic.failure(currentStep, reason: failure).record(observer: ports.diagnostic)
            throw failure
        }
    }
}

private actor PassportServerRelayOutcome {
    private(set) var failure: PassportServerFailure?
    func failed(_ error: Error) { failure = PassportServerFailure.mapped(error) }
}
