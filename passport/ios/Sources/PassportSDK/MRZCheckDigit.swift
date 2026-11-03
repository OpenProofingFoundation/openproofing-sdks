import Foundation

/// The ICAO 9303 machine-readable-zone check digit: an alternating 7/3/1-weighted
/// mod-10 sum over a field's characters (digits as themselves, `A`-`Z` as 10-35,
/// filler `<` as 0). Public algorithm (ICAO Doc 9303 Part 3 §4.9) — implemented
/// directly from the spec rather than vendored from any single library, and cross-
/// checked against `cheminfo/mrz` (MIT, github.com/cheminfo/mrz) as an independent
/// test oracle: identical synthetic TD1 vectors were fed to both, including a
/// deliberately corrupted check digit, before this file was trusted.
enum MRZCheckDigit {
  /// Computes the expected check digit for `value` (which must already be in MRZ
  /// form: uppercase `A`-`Z`, `0`-`9`, and `<` fillers). Returns nil if `value`
  /// contains any other character.
  static func compute(for value: String) -> Character? {
    var sum = 0
    for (index, character) in value.enumerated() {
      guard let digit = numericValue(character) else { return nil }
      sum += digit * weights[index % weights.count]
    }
    return Character(String(sum % 10))
  }

  /// True when `checkDigit` matches the digit `compute(for:)` derives from `value`.
  static func isValid(_ value: String, checkDigit: Character) -> Bool {
    compute(for: value) == checkDigit
  }

  private static let weights = [7, 3, 1]

  private static func numericValue(_ character: Character) -> Int? {
    if character == "<" { return 0 }
    if let digit = character.wholeNumberValue, character.isASCII, character.isNumber {
      return digit
    }
    if character.isASCII, character.isUppercase, character.isLetter,
      let ascii = character.asciiValue
    {
      return Int(ascii) - Int(UInt8(ascii: "A")) + 10
    }
    return nil
  }
}
