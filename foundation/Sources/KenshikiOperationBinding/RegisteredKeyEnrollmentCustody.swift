import Foundation
import Security

public enum RegisteredKeyEnrollmentError: Error {
  case bindingUnavailable, identityMismatch, interruptedAttestation
  case attestationRetryDeferred(until: Date), attestationChallengeExpired
}

public struct RegisteredKeyEnrollmentRecord: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable { case generated, attesting, retryableAttestation, prepared, registered }
  public let version: Int
  public let keyID: String
  public let backendBaseURL: URL
  public let environment: String
  public let clientInstallationID: String
  public var phase: Phase
  public var packet: Data?
  public var packetExpiresAt: Date?
  public var attestationAttempt: RegisteredKeyAttestationAttempt?
  public init(
    version: Int, keyID: String, backendBaseURL: URL, environment: String,
    clientInstallationID: String,
    phase: Phase, packet: Data? = nil, packetExpiresAt: Date? = nil,
    attestationAttempt: RegisteredKeyAttestationAttempt? = nil
  ) {
    self.version = version
    self.keyID = keyID
    self.backendBaseURL = backendBaseURL
    self.environment = environment
    self.clientInstallationID = clientInstallationID
    self.phase = phase
    self.packet = packet
    self.packetExpiresAt = packetExpiresAt
    self.attestationAttempt = attestationAttempt
  }
}

public struct RegisteredKeyEnrollmentPorts: Sendable {
  public let load: @Sendable () async throws -> Data?
  public let save: @Sendable (Data) async throws -> Void
  public let generate: @Sendable () async throws -> String
  public let attest: @Sendable (String, Data) async throws -> Data
  public let assert: @Sendable (String, Data) async throws -> Data
  public init(
    load: @escaping @Sendable () async throws -> Data?,
    save: @escaping @Sendable (Data) async throws -> Void,
    generate: @escaping @Sendable () async throws -> String,
    attest: @escaping @Sendable (String, Data) async throws -> Data,
    assert: @escaping @Sendable (String, Data) async throws -> Data
  ) {
    self.load = load
    self.save = save
    self.generate = generate
    self.attest = attest
    self.assert = assert
  }
}

/// Product codecs supply opaque packets; custody never selects an endpoint or interprets identity claims.
public struct RegisteredKeyEnrollmentCustody: Sendable {
  public struct Challenge: Codable, Equatable, Sendable {
    public let hash: Data
    public let expiresAt: Date
    public let context: Data
    public init(hash: Data, expiresAt: Date, context: Data) {
      self.hash = hash
      self.expiresAt = expiresAt
      self.context = context
    }
  }
  public struct Profile: Sendable {
    public let challenge: @Sendable (RegisteredKeyEnrollmentRecord) async throws -> Challenge
    public let packet: @Sendable (RegisteredKeyEnrollmentRecord, Challenge, Data) throws -> Data
    public let replay: @Sendable (RegisteredKeyEnrollmentRecord, Data) async throws -> Data
    public let recover: @Sendable (RegisteredKeyEnrollmentRecord) async throws -> Data
    public let isUnknownKey: @Sendable (Error) -> Bool
    public let attestationRetry: RegisteredKeyAttestationRetryPolicy?
    public init(
      challenge: @escaping @Sendable (RegisteredKeyEnrollmentRecord) async throws -> Challenge,
      packet: @escaping @Sendable (RegisteredKeyEnrollmentRecord, Challenge, Data) throws -> Data,
      replay: @escaping @Sendable (RegisteredKeyEnrollmentRecord, Data) async throws -> Data,
      recover: @escaping @Sendable (RegisteredKeyEnrollmentRecord) async throws -> Data,
      isUnknownKey: @escaping @Sendable (Error) -> Bool,
      attestationRetry: RegisteredKeyAttestationRetryPolicy? = nil
    ) {
      self.challenge = challenge
      self.packet = packet
      self.replay = replay
      self.recover = recover
      self.isUnknownKey = isUnknownKey
      self.attestationRetry = attestationRetry
    }
  }
  private let ports: RegisteredKeyEnrollmentPorts
  public init(ports: RegisteredKeyEnrollmentPorts) { self.ports = ports }
  public func execute(
    service: URL, environment: String, original: RegisteredKeyEnrollmentRecord?,
    makeClientID: @Sendable () -> String, profile: Profile, now: Date = Date()
  ) async throws -> (RegisteredKeyEnrollmentRecord, Data) {
    var key: RegisteredKeyEnrollmentRecord
    if let bytes = try await ports.load() {
      key = try decode(bytes, original: original)
    } else {
      guard original == nil else { throw RegisteredKeyEnrollmentError.bindingUnavailable }
      key = RegisteredKeyEnrollmentRecord(
        version: profile.attestationRetry == nil ? 1 : 2,
        keyID: try await ports.generate(), backendBaseURL: service,
        environment: environment, clientInstallationID: makeClientID(), phase: .generated)
      try await save(key)
    }
    try validate(key, service: service, environment: environment, original: original)
    if key.version == 2, profile.attestationRetry == nil,
      [.generated, .attesting, .retryableAttestation].contains(key.phase) {
      throw RegisteredKeyEnrollmentError.interruptedAttestation
    }
    if key.packetExpiresAt.map({ $0 <= now }) == true, key.packet != nil {
      key.packet = nil
      try await save(key)
    }
    if key.phase == .generated {
      let challenge = try await profile.challenge(key)
      return try await attest(key, challenge: challenge, profile: profile)
    }
    switch try retryChallenge(key, profile: profile) {
    case .retained(let challenge):
      return try await attest(key, challenge: challenge, profile: profile)
    case .refresh(let policy, let failures):
      var unattested = key
      unattested.attestationAttempt = nil
      let challenge = try await profile.challenge(unattested)
      // The new challenge continues the same attempt: the failure count, and so the policy's
      // backoff, carries over instead of starting again.
      unattested.attestationAttempt = .init(challenge: challenge, failures: failures,
        nextAllowedAt: min(policy.now(), challenge.expiresAt))
      return try await attest(unattested, challenge: challenge, profile: profile)
    case nil: break
    }
    guard key.phase != .attesting else { throw RegisteredKeyEnrollmentError.interruptedAttestation }
    do { return (key, try await profile.recover(key)) } catch {
      guard profile.isUnknownKey(error), let packet = key.packet else { throw error }
      return (key, try await profile.replay(key, packet))
    }
  }
  public func completed(_ expected: RegisteredKeyEnrollmentRecord) async throws {
    guard let bytes = try await ports.load() else {
      throw RegisteredKeyEnrollmentError.bindingUnavailable
    }
    var key = try decode(bytes, original: expected)
    try validate(
      key, service: expected.backendBaseURL, environment: expected.environment, original: expected)
    key.phase = .registered
    key.packet = nil
    key.packetExpiresAt = nil
    key.attestationAttempt = nil
    try await save(key)
  }
  private func decode(_ bytes: Data, original: RegisteredKeyEnrollmentRecord?) throws
    -> RegisteredKeyEnrollmentRecord
  {
    guard bytes.count <= 1_048_576 else { throw RegisteredKeyEnrollmentError.bindingUnavailable }
    do { return try JSONDecoder().decode(RegisteredKeyEnrollmentRecord.self, from: bytes) } catch {
      guard let original, String(data: bytes, encoding: .utf8) == original.keyID else {
        throw RegisteredKeyEnrollmentError.bindingUnavailable
      }
      return original
    }
  }
  private func validate(
    _ key: RegisteredKeyEnrollmentRecord, service: URL, environment: String,
    original: RegisteredKeyEnrollmentRecord?
  ) throws {
    guard [1, 2].contains(key.version), key.backendBaseURL == service, key.environment == environment,
      !key.keyID.isEmpty, key.keyID.utf8.count <= 4096,
      !key.clientInstallationID.isEmpty, key.clientInstallationID.utf8.count <= 256,
      original == nil
        || key.keyID == original?.keyID
          && key.clientInstallationID == original?.clientInstallationID
          && original?.backendBaseURL == service && original?.environment == environment,
      key.phase == .prepared || key.packet == nil && key.packetExpiresAt == nil,
      key.packet.map({ $0.count <= 524_288 }) ?? true,
      key.packetExpiresAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
      validAttemptPhase(key)
    else {
      throw RegisteredKeyEnrollmentError.identityMismatch
    }
  }
  private func save(_ key: RegisteredKeyEnrollmentRecord) async throws {
    try Task.checkCancellation()
    try await ports.save(JSONEncoder().encode(key))
  }
  private func validAttemptPhase(_ key: RegisteredKeyEnrollmentRecord) -> Bool {
    if key.version == 1 { return key.attestationAttempt == nil && key.phase != .retryableAttestation }
    if key.phase == .attesting || key.phase == .retryableAttestation {
      return key.attestationAttempt.map { key.phase != .retryableAttestation || $0.failures > 0 } ?? false
    }
    return key.attestationAttempt == nil
  }
  private enum RetryInput { case retained(Challenge), refresh(RegisteredKeyAttestationRetryPolicy, failures: UInt16) }
  private func retryChallenge(_ key: RegisteredKeyEnrollmentRecord, profile: Profile) throws -> RetryInput? {
    guard let attempt = key.attestationAttempt else { return nil }
    guard let policy = profile.attestationRetry else {
      throw RegisteredKeyEnrollmentError.interruptedAttestation
    }
    try attempt.validate()
    try policy.validate(key, attempt.challenge)
    guard attempt.challenge.expiresAt > policy.now() else {
      // Only a known retryable platform result leaves the key provably unattested. After an
      // unknown outcome or a late platform success, the expired challenge stays final.
      guard key.phase == .retryableAttestation else {
        throw RegisteredKeyEnrollmentError.attestationChallengeExpired
      }
      return .refresh(policy, failures: attempt.failures)
    }
    guard key.phase == .retryableAttestation else { return nil }
    guard attempt.nextAllowedAt <= policy.now() else {
      throw RegisteredKeyEnrollmentError.attestationRetryDeferred(until: attempt.nextAllowedAt)
    }
    return .retained(attempt.challenge)
  }
  private func attest(
    _ original: RegisteredKeyEnrollmentRecord, challenge: Challenge, profile: Profile
  ) async throws -> (RegisteredKeyEnrollmentRecord, Data) {
    var key = original
    if let policy = profile.attestationRetry {
      try policy.validate(key, challenge)
      guard challenge.expiresAt > policy.now() else {
        throw RegisteredKeyEnrollmentError.attestationChallengeExpired
      }
      let attempt = key.attestationAttempt ?? .init(challenge: challenge, failures: 0,
        nextAllowedAt: min(policy.now(), challenge.expiresAt))
      try attempt.validate()
      // A generated v1 record can adopt v2 before its first platform call; an in-flight v1 cannot.
      key = .init(version: 2, keyID: key.keyID, backendBaseURL: key.backendBaseURL,
        environment: key.environment, clientInstallationID: key.clientInstallationID,
        phase: .attesting, attestationAttempt: attempt)
    }
    key.phase = .attesting
    try await save(key)
    try Task.checkCancellation()
    let attestation: Data
    do { attestation = try await ports.attest(key.keyID, challenge.hash) } catch {
      try Task.checkCancellation()
      if let policy = profile.attestationRetry, policy.isRetryable(error),
        var attempt = key.attestationAttempt {
        attempt.failures = attempt.failures == UInt16.max ? UInt16.max : attempt.failures + 1
        let delay = policy.delay(attempt.failures)
        guard delay.isFinite, delay >= 0, delay <= 86_400 else {
          throw RegisteredKeyEnrollmentError.identityMismatch
        }
        attempt.nextAllowedAt = min(policy.now().addingTimeInterval(delay), challenge.expiresAt)
        key.attestationAttempt = attempt
        key.phase = .retryableAttestation
        try await save(key)
      }
      throw error
    }
    try Task.checkCancellation()
    if let policy = profile.attestationRetry, challenge.expiresAt <= policy.now() {
      throw RegisteredKeyEnrollmentError.attestationChallengeExpired
    }
    let packet = try profile.packet(key, challenge, attestation)
    key.packet = packet
    key.packetExpiresAt = challenge.expiresAt
    key.attestationAttempt = nil
    key.phase = .prepared
    try await save(key)
    return (key, try await profile.replay(key, packet))
  }
  /// The existing sortable client identifier codec, preserved for compatibility.
  public static func makeClientID(now: Date = Date()) -> String {
    let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    var value = UInt64(now.timeIntervalSince1970 * 1000)
    var chars = Array(repeating: Character("0"), count: 26)
    for index in stride(from: 9, through: 0, by: -1) {
      chars[index] = alphabet[Int(value & 31)]
      value >>= 5
    }
    var random = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
    for index in 10..<26 {
      chars[index] = alphabet[Int(random[index - 10] & 31)]
    }
    return String(chars)
  }

}
