import Foundation

/// ICAO Doc 9303 TD3 BAC input: document number and the two dates, each with its check digit.
/// This constructs access material, not document authenticity or a date-century inference.
/// Check-digit contract: ICAO Doc 9303 Part 3, section 4.9 and Appendix A.
/// https://www.icao.int/sites/default/files/publications/DocSeries/9303_p3_cons_en.pdf
public struct PassportAccessKey: Sendable, Equatable {
  public let value: String

  public init(documentNumber: String, birthDateYYMMDD: String, expiryDateYYMMDD: String) throws {
    let number = Array(documentNumber.utf8)
    guard (1...9).contains(number.count), number.allSatisfy(Self.isMRZByte),
      number.contains(where: { $0 != 60 }),
      Self.dateDigits(birthDateYYMMDD), Self.dateDigits(expiryDateYYMMDD)
    else { throw PassportReadFailure.invalidAccessKey }
    let padded = documentNumber + String(repeating: "<", count: 9 - number.count)
    value =
      padded + Self.checkDigit(padded)
      + birthDateYYMMDD + Self.checkDigit(birthDateYYMMDD)
      + expiryDateYYMMDD + Self.checkDigit(expiryDateYYMMDD)
  }

  private static func dateDigits(_ text: String) -> Bool {
    text.utf8.count == 6 && text.utf8.allSatisfy { (48...57).contains($0) }
  }

  private static func isMRZByte(_ byte: UInt8) -> Bool {
    byte == 60 || (48...57).contains(byte) || (65...90).contains(byte)
  }

  private static func checkDigit(_ text: String) -> String {
    let weights = [7, 3, 1]
    let sum = text.utf8.enumerated().reduce(0) { total, entry in
      let value = entry.element == 60 ? 0 : Int(entry.element) - (entry.element >= 65 ? 55 : 48)
      return total + value * weights[entry.offset % weights.count]
    }
    return String(sum % 10)
  }
}
