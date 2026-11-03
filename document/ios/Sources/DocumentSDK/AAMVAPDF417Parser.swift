import Foundation

/// Decoded barcode structure only; neither issuer validation nor identity verification.
public struct AAMVAPDF417Result: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case readable, malformed, unsupported }
  /// Why the structure could not be read, checked in this order. Nil when it was read; a missing
  /// required element is reported in `missingRequiredElements`, not here.
  public enum Refusal: String, Codable, Sendable, Error {
    case tooLarge, nonASCII, header, issuerIIN, version, unsupportedVersion, jurisdictionVersion
    case entries, descriptors, descriptor, documentType, element, conflict
    /// The last subfile has no closing CR: the read may have ended inside a value.
    case unterminated
  }
  public let rawPayload: String
  public let status: Status
  public let version: Int?
  public let issuerIIN: String?
  public let jurisdictionVersion: Int?
  /// Exact identity-subfile values, including whitespace; no date or issuer interpretation.
  public let fields: [String: String]
  public let missingRequiredElements: [String]
  /// Nil on results persisted before refusals were recorded.
  public let refusal: Refusal?
  /// The identity subfile's type, `DL` or `ID`, when the structure was read.
  public let subfileType: String?

  init(
    rawPayload: String, status: Status, version: Int? = nil,
    issuerIIN: String? = nil, jurisdictionVersion: Int? = nil,
    fields: [String: String] = [:], missingRequiredElements: [String] = [],
    refusal: Refusal? = nil, subfileType: String? = nil
  ) {
    self.rawPayload = rawPayload
    self.status = status
    self.version = version
    self.issuerIIN = issuerIIN
    self.jurisdictionVersion = jurisdictionVersion
    self.fields = fields
    self.missingRequiredElements = missingRequiredElements
    self.refusal = refusal
    self.subfileType = subfileType
  }
}

/// Structural reader adapted from Pulse iOS AAMVABarcodeEnvelope. Supports the historical
/// v01 header, DL/ID subfiles and v02...11 headers. Values remain unsigned observations.
/// CR/subfile boundaries constrain identity data even when a printed descriptor length drifts.
/// The only offset correction is the published South Carolina v01 one-subfile shape.
/// Refusals are checked in the order of pulse.aamva-normalization.v1's structure rule.
public enum AAMVAPDF417Parser {
  /// Names this reader in evidence it produced (`parser_version`); change it when parsing changes.
  public static let implementationVersion = "aamva-pdf417-parser-v1"

  private static let requiredElements: Set<String> = [
    "DBA", "DBD", "DBB", "DAG", "DAI", "DAJ", "DAK", "DAQ",
  ]

  public static func parse(_ payload: String) -> AAMVAPDF417Result {
    let reader = Reader(bytes: Array(payload.utf8))
    let bytes = reader.bytes
    func refused(_ refusal: AAMVAPDF417Result.Refusal, _ status: AAMVAPDF417Result.Status = .malformed,
                 version: Int? = nil, issuer: String? = nil, jurisdiction: Int? = nil) -> AAMVAPDF417Result {
      .init(rawPayload: payload, status: status, version: version, issuerIIN: issuer,
        jurisdictionVersion: jurisdiction, refusal: refusal)
    }
    guard bytes.count <= 16_384 else { return refused(.tooLarge) }
    guard bytes.allSatisfy({ $0 < 0x80 }) else { return refused(.nonASCII) }
    guard bytes.count >= 19, bytes.starts(with: [0x40, 0x0A]), bytes[2] == 0x1E || bytes[2] == 0x1C,
      bytes[3..<9].elementsEqual([0x0D, 0x41, 0x4E, 0x53, 0x49, 0x20])
    else { return refused(.header) }
    guard let issuer = reader.ascii(9, 6), reader.decimal(9, 6) != nil else { return refused(.issuerIIN) }
    guard let version = reader.decimal(15, 2) else { return refused(.version) }
    guard version >= 1 else { return refused(.version, .unsupported, version: version, issuer: issuer) }
    guard version <= 11 else { return refused(.unsupportedVersion, .unsupported, version: version, issuer: issuer) }
    let legacySC = issuer == "636005" && version == 1
    let countOffset = version == 1 ? 17 : 19
    guard bytes[2] == 0x1E || legacySC else { return refused(.header, version: version) }
    guard let jurisdiction = version == 1 ? 0 : reader.decimal(17, 2) else {
      return refused(.jurisdictionVersion, version: version)
    }
    guard let count = reader.decimal(countOffset, 2), (1...99).contains(count) else {
      return refused(.entries, version: version)
    }
    let descriptors: [Descriptor]
    switch reader.descriptors(count: count, start: countOffset + 2, legacySC: legacySC) {
    case .failure(let refusal): return refused(refusal, version: version)
    case .success(let read): descriptors = read
    }
    let identities = descriptors.filter { $0.type == "DL" || $0.type == "ID" }
    guard identities.count == 1, let identity = identities.first else {
      return refused(.documentType, identities.isEmpty ? .unsupported : .malformed,
        version: version, issuer: issuer, jurisdiction: jurisdiction)
    }
    var allFields: [String: String] = [:]
    var identityFields: [String: String] = [:]
    for (index, descriptor) in descriptors.enumerated() {
      let start = descriptor.offset + 2
      let limit = index + 1 < descriptors.count ? descriptors[index + 1].offset : bytes.count
      guard start < limit else { return refused(.descriptors, version: version) }
      // Historical intermediate subfiles may end at the next declared subfile.
      // End of input is not a segment boundary: it could cut through a value.
      let terminator = bytes[start..<limit].firstIndex(of: 0x0D)
      guard index + 1 < descriptors.count || terminator != nil else {
        return refused(.unterminated, version: version)
      }
      let end = terminator ?? limit
      guard let body = reader.ascii(start, end - start) else { return refused(.element, version: version) }
      let fields: [String: String]
      switch elements(body) {
      case .failure(let refusal): return refused(refusal, version: version)
      case .success(let read): fields = read
      }
      guard merge(fields, into: &allFields) else { return refused(.conflict, version: version) }
      if descriptor.type == "DL" || descriptor.type == "ID" { identityFields = fields }
    }
    var missing = requiredElements.filter { !hasValue(identityFields[$0]) }
    // Historical name element identifiers differ. This checks presence only; the relying
    // party must resolve conflicting names, placeholders, country, dates and identifiers.
    let fullName = identityFields["DAA"]?.split(separator: ",", omittingEmptySubsequences: false)
    let fullNamePresent =
      fullName.map {
        (2...4).contains($0.count) && hasValue(String($0[0])) && hasValue(String($0[1]))
      } ?? false
    if !fullNamePresent && !hasValue(identityFields["DCS"]) && !hasValue(identityFields["DAB"]) {
      missing.insert("DCS/DAB/DAA")
    }
    if !fullNamePresent && !hasValue(identityFields["DAC"]) && !hasValue(identityFields["DCT"]) {
      missing.insert("DAC/DCT/DAA")
    }
    return .init(
      rawPayload: payload, status: missing.isEmpty ? .readable : .malformed,
      version: version, issuerIIN: issuer, jurisdictionVersion: jurisdiction,
      fields: identityFields, missingRequiredElements: missing.sorted(), subfileType: identity.type)
  }

  private static func hasValue(_ raw: String?) -> Bool {
    raw.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
  }

  private static func merge(_ fields: [String: String], into target: inout [String: String]) -> Bool
  {
    for (code, value) in fields {
      if let previous = target[code],
        previous.trimmingCharacters(in: .whitespaces) != value.trimmingCharacters(in: .whitespaces)
      {
        return false
      }
      if target[code] == nil { target[code] = value }
    }
    return true
  }

  private static func elements(_ body: String) -> Result<[String: String], AAMVAPDF417Result.Refusal> {
    var fields: [String: String] = [:]
    for field in body.split(separator: "\n", omittingEmptySubsequences: true) {
      // Short lines and non-letter codes are skipped, as pulse-ios and the Worker do;
      // a value outside printable ASCII still makes the barcode malformed.
      guard field.count >= 3 else { continue }
      let code = String(field.prefix(3))
      let value = String(field.dropFirst(3))
      guard code.utf8.allSatisfy({ (0x41...0x5A).contains($0) }) else { continue }
      guard value.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else { return .failure(.element) }
      guard merge([code: value], into: &fields) else { return .failure(.conflict) }
    }
    return .success(fields)
  }

  private struct Descriptor {
    let type: String
    let offset: Int
  }

  private struct Reader {
    let bytes: [UInt8]

    func ascii(_ offset: Int, _ length: Int) -> String? {
      guard offset >= 0, length >= 0, offset <= bytes.count - length else { return nil }
      return String(bytes: bytes[offset..<(offset + length)], encoding: .ascii)
    }

    func decimal(_ offset: Int, _ length: Int) -> Int? {
      guard let value = ascii(offset, length), value.allSatisfy(\.isNumber) else { return nil }
      return Int(value)
    }

    func descriptors(count: Int, start: Int, legacySC: Bool) -> Result<[Descriptor], AAMVAPDF417Result.Refusal> {
      let end = start + count * 10
      guard end <= bytes.count else { return .failure(.descriptors) }
      var result: [Descriptor] = []
      var seenTypes: Set<String> = []
      var seenOffsets: Set<Int> = []
      for index in 0..<count {
        let position = start + index * 10
        guard let type = ascii(position, 2), type.utf8.allSatisfy({ (0x41...0x5A).contains($0) }),
          seenTypes.insert(type).inserted, let declaredOffset = decimal(position + 2, 4),
          decimal(position + 6, 4) != nil
        else { return .failure(.descriptor) }
        var offset = declaredOffset
        // SC DMV's published v01 barcode declares DL at 30, but starts it at 29.
        // Never search arbitrary surrounding bytes for a plausible identity subfile.
        if legacySC, count == 1, type == "DL", declaredOffset == 30,
          ascii(29, 2) == "DL", let firstCode = ascii(31, 3),
          firstCode.utf8.allSatisfy({ (0x41...0x5A).contains($0) })
        {
          offset = 29
        }
        guard offset >= end, ascii(offset, 2) == type, seenOffsets.insert(offset).inserted else {
          return .failure(.descriptor)
        }
        result.append(.init(type: type, offset: offset))
      }
      return .success(result.sorted { $0.offset < $1.offset })
    }
  }
}
