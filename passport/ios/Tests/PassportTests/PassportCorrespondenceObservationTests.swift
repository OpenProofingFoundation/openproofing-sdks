import XCTest

@testable import PassportSDK

final class PassportCorrespondenceObservationTests: XCTestCase {
  func testDocumentFillersAndNameSpacingDoNotCreateFalseDifferences() {
    let result = PassportCorrespondenceObservation(
      printed: printed(number: " x1234567<\n", surname: "van<<sample", given: "JANE<<<ANN"),
      chip: chip(surname: " VAN   SAMPLE ", given: "Jane Ann"))
    XCTAssertEqual(result.mismatchedFields, [])
    XCTAssertEqual(Set(result.fields.values), [.matches])
  }

  func testEveryMismatchedFieldIsReportedInsteadOfOnlyTheFirst() {
    let result = PassportCorrespondenceObservation(
      printed: printed(
        number: "OTHER", birth: "900101", expiry: "300101", surname: "OTHER", given: "OTHER"),
      chip: chip())
    XCTAssertEqual(
      result.mismatchedFields, [.documentNumber, .birthDate, .expiryDate, .surname, .givenNames])
  }

  func testReviewedNameMismatchIsVisibleEvenWhenChipAccessFieldsAgree() {
    let result = PassportCorrespondenceObservation(
      printed: printed(surname: "SANPLE"), chip: chip())
    XCTAssertEqual(result.mismatchedFields, [.surname])
    XCTAssertEqual(result.fields[.documentNumber], .matches)
  }

  func testMissingPrintedGivenNamesAreNotClaimedToMatch() {
    let result = PassportCorrespondenceObservation(printed: printed(given: ""), chip: chip())
    XCTAssertEqual(result.fields[.givenNames], .notCompared)
    XCTAssertEqual(result.mismatchedFields, [])
  }

  func testDatesAreComparedWithoutGuessingCenturyOrReformatting() {
    let result = PassportCorrespondenceObservation(
      printed: printed(birth: "19850615", expiry: "320101 "), chip: chip())
    XCTAssertEqual(result.mismatchedFields, [.birthDate, .expiryDate])
  }

  private func printed(
    number: String = "X1234567", birth: String = "850615", expiry: String = "320101",
    surname: String = "SAMPLE", given: String = "JANE"
  ) -> PassportMRZObservation {
    .init(
      documentNumber: number, birthDateYYMMDD: birth, expiryDateYYMMDD: expiry,
      surname: surname, givenNames: given, nationality: "UTO", issuingState: "UTO", sex: "F",
      normalizedLines: [])
  }

  private func chip(surname: String = "SAMPLE", given: String = "JANE") -> PassportReadObservation {
    .init(
      documentNumber: "X1234567", surname: surname, givenNames: given, nationality: "UTO",
      issuingState: "UTO", birthDateYYMMDD: "850615", expiryDateYYMMDD: "320101", sex: "F",
      personalNumber: nil, dateOfIssue: nil, issuingAuthority: nil, placeOfBirth: nil,
      basicAccessControl: .succeeded, pace: .notPerformed, activeAuthentication: .notPerformed,
      chipAuthentication: .notPerformed, countrySigningChain: .succeeded,
      documentSignature: .succeeded, dataGroupHashes: .succeeded,
      documentSigningCertificateDER: nil, activeAuthenticationChallenge: nil,
      activeAuthenticationSignature: nil, securityObject: Data(), dataGroups: [:],
      declaredDataGroups: [], dg2: nil, portrait: nil, dg2Digest: nil, dg2DigestAlgorithm: nil,
      chipAuthenticationResponse: nil)
  }
}
