import Foundation

/// OCR observation, not chip evidence. Numeric OCR substitutions are applied before the five
/// TD3 check digits are evaluated. Dates retain YYMMDD; names retain ICAO filler characters.
/// The native host decides when to capture and confirm a complete observation.
public struct PassportMRZObservation: Equatable, Sendable {
  public enum Completeness: String, Sendable { case complete, partial }
  public enum MissingField: String, Sendable { case name, nationality, issuingState }
  public let documentNumber: String
  public let birthDateYYMMDD: String
  public let expiryDateYYMMDD: String
  public let surname: String
  public let givenNames: String
  public let nationality: String
  public let issuingState: String
  public let sex: String
  /// Alphabet-normalized selected lines, before numeric OCR substitutions. No image is retained.
  public let normalizedLines: [String]
  public var missingFields: [MissingField] {
    var missing: [MissingField] = []
    if (surname + givenNames).replacingOccurrences(of: "<", with: "").isEmpty {
      missing.append(.name)
    }
    if nationality.isEmpty { missing.append(.nationality) }
    if issuingState.isEmpty { missing.append(.issuingState) }
    return missing
  }
  public var completeness: Completeness { missingFields.isEmpty ? .complete : .partial }

  /// Compare validated numeric OCR equivalents without erasing the selected raw lines.
  /// Alphanumeric document/optional data and the complete name row remain exact.
  package var captureComparisonLines: [String] {
    guard let last = normalizedLines.last, last.count == 44 else { return normalizedLines }
    var chars = Array(last)
    for index in [9] + Array(13..<20) + Array(21..<28) + [42, 43] {
      chars[index] = Character(MRZText.digit(chars[index]))
    }
    return Array(normalizedLines.dropLast()) + [String(chars)]
  }

}

/// Parses the two-line TD3 (passport) MRZ and validates ICAO 9303 check digits.
/// Strict by design: line 2 is accepted only when the document-number, DOB, and expiry check
/// digits all pass (after digit disambiguation), so OCR noise never silently fills the wrong key.
/// Line 1 (names / issuing state / nationality) is best-effort and only enriches the result.
public enum PassportMRZOCRParser {
  /// - Parameter candidates: OCR alternatives grouped by observation, one inner array per
  ///   recognised row. TD3 tolerates flattening because it locates line 1 and line 2 by
  ///   shape rather than by position, but the grouping is preserved so every format sees
  ///   the same contract.
  public static func parse(candidates: [[String]]) -> PassportMRZObservation? {
    // Normalize each candidate to the MRZ alphabet; also split an accidentally-merged 88-char
    // read into its two 44-char halves.
    var lines: [String] = []
    for raw in candidates.flatMap({ $0 }) {
      let normalized = MRZText.normalize(raw)
      if normalized.count >= 88 {
        lines.append(String(normalized.prefix(44)))
        lines.append(String(normalized.dropFirst(44).prefix(44)))
      }
      if normalized.count >= 28 { lines.append(normalized) }
    }

    let line1 = lines.first(where: isLikelyLine1)
    // Try each plausible line-2 candidate; the first whose check digits validate wins.
    for line in lines where line.count >= 44 {
      if let scan = parseLine2(String(line.prefix(44)), line1: line1) { return scan }
    }
    return nil
  }

  /// Complete automatic-capture read. OCR alternatives retain their supplied rank within
  /// each physical row. Lower-ranked hypotheses cannot veto that row pair's best valid read;
  /// different complete documents from distinct physical row groups remain ambiguous.
  public static func parseComplete(candidates: [[String]]) -> PassportMRZObservation? {
    guard candidates.count <= 32, candidates.allSatisfy({ $0.count <= 10 }) else { return nil }
    let rows = candidates.map { alternatives in
      alternatives.compactMap { raw -> String? in
        guard raw.utf8.count <= 256 else { return nil }
        let line = MRZText.normalize(raw)
        return line.count == 44 || line.count == 88 ? line : nil
      }
    }
    var complete: [PassportMRZObservation] = []
    for (index, alternatives) in rows.enumerated() {
      // A single Vision observation can contain both complete printed rows.
      for line in alternatives where line.count == 88 {
        let first = String(line.prefix(44)), second = String(line.suffix(44))
        if isCompleteLine1(first), let value = parseLine2(second, line1: first),
          value.completeness == .complete {
          complete.append(value)
          break
        }
      }
      for (otherIndex, secondAlternatives) in rows.enumerated() where index != otherIndex {
        if let value = highestRankedCompletePair(first: alternatives, second: secondAlternatives) {
          complete.append(value)
        }
      }
    }
    guard let value = complete.first,
      complete.allSatisfy({ $0.captureComparisonLines == value.captureComparisonLines }) else { return nil }
    return value
  }

  private static func highestRankedCompletePair(
    first: [String], second: [String]
  ) -> PassportMRZObservation? {
    for nameLine in first where nameLine.count == 44 && isCompleteLine1(nameLine) {
      for keyLine in second where keyLine.count == 44 {
        if let value = parseLine2(keyLine, line1: nameLine), value.completeness == .complete {
          return value
        }
      }
    }
    return nil
  }

  private static func isCompleteLine1(_ line: String) -> Bool {
    isLikelyLine1(line) && line.allSatisfy { $0.isLetter || $0 == "<" }
  }

  /// TD3 line 1 carries the names, separated by "<<". OCR often mangles the leading "P<USA"
  /// prefix, so the reliable signal is the "<<" name separator — don't require a clean "P".
  /// Letters must outnumber digits: a name line is alphabetic, while a line 2 is digit-heavy —
  /// without that test, a line2-only read reused line 2 as its own "name line" and the review
  /// screen asked the holder to confirm raw MRZ bytes as their name.
  private static func isLikelyLine1(_ line: String) -> Bool {
    guard line.count >= 44 else { return false }
    let chars = Array(line.prefix(44))
    guard chars[0] == "P", chars[1] == "<" || chars[1].isLetter,
      chars[2..<5].allSatisfy(\.isLetter),
      String(chars[5...]).contains("<<")
    else { return false }
    let letters = line.filter(\.isLetter).count
    let digits = line.filter(\.isNumber).count
    return letters > digits
  }

  private static func parseLine2(_ line: String, line1: String?) -> PassportMRZObservation? {
    let chars = Array(line)
    guard chars.count == 44 else { return nil }
    func slice(_ from: Int, _ upTo: Int) -> String { String(chars[from..<min(upTo, chars.count)]) }

    // Document number (9, alphanumeric) + its check digit. Pure-numeric fields get OCR
    // letter→digit disambiguation (O→0, I/L→1, S→5, B→8, …) before validation.
    let docRaw = slice(0, 9)
    let docCheck = MRZText.digit(chars[9])
    let nationality = slice(10, 13)
    let dob = MRZText.digits(slice(13, 19))
    let dobCheck = MRZText.digit(chars[19])
    let sexChar = String(chars[20])
    let expiry = MRZText.digits(slice(21, 27))
    let expiryCheck = MRZText.digit(chars[27])
    let optionalData = slice(28, 42)
    let optionalCheck = MRZText.digit(chars[42])
    let compositeCheck = MRZText.digit(chars[43])

    guard let docCheckChar = docCheck.first, let dobCheckChar = dobCheck.first,
      let expiryCheckChar = expiryCheck.first,
      let optionalCheckChar = optionalCheck.first,
      let compositeCheckChar = compositeCheck.first
    else { return nil }
    let composite =
      docRaw + docCheck + dob + dobCheck + expiry + expiryCheck + optionalData + optionalCheck
    guard MRZCheckDigit.isValid(docRaw, checkDigit: docCheckChar),
      MRZCheckDigit.isValid(dob, checkDigit: dobCheckChar),
      MRZCheckDigit.isValid(expiry, checkDigit: expiryCheckChar),
      MRZCheckDigit.isValid(optionalData, checkDigit: optionalCheckChar),
      MRZCheckDigit.isValid(composite, checkDigit: compositeCheckChar),
      isValidYYMMDD(dob), isValidYYMMDD(expiry),
      ["M", "F", "<"].contains(sexChar)
    else { return nil }

    let documentNumber = docRaw.replacingOccurrences(of: "<", with: "")
    guard !documentNumber.isEmpty else { return nil }

    let sex = sexChar == "<" ? "X" : sexChar
    let names = parseLine1(line1)
    let nat = nationality.replacingOccurrences(of: "<", with: "")
    let validNationality = nat.count == 3 && nat.allSatisfy(\.isLetter)

    return PassportMRZObservation(
      documentNumber: documentNumber,
      birthDateYYMMDD: dob,
      expiryDateYYMMDD: expiry,
      surname: names.surname,
      givenNames: names.givenNames,
      nationality: validNationality ? nat : "",
      issuingState: names.issuingState,
      sex: sex, normalizedLines: [line1, line].compactMap { $0 })
  }

  private struct Line1Fields {
    var issuingState = ""
    var surname = ""
    var givenNames = ""
  }

  /// TD3 line 1: P<ISS SURNAME<<GIVEN<NAMES<<<...
  /// Tolerant of a mangled "P<ISS" prefix: when the line starts with "P" the issuing state is
  /// positional (chars 2..5) and names start at 5; otherwise we fall back to the names after "<<".
  private static func parseLine1(_ line1: String?) -> Line1Fields {
    guard let line1, isLikelyLine1(line1) else { return Line1Fields() }
    let chars = Array(line1.prefix(44))
    var fields = Line1Fields()
    fields.issuingState = String(chars[2..<5])
    let names = String(chars[5...])
    let parts = names.components(separatedBy: "<<")
    fields.surname = (parts.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<"))
    fields.givenNames = parts.count > 1 ? parts[1] : ""
    return fields
  }

  private static func isValidYYMMDD(_ raw: String) -> Bool {
    guard raw.count == 6,
      let year = Int(raw.prefix(2)),
      let month = Int(raw.dropFirst(2).prefix(2)),
      let day = Int(raw.suffix(2))
    else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
    let components = DateComponents(year: 2000 + year, month: month, day: day)
    guard let date = calendar.date(from: components) else { return false }
    let validated = calendar.dateComponents([.year, .month, .day], from: date)
    return validated.year == 2000 + year && validated.month == month && validated.day == day
  }
}

/// MRZ text normalization shared by every format's parser: alphabet filtering and the OCR
/// letter→digit disambiguation table. Lives here (not inside a format-specific parser) because
/// TD1 and TD3 reads come off the same camera with the same misread modes.
enum MRZText {
  static let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<")

  /// Uppercase and strip everything outside the MRZ alphabet.
  static func normalize(_ raw: String) -> String {
    String(raw.uppercased().unicodeScalars.filter { alphabet.contains($0) })
  }

  private static let digitFixups: [Character: Character] =
    ["O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "B": "8", "G": "6"]

  /// Coerce a single char to its digit reading where OCR commonly confuses it.
  static func digit(_ character: Character) -> String {
    if character.isNumber { return String(character) }
    return String(digitFixups[character] ?? character)
  }

  /// Coerce a numeric field (DOB/expiry) char-by-char.
  static func digits(_ field: String) -> String { String(field.map { Character(digit($0)) }) }
}
