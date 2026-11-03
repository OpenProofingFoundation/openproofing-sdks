import Foundation
import KenshikiPulsePassport
import XCTest
@testable import KenshikiReference

final class PassportServerPresentationTests: XCTestCase {
    @MainActor func testCanonicalServerChecksUseOneProjectionWithoutUnperformedHardwareRows() {
        let report = PulsePassportValidationReport(result: .verified, validator: "passport_validator", receiptId: nil,
            sodVerified: true, dscVerified: true, cscaVerified: true, dataGroupHashesVerified: true,
            chipAuthenticated: false, activeAuthentication: false, chipAuthentication: false, crlChecked: true,
            documentExpired: false, failureReason: nil, trustBundleVersion: "synthetic-version",
            trustManifestSha256: String(repeating: "a", count: 64), assurance: .passiveAuthenticationOnly)
        let server = PassportServerVerification(sessionID: "session", nonceID: "nonce", verifiedAt: Date(),
            validator: report.validator, activeAuthentication: false, chipAuthentication: false,
            assurance: report.assurance.rawValue, trustBundleVersion: report.trustBundleVersion,
            securityObjectSHA256: String(repeating: "b", count: 64), validationReport: report)
        let summary = PassportServerPresentation.rows(server, historical: false, includeProvenance: false)
        let details = PassportServerPresentation.rows(server, historical: false)
        XCTAssertEqual(Array(details.prefix(summary.count)).map { $0.identifier + ":" + $0.value },
            summary.map { $0.identifier + ":" + $0.value })
        XCTAssertEqual(summary.map(\.identifier), ["passport.server.status", "passport.server.sod", "passport.server.dsc",
            "passport.server.csca", "passport.server.hashes", "passport.server.crl", "passport.server.expiry", "passport.server.assurance"])
        XCTAssertFalse(summary.contains { ["passport.server.aa", "passport.server.ca", "passport.server.trustManifest"].contains($0.identifier) })
        XCTAssertTrue(details.contains { $0.identifier == "passport.server.trustManifest" && $0.value == report.trustManifestSha256 })
    }
    @MainActor func testHistoricalReceiptDoesNotInventMissingServerChecks() {
        let server = PassportServerVerification(sessionID: "session", nonceID: "nonce", verifiedAt: Date(),
            validator: "passport_validator", activeAuthentication: false, chipAuthentication: false,
            assurance: nil, trustBundleVersion: nil, securityObjectSHA256: String(repeating: "a", count: 64))
        let rows = PassportServerPresentation.rows(server, historical: true)
        XCTAssertTrue(rows.contains { $0.identifier == "passport.server.reportUnavailable" })
        XCTAssertFalse(rows.contains { ["passport.server.sod", "passport.server.csca", "passport.server.hashes",
            "passport.server.aa", "passport.server.ca"].contains($0.identifier) })
    }
}
