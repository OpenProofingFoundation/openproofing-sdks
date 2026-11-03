import XCTest

#if canImport(NFCPassportReader)
    @testable import NFCPassportReader

    final class NFCPassportPassiveAuthenticationTests: XCTestCase {
        func testAllThreePassiveAuthenticationLegsAreRequiredForVerified() {
            XCTAssertEqual(verdict(csca: true, sod: true, hashes: true), .verified)
            XCTAssertEqual(verdict(csca: true, sod: false, hashes: true), .integrityFailure)
            XCTAssertEqual(verdict(csca: true, sod: true, hashes: false), .integrityFailure)
            XCTAssertEqual(verdict(csca: false, sod: true, hashes: true), .integrityFailure)
        }

        func testMissingTrustAnchorIsDistinctOnlyWhenSignedDataIsIntact() {
            XCTAssertEqual(
                verdict(csca: false, sod: true, hashes: true, trustAnchorFailure: true),
                .trustAnchorNotFound)
            XCTAssertEqual(
                verdict(csca: false, sod: false, hashes: true, trustAnchorFailure: true),
                .integrityFailure)
            XCTAssertEqual(
                verdict(csca: false, sod: true, hashes: false, trustAnchorFailure: true),
                .integrityFailure)
        }

        private func verdict(
            csca: Bool,
            sod: Bool,
            hashes: Bool,
            trustAnchorFailure: Bool = false
        ) -> PassportPassiveAuthenticationVerdict {
            NFCPassportModel.passiveAuthenticationVerdict(
                cscaVerified: csca,
                sodSignatureVerified: sod,
                dataGroupHashesVerified: hashes,
                trustAnchorValidationFailed: trustAnchorFailure)
        }
    }
#endif
