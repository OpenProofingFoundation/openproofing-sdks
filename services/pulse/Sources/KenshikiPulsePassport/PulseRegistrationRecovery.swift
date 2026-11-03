// Adapted from IdentityGateway/PulseRegistrationRecovery.swift; see reference-apps/passport-server-provenance.json.
import CryptoKit
import Foundation
import KenshikiOperationBinding

public enum PulseRegistrationRecoveryFailure: Error, Equatable, Sendable {
  case configurationMismatch, ownerMismatch, keyBindingUnavailable, interruptedAttestation,
    unsupportedRecovery
}

typealias PulseRegistrationKey = RegisteredKeyEnrollmentRecord
typealias PulseRegistrationKeyPorts = RegisteredKeyEnrollmentPorts

/// Registered-key recovery uses fresh assertions, never another Apple registration attestation.
public struct PulseRegistrationKeyRecovery: Sendable {
  public init(makeRequestID:@escaping @Sendable()->String = {UUID().uuidString.lowercased()},configuration:PulsePassportRegistrationConfiguration,keys:RegisteredKeyEnrollmentPorts,send:@escaping @Sendable(String,String,Data)async throws->Data,now:@escaping @Sendable()->Date = {Date()}) {self.makeRequestID=makeRequestID;self.configuration=configuration;self.keys=keys;self.send=send;self.now=now}
  var makeRequestID: @Sendable () -> String = { UUID().uuidString.lowercased() }
  let configuration: PulsePassportRegistrationConfiguration
  let keys: PulseRegistrationKeyPorts
  let send: @Sendable (String, String, Data) async throws -> Data
  var now: @Sendable () -> Date = { Date() }

  public func recover(_ key: RegisteredKeyEnrollmentRecord, original: PulsePassportCredentials?) async throws
    -> PulsePassportCredentials
  {
    let origin = try serviceOrigin(configuration.baseURL)
    let requestID = makeRequestID()
    let request: [String: Any] = [
      "v": "pulse.installation-key-recovery-request.v1", "request_id": requestID,
      "key_id": key.keyID,
      "application_id": try applicationID(), "environment": key.environment,
      "service_origin": origin,
    ]
    let data = try await send(
      "pulse/installations/key-recovery/v1/challenge", "pulse.installation-key-recovery-request.v1",
      KenshikiOperationBinding.CanonicalJSON.data(withJSONObject: request))
    let packet = try object(data)
    struct Clock: Decodable {
      let issued_at: Int64
      let expires_at: Int64
    }
    let clock = try JSONDecoder().decode(Clock.self, from: data)
    guard
      Set(packet.keys) == [
        "v", "request_id", "key_id_hash", "application_id", "environment", "service_origin",
        "installation_id", "client_installation_id", "challenge_id", "challenge", "issued_at",
        "expires_at",
      ],
      packet["v"] as? String == "pulse.installation-key-recovery-challenge.v1",
      packet["request_id"] as? String == requestID,
      packet["key_id_hash"] as? String == SealedOperation.sha256(Data(key.keyID.utf8)),
      packet["application_id"] as? String == (try applicationID()),
      packet["environment"] as? String == key.environment,
      packet["service_origin"] as? String == origin,
      let installation = packet["installation_id"] as? String,
      installation == "pulse_" + key.clientInstallationID,
      packet["client_installation_id"] as? String == key.clientInstallationID,
      original == nil || installation == original?.installationID,
      let challengeID = packet["challenge_id"] as? String, UUID(uuidString: challengeID) != nil,
      let challenge = packet["challenge"] as? String,
      challenge.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
      clock.issued_at >= 0, clock.issued_at <= Int64(now().timeIntervalSince1970) + 60,
      clock.expires_at > Int64(now().timeIntervalSince1970),
      clock.expires_at < 9_007_199_254_740_991,
      clock.expires_at > clock.issued_at, clock.expires_at - clock.issued_at <= 300
    else { throw PulseRegistrationRecoveryFailure.ownerMismatch }
    var material = Data("pulse:installation-key-recovery:v1".utf8)
    material.append(0)
    material.append(try KenshikiOperationBinding.CanonicalJSON.data(withJSONObject: packet))
    let hash = Data(SHA256.hash(data: material))
    let assertion = try await keys.assert(key.keyID, hash)
    let body = try KenshikiOperationBinding.CanonicalJSON.data(withJSONObject: [
      "challenge": packet,
      "app_attest": [
        "key_id": key.keyID, "client_data_hash": InstallationWriteProof.base64URL(hash),
        "assertion_object": InstallationWriteProof.base64URL(assertion),
      ],
    ])
    let resultData = try await send(
      "pulse/installations/key-recovery/v1", "pulse.installation-key-recovery.v1", body)
    let result = try object(resultData)
    struct Readiness: Decodable { let production_ready: Bool }
    let readiness = try JSONDecoder().decode(Readiness.self, from: resultData)
    guard
      Set(result.keys) == [
        "v", "request_id", "request_digest", "key_id_hash", "application_id", "environment",
        "service_origin", "installation_id", "client_installation_id", "token", "token_type",
        "expires_at",
        "credential_lifecycle", "production_ready",
      ],
      result["v"] as? String == "pulse.installation-key-recovery.v1",
      result["request_id"] as? String == requestID,
      result["request_digest"] as? String == SealedOperation.sha256(material),
      result["key_id_hash"] as? String == packet["key_id_hash"] as? String,
      result["application_id"] as? String == (try applicationID()),
      result["environment"] as? String == key.environment,
      result["service_origin"] as? String == origin,
      result["installation_id"] as? String == installation,
      result["client_installation_id"] as? String == key.clientInstallationID,
      result["token_type"] as? String == "Bearer", result["expires_at"] is NSNull,
      result["credential_lifecycle"] as? String == "recovered",
      readiness.production_ready == (key.environment == "production"),
      let token = result["token"] as? String, !token.isEmpty
    else { throw PulseRegistrationRecoveryFailure.ownerMismatch }
    return .init(
      installationID: installation, clientInstallationID: key.clientInstallationID,
      appAttestKeyID: key.keyID,
      token: token, expiresAt: nil, backendBaseURL: key.backendBaseURL, mode: .appAttest,
      appAttestEnvironment: key.environment)
  }
  private func object(_ data: Data) throws -> [String: Any] {
    _ = try KenshikiOperationBinding.CanonicalJSON.canonicalize(data)
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PulseRegistrationRecoveryFailure.ownerMismatch
    }
    return value
  }
  private func applicationID() throws -> String {
    guard let id = configuration.applicationIdentifier, !id.isEmpty, id.count <= 256,
      !id.unicodeScalars.contains(where: { $0.value < 32 })
    else { throw PulseRegistrationRecoveryFailure.configurationMismatch }
    return id
  }
  private func serviceOrigin(_ url: URL) throws -> String {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme == "https", parts.host != nil,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.path.isEmpty || parts.path == "/"
    else { throw PulseRegistrationRecoveryFailure.configurationMismatch }
    parts.scheme = "https"
    parts.host = parts.host?.lowercased()
    if parts.port == 443 { parts.port = nil }
    parts.path = ""
    parts.query = nil
    parts.fragment = nil
    guard let origin = parts.string else {
      throw PulseRegistrationRecoveryFailure.configurationMismatch
    }
    return origin
  }
}

/// One key-reference record owns initial attestation and its exact first registration packet.
public struct PulseRegistrationLifecycle: Sendable {
  public init(configuration:PulsePassportRegistrationConfiguration,keys:RegisteredKeyEnrollmentPorts,send:@escaping @Sendable(String,String,Data)async throws->Data,now:@escaping @Sendable()->Date = {Date()},makeRequestID:@escaping @Sendable()->String = {UUID().uuidString.lowercased()}) {self.configuration=configuration;self.keys=keys;self.send=send;self.now=now;self.makeRequestID=makeRequestID}
  let configuration: PulsePassportRegistrationConfiguration
  let keys: PulseRegistrationKeyPorts
  let send: @Sendable (String, String, Data) async throws -> Data
  var now: @Sendable () -> Date = { Date() }
  var makeRequestID: @Sendable () -> String = { UUID().uuidString.lowercased() }

  public func candidate(
    original: PulsePassportCredentials?, app: PulsePassportAppMetadata,
    device: PulsePassportDeviceMetadata
  ) async throws -> PulsePassportCredentials {
    try PulseRegistrationRequestAuthority.validate(configuration)
    do {
      let (_, result) = try await RegisteredKeyEnrollmentCustody(ports: keys).execute(
        service: configuration.baseURL, environment: environment(),
        original: original.map(identity),
        makeClientID: { RegisteredKeyEnrollmentCustody.makeClientID() },
        profile: .init(
          challenge: { key in try await challenge(key, app: app, device: device) },
          packet: { key, challenge, attestation in
            try packet(key, challenge: challenge, attestation: attestation)
          },
          replay: { key, bytes in try JSONEncoder().encode(await replay(bytes, key: key)) },
          recover: { key in
            try JSONEncoder().encode(
              await PulseRegistrationKeyRecovery(
                makeRequestID: makeRequestID, configuration: configuration, keys: keys, send: send,
                now: now
              ).recover(
                key, original: original))
          },
          isUnknownKey: { Self.isUnknownKey($0) },
          attestationRetry: PulseRegistrationAttestationContext.policy(configuration: configuration, now: now)), now: now())
      return try JSONDecoder().decode(PulsePassportCredentials.self, from: result)
    } catch RegisteredKeyEnrollmentError.attestationRetryDeferred(let until) {
      throw PulseRegistrationRetryFailure.deferred(until: until)
    } catch RegisteredKeyEnrollmentError.attestationChallengeExpired {
      throw PulseRegistrationRetryFailure.challengeExpired
    } catch RegisteredKeyEnrollmentError.interruptedAttestation {
      throw PulseRegistrationRecoveryFailure.interruptedAttestation
    } catch is RegisteredKeyEnrollmentError {
      throw PulseRegistrationRecoveryFailure.keyBindingUnavailable
    }
  }
  public func completed(_ credentials: PulsePassportCredentials) async throws {
    do {
      try await RegisteredKeyEnrollmentCustody(ports: keys).completed(identity(credentials))
    } catch is RegisteredKeyEnrollmentError {
      throw PulseRegistrationRecoveryFailure.keyBindingUnavailable
    }
  }
  private func identity(_ credentials: PulsePassportCredentials) throws -> PulseRegistrationKey {
    guard let key = credentials.appAttestKeyID, !key.isEmpty,
      credentials.installationID == "pulse_" + credentials.clientInstallationID,
      credentials.backendBaseURL == configuration.baseURL,
      credentials.appAttestEnvironment?.lowercased() == (try environment())
    else { throw PulseRegistrationRecoveryFailure.ownerMismatch }
    return .init(
      version: 1, keyID: key, backendBaseURL: configuration.baseURL, environment: try environment(),
      clientInstallationID: credentials.clientInstallationID, phase: .registered)
  }
  private static func isUnknownKey(_ error: Error) -> Bool {
    (error as? PulseRegistrationUnknownKeyFailure)?.isUnknownRegisteredKey == true
  }
  private func environment() throws -> String {
    guard let appID = configuration.applicationIdentifier, !appID.isEmpty else {
      throw PulseRegistrationRecoveryFailure.configurationMismatch
    }
    guard let value = configuration.appAttestEnvironment?.lowercased(),
      ["production", "development"].contains(value)
    else {
      throw PulseRegistrationRecoveryFailure.configurationMismatch
    }
    return value
  }
  private func challenge(
    _ key: PulseRegistrationKey, app: PulsePassportAppMetadata,
    device: PulsePassportDeviceMetadata
  ) async throws -> RegisteredKeyEnrollmentCustody.Challenge {
    let appValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(app))
    let deviceValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device))
    let context: [String: Any] = [
      "schemaVersion": "pulse.app-attest-challenge.v1",
      "clientInstallationId": key.clientInstallationID, "app": appValue, "device": deviceValue,
    ]
    let challengeData = try await send(
      "api/v1/pulse/app-attest/challenge", "pulse.app-attest-challenge.v1",
      KenshikiOperationBinding.CanonicalJSON.data(withJSONObject: context))
    struct Challenge: Decodable {
      let challenge: String
      let expiresAt: String
    }
    let challenge = try JSONDecoder().decode(Challenge.self, from: challengeData)
    guard !challenge.challenge.isEmpty, let expiry = PulsePassportClock.date(challenge.expiresAt),
      expiry > now(), expiry.timeIntervalSince(now()) <= 600
    else { throw PulseRegistrationRecoveryFailure.ownerMismatch }
    let frozen = PulseRegistrationAttestationContext(version: 1, challenge: challenge.challenge,
      expiresAt: challenge.expiresAt, app: app, device: device,
      keyIDHash: SealedOperation.sha256(Data(key.keyID.utf8)),
      clientInstallationID: key.clientInstallationID, service: key.backendBaseURL,
      environment: key.environment, applicationID: configuration.applicationIdentifier ?? "")
    let frozenData = try KenshikiOperationBinding.CanonicalJSON.canonicalize(JSONEncoder().encode(frozen))
    let result = RegisteredKeyEnrollmentCustody.Challenge(
      hash: Data(SHA256.hash(data: Data(challenge.challenge.utf8))), expiresAt: expiry,
      context: frozenData)
    try PulseRegistrationAttestationContext.validate(result, key: key, configuration: configuration)
    return result
  }
  private func packet(
    _ key: PulseRegistrationKey, challenge: RegisteredKeyEnrollmentCustody.Challenge,
    attestation: Data
  ) throws -> Data {
    try PulseRegistrationAttestationContext.validate(challenge, key: key, configuration: configuration)
    let context = try JSONDecoder().decode(PulseRegistrationAttestationContext.self, from: challenge.context)
    let nonce = context.challenge
    let appValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context.app))
    let deviceValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context.device))
    let packet = try KenshikiOperationBinding.CanonicalJSON.data(withJSONObject: [
      "schemaVersion": "pulse.installation-registration.v1", "mode": "appAttest",
      "clientInstallationId": key.clientInstallationID, "app": appValue, "device": deviceValue,
      "appAttest": [
        "keyId": key.keyID, "challenge": nonce,
        "attestationObject": InstallationWriteProof.base64URL(attestation),
        "clientDataHash": InstallationWriteProof.base64URL(challenge.hash),
      ],
    ])
    return packet
  }
  private func replay(_ packet: Data, key: PulseRegistrationKey) async throws
    -> PulsePassportCredentials
  {
    guard let object = try JSONSerialization.jsonObject(with: packet) as? [String: Any],
      Set(object.keys) == [
        "schemaVersion", "mode", "clientInstallationId", "app", "device", "appAttest",
      ],
      object["schemaVersion"] as? String == "pulse.installation-registration.v1",
      object["mode"] as? String == "appAttest",
      object["clientInstallationId"] as? String == key.clientInstallationID,
      let proof = object["appAttest"] as? [String: String],
      Set(proof.keys) == ["keyId", "challenge", "attestationObject", "clientDataHash"],
      proof["keyId"] == key.keyID,
      let challenge = proof["challenge"],
      proof["clientDataHash"]
        == InstallationWriteProof.base64URL(Data(SHA256.hash(data: Data(challenge.utf8)))),
      try KenshikiOperationBinding.CanonicalJSON.canonicalize(packet) == packet
    else {
      throw PulseRegistrationRecoveryFailure.ownerMismatch
    }
    let data = try await send(
      "api/v1/pulse/installations", "pulse.installation-registration.v1", packet)
    struct Registration: Decodable {
      let installationId: String
      let token: String
      let tokenType: String
      let expiresAt: String?
    }
    let response = try JSONDecoder().decode(Registration.self, from: data)
    guard response.installationId == "pulse_" + key.clientInstallationID, !response.token.isEmpty,
      response.tokenType == "Bearer",
      response.expiresAt == nil
    else { throw PulseRegistrationRecoveryFailure.ownerMismatch }
    return .init(
      installationID: response.installationId, clientInstallationID: key.clientInstallationID,
      appAttestKeyID: key.keyID,
      token: response.token, expiresAt: nil, backendBaseURL: key.backendBaseURL, mode: .appAttest,
      appAttestEnvironment: key.environment)
  }
}

/// Product request authority; configuration cannot replace HTTP authentication or routing headers.
public enum PulseRegistrationRequestAuthority {
  public static func validate(_ configuration: PulsePassportRegistrationConfiguration) throws {
    guard let parts = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
      parts.scheme == "https", parts.host?.isEmpty == false, parts.user == nil,
      parts.password == nil,
      parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/"
    else {
      throw PulseRegistrationRecoveryFailure.configurationMismatch
    }
    let reserved = Set([
      "host", "authorization", "proxy-authorization", "content-type", "accept", "connection",
      "x-pulse-schema-version", "idempotency-key", "forwarded", "x-original-url", "x-rewrite-url",
      "x-http-method-override",
    ])
    guard
      configuration.additionalHeaders.keys.allSatisfy({
        !reserved.contains($0.lowercased()) && !$0.lowercased().hasPrefix("x-forwarded-")
      })
    else { throw PulseRegistrationRecoveryFailure.configurationMismatch }
  }
}
