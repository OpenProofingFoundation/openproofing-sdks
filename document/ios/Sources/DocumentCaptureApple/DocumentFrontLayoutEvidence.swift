import Foundation

/// Provisional English title and portrait observations on a prepared card image.
/// This is neither a validated document classifier nor an authenticity result.
/// Full-document geometry, readability, and derivative integrity are separate gates.
public struct DocumentFrontLayoutEvidence: Codable, Equatable, Sendable {
  public let detectedFaceCount: Int?
  public let driverTitleTokenObserved: Bool
  public let licenseTitleTokenObserved: Bool

  public var provisionalFrontLayoutCandidate: Bool {
    detectedFaceCount == 1 && driverTitleTokenObserved && licenseTitleTokenObserved
  }

  /// The caller must supply observations from its verified, card-scoped derivative,
  /// not full-frame OCR that could include unrelated faces or text in the background.
  /// Unknown and unsupported titles deliberately remain non-candidates.
  public static func evaluate(
    recognizedText: [String], detectedFaceCount: Int?
  ) -> Self {
    let words = Set(
      recognizedText.flatMap { line in
        line.uppercased().components(separatedBy: CharacterSet.letters.inverted)
      })
    return Self(
      detectedFaceCount: detectedFaceCount,
      driverTitleTokenObserved: words.contains("DRIVER") || words.contains("DRIVERS"),
      licenseTitleTokenObserved: words.contains("LICENSE") || words.contains("LICENCE"))
  }

  private enum CodingKeys: String, CodingKey {
    case detectedFaceCount
    case driverTitleTokenObserved = "hasDriverTitleToken"
    case licenseTitleTokenObserved = "hasLicenseTitleToken"
  }
}
