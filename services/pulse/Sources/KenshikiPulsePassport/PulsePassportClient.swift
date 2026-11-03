import Foundation
import CryptoKit
import KenshikiOperationBinding

public actor PulsePassportClient {
  public static let verifyDomain = "pulse:passport-verify:v1"
  public static let sessionDomain = "pulse:identity-session:v1"
  public static let workflow = "passport_identity"
  public nonisolated let baseURL: URL
  public nonisolated let deviceID: String
  private let now: @Sendable () -> Date
  private let attestation: PulseNativeAttestation
  private let transport: any PulseBoundedHTTPTransport
  private let diagnostic: @Sendable (PulsePassportDiagnostic) -> Void

  /// `deviceID` is the installation's id: the Worker refuses a submission whose `device_id`
  /// is not the installation the bearer names.
  public init(baseURL: URL, deviceID: String, attestation: PulseNativeAttestation,
              transport: (any PulseBoundedHTTPTransport)? = nil,
              now: @escaping @Sendable () -> Date = { Date() },
              diagnostic: @escaping @Sendable (PulsePassportDiagnostic) -> Void = { _ in
                // Hosts choose a privacy-safe diagnostic sink; this adapter does not log identity data.
              }) {
    self.now = now
    self.baseURL = baseURL
    self.deviceID = deviceID
    self.attestation = attestation
    self.diagnostic = diagnostic
    if let transport {
      self.transport = transport
    } else {
      self.transport = URLSessionPulseBoundedHTTPTransport()
    }
  }

  /// Opens the device-owned session under `operationID` and `issuedAt`. Keep both for the life of one
  /// ceremony: the Worker claims the pair, and a retry with the same pair returns the same session.
  public func openSession(operationID: String, issuedAt: Date,onStage:@escaping @Sendable(PulsePassportPreparationStage)async throws->Void = {_ in}) async throws -> PulsePassportSession {
    try validateBaseURL()
    let issued = issuedAt.formatted(Date.ISO8601FormatStyle())
    let hash = try PulseAttestedPayloadHash.clientDataHash(
      domain: Self.sessionDomain,
      payload: .object(["device_id": .string(deviceID), "issued_at": .string(issued),
                        "operation_id": .string(operationID)]))
    try await onStage(.appAttestAssertion)
    let assertion = try await self.assertion(over: hash)
    let body = try CanonicalJSONValue.object([
      "operation_id": .string(operationID), "device_id": .string(deviceID), "issued_at": .string(issued),
      "app_attest": Self.appAttest(assertion),
    ]).canonicalJSONString()
    try await onStage(.session)
    let reply = try await postJSON("identity/sessions", token: nil, body: Data(body.utf8), expecting: [200, 201])
    struct Reply: Decodable { let session_id: String; let nonce: String; let expires_at: String }
    let decoded: Reply = try decode(reply.body, endpoint: .session)
    try require(!decoded.session_id.isEmpty && !decoded.nonce.isEmpty, .binding, endpoint: .session)
    guard let expires = PulsePassportClock.date(decoded.expires_at) else { throw PulsePassportFailure.invalidResponse }
    guard expires > now() else { throw PulsePassportFailure.challengeExpired }
    return PulsePassportSession(sessionID: decoded.session_id, sessionNonce: decoded.nonce,
                                expiresAt: decoded.expires_at)
  }

  /// Issues the nonce the chip will sign. An unexpired nonce for the same session is returned again.
  public func issueNonce(for session: PulsePassportSession) async throws -> PulsePassportNonce {
    try validateBaseURL()
    let body = try CanonicalJSONValue.object([
      "session_id": .string(session.sessionID), "session_nonce": .string(session.sessionNonce),
      "device_id": .string(deviceID), "attestation_id": .null, "workflow": .string(Self.workflow),
      "payload_commitment_hash": .null,
    ]).canonicalJSONString()
    let reply = try await postJSON("passport/nonce", token: nil, body: Data(body.utf8), expecting: [200, 201])
    let nonce = try decodeNonce(reply.body)
    try require(nonce.sessionID == session.sessionID && nonce.workflow == Self.workflow &&
      nonce.payloadCommitmentHash == nil && !nonce.nonceID.isEmpty && !nonce.nonce.isEmpty &&
      !nonce.iacKeyID.isEmpty, .binding, endpoint: .nonce)
    guard let expires = PulsePassportClock.date(nonce.expiresAt) else { throw PulsePassportFailure.invalidResponse }
    guard expires > now() else { throw PulsePassportFailure.challengeExpired }
    return nonce
  }

  /// The server's Chip Authentication challenge for this nonce and these exact DG14 bytes. DG14 is
  /// untrusted here; the Worker authenticates it against the SOD at verify time.
  public func chipAuthenticationChallenge(nonce: PulsePassportNonce, dg14: Data) async throws
    -> PulseChipAuthenticationChallenge
  {
    try validateBaseURL()
    var members = Self.consumeMembers(nonce, deviceID: deviceID)
    members["dg14"] = .string(dg14.base64EncodedString())
    let body = try CanonicalJSONValue.object(members).canonicalJSONString()
    let reply = try await postJSON("passport/chip-authentication", token: nil, body: Data(body.utf8),
                               expecting: [200])
    struct Reply: Decodable {
      let protocolName: String
      let nonceID: String
      let caProtocolOID: String
      let keyID: Int?
      let ephemeralPublicKey: String
      let protectedCommand: String
      enum CodingKeys: String, CodingKey {
        case protocolName = "protocol", nonceID = "nonce_id", caProtocolOID = "ca_protocol_oid"
        case keyID = "key_id", ephemeralPublicKey = "ephemeral_public_key", protectedCommand = "protected_command"
      }
    }
    let decoded: Reply = try decode(reply.body, endpoint: .chipAuthentication)
    guard decoded.protocolName == "pulse.passport-ca.v1", decoded.nonceID == nonce.nonceID,
      let publicKey = Self.base64URLDecoded(decoded.ephemeralPublicKey), !publicKey.isEmpty,
      let command = Self.base64URLDecoded(decoded.protectedCommand), !command.isEmpty
    else {
      PulsePassportDiagnostic.check(.binding, endpoint: .chipAuthentication, passed: false).record(observer: diagnostic)
      throw PulsePassportFailure.invalidResponse
    }
    PulsePassportDiagnostic.check(.binding, endpoint: .chipAuthentication, passed: true).record(observer: diagnostic)
    return PulseChipAuthenticationChallenge(
      protocolName: decoded.protocolName, caProtocolOID: decoded.caProtocolOID, keyID: decoded.keyID,
      ephemeralPublicKey: publicKey, protectedCommand: command)
  }

  /// Submits the read. `chipAuthenticationResponse` is the chip's raw answer to the relayed protected
  /// command, required by the Worker whenever the SOD-authenticated DG14 declares a Chip
  /// Authentication key. An assertion the Worker reports as already used is re-signed once.
  public func verify(_ proof: PulsePassportChipProof, nonce: PulsePassportNonce,
                     chipAuthenticationResponse: Data?) async throws -> PulsePassportVerification
  {
    try validateBaseURL()
    let payload = try Self.payloadJSON(proof, nonce: nonce, deviceID: deviceID,
                                       chipAuthenticationResponse: chipAuthenticationResponse)
    let token = try await installationToken()
    do {
      return try await submitWithFreshCounter(payload, token: token, nonce: nonce)
    } catch let error where Self.classification(error) == .unauthorized {
      guard let recover = attestation.recoverInstallationToken else { throw error }
      // A known bearer refusal is recovered with the same registered key and installation.
      // No nonce/session replacement or Apple registration attestation occurs here.
      let recovered = try await recover()
      try Task.checkCancellation()
      guard !recovered.isEmpty else { throw PulsePassportFailure.unauthorized }
      return try await submitWithFreshCounter(payload, token: recovered, nonce: nonce)
    }
  }

  private func submitWithFreshCounter(_ payload: String, token: String, nonce: PulsePassportNonce) async throws -> PulsePassportVerification {
    do { return try await submit(payload, token: token, nonce: nonce) }
    catch let error where Self.classification(error) == .assertionReused { return try await submit(payload, token: token, nonce: nonce) }
  }

  // MARK: - The wire

  private func submit(_ payload: String, token: String, nonce: PulsePassportNonce) async throws -> PulsePassportVerification {
    let hash = Self.verifyClientDataHash(payloadJSON: payload)
    let assertion = try await self.assertion(over: hash)
    let body = try CanonicalJSONValue.object([
      "payload_json": .string(payload), "app_attest": Self.appAttest(assertion),
    ]).canonicalJSONString()
    // A failed validation is a 403 carrying the same body as a verified one.
    let reply = try await postJSON("passport/verify", token: token, body: Data(body.utf8), expecting: [200, 403])
    let verdict = try decodeVerification(reply.body, status: reply.status, nonce: nonce)
    PulsePassportDiagnostic.verdict(verdict).record(observer: diagnostic)
    return verdict
  }

  /// SHA-256(`pulse:passport-verify:v1` || 0x00 || payload_json), over exactly the text sent.
  public static func verifyClientDataHash(payloadJSON: String) -> Data {
    PulseAttestedPayloadHash.clientDataHash(domain: verifyDomain, canonicalJSON: payloadJSON)
  }

  public static func payloadJSON(_ proof: PulsePassportChipProof, nonce: PulsePassportNonce, deviceID: String,
                          chipAuthenticationResponse: Data?) throws -> String {
    guard !proof.securityObject.isEmpty, !proof.documentSigningCertificate.isEmpty,
      proof.sentDataGroups["DG1"] != nil
    else { throw PulsePassportFailure.incompleteProof }
    var active: CanonicalJSONValue = .null
    if let challenge = proof.activeAuthenticationChallenge, let signature = proof.activeAuthenticationSignature {
      active = .object(["challenge": .string(base64URL(challenge)), "signature": .string(base64URL(signature))])
    }
    var members = consumeMembers(nonce, deviceID: deviceID)
    members["nfc_passport"] = .object([
      "sod": .string(proof.securityObject.base64EncodedString()),
      "document_signing_certificate": .string(proof.documentSigningCertificate.base64EncodedString()),
      "data_groups": .object(proof.sentDataGroups.mapValues { .string($0.base64EncodedString()) }),
      "active_authentication": active,
      "chip_authentication": chipAuthenticationResponse.map {
        .object(["response_apdu": .string($0.base64EncodedString())])
      } ?? .null,
    ])
    return try CanonicalJSONValue.object(members).canonicalJSONString()
  }

  private static func consumeMembers(_ nonce: PulsePassportNonce, deviceID: String) -> [String: CanonicalJSONValue] {
    [
      "session_id": .string(nonce.sessionID), "device_id": .string(deviceID),
      "nonce_id": .string(nonce.nonceID), "nonce": .string(nonce.nonce),
      "workflow": .string(nonce.workflow), "iac_key_id": .string(nonce.iacKeyID),
      "payload_commitment_hash": nonce.payloadCommitmentHash.map { .string($0) } ?? .null,
    ]
  }

  private static func appAttest(_ assertion: PulseAppAttestAssertion) -> CanonicalJSONValue {
    .object([
      "key_id": .string(assertion.keyID), "assertion_object": .string(assertion.assertionObject ?? ""),
      "client_data_hash": .string(assertion.clientDataHash),
    ])
  }

  public func installationToken() async throws -> String {
    let token = try await attestation.installationToken()
    guard !token.isEmpty else { throw PulsePassportFailure.unauthorized }
    return token
  }

  public func assertion(over hash: Data) async throws -> PulseAppAttestAssertion {
    let assertion = try await attestation.assert(hash)
    try Task.checkCancellation()
    guard !assertion.keyID.isEmpty, assertion.assertionObject?.isEmpty == false,
      assertion.clientDataHash == hash.base64EncodedString()
    else { throw PulsePassportFailure.unauthorized }
    return assertion
  }

  public func validateBaseURL() throws {
    try Task.checkCancellation()
    guard baseURL.scheme == "https", baseURL.host != nil, baseURL.port == nil, baseURL.user == nil,
      baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
      baseURL.path.isEmpty || baseURL.path == "/"
    else { throw PulsePassportFailure.invalidRequest }
  }

  public func postJSON(_ path: String, token: String?, body: Data, expecting statuses: Set<Int>) async throws
    -> (status: Int, body: Data)
  {
    try validateBaseURL()
    let url = baseURL.appendingPathComponent(path)
    var headers = ["Content-Type": "application/json"]
    if let token { headers["Authorization"] = "Bearer " + token }
    let reply: PulseBoundedHTTPResponse
    do {
      reply = try await transport.post(to: url, headers: headers, body: body, maxResponseBytes: 65_536)
    } catch is CancellationError { throw CancellationError() } catch let error as URLError {
      if error.code == .cancelled { throw CancellationError() }
      PulsePassportDiagnostic.transport(.init(path: path), reason: error.code == .timedOut ? .timedOut : .unavailable).record(observer: diagnostic)
      throw error.code == .timedOut ? PulsePassportFailure.timedOut : .unavailable
    } catch is PulseBoundedHTTPTransportError {
      PulsePassportDiagnostic.transport(.init(path: path), reason: .invalidResponse).record(observer: diagnostic)
      throw PulsePassportFailure.invalidResponse
    } catch {
      PulsePassportDiagnostic.transport(.init(path: path), reason: .unavailable).record(observer: diagnostic)
      throw PulsePassportFailure.unavailable
    }
    try Task.checkCancellation()
    let endpoint = PulsePassportDiagnostic.Endpoint(path: path)
    guard reply.body.count <= 65_536 else { throw PulsePassportFailure.invalidResponse }
    PulsePassportDiagnostic.http(endpoint, status: reply.statusCode, reason: Self.failureReason(reply.body)).record(observer: diagnostic)
    try require(reply.responseURL == url, .responseURL, endpoint: endpoint)
    PulsePassportDiagnostic.check(.status, endpoint: endpoint, passed: statuses.contains(reply.statusCode)).record(observer: diagnostic)
    try require(reply.mimeType?.lowercased() == "application/json", .mime, endpoint: endpoint)
    do { _ = try CanonicalJSON.canonicalize(reply.body) } catch {
      PulsePassportDiagnostic.check(.json, endpoint: endpoint, passed: false).record(observer: diagnostic)
      throw PulsePassportFailure.invalidResponse
    }
    PulsePassportDiagnostic.check(.json, endpoint: endpoint, passed: true).record(observer: diagnostic)
    guard statuses.contains(reply.statusCode) else { throw Self.httpFailure(status: reply.statusCode, body: reply.body) }
    return (reply.statusCode, reply.body)
  }

  private func require(_ passed: Bool, _ check: PulsePassportDiagnostic.Check, endpoint: PulsePassportDiagnostic.Endpoint) throws {
    PulsePassportDiagnostic.check(check, endpoint: endpoint, passed: passed).record(observer: diagnostic)
    guard passed else { throw PulsePassportFailure.invalidResponse }
  }

  private func decode<T: Decodable>(_ body: Data, endpoint: PulsePassportDiagnostic.Endpoint) throws -> T {
    do {
      let result = try JSONDecoder().decode(T.self, from: body)
      PulsePassportDiagnostic.check(.body, endpoint: endpoint, passed: true).record(observer: diagnostic)
      return result
    } catch {
      PulsePassportDiagnostic.check(.body, endpoint: endpoint, passed: false).record(observer: diagnostic)
      throw PulsePassportFailure.invalidResponse
    }
  }

  private func decodeNonce(_ body: Data) throws -> PulsePassportNonce {
    struct Reply: Decodable {
      let session_id: String
      let nonce_id: String
      let nonce: String
      let expires_at: String
      let iac_key_id: String
      let workflow: String
      let payload_commitment_hash: String?
    }
    let decoded: Reply = try decode(body, endpoint: .nonce)
    return PulsePassportNonce(
      sessionID: decoded.session_id, nonceID: decoded.nonce_id, nonce: decoded.nonce,
      expiresAt: decoded.expires_at, iacKeyID: decoded.iac_key_id, workflow: decoded.workflow,
      payloadCommitmentHash: decoded.payload_commitment_hash)
  }

  private func decodeVerification(_ body: Data, status: Int, nonce: PulsePassportNonce) throws -> PulsePassportVerification {
    struct Reply: Decodable {
      let session_id: String
      let nonce_id: String
      let status: String
      let validation: PulsePassportValidationReport
      let holder_binding: String?
    }
    let reply: Reply
    do { reply = try JSONDecoder().decode(Reply.self, from: body) } catch {
      PulsePassportDiagnostic.check(.body, endpoint: .verify, passed: false).record(observer: diagnostic)
      // A 403 that is not a validation result is the Worker refusing the request itself.
      if status == 403 { throw Self.httpFailure(status: status, body: body) }; throw PulsePassportFailure.invalidResponse
    }
    PulsePassportDiagnostic.check(.body, endpoint: .verify, passed: true).record(observer: diagnostic)
    guard reply.session_id == nonce.sessionID, reply.nonce_id == nonce.nonceID,
      let verdict = PulsePassportVerification.Status(rawValue: reply.status),
      reply.validation.result == verdict, (verdict == .verified) == (status == 200)
    else {
      PulsePassportDiagnostic.check(.binding, endpoint: .verify, passed: false).record(observer: diagnostic)
      throw PulsePassportFailure.invalidResponse
    }
    PulsePassportDiagnostic.check(.binding, endpoint: .verify, passed: true).record(observer: diagnostic)
    try reply.validation.validate()
    return PulsePassportVerification(
      status: verdict, validator: reply.validation.validator, failureReason: reply.validation.failureReason,
      activeAuthentication: reply.validation.activeAuthentication,
      chipAuthentication: reply.validation.chipAuthentication,
      documentExpired: reply.validation.documentExpired,
      trustBundleVersion: reply.validation.trustBundleVersion, assurance: reply.validation.assurance.rawValue,
      holderBinding: reply.holder_binding, validationReport: reply.validation)
  }

  private static func failureReason(_ body: Data) -> String? {
    struct Envelope: Decodable {
      struct Body: Decodable {
        struct Details: Decodable { let reason: String? }
        let details: Details?
      }
      let error: Body
    }
    // A body that is not the Worker's error envelope still answers by its status alone.
    return try? JSONDecoder().decode(Envelope.self, from: body).error.details?.reason
  }

  public static func classification(_ error: Error) -> PulsePassportFailure? {
    (error as? PulsePassportHTTPFailure)?.classification ?? (error as? PulsePassportFailure)
  }
  private static func httpFailure(status:Int, body:Data) -> PulsePassportHTTPFailure {
    struct Envelope:Decodable { struct Item:Decodable { let code:String?;struct Details:Decodable {let reason:String?};let details:Details? };let error:Item }
    let packet=try? JSONDecoder().decode(Envelope.self,from:body)
    return .init(statusCode:status,code:packet?.error.code,reason:packet?.error.details?.reason,classification:failure(status:status,body:body))
  }
  private static func failure(status: Int, body: Data) -> PulsePassportFailure {
    let reason = failureReason(body)
    switch (status, reason) {
    case (409, "app_attest_assertion_reused"): return .assertionReused
    case (409, "face_attempt_recorded"): return .faceAttemptRecorded
    case (409, "face_passport_unbound"): return .facePassportUnbound
    case (410, _): return .challengeExpired
    case (503, "chip_authentication_unavailable"): return .chipAuthenticationUnavailable
    case (400, "chip_authentication_unsupported"): return .chipAuthenticationUnsupported
    case (400, _), (422, _): return .invalidRequest
    case (401, _): return .unauthorized
    case (403, _): return .forbidden
    case (409, _): return .conflict
    case (429, _): return .rateLimited
    default: return .unavailable
    }
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func base64URLDecoded(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    if base64.count % 4 != 0 { base64.append(String(repeating: "=", count: 4 - base64.count % 4)) }
    return Data(base64Encoded: base64)
  }
}
