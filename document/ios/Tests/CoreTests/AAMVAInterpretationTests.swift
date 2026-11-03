import Foundation
import Testing

@testable import DocumentSDK

private let identity = "DCSEXAMPLE\nDACALICE\nDBB01021990\nDBD01022020\nDBA01022030\nDAG1 SAMPLE ST\n"
  + "DAISAMPLE CITY\nDAJWA\nDAK98000\nDAQEXAMPLE123\n"

/// One DL subfile at the offset its descriptor names, ending with CR.
private func barcode(_ body: String = identity, header: String = "@\n\u{1e}\rANSI 636045090201") -> String {
  let subfile = "DL" + body + "\r"
  let offset = header.utf8.count + 10
  return header + "DL" + String(format: "%04d%04d", offset, subfile.utf8.count) + subfile
}

@Test func aamvaParserNamesEveryStructuralRefusal() {
  let cases: [(String, AAMVAPDF417Result.Refusal)] = [
    (barcode(identity + "DCF" + String(repeating: "A", count: 16_384) + "\n"), .tooLarge),
    (barcode(identity + "DCFÉ\n"), .nonASCII),
    ("@\nXANSI " + barcode().dropFirst(9), .header),
    (barcode(header: "@\n\u{1e}\rANSI 63604X090201"), .issuerIIN),
    (barcode(header: "@\n\u{1e}\rANSI 636045XX0201"), .version),
    (barcode(header: "@\n\u{1e}\rANSI 636045000201"), .version),
    (barcode(header: "@\n\u{1e}\rANSI 636045120201"), .unsupportedVersion),
    (barcode(header: "@\n\u{1c}\rANSI 636045090201"), .header),
    (barcode(header: "@\n\u{1e}\rANSI 63604509XX01"), .jurisdictionVersion),
    (barcode(header: "@\n\u{1e}\rANSI 636045090200"), .entries),
    (barcode(identity + "DCF\u{7}\n"), .element),
    (barcode(identity + "DAQOTHER\n"), .conflict),
    (String(barcode().dropLast()), .unterminated),
  ]
  for (payload, refusal) in cases {
    let result = AAMVAPDF417Parser.parse(payload)
    #expect(result.refusal == refusal, "\(refusal)")
    #expect(result.status != .readable)
    #expect(result.fields.isEmpty)
  }
  let readable = AAMVAPDF417Parser.parse(barcode())
  #expect(readable.status == .readable)
  #expect(readable.refusal == nil)
  #expect(readable.subfileType == "DL")
  // A missing element is not a structural refusal: the fields stay readable to interpret.
  let missing = AAMVAPDF417Parser.parse(barcode(identity.replacingOccurrences(of: "DAQEXAMPLE123\n", with: "")))
  #expect(missing.status == .malformed)
  #expect(missing.refusal == nil)
  #expect(missing.missingRequiredElements == ["DAQ"])
}

@Test func aamvaParserRefusesDescriptorProblemsAndIdentityCounts() {
  let header = "@\n\u{1e}\rANSI 636045090201"
  #expect(AAMVAPDF417Parser.parse(header + "DL00").refusal == .descriptors)
  #expect(AAMVAPDF417Parser.parse(header + "D10031" + "0010DLDAQX\r").refusal == .descriptor)
  #expect(AAMVAPDF417Parser.parse(header + "DL00320010ZZDAQX\r").refusal == .descriptor)
  let jurisdictionOnly = AAMVAPDF417Parser.parse(header + "ZA00310008ZAZAAX\r")
  #expect(jurisdictionOnly.refusal == .documentType)
  #expect(jurisdictionOnly.status == .unsupported)
}

@Test func aamvaIdentityNamesReadEachGenerationAndNameTheirElement() {
  let modern = AAMVAIdentityNames(["DCS": " EXAMPLE ", "DAC": "ALICE", "DAD": "NONE"])
  #expect(modern.reading(.family) == .init(value: "EXAMPLE", element: "DCS"))
  #expect(modern.reading(.given) == .init(value: "ALICE", element: "DAC"))
  #expect(modern.reading(.middle) == nil)
  let combined = AAMVAIdentityNames(["DCS": "EXAMPLE", "DCT": "ALICE,MARY,JO"])
  #expect(combined.reading(.given) == .init(value: "ALICE", element: "DCT"))
  #expect(combined.reading(.middle) == .init(value: "MARY,JO", element: "DCT"))
  let historical = AAMVAIdentityNames(["DAA": "EXAMPLE,ALICE,,JR"])
  #expect(historical.reading(.family) == .init(value: "EXAMPLE", element: "DAA"))
  #expect(historical.reading(.given) == .init(value: "ALICE", element: "DAA"))
  #expect(historical.reading(.middle) == nil)
  // DAA counts only with two to four comma slots.
  #expect(AAMVAIdentityNames(["DAA": "EXAMPLE"]).readings.isEmpty)
  #expect(AAMVAIdentityNames(["DAA": "A,B,C,D,E"]).readings.isEmpty)
}

@Test func aamvaIdentityNamesReportAConflictWithoutChoosingAPerson() {
  let names = AAMVAIdentityNames(["DCS": "EXAMPLE", "DAA": "OTHER,ALICE", "DAC": "ALICE"])
  #expect(names.conflicts(.family))
  #expect(names.reading(.family) == nil)
  #expect(!names.conflicts(.given))
  #expect(names.reading(.given) == .init(value: "ALICE", element: "DAC"))
}

@Test func aamvaDateAcceptsExactlyOneRealCalendarDate() {
  #expect(AAMVADate.iso("04011980") == "1980-04-01")
  #expect(AAMVADate.iso("19800401") == "1980-04-01")
  #expect(AAMVADate.iso("01121201") == nil)  // 0112-12-01 and 1201-01-12 are both real.
  #expect(AAMVADate.iso("02311980") == nil)
  #expect(AAMVADate.iso("02292000") == "2000-02-29")
  #expect(AAMVADate.iso("02291900") == nil)
  // Proleptic Gregorian: 1500 is not a leap year even though the Julian calendar had one.
  #expect(AAMVADate.iso("02291500") == nil)
  #expect(AAMVADate.iso("0401198") == nil)
  #expect(AAMVADate.iso("0401198A") == nil)
}

@Test func aamvaIssuerRegistryNamesCountryAndCode() {
  #expect(AAMVAIssuerJurisdiction.issuer("636014") == .init(country: "US", code: "CA"))
  #expect(AAMVAIssuerJurisdiction.issuer("636012") == .init(country: "CA", code: nil))
  #expect(AAMVAIssuerJurisdiction.issuer("636056") == .init(country: "MX", code: nil))
  #expect(AAMVAIssuerJurisdiction.issuer("636027") == .init(country: "US", code: nil))
  #expect(AAMVAIssuerJurisdiction.issuer("999999") == nil)
}
