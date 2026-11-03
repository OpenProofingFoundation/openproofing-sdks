import Foundation

/// The adopter supplies its public origin and the exact route derived from approved content.
/// Foundation parses the URL; a matching final token alone never authorizes another route.
public enum RecipientCapabilityURL {
  public static func validate(_ url: URL, origin: URL, path: String) throws {
    guard let base = URLComponents(url: origin, resolvingAgainstBaseURL: false),
      let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
      base.scheme?.lowercased() == "https", value.scheme?.lowercased() == "https",
      let host = base.host, !host.isEmpty, value.host?.lowercased() == host.lowercased(),
      (base.port ?? 443) == (value.port ?? 443),
      base.user == nil, base.password == nil, value.user == nil, value.password == nil,
      base.query == nil, base.fragment == nil,
      base.percentEncodedPath.isEmpty || base.percentEncodedPath == "/",
      value.query == nil, value.fragment == nil,
      path.hasPrefix("/"), !path.hasPrefix("//"), value.percentEncodedPath == path
    else { throw ServiceTrustError.invalidResponse }
  }
}
