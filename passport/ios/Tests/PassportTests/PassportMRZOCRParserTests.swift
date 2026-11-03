import XCTest

@testable import PassportSDK

/// Regression net for `PassportMRZOCRParser` (TD3/passport), written BEFORE the MRZ-parser
/// consolidation (dedup with `MRZCheckDigit`, generic TD1 capture pipeline) so that
/// work has an independent baseline to prove against. `PassportMRZOCRParser` had zero test
/// coverage before this file.
///
/// Fixture is fully synthetic — document type P, issuing/nationality `UTO` (ICAO's
/// own fictitious example country code), name "SPECIMEN SYNTHETIC" — nothing drawn
/// from a real document. Check digits (document number=7, DOB=1, expiry=5)
/// independently verified against the `cheminfo/mrz` oracle before being committed
/// to this file.
final class PassportMRZOCRParserTests: XCTestCase {
  private let line1 = "P<UTOSPECIMEN<<SYNTHETIC<<<<<<<<<<<<<<<<<<<<"
  private let line2 = "X1234567<7UTO8506151F3201015<<<<<<<<<<<<<<08"

  func testCompleteReadRejectsPartialTruncatedOversizedAndSameRowAlternatives() throws {
    XCTAssertNotNil(PassportMRZOCRParser.parseComplete(candidates: [[line1], [line2]]))
    XCTAssertNotNil(PassportMRZOCRParser.parseComplete(candidates: [[line1 + line2]]))
    XCTAssertNil(PassportMRZOCRParser.parseComplete(candidates: [[line2]]))
    XCTAssertNil(PassportMRZOCRParser.parseComplete(candidates:
      [[line1.replacingOccurrences(of: "SPECIMEN", with: "SPEC1MEN")], [line2]]))
    XCTAssertNil(PassportMRZOCRParser.parseComplete(candidates: [[line1, line2]]))
    XCTAssertNil(PassportMRZOCRParser.parseComplete(candidates: [[String(line1.dropLast())], [line2]]))
    XCTAssertNil(PassportMRZOCRParser.parseComplete(candidates: [[line1 + "X"], [line2]]))
    XCTAssertNil(PassportMRZOCRParser.parseComplete(candidates: [[line1], [line2 + "X"]]))
  }

  func testCompleteReadUsesHighestRankedValidNameAlternative() {
    let otherName = line1.replacingOccurrences(of: "SPECIMEN", with: "EXAMPLES")
    let scan = PassportMRZOCRParser.parseComplete(candidates: [[line1, otherName], [line2]])
    XCTAssertEqual(scan?.surname, "SPECIMEN")
    XCTAssertEqual(scan?.normalizedLines.first, line1)
    let reversed = PassportMRZOCRParser.parseComplete(candidates: [[otherName, line1], [line2]])
    XCTAssertEqual(reversed?.surname, "EXAMPLES")
    let invalidName = line1.replacingOccurrences(of: "SPECIMEN", with: "SPEC1MEN")
    XCTAssertEqual(PassportMRZOCRParser.parseComplete(candidates: [[invalidName, line1], [line2]])?.surname, "SPECIMEN")
  }

  func testCompleteReadRejectsDistinctPhysicalRowDocuments() {
    let otherName = line1.replacingOccurrences(of: "SPECIMEN", with: "EXAMPLES")
    XCTAssertNil(PassportMRZOCRParser.parseComplete(candidates: [[line1], [otherName], [line2]]))
    let otherKey = "L898902C36UTO7408122F1204159ZE184226B<<<<<10"
    XCTAssertNil(PassportMRZOCRParser.parseComplete(candidates: [[line1], [line2], [otherKey]]))
    XCTAssertNil(PassportMRZOCRParser.parseComplete(candidates: [[line1 + line2], [otherName + line2]]))
  }

  func testCompleteReadUsesHighestRankedValidKeyAndMergedAlternatives() {
    let otherKey = "L898902C36UTO7408122F1204159ZE184226B<<<<<10"
    XCTAssertEqual(PassportMRZOCRParser.parseComplete(candidates: [[line1], [line2, otherKey]])?.documentNumber, "X1234567")
    XCTAssertEqual(PassportMRZOCRParser.parseComplete(candidates: [[line1], [otherKey, line2]])?.documentNumber, "L898902C3")
    var invalid = Array(line2)
    invalid[9] = "0"
    XCTAssertEqual(PassportMRZOCRParser.parseComplete(candidates: [[line1], [String(invalid), line2]])?.documentNumber, "X1234567")
    let otherName = line1.replacingOccurrences(of: "SPECIMEN", with: "EXAMPLES")
    XCTAssertEqual(PassportMRZOCRParser.parseComplete(candidates: [[line1 + line2, otherName + line2]])?.surname, "SPECIMEN")
    XCTAssertNil(PassportMRZOCRParser.parseComplete(candidates: [[line1, line2]]))
  }

  func testCompleteReadAcceptsRepeatedAndNumericEquivalentAlternatives() {
    XCTAssertNotNil(PassportMRZOCRParser.parseComplete(candidates: [[line1, line1], [line2, line2]]))
    var equivalent = Array(line2)
    equivalent[15] = "O"
    let scan = PassportMRZOCRParser.parseComplete(candidates: [[line1], [line2, String(equivalent)]])
    XCTAssertEqual(scan?.birthDateYYMMDD, "850615")
    XCTAssertEqual(scan?.normalizedLines.last, line2)
  }

  func testValidTD3ParsesAllFields() throws {
    let scan = try XCTUnwrap(PassportMRZOCRParser.parse(candidates: [[line1], [line2]]))
    XCTAssertEqual(scan.documentNumber, "X1234567")
    XCTAssertEqual(scan.birthDateYYMMDD, "850615")
    XCTAssertEqual(scan.expiryDateYYMMDD, "320101")
    XCTAssertEqual(scan.surname, "SPECIMEN")
    XCTAssertEqual(scan.nationality, "UTO")
    XCTAssertEqual(scan.issuingState, "UTO")
    XCTAssertEqual(scan.sex, "F")
    XCTAssertEqual(scan.givenNames, "SYNTHETIC")
    XCTAssertEqual(scan.completeness, .complete)
  }

  func testWrongDocumentNumberCheckDigitRejectsLine() {
    var chars = Array(line2)
    chars[9] = (chars[9] == "6") ? "7" : "6"  // flip the doc# check digit away from 7
    XCTAssertNil(PassportMRZOCRParser.parse(candidates: [[line1], [String(chars)]]))
  }

  func testWrongBirthDateCheckDigitRejectsLine() {
    var chars = Array(line2)
    chars[19] = (chars[19] == "0") ? "1" : "0"  // flip the DOB check digit away from 1
    XCTAssertNil(PassportMRZOCRParser.parse(candidates: [[line1], [String(chars)]]))
  }

  func testWrongExpiryCheckDigitRejectsLine() {
    var chars = Array(line2)
    chars[27] = (chars[27] == "6") ? "5" : "6"  // flip the expiry check digit away from 5
    XCTAssertNil(PassportMRZOCRParser.parse(candidates: [[line1], [String(chars)]]))
  }

  func testOCRLetterDigitDisambiguationInBirthDate() throws {
    // OCR commonly misreads '0' as 'O' in numeric fields; the DOB/expiry fields
    // apply a fixup table before check-digit validation. Corrupt one digit of
    // "850615" (the '0' at index 2) to 'O' — disambiguation should restore it and
    // the check digit (computed against the true "850615") should still pass.
    var chars = Array(line2)
    let dobStart = 13
    XCTAssertEqual(chars[dobStart + 2], "0")
    chars[dobStart + 2] = "O"
    let scan = try XCTUnwrap(PassportMRZOCRParser.parse(candidates: [[line1], [String(chars)]]))
    XCTAssertEqual(
      scan.birthDateYYMMDD, "850615", "OCR fixup should restore the digit before validation")
  }

  func testFirstCheckDigitValidCandidateWinsOverEarlierGarbage() throws {
    let garbage = "NOT<AN<MRZ<LINE<AT<ALL<<<<<<<<<<<<<<<<<<<<<<"
    var badChars = Array(line2)
    badChars[9] = (badChars[9] == "6") ? "7" : "6"
    let badLine2 = String(badChars)

    let scan = try XCTUnwrap(
      PassportMRZOCRParser.parse(candidates: [[garbage], [line1], [badLine2], [line2]]))
    XCTAssertEqual(scan.documentNumber, "X1234567")
  }

  func testLine2OnlyReadStillParsesKeyFieldsAndReportsNameMissing() throws {
    // No line1 candidate at all — a partial frame missed the name line. The three
    // key fields (which drive check-digit validation) must still parse, the name
    // must be reported MISSING, and — the regression this guards — line 2 must
    // never be reused as its own "name line": an earlier `isLikelyLine1` accepted
    // any 44-char line containing "<<", so the review screen asked the holder to
    // confirm raw MRZ bytes as their name. Line 1 must be letters-majority.
    let scan = try XCTUnwrap(PassportMRZOCRParser.parse(candidates: [[line2]]))
    XCTAssertEqual(scan.documentNumber, "X1234567")
    XCTAssertEqual(scan.birthDateYYMMDD, "850615")
    XCTAssertTrue(scan.surname.isEmpty, "line 2 must not masquerade as the name line")
    XCTAssertTrue(scan.givenNames.isEmpty)
    XCTAssertEqual(scan.completeness, .partial)
    XCTAssertEqual(scan.missingFields, [.name, .issuingState])
  }

  func testMergedEightyEightCharacterReadSplitsIntoTwoLines() throws {
    let merged = line1 + line2
    XCTAssertEqual(merged.count, 88)
    let scan = try XCTUnwrap(PassportMRZOCRParser.parse(candidates: [[merged]]))
    XCTAssertEqual(scan.documentNumber, "X1234567")
    XCTAssertEqual(scan.surname, "SPECIMEN")
  }

  func testInvalidSexCharacterRejectsLine() {
    var chars = Array(line2)
    chars[20] = "9"  // not "M" or "F"
    XCTAssertNil(PassportMRZOCRParser.parse(candidates: [[line1], [String(chars)]]))
  }

  func testUnspecifiedSexFillerMapsToX() throws {
    var chars = Array(line2)
    chars[20] = "<"
    let scan = try XCTUnwrap(PassportMRZOCRParser.parse(candidates: [[line1], [String(chars)]]))
    XCTAssertEqual(scan.sex, "X")
  }

  func testWrongOptionalDataCheckDigitRejectsLine() {
    var chars = Array(line2)
    chars[42] = "1"
    XCTAssertNil(PassportMRZOCRParser.parse(candidates: [[line1], [String(chars)]]))
  }

  func testWrongCompositeCheckDigitRejectsLine() {
    var chars = Array(line2)
    chars[43] = (chars[43] == "8") ? "7" : "8"
    XCTAssertNil(PassportMRZOCRParser.parse(candidates: [[line1], [String(chars)]]))
  }

  func testImpossibleCalendarDateRejectsEvenWithMatchingCheckDigits() throws {
    var chars = Array(line2)
    chars.replaceSubrange(13..<19, with: Array("991332"))
    chars[19] = try XCTUnwrap(MRZCheckDigit.compute(for: String(chars[13..<19])))
    let composite =
      String(chars[0..<10]) + String(chars[13..<20]) + String(chars[21..<43])
    chars[43] = try XCTUnwrap(MRZCheckDigit.compute(for: composite))
    XCTAssertNil(PassportMRZOCRParser.parse(candidates: [[line1], [String(chars)]]))
  }

  func testMalformedNameLineRemainsObservationOnly() throws {
    let malformedLine1 = "X<UTOSPECIMEN<<SYNTHETIC<<<<<<<<<<<<<<<<<<<<"
    let scan = try XCTUnwrap(PassportMRZOCRParser.parse(candidates: [[malformedLine1], [line2]]))
    XCTAssertEqual(scan.completeness, .partial)
  }

  func testEmptyCandidatesReturnsNil() {
    XCTAssertNil(PassportMRZOCRParser.parse(candidates: []))
  }

  func testTooShortCandidateIsIgnored() {
    XCTAssertNil(PassportMRZOCRParser.parse(candidates: [["TOO<SHORT"]]))
  }

  func testNonMRZCharactersAreStrippedBeforeParsing() throws {
    // A realistic OCR read carries stray whitespace/punctuation the normalizer
    // must strip before the fixed-offset slicing below it is meaningful.
    let noisyLine2 = line2.map { String($0) }.joined(separator: " ")
    let scan = try XCTUnwrap(PassportMRZOCRParser.parse(candidates: [[line1], [noisyLine2]]))
    XCTAssertEqual(scan.documentNumber, "X1234567")
  }
}
