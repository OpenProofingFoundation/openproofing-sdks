import CryptoKit
import Foundation
import Security

/// Typed Keychain failures from SDK custody. Key material and lifecycle are module-owned.
public enum CaptureEvidenceKey {
  enum KeyCreation: Sendable { case permitted, forbidden }

  static func remove(service: String, account: String, accessGroup: String?) throws {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure(status: status)
    }
  }

  public struct Failure: Error { public let status: OSStatus }

  static func loadOrCreate(
    service: String, account: String = "capture-evidence-v1", accessGroup: String? = nil,
    creation: KeyCreation = .permitted
  ) throws -> SymmetricKey {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecSuccess {
      guard let data = result as? Data, data.count == 32 else {
        throw Failure(status: errSecDecode)
      }
      return SymmetricKey(data: data)
    }
    guard status == errSecItemNotFound else { throw Failure(status: status) }
    guard creation == .permitted else { throw Failure(status: errSecItemNotFound) }
    let fresh = SymmetricKey(size: .bits256)
    var insertion = query
    insertion[kSecValueData as String] = fresh.withUnsafeBytes { Data($0) }
    insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let inserted = SecItemAdd(insertion as CFDictionary, nil)
    if inserted == errSecDuplicateItem {
      return try loadOrCreate(
        service: service, account: account, accessGroup: accessGroup, creation: creation)
    }
    guard inserted == errSecSuccess else { throw Failure(status: inserted) }
    return fresh
  }
}
