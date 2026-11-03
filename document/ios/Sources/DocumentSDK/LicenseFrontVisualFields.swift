import Foundation

/// Who issued a US driver licence or ID card, read from the capture's own text
/// recognition of the front. Every US licence prints its state's name across
/// the top ("WASHINGTON", "California USA DRIVER LICENSE"); this finds the line
/// that is that name plus, at most, the card's own title words.
///
/// Conservative in the same way as `PassportCardVisualFields`: a line with any
/// other word in it is not a header, so an address such as "WASHINGTON DC
/// 20001" or "VIRGINIA BEACH VA" never counts. No header, or headers naming
/// two jurisdictions, give nothing.
public struct LicenseFrontVisualFields: Codable, Equatable, Sendable {
  public let extractorVersion: String
  /// The USPS code of the issuing jurisdiction, such as "WA", or nil.
  public let issuingJurisdiction: String?
  /// The recognized line it was read from, unchanged.
  public let issuingJurisdictionLine: String?

  public init(extractorVersion: String, issuingJurisdiction: String?, issuingJurisdictionLine: String?) {
    self.extractorVersion = extractorVersion
    self.issuingJurisdiction = issuingJurisdiction
    self.issuingJurisdictionLine = issuingJurisdictionLine
  }

  public static func extract(lines: [String]) -> Self {
    var found: [(code: String, line: String)] = []
    for line in lines {
      if let code = headerJurisdiction(line), !found.contains(where: { $0.code == code }) {
        found.append((code, line))
      }
    }
    let only = found.count == 1 ? found.first : nil
    return .init(
      extractorVersion: "us-licence-front-header-v1",
      issuingJurisdiction: only?.code, issuingJurisdictionLine: only?.line)
  }

  /// The jurisdiction a line names, when every other word on it is a title word.
  static func headerJurisdiction(_ line: String) -> String? {
    let words = line.uppercased()
      .split(whereSeparator: { !$0.isLetter })
      .map(String.init)
    guard !words.isEmpty else { return nil }
    // Longest names first, so "WEST VIRGINIA" is never read as "VIRGINIA".
    for jurisdiction in jurisdictions {
      let name = jurisdiction.words
      guard name.count <= words.count else { continue }
      for start in 0...(words.count - name.count) where Array(words[start..<start + name.count]) == name {
        let rest = words[..<start] + words[(start + name.count)...]
        if rest.allSatisfy(titleWords.contains) { return jurisdiction.code }
      }
    }
    return nil
  }

  /// Words a licence prints beside the state's name in its header.
  private static let titleWords: Set<String> = [
    "USA", "US", "STATE", "OF", "THE", "COMMONWEALTH", "DRIVER", "DRIVERS", "S",
    "LICENSE", "LICENCE", "IDENTIFICATION", "ID", "CARD", "ENHANCED", "REAL",
  ]

  /// US states, the District of Columbia and the territories whose DMVs AAMVA
  /// assigns an issuer number, with their USPS codes. Written in upper case, as
  /// the header prints them and as they are matched: these are text read off the
  /// card, not words this SDK shows anyone.
  private static let names: [(String, String)] = [
    ("ALABAMA", "AL"), ("ALASKA", "AK"), ("AMERICAN SAMOA", "AS"), ("ARIZONA", "AZ"),
    ("ARKANSAS", "AR"), ("CALIFORNIA", "CA"), ("COLORADO", "CO"), ("CONNECTICUT", "CT"),
    ("DELAWARE", "DE"), ("DISTRICT OF COLUMBIA", "DC"), ("FLORIDA", "FL"), ("GEORGIA", "GA"),
    ("GUAM", "GU"), ("HAWAII", "HI"), ("IDAHO", "ID"), ("ILLINOIS", "IL"), ("INDIANA", "IN"),
    ("IOWA", "IA"), ("KANSAS", "KS"), ("KENTUCKY", "KY"), ("LOUISIANA", "LA"), ("MAINE", "ME"),
    ("MARYLAND", "MD"), ("MASSACHUSETTS", "MA"), ("MICHIGAN", "MI"), ("MINNESOTA", "MN"),
    ("MISSISSIPPI", "MS"), ("MISSOURI", "MO"), ("MONTANA", "MT"), ("NEBRASKA", "NE"),
    ("NEVADA", "NV"), ("NEW HAMPSHIRE", "NH"), ("NEW JERSEY", "NJ"), ("NEW MEXICO", "NM"),
    ("NEW YORK", "NY"), ("NORTH CAROLINA", "NC"), ("NORTH DAKOTA", "ND"),
    ("NORTHERN MARIANA ISLANDS", "MP"), ("OHIO", "OH"), ("OKLAHOMA", "OK"), ("OREGON", "OR"),
    ("PENNSYLVANIA", "PA"), ("PUERTO RICO", "PR"), ("RHODE ISLAND", "RI"),
    ("SOUTH CAROLINA", "SC"), ("SOUTH DAKOTA", "SD"), ("TENNESSEE", "TN"), ("TEXAS", "TX"),
    ("UTAH", "UT"), ("VERMONT", "VT"), ("VIRGIN ISLANDS", "VI"), ("VIRGINIA", "VA"),
    ("WASHINGTON", "WA"), ("WEST VIRGINIA", "WV"), ("WISCONSIN", "WI"), ("WYOMING", "WY"),
  ]
  private static let jurisdictions: [(words: [String], code: String)] = names
    .map { name, code in (words: name.uppercased().split(separator: " ").map(String.init), code: code) }
    .sorted { $0.words.count > $1.words.count }
}
