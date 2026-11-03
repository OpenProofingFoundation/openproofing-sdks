#if DEBUG
  import CryptoKit
  import Foundation
  import Security

  extension CaptureCustodyRuntime {
    /// Explicit synthetic test composition. Absent from Release; never selected by normal opening,
    /// simulator detection, XCTest environment variables or a hardware failure.
    @_spi(CaptureTestFixture)
    public static func testing(configuration: CaptureCustodyConfiguration,
      signing: CaptureSigningConfiguration? = nil) throws -> CaptureCustodyRuntime
    {
      try CaptureFixtureKeys.requireSynthetic(configuration)
      return try CaptureCustodyRuntime(configuration: configuration, loadKey: {
        try CaptureFixtureKeys.shared.load(configuration, creation: $0)
      }, removeKey: { CaptureFixtureKeys.shared.remove(configuration) }, signing: signing)
    }

    /// Fault injection for retained-ciphertext/missing-key tests; never touches platform keys.
    @_spi(CaptureTestFixture)
    public static func testingRemoveKey(configuration: CaptureCustodyConfiguration) throws {
      try CaptureFixtureKeys.requireSynthetic(configuration)
      CaptureFixtureKeys.shared.remove(configuration)
    }

    @_spi(CaptureTestFixture)
    public static func testingKeyExists(configuration: CaptureCustodyConfiguration) throws -> Bool {
      try CaptureFixtureKeys.requireSynthetic(configuration)
      return CaptureFixtureKeys.shared.contains(configuration)
    }

    @_spi(CaptureTestFixture)
    public static func testingForErasure(configuration: CaptureCustodyConfiguration) throws -> CaptureCustodyRuntime {
      try CaptureFixtureKeys.requireSynthetic(configuration)
      return try CaptureCustodyRuntime(erasing: configuration,
        removeKey: { CaptureFixtureKeys.shared.remove(configuration) })
    }
  }

  private final class CaptureFixtureKeys: @unchecked Sendable {
    static let shared = CaptureFixtureKeys()
    private let lock = NSLock()
    private var keys: [String: SymmetricKey] = [:]
    static func requireSynthetic(_ configuration: CaptureCustodyConfiguration) throws {
      guard ["synthetic.", "test."].contains(where: configuration.applicationID.hasPrefix),
        ["synthetic.", "test."].contains(where: configuration.keychainService.hasPrefix),
        configuration.accessGroup.hasPrefix("TEST.") else { throw CaptureEvidenceStoreError.invalidRecord }
    }
    private func namespace(_ configuration: CaptureCustodyConfiguration) -> String {
      [configuration.applicationID, configuration.accessGroup, configuration.keychainService,
        configuration.keychainAccount].joined(separator: "\0")
    }
    func load(_ configuration: CaptureCustodyConfiguration, creation: CaptureEvidenceKey.KeyCreation)
      throws -> SymmetricKey
    {
      try lock.withLock {
        let identity = namespace(configuration)
        if let key = keys[identity] { return key }
        guard creation == .permitted else { throw CaptureEvidenceKey.Failure(status: errSecItemNotFound) }
        let key = SymmetricKey(size: .bits256)
        keys[identity] = key
        return key
      }
    }
    func contains(_ configuration: CaptureCustodyConfiguration) -> Bool {
      lock.withLock { keys[namespace(configuration)] != nil }
    }
    func remove(_ configuration: CaptureCustodyConfiguration) {
      _ = lock.withLock { keys.removeValue(forKey: namespace(configuration)) }
    }
  }
#endif
