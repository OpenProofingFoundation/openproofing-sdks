// Adapted from IdentityGateway/PulseRegistrationAttestationRetry.swift; see reference-apps/passport-server-provenance.json.
import CryptoKit
import Foundation
import KenshikiOperationBinding

/// Admission for an explicit retry; neither case authorizes key replacement or an unchecked request.
public enum PulseRegistrationRetryFailure: Error, Equatable, Sendable {
  case deferred(until: Date)
  case challengeExpired
}

/// Frozen local context, not a new wire member. Metadata remains from the original challenge attempt.
public struct PulseRegistrationAttestationContext: Codable, Sendable {
  let version: Int
  let challenge: String
  let expiresAt: String
  let app: PulsePassportAppMetadata
  let device: PulsePassportDeviceMetadata
  let keyIDHash: String
  let clientInstallationID: String
  let service: URL
  let environment: String
  let applicationID: String

  static func validate(_ challenge: RegisteredKeyEnrollmentCustody.Challenge,
    key: PulseRegistrationKey, configuration: PulsePassportRegistrationConfiguration) throws {
    do { try validateBoundContext(challenge, key: key, configuration: configuration) }
    catch { throw PulseRegistrationRecoveryFailure.keyBindingUnavailable }
  }

  private static func validateBoundContext(_ challenge: RegisteredKeyEnrollmentCustody.Challenge,
    key: PulseRegistrationKey, configuration: PulsePassportRegistrationConfiguration) throws {
    guard challenge.hash.count == 32, challenge.context.count <= 16_384,
      try CanonicalJSON.canonicalize(challenge.context) == challenge.context,
      let object = try JSONSerialization.jsonObject(with: challenge.context) as? [String: Any],
      Set(object.keys) == ["version", "challenge", "expiresAt", "app", "device", "keyIDHash",
        "clientInstallationID", "service", "environment", "applicationID"]
    else { throw PulseRegistrationRecoveryFailure.keyBindingUnavailable }
    let retained = try JSONDecoder().decode(Self.self, from: challenge.context)
    guard retained.version == 1, !retained.challenge.isEmpty,
      retained.challenge.utf8.count <= 4096,
      retained.keyIDHash == SealedOperation.sha256(Data(key.keyID.utf8)),
      retained.clientInstallationID == key.clientInstallationID,
      retained.service == key.backendBaseURL, retained.service == configuration.baseURL,
      retained.environment == key.environment,
      retained.environment == configuration.appAttestEnvironment?.lowercased(),
      retained.applicationID == configuration.applicationIdentifier,
      PulsePassportClock.date(retained.expiresAt) == challenge.expiresAt,
      Data(SHA256.hash(data: Data(retained.challenge.utf8))) == challenge.hash
    else { throw PulseRegistrationRecoveryFailure.keyBindingUnavailable }
  }

  static func policy(configuration: PulsePassportRegistrationConfiguration,
    now: @escaping @Sendable () -> Date) -> RegisteredKeyAttestationRetryPolicy {
    .init(now: now, isRetryable: { error in
      let error = error as NSError
      // Apple's documented transient result. Other errors and interrupted calls remain ambiguous.
      return error.domain == "com.apple.devicecheck.error" && error.code == 4
    }, validate: { key, challenge in
      try validate(challenge, key: key, configuration: configuration)
    }, delay: { failures in
      // Product admission policy, not an Apple-prescribed schedule. No timer or automatic loop.
      min(30, 2 * pow(2, Double(min(failures > 0 ? failures - 1 : 0, 4))))
    })
  }
}
