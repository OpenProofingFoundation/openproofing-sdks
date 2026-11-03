/// Semantic server facts shared by native adopters. Hosts own localized labels and values.
/// An absent historical report must remain absent; local checks never populate these rows.
public struct PulsePassportCheckObservation: Equatable, Sendable {
    public enum Check: String, CaseIterable, Sendable {
        case securityObjectSignature, documentSigningCertificate, countrySigningAuthority
        case dataGroupHashes, certificateRevocation, documentNotExpired
        case activeAuthentication, chipAuthentication
    }
    public let check: Check
    public let passed: Bool?

    public init(check: Check, passed: Bool?) {
        self.check = check
        self.passed = passed
    }
}

extension PulsePassportValidationReport {
    /// The server's exact issuer/data checks. Only verified optional hardware proofs are
    /// foregrounded: a false hardware flag does not establish a deficient or unsupported chip.
    public var presentedChecks: [PulsePassportCheckObservation] {
        var checks: [PulsePassportCheckObservation] = [
            .init(check: .securityObjectSignature, passed: sodVerified),
            .init(check: .documentSigningCertificate, passed: dscVerified),
            .init(check: .countrySigningAuthority, passed: cscaVerified),
            .init(check: .dataGroupHashes, passed: dataGroupHashesVerified),
            .init(check: .certificateRevocation, passed: crlChecked),
            .init(check: .documentNotExpired, passed: documentExpired.map { !$0 })
        ]
        if activeAuthentication { checks.append(.init(check: .activeAuthentication, passed: true)) }
        if chipAuthentication { checks.append(.init(check: .chipAuthentication, passed: true)) }
        return checks
    }
}
