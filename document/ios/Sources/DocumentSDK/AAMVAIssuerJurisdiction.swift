import Foundation

/// The AAMVA issuer registry by the six-digit barcode header IIN, never a DMV participation or
/// authenticity verdict. A holder's address is not an issuer signal. Unknown IINs return nil; no
/// jurisdiction is inferred.
///
/// Exact copy of the `issuers` table of pulse-compliance references/aamva/aamva-normalization-v1.yaml
/// (SHA-256 0851f993feb26c022baa1ce2e16b77a6128bbbd7541e4b948627958f20cf1d33), which supersedes Pulse iOS AAMVAIssuerCountry (removed in 68f4fc7c) and the
/// earlier projection of the Worker's aamvaIssuerIin.ts.
/// https://www.aamva.org/identity/issuer-identification-numbers-(iin)
public enum AAMVAIssuerJurisdiction {
  public struct Issuer: Equatable, Sendable {
    /// ISO 3166-1 alpha-2 country of the issuing authority.
    public let country: String
    /// The issuer's two-letter jurisdiction code; nil for an issuer without one (non-US issuers and
    /// the US State Department).
    public let code: String?

    public init(country: String, code: String?) {
      self.country = country
      self.code = code
    }
  }

  public static func issuer(_ iin: String) -> Issuer? {
    issuers[iin.trimmingCharacters(in: .whitespacesAndNewlines)]
  }

  /// The issuer's jurisdiction code, when it has one.
  public static func resolve(_ iin: String) -> String? {
    issuer(iin)?.code
  }

  /// Every jurisdiction code of the issuers in one country.
  public static func codes(country: String) -> Set<String> {
    Set(issuers.values.compactMap { $0.country == country ? $0.code : nil })
  }

  private static let issuers: [String: Issuer] = [
    "604426": .init(country: "CA", code: nil),  // Prince Edward Island
    "604427": .init(country: "US", code: "AS"),  // American Samoa
    "604428": .init(country: "CA", code: nil),  // Quebec
    "604429": .init(country: "CA", code: nil),  // Yukon
    "604430": .init(country: "US", code: "MP"),  // Northern Mariana Islands
    "604431": .init(country: "US", code: "PR"),  // Puerto Rico
    "604432": .init(country: "CA", code: nil),  // Alberta
    "604433": .init(country: "CA", code: nil),  // Nunavut
    "604434": .init(country: "CA", code: nil),  // Northwest Territories
    "636000": .init(country: "US", code: "VA"),  // Virginia
    "636001": .init(country: "US", code: "NY"),  // New York
    "636002": .init(country: "US", code: "MA"),  // Massachusetts
    "636003": .init(country: "US", code: "MD"),  // Maryland
    "636004": .init(country: "US", code: "NC"),  // North Carolina
    "636005": .init(country: "US", code: "SC"),  // South Carolina
    "636006": .init(country: "US", code: "CT"),  // Connecticut
    "636007": .init(country: "US", code: "LA"),  // Louisiana
    "636008": .init(country: "US", code: "MT"),  // Montana
    "636009": .init(country: "US", code: "NM"),  // New Mexico
    "636010": .init(country: "US", code: "FL"),  // Florida
    "636011": .init(country: "US", code: "DE"),  // Delaware
    "636012": .init(country: "CA", code: nil),  // Ontario
    "636013": .init(country: "CA", code: nil),  // Nova Scotia
    "636014": .init(country: "US", code: "CA"),  // California
    "636015": .init(country: "US", code: "TX"),  // Texas
    "636016": .init(country: "CA", code: nil),  // Newfoundland
    "636017": .init(country: "CA", code: nil),  // New Brunswick
    "636018": .init(country: "US", code: "IA"),  // Iowa
    "636019": .init(country: "US", code: "GU"),  // Guam
    "636020": .init(country: "US", code: "CO"),  // Colorado
    "636021": .init(country: "US", code: "AR"),  // Arkansas
    "636022": .init(country: "US", code: "KS"),  // Kansas
    "636023": .init(country: "US", code: "OH"),  // Ohio
    "636024": .init(country: "US", code: "VT"),  // Vermont
    "636025": .init(country: "US", code: "PA"),  // Pennsylvania
    "636026": .init(country: "US", code: "AZ"),  // Arizona
    "636027": .init(country: "US", code: nil),  // State Dept. (Diplomatic)
    "636028": .init(country: "CA", code: nil),  // British Columbia
    "636029": .init(country: "US", code: "OR"),  // Oregon
    "636030": .init(country: "US", code: "MO"),  // Missouri
    "636031": .init(country: "US", code: "WI"),  // Wisconsin
    "636032": .init(country: "US", code: "MI"),  // Michigan
    "636033": .init(country: "US", code: "AL"),  // Alabama
    "636034": .init(country: "US", code: "ND"),  // North Dakota
    "636035": .init(country: "US", code: "IL"),  // Illinois
    "636036": .init(country: "US", code: "NJ"),  // New Jersey
    "636037": .init(country: "US", code: "IN"),  // Indiana
    "636038": .init(country: "US", code: "MN"),  // Minnesota
    "636039": .init(country: "US", code: "NH"),  // New Hampshire
    "636040": .init(country: "US", code: "UT"),  // Utah
    "636041": .init(country: "US", code: "ME"),  // Maine
    "636042": .init(country: "US", code: "SD"),  // South Dakota
    "636043": .init(country: "US", code: "DC"),  // District of Columbia
    "636044": .init(country: "CA", code: nil),  // Saskatchewan
    "636045": .init(country: "US", code: "WA"),  // Washington
    "636046": .init(country: "US", code: "KY"),  // Kentucky
    "636047": .init(country: "US", code: "HI"),  // Hawaii
    "636048": .init(country: "CA", code: nil),  // Manitoba
    "636049": .init(country: "US", code: "NV"),  // Nevada
    "636050": .init(country: "US", code: "ID"),  // Idaho
    "636051": .init(country: "US", code: "MS"),  // Mississippi
    "636052": .init(country: "US", code: "RI"),  // Rhode Island
    "636053": .init(country: "US", code: "TN"),  // Tennessee
    "636054": .init(country: "US", code: "NE"),  // Nebraska
    "636055": .init(country: "US", code: "GA"),  // Georgia
    "636056": .init(country: "MX", code: nil),  // Coahuila
    "636057": .init(country: "MX", code: nil),  // Hidalgo
    "636058": .init(country: "US", code: "OK"),  // Oklahoma
    "636059": .init(country: "US", code: "AK"),  // Alaska
    "636060": .init(country: "US", code: "WY"),  // Wyoming
    "636061": .init(country: "US", code: "WV"),  // West Virginia
    "636062": .init(country: "US", code: "VI"),  // Virgin Islands
  ]
}
