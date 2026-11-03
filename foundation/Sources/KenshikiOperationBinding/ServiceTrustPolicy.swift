import CryptoKit
import Foundation
import Security

public enum ServiceTrustError: Error, Equatable, Sendable {
  case invalidConfiguration
  case untrustedDestination
  case invalidResponse
  case responseTooLarge
}

/// The host supplies service identities and independently provisioned current/rotation pins.
/// Pins identify the leaf service key, not a shared public issuer. Pins never replace chain validation.
public struct ServiceTrustPolicy: Sendable {
  private let pinsByHost: [String: Set<Data>]

  public init(base64PinsByHost: [String: [String]]) throws {
    guard !base64PinsByHost.isEmpty else { throw ServiceTrustError.invalidConfiguration }
    var normalized: [String: Set<Data>] = [:]
    for (host, encoded) in base64PinsByHost {
      let name = host.lowercased()
      guard Self.validHost(name), normalized[name] == nil else {
        throw ServiceTrustError.invalidConfiguration
      }
      var pins = Set<Data>()
      for value in encoded {
        guard let pin = Data(base64Encoded: value), pin.count == 32,
          pin.base64EncodedString() == value
        else { throw ServiceTrustError.invalidConfiguration }
        pins.insert(pin)
      }
      guard pins.count >= 2 else { throw ServiceTrustError.invalidConfiguration }
      normalized[name] = pins
    }
    pinsByHost = normalized
  }

  public func validateDestination(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https", let host = url.host,
      pinsByHost[host.lowercased()] != nil, url.port == nil || url.port == 443,
      url.user == nil, url.password == nil, url.fragment == nil
    else { throw ServiceTrustError.untrustedDestination }
  }

  public func validateRequest(_ request: URLRequest) throws {
    guard let url = request.url else { throw ServiceTrustError.untrustedDestination }
    try validateDestination(url)
    let names = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
    guard !names.contains("host"), !names.contains(":authority") else {
      throw ServiceTrustError.untrustedDestination
    }
  }

  public func accepts(host: String, chainIsValid: Bool, chainSPKIHashes: [Data]) -> Bool {
    guard chainIsValid, let pins = pinsByHost[host.lowercased()], let leaf = chainSPKIHashes.first else { return false }
    return pins.contains(leaf)
  }

  /// Hash the issuer's exact DER SubjectPublicKeyInfo; never reconstruct a key-type header.
  public static func spkiSHA256(of certificate: SecCertificate) -> Data? {
    guard let bytes = subjectPublicKeyInfo(SecCertificateCopyData(certificate) as Data) else { return nil }
    return Data(SHA256.hash(data: bytes))
  }

  static func subjectPublicKeyInfo(_ der: Data) -> Data? {
    guard let certificate = TrustDERElement.parse(der, at: 0, limit: der.count), certificate.tag == 0x30,
      certificate.end == der.count,
      let tbs = TrustDERElement.parse(der, at: certificate.content, limit: certificate.end), tbs.tag == 0x30
    else { return nil }
    var cursor = tbs.content
    guard let first = TrustDERElement.parse(der, at: cursor, limit: tbs.end) else { return nil }
    if first.tag == 0xA0 { cursor = first.end }
    for _ in 0..<5 {
      guard let field = TrustDERElement.parse(der, at: cursor, limit: tbs.end) else { return nil }
      cursor = field.end
    }
    guard let spki = TrustDERElement.parse(der, at: cursor, limit: tbs.end), spki.tag == 0x30 else { return nil }
    return der.subdata(in: cursor..<spki.end)
  }

  private static func validHost(_ host: String) -> Bool {
    guard host.count <= 253, host.contains("."), !host.hasSuffix(".") else { return false }
    return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
        && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
  }
}

private struct TrustDERElement {
  let tag: UInt8
  let content: Int
  let end: Int

  static func parse(_ data: Data, at offset: Int, limit: Int) -> Self? {
    guard offset >= 0, limit <= data.count, offset + 2 <= limit else { return nil }
    var cursor = offset + 1
    var length = Int(data[cursor])
    cursor += 1
    if length & 0x80 != 0 {
      let count = length & 0x7f
      guard (1...4).contains(count), cursor + count <= limit, data[cursor] != 0 else { return nil }
      length = 0
      for _ in 0..<count { length = (length << 8) | Int(data[cursor]); cursor += 1 }
      guard length >= 128 else { return nil }
    }
    guard length <= limit - cursor else { return nil }
    return Self(tag: data[offset], content: cursor, end: cursor + length)
  }
}
