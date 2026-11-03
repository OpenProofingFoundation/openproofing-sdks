import CryptoKit
import Foundation

public enum StoreAccessPolicy: String, Codable, Sendable {
  case identityWhenUnlocked
  case backgroundAfterFirstUnlock
}

public enum ProtectedStoreKeyError: Error, Equatable {
  case invalidIdentity, invalidEnvelope, invalidKeySize, missingKey, hardwareUnavailable
  case keyAlreadyExists, keychainFailure(Int32)
}

/// Names are supplied by the adopting app; cryptographic construction and protection are fixed here.
public struct StoreKeyIdentity: Codable, Equatable, Sendable {
  public let applicationID: String
  public let storeID: String
  public let purpose: String
  public let keychainAccessGroup: String
  public let accessPolicy: StoreAccessPolicy

  public init(applicationID: String, storeID: String, purpose: String, keychainAccessGroup: String,
    accessPolicy: StoreAccessPolicy) throws
  {
    guard [applicationID, storeID, purpose, keychainAccessGroup].allSatisfy({
      !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    }) else { throw ProtectedStoreKeyError.invalidIdentity }
    self.applicationID = applicationID
    self.storeID = storeID
    self.purpose = purpose
    self.keychainAccessGroup = keychainAccessGroup
    self.accessPolicy = accessPolicy
  }

  private enum CodingKeys: String, CodingKey {
    case applicationID, storeID, purpose, keychainAccessGroup, accessPolicy
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(applicationID: values.decode(String.self, forKey: .applicationID),
      storeID: values.decode(String.self, forKey: .storeID),
      purpose: values.decode(String.self, forKey: .purpose),
      keychainAccessGroup: values.decode(String.self, forKey: .keychainAccessGroup),
      accessPolicy: values.decode(StoreAccessPolicy.self, forKey: .accessPolicy))
  }

  // Length prefixes prevent separator ambiguity. Changing any namespace or policy changes the key.
  var binding: Data {
    Self.frame([Data("kenshiki/store-key/v1".utf8), Data(applicationID.utf8), Data(storeID.utf8),
      Data(purpose.utf8), Data(keychainAccessGroup.utf8), Data(accessPolicy.rawValue.utf8)])
  }
  var account: String { SHA256.hash(data: binding).map { String(format: "%02x", $0) }.joined() }

  static func frame(_ fields: [Data]) -> Data {
    var output = Data()
    for field in fields {
      var count = UInt64(field.count).bigEndian
      withUnsafeBytes(of: &count) { output.append(contentsOf: $0) }
      output.append(field)
    }
    return output
  }
}
