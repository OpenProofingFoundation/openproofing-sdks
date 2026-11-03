import Foundation
import KenshikiPulsePassport

/// One prepared server projection for chip results and the journey's second-level details.
/// Local observations and missing historical facts never become server checks.
@MainActor enum PassportServerPresentation {
    static func rows(_ server: PassportServerVerification, historical: Bool,
                     includeProvenance: Bool = true) -> [PassportResultRow] {
        var rows = [row("passport.server.status", text(historical ? "passport.server.historical" : "passport.server.verified"))]
        if let report = server.validationReport {
            rows += checkRows(report)
            let assuranceKey: String
            switch report.assurance {
            case .chipAuthenticated: assuranceKey = "passport.server.assurance.chipAuthenticated"
            case .passiveAuthenticationOnly: assuranceKey = "passport.server.assurance.passive"
            case .unverified: assuranceKey = "passport.server.assurance.unverified"
            }
            rows.append(row("passport.server.assurance", text(assuranceKey)))
            if includeProvenance {
                if let version = report.trustBundleVersion { rows.append(row("passport.server.trustVersion", version)) }
                if let digest = report.trustManifestSha256 { rows.append(row("passport.server.trustManifest", digest)) }
            }
        } else {
            rows.append(row("passport.server.reportUnavailable", text("telemetry.unavailable")))
            if server.activeAuthentication { rows.append(row("passport.server.aa", text("passport.result.passed"))) }
            if server.chipAuthentication { rows.append(row("passport.server.ca", text("passport.result.passed"))) }
        }
        if includeProvenance {
            rows.append(row("passport.server.validator", server.validator))
            rows.append(row("passport.server.verifiedAt", server.verifiedAt.formatted(date: .abbreviated, time: .shortened)))
        }
        return rows
    }
    static func rows(_ rejected: PassportServerRejection) -> [PassportResultRow] {
        var rows = [row("passport.server.status", text("passport.server.failed"))]
        rows += checkRows(rejected.report)
        rows.append(row("passport.server.assurance", text("passport.server.assurance.unverified")))
        if let reason = rejected.report.failureReason { rows.append(row("passport.server.failureReason", reason)) }
        rows.append(row("passport.server.validator", rejected.report.validator))
        if let receipt = rejected.report.receiptId { rows.append(row("passport.server.receiptID", receipt)) }
        rows.append(row("passport.server.receivedAt", rejected.receivedAt.formatted(date: .abbreviated, time: .shortened)))
        rows.append(row("passport.server.origin", rejected.origin.absoluteString))
        rows.append(row("passport.server.installation", rejected.installationID))
        rows.append(row("passport.server.session", rejected.sessionID))
        rows.append(row("passport.server.nonce", rejected.nonceID))
        rows.append(row("passport.result.sod", rejected.securityObjectSHA256))
        if let version = rejected.report.trustBundleVersion { rows.append(row("passport.server.trustVersion", version)) }
        if let digest = rejected.report.trustManifestSha256 { rows.append(row("passport.server.trustManifest", digest)) }
        return rows
    }
    private static func checkRows(_ report: PassportServerValidationReport) -> [PassportResultRow] {
        report.presentedChecks.map { fact in
            let key: String
            switch fact.check {
            case .securityObjectSignature: key = "passport.server.sod"
            case .documentSigningCertificate: key = "passport.server.dsc"
            case .countrySigningAuthority: key = "passport.server.csca"
            case .dataGroupHashes: key = "passport.server.hashes"
            case .certificateRevocation: key = "passport.server.crl"
            case .documentNotExpired: key = "passport.server.expiry"
            case .activeAuthentication: key = "passport.server.aa"
            case .chipAuthentication: key = "passport.server.ca"
            }
            return row(key, text(fact.passed.map { $0 ? "passport.result.passed" : "passport.result.failed" } ?? "telemetry.unavailable"))
        }
    }
    private static func text(_ key: String) -> String { KenshikiCopy.text(key) }
    private static func row(_ key: String, _ value: String) -> PassportResultRow {
        .init(label: text(key), value: value, identifier: key)
    }
}
