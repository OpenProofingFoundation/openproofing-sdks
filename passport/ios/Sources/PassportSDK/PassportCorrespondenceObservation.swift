import Foundation

/// Correspondence between the printed page the holder reviewed and the separately read chip.
/// The comparison preserves the source capture flow's normalization: document fillers are
/// removed, names collapse filler-separated spaces, and dates remain exact YYMMDD values.
/// Every field reports independently; this is neither chip authentication nor an identity verdict.
public struct PassportCorrespondenceObservation: Equatable, Sendable {
  public enum Field: String, CaseIterable, Codable, Sendable {
    case documentNumber, birthDate, expiryDate, surname, givenNames
  }

  public enum Comparison: String, Codable, Sendable {
    case matches, differs, notCompared
  }

  public let fields: [Field: Comparison]

  /// A stable field order lets hosts describe all differences without parsing SDK prose.
  public var mismatchedFields: [Field] {
    Field.allCases.filter { fields[$0] == .differs }
  }

  public init(printed: PassportMRZObservation, chip: PassportReadObservation) {
    fields = [
      .documentNumber: Self.compare(
        Self.documentNumber(printed.documentNumber), Self.documentNumber(chip.documentNumber)),
      .birthDate: Self.compare(printed.birthDateYYMMDD, chip.birthDateYYMMDD),
      .expiryDate: Self.compare(printed.expiryDateYYMMDD, chip.expiryDateYYMMDD),
      .surname: Self.compare(Self.name(printed.surname), Self.name(chip.surname)),
      // The source flow compared given names only when the printed observation supplied them.
      // Not compared is explicit; a missing printed value is never reported as agreement.
      .givenNames: printed.givenNames.isEmpty
        ? .notCompared : Self.compare(Self.name(printed.givenNames), Self.name(chip.givenNames)),
    ]
  }

  private static func compare(_ printed: String, _ chip: String) -> Comparison {
    printed == chip ? .matches : .differs
  }

  private static func documentNumber(_ value: String) -> String {
    value.replacingOccurrences(of: "<", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  private static func name(_ value: String) -> String {
    value.replacingOccurrences(of: "<", with: " ")
      .split(separator: " ").joined(separator: " ").uppercased()
  }
}
