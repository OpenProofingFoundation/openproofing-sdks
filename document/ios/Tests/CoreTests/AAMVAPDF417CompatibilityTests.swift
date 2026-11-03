import Foundation
import Testing

@testable import DocumentSDK

@Test func aamvaHistoricalHeadersAndNamesRetainUnsignedSource() throws {
  for version in 1...11 {
    let names: [String: String]
    switch version {
    case 1: names = ["DAA": "EXAMPLE,ALICE,,JR", "DAD": ""]
    case 2...3: names = ["DCS": "EXAMPLE", "DCT": "ALICE,MARY"]
    default: names = ["DCS": "EXAMPLE", "DAC": "ALICE", "DAD": "NONE"]
    }
    let payload = barcode(version: version, fields: names)
    let parsed = AAMVAPDF417Parser.parse(payload)
    #expect(parsed.status == .readable)
    #expect(parsed.version == version)
    #expect(parsed.issuerIIN == "636045")
    #expect(parsed.jurisdictionVersion == (version == 1 ? 0 : 2))
    #expect(parsed.rawPayload == payload)
    for (key, value) in names { #expect(parsed.fields[key] == value) }
    #expect(
      try JSONDecoder().decode(AAMVAPDF417Result.self, from: JSONEncoder().encode(parsed)) == parsed
    )
  }
}

@Test func aamvaLegacySouthCarolinaCorrectionIsExact() {
  let source = barcode(
    version: 1, issuer: "636005", fields: ["DAB": "EXAMPLE", "DAC": "ALICE"],
    separator: "\u{1c}", declaredOffset: 30)
  #expect(AAMVAPDF417Parser.parse(source).status == .readable)
  #expect(
    AAMVAPDF417Parser.parse(source.replacingOccurrences(of: "636005", with: "636045")).status
      == .malformed)
  #expect(
    AAMVAPDF417Parser.parse(source.replacingOccurrences(of: "DL0030", with: "DL0031")).status
      == .malformed)
  #expect(
    AAMVAPDF417Parser.parse(barcode(version: 9, issuer: "636005", separator: "\u{1c}")).status
      == .malformed)
  // The exception is not a general scan for the next plausible DL marker.
  #expect(
    AAMVAPDF417Parser.parse(source.replacingOccurrences(of: "DLDAB", with: "  DLDAB")).status
      == .malformed)
}

@Test func aamvaIdentitySubfileAndCRBoundariesOverrideDriftingLengths() {
  let stateID = barcode(type: "ID", extraSubfile: ("ZA", ["ZAA": "LOCAL"]))
  #expect(AAMVAPDF417Parser.parse(stateID).status == .readable)
  #expect(AAMVAPDF417Parser.parse(stateID).fields["ZAA"] == nil)
  let drifting = barcode(declaredLength: 9999, extraSubfile: ("ZA", ["ZAA": "LOCAL"]))
  #expect(AAMVAPDF417Parser.parse(drifting).status == .readable)
  let missingNumber = barcode(
    omit: "DAQ", extraSubfile: ("ZA", ["DAQ": "SHOULD-NOT-BECOME-IDENTITY"]))
  #expect(AAMVAPDF417Parser.parse(missingNumber).missingRequiredElements == ["DAQ"])
  let contradiction = barcode(extraSubfile: ("ZA", ["DAQ": "OTHER-PERSON"]))
  #expect(AAMVAPDF417Parser.parse(contradiction).status == .malformed)
  let twoIdentities = barcode(extraSubfile: ("ID", ["DAQ": "EXAMPLE123"]))
  #expect(AAMVAPDF417Parser.parse(twoIdentities).status == .malformed)
  // A subfile that ends at the next one without a CR is accepted, as pulse-ios's
  // AAMVABarcodeEnvelope and the Worker's personaBarcode.ts accept it.
  #expect(
    AAMVAPDF417Parser.parse(stateID.replacingOccurrences(of: "\rZA", with: "\nZA")).status
      == .readable)
}

@Test func aamvaBoundsAndEmptyOptionalFieldsRemainExplicit() {
  #expect(
    AAMVAPDF417Parser.parse(barcode(fields: ["DCS": "EXAMPLE", "DAC": "ALICE", "DAD": ""])).status
      == .readable)
  #expect(
    AAMVAPDF417Parser.parse(barcode(fields: ["DCS": "EXAMPLE", "DAC": "ALICE", "DAQ": " "]))
      .missingRequiredElements == ["DAQ"])
  #expect(
    AAMVAPDF417Parser.parse(barcode(fields: ["DCS": "EXAMPLE", "DAC": "ALICE", "DAQ": "\tBAD"]))
      .status == .malformed)
  #expect(
    AAMVAPDF417Parser.parse(
      barcode(fields: [
        "DCS": "EXAMPLE", "DAC": "ALICE", "DAQ": String(repeating: "A", count: 16_384),
      ])
    ).status == .malformed)
  // Readable describes syntax only. The server remains responsible for usable identity values.
  #expect(
    AAMVAPDF417Parser.parse(barcode(fields: ["DCS": "EXAMPLE", "DAC": "ALICE", "DBB": "NONE"]))
      .status == .readable)
}

@Test func aamvaOldPersistedResultsDecodeWithoutNewProvenanceFields() throws {
  let legacy = Data(
    #"{"rawPayload":"unsigned","status":"readable","version":9,"fields":{"DAQ":"EXAMPLE"},"missingRequiredElements":[]}"#
      .utf8)
  let result = try JSONDecoder().decode(AAMVAPDF417Result.self, from: legacy)
  #expect(result.issuerIIN == nil)
  #expect(result.jurisdictionVersion == nil)
}

@Test func aamvaRejectsEveryTruncatedPrefixIncludingPartialLastField() {
  // Sorted fields put the surname last: even a single remaining letter used to
  // satisfy required-field checks when the rest of the segment was missing.
  let complete = barcode()
  #expect(AAMVAPDF417Parser.parse(complete).status == .readable)
  for length in 0..<complete.utf8.count {
    let prefix = String(decoding: complete.utf8.prefix(length), as: UTF8.self)
    #expect(AAMVAPDF417Parser.parse(prefix).status != .readable)
  }
}

@Test func aamvaRejectsTruncatedJurisdictionSegmentAfterCompleteIdentity() {
  let complete = barcode(extraSubfile: ("ZA", ["ZAA": "LOCAL-SEGMENT"]))
  #expect(AAMVAPDF417Parser.parse(complete).status == .readable)
  for removed in 1...15 {
    let prefix = String(complete.dropLast(removed))
    #expect(AAMVAPDF417Parser.parse(prefix).status != .readable)
    #expect(AAMVAPDF417Parser.parse(prefix).rawPayload == prefix)
  }
}

private func barcode(
  version: Int = 9, issuer: String = "636045", type: String = "DL",
  fields: [String: String] = ["DCS": "EXAMPLE", "DAC": "ALICE"],
  separator: String = "\u{1e}", declaredOffset: Int? = nil, declaredLength: Int? = nil,
  omit: String? = nil, extraSubfile: (String, [String: String])? = nil
) -> String {
  var identity = [
    "DBA": "09242030", "DBD": "09242020", "DBB": "01011980", "DAG": "1 SAMPLE ST",
    "DAI": "EXAMPLE CITY", "DAJ": "WA", "DAK": "98000", "DAQ": "EXAMPLE123",
  ]
  identity.merge(fields) { _, supplied in supplied }
  if let omit { identity.removeValue(forKey: omit) }
  func body(_ type: String, _ fields: [String: String]) -> String {
    type + fields.sorted { $0.key < $1.key }.map { $0.key + $0.value + "\n" }.joined() + "\r"
  }
  let first = body(type, identity)
  let second = extraSubfile.map { body($0.0, $0.1) } ?? ""
  let count = extraSubfile == nil ? 1 : 2
  let header =
    "@\n" + separator + "\rANSI " + issuer + String(format: "%02d", version)
    + (version == 1 ? "" : "02") + String(format: "%02d", count)
  let offset = header.utf8.count + count * 10
  let descriptor =
    type + String(format: "%04d%04d", declaredOffset ?? offset, declaredLength ?? first.utf8.count)
  let next =
    extraSubfile.map {
      $0.0 + String(format: "%04d%04d", offset + first.utf8.count, second.utf8.count)
    } ?? ""
  return header + descriptor + next + first + second
}
