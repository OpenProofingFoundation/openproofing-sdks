import Foundation

/// An AAMVA date element as a calendar date. Older US and Canadian encodings put the year first, so
/// eight digits are read as MMDDYYYY and as YYYYMMDD, and accepted only when exactly one real date
/// results; an ambiguous date is never guessed.
///
/// Ported from Pulse iOS AAMVABarcodeParser.isoDate (removed from the app in 68f4fc7c). Days are
/// validated arithmetically in the proleptic Gregorian calendar instead of through `Calendar`,
/// whose Gregorian calendar can switch to Julian rules before 1582.
public enum AAMVADate {
  /// `YYYY-MM-DD`, or nil when the value is not eight digits naming exactly one real date.
  public static func iso(_ raw: String) -> String? {
    guard raw.utf8.count == 8, raw.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
    let digits = Array(raw.utf8).map { Int($0) - 0x30 }
    func number(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }
    let candidates = Set([
      date(year: number(4..<8), month: number(0..<2), day: number(2..<4)),
      date(year: number(0..<4), month: number(4..<6), day: number(6..<8)),
    ].compactMap { $0 })
    return candidates.count == 1 ? candidates.first : nil
  }

  private static func date(year: Int, month: Int, day: Int) -> String? {
    guard year >= 1, (1...12).contains(month) else { return nil }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    guard (1...days).contains(day) else { return nil }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }
}
