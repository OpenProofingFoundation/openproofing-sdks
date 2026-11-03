import XCTest
@testable import KenshikiPulsePassport

final class PulsePassportCheckProjectionTests: XCTestCase {
    func testPassiveReportProjectsActualChecksWithoutAbsentOptionalHardwareRows() {
        let report = report()
        XCTAssertEqual(report.presentedChecks.map(\.check), [.securityObjectSignature, .documentSigningCertificate,
            .countrySigningAuthority, .dataGroupHashes, .certificateRevocation, .documentNotExpired])
        XCTAssertTrue(report.presentedChecks.allSatisfy { $0.passed == true })
        XCTAssertFalse(report.activeAuthentication)
        XCTAssertFalse(report.chipAuthentication)
    }
    func testPerformedHardwareProofsRemainVisibleAndUnknownExpiryRemainsUnknown() {
        let report = report(active: true, chip: true, expired: nil)
        XCTAssertEqual(report.presentedChecks.suffix(2).map(\.check), [.activeAuthentication, .chipAuthentication])
        XCTAssertNil(report.presentedChecks.first { $0.check == .documentNotExpired }?.passed)
    }
    func testFailedActualServerChecksAreNotReplacedWithLocalOrAssumedPasses() {
        let report = report(result: .failed, checks: false, expired: true)
        XCTAssertTrue(report.presentedChecks.allSatisfy { $0.passed == false })
        XCTAssertEqual(report.result, .failed)
        XCTAssertEqual(report.assurance, .unverified)
    }
    private func report(result: PulsePassportVerification.Status = .verified, checks: Bool = true,
                        active: Bool = false, chip: Bool = false, expired: Bool? = false) -> PulsePassportValidationReport {
        .init(result: result, validator: "passport_validator", receiptId: nil, sodVerified: checks,
            dscVerified: checks, cscaVerified: checks, dataGroupHashesVerified: checks,
            chipAuthenticated: active || chip, activeAuthentication: active, chipAuthentication: chip,
            crlChecked: checks, documentExpired: expired, failureReason: result == .failed ? "data_group_hash_mismatch" : nil,
            trustBundleVersion: "synthetic-test", trustManifestSha256: String(repeating: "a", count: 64),
            assurance: result == .failed ? .unverified : (active || chip ? .chipAuthenticated : .passiveAuthenticationOnly))
    }
}
