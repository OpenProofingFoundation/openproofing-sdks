// Responsibility: Owns one configured local capture-custody generation and its erase lifecycle.
// Control: Revokes admission before erasure; pending erasure and missing-key ciphertext cannot create replacement custody.
// App counterpart: App capture and check-in custody owners use this runtime with their own store configuration.
// Specification: RFC-0002 §§12.2–12.4, 13.3.

import CryptoKit
import Foundation
import Security
@_spi(CustodyAdapter) import KenshikiProtectedStorage

/// The host supplies names and a durable location. The SDK owns keys, protection and IO.
public struct CaptureCustodyConfiguration: Sendable {
  public let applicationID: String
  public let directory: URL
  public let keychainService: String
  public let keychainAccount: String
  public let accessGroup: String

  public init(
    applicationID: String, directory: URL, keychainService: String, keychainAccount: String,
    accessGroup: String
  ) throws {
    guard !applicationID.isEmpty, directory.isFileURL, !keychainService.isEmpty, !keychainAccount.isEmpty,
      !accessGroup.isEmpty
    else { throw CaptureEvidenceStoreError.invalidRecord }
    self.applicationID = applicationID
    self.directory = directory.standardizedFileURL
    self.keychainService = keychainService
    self.keychainAccount = keychainAccount
    self.accessGroup = accessGroup
  }

  // Reuse the sole SDK process adapter. The caller supplies the root and names,
  // never a filesystem implementation that could weaken the protection mechanism.
  var files: FileManager { FileManager.default }
}

/// One custody generation. Erasure revokes this generation permanently. Delayed capture,
/// processing and checkpoint publishers cannot resurrect evidence after an erase completes.
/// Other configurations in this process have independent stores and Keychain identities.
public actor CaptureCustodyRuntime {
  private let lease: CaptureCustodyLease
  private let fileManager: FileManager
  private var eraseTask: Task<Void, Error>?
  private let removeKey: @Sendable () throws -> Void
  public nonisolated let store: CaptureEvidenceStore
  public nonisolated let configuration: CaptureCustodyConfiguration
  /// Reopened pending erasures expose only a revoked store and explicit `erase()` retry.
  public nonisolated let erasurePendingOnOpen: Bool
  /// Ciphertext was found without its Keychain key. No replacement key is created; the store
  /// refuses every read with `custodyKeyMissing`, and `erase()` deletes the files.
  public nonisolated let keyMissingOnOpen: Bool

  public init(configuration: CaptureCustodyConfiguration) throws {
    try self.init(configuration: configuration, selectedSigning: nil)
  }

  public init(configuration: CaptureCustodyConfiguration, signing: CaptureSigningConfiguration) throws {
    try self.init(configuration: configuration, selectedSigning: signing)
  }

  private init(configuration: CaptureCustodyConfiguration, selectedSigning: CaptureSigningConfiguration?) throws {
    let vault = try CaptureEvidenceKey.hardwareVault(configuration)
    try self.init(configuration: configuration,
      loadCipher: { retained in
        try CaptureEvidenceKey.hardwareCipher(configuration, vault: vault, retainedCiphertext: retained)
      }, removeKey: {
        try CaptureEvidenceKey.markExplicitErasureComplete(configuration, identity: vault.identity)
        try vault.retireAfterVerifiedCiphertextErasure()
        try CaptureEvidenceKey.remove(service: configuration.keychainService,
          account: configuration.keychainAccount, accessGroup: configuration.accessGroup)
      }, signing: selectedSigning)
  }

  /// Explicit destructive recovery. It never decrypts, unwraps or migrates old custody, and exposes
  /// only a permanently revoked store. The owner must request erasure; ordinary opening uses init.
  public init(erasing configuration: CaptureCustodyConfiguration) throws {
    let vault = try CaptureEvidenceKey.hardwareVault(configuration)
    try self.init(erasing: configuration, removeKey: {
      try CaptureEvidenceKey.markExplicitErasureComplete(configuration, identity: vault.identity)
      try vault.retireAfterVerifiedCiphertextErasure()
      try CaptureEvidenceKey.remove(service: configuration.keychainService,
        account: configuration.keychainAccount, accessGroup: configuration.accessGroup)
    })
  }

  init(erasing configuration: CaptureCustodyConfiguration,
    removeKey: @escaping @Sendable () throws -> Void) throws
  {
    let lease = try CaptureCustodyLease.acquire(configuration)
    let manager = configuration.files
    try CaptureCustodyErasureState.prepareExplicitErasure(directory: configuration.directory,
      fileManager: manager)
    self.configuration = configuration
    self.lease = lease
    fileManager = manager
    erasurePendingOnOpen = true
    keyMissingOnOpen = false
    store = try CaptureEvidenceStore(directory: configuration.directory, cipher: .unavailable,
      custodyLease: lease)
    self.removeKey = removeKey
  }

  // Internal dependency injection exercises key-deletion failures without a real Keychain.
  init(configuration: CaptureCustodyConfiguration,
    loadKey: (CaptureEvidenceKey.KeyCreation) throws -> SymmetricKey,
    removeKey: @escaping @Sendable () throws -> Void,
    signing: CaptureSigningConfiguration? = nil) throws
  {
    try self.init(configuration: configuration, loadCipher: { retained in
      do { return CaptureEvidenceCipher(key: try loadKey(.forbidden)) }
      catch let failure as CaptureEvidenceKey.Failure where failure.status == errSecItemNotFound {
        guard !retained else { throw failure }
        return CaptureEvidenceCipher(key: try loadKey(.permitted))
      }
    }, removeKey: removeKey, signing: signing)
  }

  private init(configuration: CaptureCustodyConfiguration,
    loadCipher: (Bool) throws -> CaptureEvidenceCipher,
    removeKey: @escaping @Sendable () throws -> Void,
    signing: CaptureSigningConfiguration? = nil) throws
  {
    if let signing, signing.applicationID != configuration.applicationID {
      throw CaptureEvidenceStoreError.integrityFailure
    }
    let lease = try CaptureCustodyLease.acquire(configuration)
    let manager = configuration.files
    fileManager = manager
    self.lease = lease
    self.configuration = configuration
    self.removeKey = removeKey
    erasurePendingOnOpen = try CaptureCustodyErasureState.pending(
      directory: configuration.directory, fileManager: manager)
    let cipher: CaptureEvidenceCipher
    var keyMissing = false
    if erasurePendingOnOpen {
      // Erase-only recovery neither unwraps keys nor depends on hardware availability.
      cipher = .unavailable
    } else {
      let existing = manager.fileExists(atPath: configuration.directory.path)
        ? try manager.contentsOfDirectory(at: configuration.directory, includingPropertiesForKeys: nil) : []
      // Unknown/quarantined files may still contain ciphertext. Only the two SDK-owned lifecycle
      // files prove absence; a renamed extension must never authorize creating a replacement key.
      let retained = existing.contains { !["custody.erasure", "journey.lock"].contains($0.lastPathComponent) }
      do { cipher = try loadCipher(retained) }
      catch let failure as CaptureEvidenceKey.Failure where failure.status == errSecItemNotFound {
        keyMissing = true
        cipher = .unavailable
      } catch ProtectedStoreKeyError.missingKey {
        keyMissing = true
        cipher = .unavailable
      }
    }
    keyMissingOnOpen = keyMissing
    store = try CaptureEvidenceStore(directory: configuration.directory, cipher: cipher,
      custodyLease: lease, keyMissing: keyMissing, signing: signing)
  }

  /// Permanently closes this generation's admission and persists the erase intent before returning.
  /// Capture owners call this before awaiting fallible native settlement, then call `erase()` to
  /// remove evidence and keys. Preparation leaves ciphertext intact and cannot be cancelled.
  public func prepareErasure() async throws {
    try await store.prepareErasure()
  }

  /// SDK-owned close, drain, erase ordering. A failed erase leaves admission closed and can retry.
  public func erase() async throws {
    if let eraseTask { return try await eraseTask.value }
    let store = store
    let configuration = configuration
    let lease = lease
    let removeKey = removeKey
    let operation = Task { [self] in
      try await store.revokeAndRemoveAll()
      try removeKey()
      try CaptureCustodyErasureState.finish(
        directory: configuration.directory, fileManager: self.fileManager)
      lease.release()
    }
    eraseTask = operation
    do { try await operation.value } catch {
      eraseTask = nil
      throw error
    }
  }
}
