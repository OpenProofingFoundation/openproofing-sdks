import Foundation
import Testing

@testable import DocumentSDK

@Test func aamvaRetainsFieldsWithoutPretendingToValidateIdentity() throws {
  for version in 8...11 {
    let raw = aamvaFixture(version: version)
    let value = AAMVAPDF417Parser.parse(raw)
    #expect(value.status == .readable)
    #expect(value.version == version)
    #expect(value.rawPayload == raw)
    #expect(value.fields["DAQ"] == " SAMPLE ")
    #expect(value.missingRequiredElements.isEmpty)
    #expect(
      try JSONDecoder().decode(AAMVAPDF417Result.self, from: JSONEncoder().encode(value)) == value)
  }
}

@Test func aamvaRejectsMalformedAndUnsupportedWithoutGuessing() {
  #expect(AAMVAPDF417Parser.parse(aamvaFixture(version: 0)).status == .unsupported)
  #expect(AAMVAPDF417Parser.parse(aamvaFixture(version: 12)).status == .unsupported)
  #expect(AAMVAPDF417Parser.parse(String(aamvaFixture().dropLast())).status == .malformed)
  #expect(AAMVAPDF417Parser.parse(aamvaFixture(extra: "DAQDUPLICATE\n")).status == .malformed)
  let missing = AAMVAPDF417Parser.parse(aamvaFixture(omit: "DAQ"))
  #expect(missing.status == .malformed)
  #expect(missing.missingRequiredElements == ["DAQ"])
  #expect(
    AAMVAPDF417Parser.parse(aamvaFixture().replacingOccurrences(of: "DL0031", with: "DL0032"))
      .status == .malformed)
  #expect(AAMVAPDF417Parser.parse("not a license").status == .malformed)
}

private func aamvaFixture(version: Int = 9, extra: String = "", omit: String? = nil) -> String {
  let codes = [
    "DCA", "DCB", "DCD", "DBA", "DCS", "DAC", "DAD", "DBD", "DBB", "DBC", "DAY",
    "DAU", "DAG", "DAI", "DAJ", "DAK", "DAQ", "DCF", "DCG", "DDE", "DDF", "DDG"
  ]
  let body = "DL" + codes.filter { $0 != omit }.map { $0 + " SAMPLE \n" }.joined() + extra + "\r"
  return "@\n\u{1e}\rANSI 636000" + String(format: "%02d0001DL0031%04d", version, body.utf8.count)
    + body
}
