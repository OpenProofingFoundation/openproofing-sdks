import CryptoKit
import Foundation
import KenshikiOperationBinding
import XCTest
@testable import KenshikiReference

private actor PassportRegistrationMemory {
    var key: Data?
    var credentials: Data?
    var generated = 0
    var attested = 0
    var rejectSave = false
    func loadKey() -> Data? { key }
    func saveKey(_ value: Data) { key = value }
    func loadCredentials() -> Data? { credentials }
    func saveCredentials(_ value: Data) throws {
        if rejectSave { rejectSave = false; throw PassportServerFailure.credentials }
        credentials = value
    }
    func rejectNextSave() { rejectSave = true }
    func generate() -> String { generated += 1; return "platform-key" }
    func attest(_ digest: Data) -> Data { attested += 1; return digest }
    var keys: RegisteredKeyEnrollmentPorts {
        .init(load: { await self.loadKey() }, save: { await self.saveKey($0) },
            generate: { await self.generate() }, attest: { _, digest in await self.attest(digest) }, assert: { _, digest in digest })
    }
    var storage: PassportRegistrationStorage {
        .init(load: { await self.loadCredentials() }, save: { try await self.saveCredentials($0) })
    }
}

private actor PassportRegistrationWorker: PulseBoundedHTTPTransport {
    enum Behavior { case success, lostFirstRegistration, wrongInstallation, unknownReason, expiredChallenge, recoverySuccess }
    let behavior: Behavior
    private(set) var requests: [(String, Data)] = []
    init(_ behavior: Behavior = .success) { self.behavior = behavior }
    func post(to url: URL, headers: [String: String], body: Data, maxResponseBytes: Int) async throws -> PulseBoundedHTTPResponse {
        requests.append((url.path, body))
        let object: [String: Any]
        var status = 200
        switch url.path {
        case "/api/v1/pulse/app-attest/challenge":
            object = ["challenge": "installation-challenge", "expiresAt": Date().addingTimeInterval(behavior == .expiredChallenge ? -10 : 300).formatted(.iso8601)]
        case "/api/v1/pulse/installations":
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let identifier = try XCTUnwrap(request["clientInstallationId"] as? String)
            if behavior == .lostFirstRegistration, requests.filter({ $0.0 == url.path }).count == 1 { throw URLError(.networkConnectionLost) }
            object = ["installationId": behavior == .wrongInstallation ? "pulse_substitution" : "pulse_" + identifier,
                "token": "installation-token", "tokenType": "Bearer", "expiresAt": NSNull()]
        case "/pulse/installations/key-recovery/v1/challenge" where behavior == .recoverySuccess:
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let initial = try XCTUnwrap(requests.first { $0.0 == "/api/v1/pulse/installations" })
            let installed = try XCTUnwrap(JSONSerialization.jsonObject(with: initial.1) as? [String: Any])
            let clientID = try XCTUnwrap(installed["clientInstallationId"] as? String)
            object = ["v": "pulse.installation-key-recovery-challenge.v1", "request_id": request["request_id"]!,
                "key_id_hash": SealedOperation.sha256(Data("platform-key".utf8)), "application_id": "TEAM.test.app", "environment": "production",
                "service_origin": "https://worker.test", "installation_id": "pulse_" + clientID, "client_installation_id": clientID,
                "challenge_id": UUID().uuidString, "challenge": String(repeating: "a", count: 43),
                "issued_at": Int64(Date().timeIntervalSince1970), "expires_at": Int64(Date().timeIntervalSince1970) + 120]
        case "/pulse/installations/key-recovery/v1" where behavior == .recoverySuccess:
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let challenge = try XCTUnwrap(request["challenge"] as? [String: Any])
            var material = Data("pulse:installation-key-recovery:v1".utf8); material.append(0)
            material.append(try CanonicalJSON.data(withJSONObject: challenge))
            object = ["v": "pulse.installation-key-recovery.v1", "request_id": challenge["request_id"]!,
                "request_digest": SealedOperation.sha256(material), "key_id_hash": challenge["key_id_hash"]!,
                "application_id": "TEAM.test.app", "environment": "production", "service_origin": "https://worker.test",
                "installation_id": challenge["installation_id"]!, "client_installation_id": challenge["client_installation_id"]!,
                "token": "recovered-token", "token_type": "Bearer", "expires_at": NSNull(),
                "credential_lifecycle": "recovered", "production_ready": true]
        case "/pulse/installations/key-recovery/v1/challenge":
            status = 404
            object = ["error": ["code": "not_found", "message": "missing", "details": ["reason": behavior == .unknownReason ? "other" : "installation_key_not_found"]]]
        default: throw PulsePassportFailure.invalidRequest
        }
        return .init(statusCode: status, body: try JSONSerialization.data(withJSONObject: object), responseURL: url, mimeType: "application/json")
    }
}

final class PassportPulseRegistrationTests: XCTestCase {
    func testFreshRegistrationUsesOnePlatformAttestationAndRetainedCredentialsAvoidNetwork() async throws {
        let memory = PassportRegistrationMemory(), worker = PassportRegistrationWorker()
        let registration = await registration(memory, worker)
        let first = try await registration.ensure()
        let second = try await registration.ensure()
        XCTAssertEqual(first.installationID, second.installationID)
        XCTAssertEqual(first.token, second.token)
        let count = await worker.requests.count, generated = await memory.generated, attested = await memory.attested
        XCTAssertEqual(count, 2); XCTAssertEqual(generated, 1); XCTAssertEqual(attested, 1)
        let storedKey = await memory.loadKey()
        let bytes = try XCTUnwrap(storedKey)
        let key = try JSONDecoder().decode(RegisteredKeyEnrollmentRecord.self, from: bytes)
        XCTAssertEqual(key.phase, .registered); XCTAssertNil(key.packet)
        let requests = await worker.requests
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1].1) as? [String: Any])
        let proof = try XCTUnwrap(request["appAttest"] as? [String: String])
        XCTAssertEqual(proof["clientDataHash"], InstallationWriteProof.base64URL(Data(SHA256.hash(data: Data("installation-challenge".utf8)))))
    }

    func testBearerRecoveryPreservesRegisteredInstallationAndKeyWithoutReattestation() async throws {
        let memory = PassportRegistrationMemory(), worker = PassportRegistrationWorker(.recoverySuccess)
        let registration = await registration(memory, worker)
        let original = try await registration.ensure()
        let recovered = try await registration.recoverUnknownInstallationBearer()
        XCTAssertEqual(original.installationID, recovered.installationID)
        XCTAssertEqual(original.appAttestKeyID, recovered.appAttestKeyID)
        XCTAssertEqual(recovered.token, "recovered-token")
        let retained = try await registration.ensure()
        XCTAssertEqual(retained.token, recovered.token)
        let generated = await memory.generated, attested = await memory.attested
        XCTAssertEqual(generated, 1); XCTAssertEqual(attested, 1)
    }

    func testLostRegistrationResponseReplaysExactPacketWithoutReattesting() async throws {
        let memory = PassportRegistrationMemory(), worker = PassportRegistrationWorker(.lostFirstRegistration)
        let registration = await registration(memory, worker)
        do { _ = try await registration.ensure(); XCTFail("Expected response loss") } catch {}
        let result = try await registration.ensure()
        XCTAssertEqual(result.token, "installation-token")
        let requests = await worker.requests
        let submitted = requests.filter { $0.0 == "/api/v1/pulse/installations" }
        XCTAssertEqual(submitted.count, 2); XCTAssertEqual(submitted.first?.1, submitted.last?.1)
        let attested = await memory.attested
        XCTAssertEqual(attested, 1)
    }

    func testCredentialWriteFailureCanReplayWithoutReplacingOrReattestingKey() async throws {
        let memory = PassportRegistrationMemory(), worker = PassportRegistrationWorker()
        await memory.rejectNextSave()
        let registration = await registration(memory, worker)
        do { _ = try await registration.ensure(); XCTFail("Expected persistence failure") } catch {}
        _ = try await registration.ensure()
        let generated = await memory.generated, attested = await memory.attested
        XCTAssertEqual(generated, 1); XCTAssertEqual(attested, 1)
        let submitted = await worker.requests.filter { $0.0 == "/api/v1/pulse/installations" }
        XCTAssertEqual(submitted.count, 2); XCTAssertEqual(submitted.first?.1, submitted.last?.1)
    }

    func testWrongInstallationResponseNeverPersistsBearer() async throws {
        let memory = PassportRegistrationMemory(), worker = PassportRegistrationWorker(.wrongInstallation)
        let registration = await registration(memory, worker)
        do { _ = try await registration.ensure(); XCTFail("Expected binding refusal") } catch {}
        let credentials = await memory.loadCredentials()
        XCTAssertNil(credentials)
    }

    func testExpiredChallengeNeverCallsPlatformAttestation() async throws {
        let memory = PassportRegistrationMemory(), worker = PassportRegistrationWorker(.expiredChallenge)
        let registration = await registration(memory, worker)
        do { _ = try await registration.ensure(); XCTFail("Expected expiry refusal") } catch {}
        let attested = await memory.attested
        XCTAssertEqual(attested, 0)
        let requests = await worker.requests
        XCTAssertEqual(requests.map(\.0), ["/api/v1/pulse/app-attest/challenge"])
    }

    func testGenericRecovery404NeverAuthorizesRegistrationPacketReplay() async throws {
        let memory = PassportRegistrationMemory(), worker = PassportRegistrationWorker(.unknownReason)
        await memory.rejectNextSave()
        let registration = await registration(memory, worker)
        do { _ = try await registration.ensure(); XCTFail("Expected persistence failure") } catch {}
        do { _ = try await registration.ensure(); XCTFail("Expected explicit unknown-key refusal") } catch {}
        let submitted = await worker.requests.filter { $0.0 == "/api/v1/pulse/installations" }
        XCTAssertEqual(submitted.count, 1)
        let attested = await memory.attested
        XCTAssertEqual(attested, 1)
    }

    private func registration(_ memory: PassportRegistrationMemory, _ worker: PassportRegistrationWorker) async -> PassportPulseRegistration {
        let slot = PassportRegistrationSlot(service: "test", account: "test", group: "test")
        return PassportPulseRegistration(configuration: .init(baseURL: URL(string: "https://worker.test")!,
            appAttestEnvironment: "production", applicationIdentifier: "TEAM.test.app"), credentialSlot: slot, keySlot: slot,
            transport: worker, app: .init(platform: "ios", appVersion: "1", buildNumber: "1", sdkVersion: "1", locale: "en"),
            device: .init(deviceClass: "iPhone", osMajorVersion: 18, modelClass: "phone"),
            storage: await memory.storage, keys: await memory.keys)
    }
}
