import Foundation
import CryptoKit

public struct PulsePassportDiagnostic: Equatable, Sendable {
    enum Step: String, Sendable { case credentials, session, nonce, chipRead, localProof, localIntegrity, verify, checkpoint, completed }
    enum Endpoint: String, Sendable {
        case session = "/identity/sessions", nonce = "/passport/nonce"
        case chipAuthentication = "/passport/chip-authentication", verify = "/passport/verify", unknown
        init(path: String) { self = Self(rawValue: "/" + path) ?? .unknown }
    }
    enum Check: String, Sendable { case responseURL, status, mime, json, body, binding, proof, integrity }
    enum FlowCheck: String, Sendable { case returnedBinding, evidenceIntegrity, checkpoint }
    public let message: String
    public let isFailure: Bool
    private init(message: String, isFailure: Bool) { self.message = message; self.isFailure = isFailure }
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
    static func verdict(_ value: PulsePassportVerification) -> Self {
        .init(message: "verdict=\(value.status.rawValue) validator=\(classification(value.validator, allowing: ["passport_validator"])) failureReason=\(classification(value.failureReason, allowing: reasons)) aa=\(value.activeAuthentication) ca=\(value.chipAuthentication)", isFailure: value.status == .failed)
    }
    func record(observer: @Sendable (Self) -> Void) { observer(self) }
}
