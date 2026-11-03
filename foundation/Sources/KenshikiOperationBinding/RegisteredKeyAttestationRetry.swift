import Foundation

/// Exact input retained only when a platform attestation attempt has a known retryable outcome.
public struct RegisteredKeyAttestationAttempt: Codable, Equatable, Sendable {
  public let challenge: RegisteredKeyEnrollmentCustody.Challenge
  public var failures: UInt16
  public var nextAllowedAt: Date
  public init(challenge: RegisteredKeyEnrollmentCustody.Challenge, failures: UInt16, nextAllowedAt: Date) {
    self.challenge = challenge
    self.failures = failures
    self.nextAllowedAt = nextAllowedAt
  }
}

/// An explicit product policy; custody supplies persistence, never timers or automatic retry loops.
public struct RegisteredKeyAttestationRetryPolicy: Sendable {
  public let now: @Sendable () -> Date
  public let isRetryable: @Sendable (Error) -> Bool
  public let validate: @Sendable (RegisteredKeyEnrollmentRecord, RegisteredKeyEnrollmentCustody.Challenge) throws -> Void
  public let delay: @Sendable (UInt16) -> TimeInterval
  public init(
    now: @escaping @Sendable () -> Date,
    isRetryable: @escaping @Sendable (Error) -> Bool,
    validate: @escaping @Sendable (RegisteredKeyEnrollmentRecord, RegisteredKeyEnrollmentCustody.Challenge) throws -> Void,
    delay: @escaping @Sendable (UInt16) -> TimeInterval
  ) {
    self.now = now
    self.isRetryable = isRetryable
    self.validate = validate
    self.delay = delay
  }
}

extension RegisteredKeyAttestationAttempt {
  func validate() throws {
    guard challenge.hash.count == 32, !challenge.context.isEmpty, challenge.context.count <= 16_384,
      challenge.expiresAt.timeIntervalSince1970.isFinite,
      nextAllowedAt.timeIntervalSince1970.isFinite, nextAllowedAt <= challenge.expiresAt
    else { throw RegisteredKeyEnrollmentError.identityMismatch }
  }
}
