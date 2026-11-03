import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif
import XCTest
@testable import KenshikiPulsePassport

actor PassportHTTPProbe: PulseBoundedHTTPTransport {
    struct Request: Sendable {let path:String;let body:Data;let authorization:String?}
    enum Reply: Sendable {case json(Int,Data),failure(PulsePassportFailure),paused(Int,Data)}
    var replies:[String:[Reply]] = [:]
    var requests:[Request]=[]
    var suspended:CheckedContinuation<Void,Never>?
    var observer:CheckedContinuation<Void,Never>?
    func enqueue(_ path:String,_ reply:Reply) {replies[path,default:[]].append(reply)}
    func post(to url:URL,headers:[String:String],body:Data,maxResponseBytes:Int) async throws->PulseBoundedHTTPResponse {
        requests.append(.init(path:url.path,body:body,authorization:headers["Authorization"]))
        guard var queue=replies[url.path],!queue.isEmpty else {throw PulsePassportFailure.invalidResponse}
        let reply=queue.removeFirst();replies[url.path]=queue
        let status:Int,data:Data
        switch reply {
        case .failure(let failure):throw failure
        case .json(let value,let bytes):status=value;data=bytes
        case .paused(let value,let bytes):
            status=value;data=bytes
            await withCheckedContinuation {suspended=$0;observer?.resume();observer=nil}
        }
        return .init(statusCode:status,body:data,responseURL:url,mimeType:"application/json")
    }
    func waitUntilPaused() async {if suspended != nil {return};await withCheckedContinuation{observer=$0}}
    func release() {suspended?.resume();suspended=nil}
    func captured()->[Request] {requests}
}

private final class PassportDiagnosticProbe:@unchecked Sendable {
    private let lock=NSLock()
    private var records:[PulsePassportDiagnostic]=[]
    func append(_ record:PulsePassportDiagnostic) {lock.lock();defer{lock.unlock()};records.append(record)}
    func messages()->[String] {lock.lock();defer{lock.unlock()};return records.map(\.message)}
}

@MainActor final class PulsePassportServiceTests:XCTestCase {
    let fixed=Date(timeIntervalSince1970:1_788_361_200)
    let fresh="2030-09-04T12:00:00Z"
    func data(_ value:[String:Any])->Data {try! JSONSerialization.data(withJSONObject:value,options:.sortedKeys)}
    func session(_ id:String="session-1",expiry:String?=nil)->Data {data(["session_id":id,"nonce":"session-secret","expires_at":expiry ?? fresh])}
    func nonce(_ id:String="session-1",expiry:String?=nil)->Data {data(["session_id":id,"nonce_id":"nonce-"+id,"nonce":"challenge-"+id,"expires_at":expiry ?? fresh,"iac_key_id":"iac-key","workflow":"passport_identity","payload_commitment_hash":NSNull()])}
    func verdict(_ id:String="session-1",failed:Bool=false)->Data {
        var report:[String:Any]=["result":failed ? "failed":"verified","validator":"passport_validator","sodVerified":true,"dscVerified":true,"cscaVerified":true,"dataGroupHashesVerified":true,"chipAuthenticated":false,"activeAuthentication":false,"chipAuthentication":false,"crlChecked":true,"documentExpired":false,"trustBundleVersion":"usa-test","trustManifestSha256":String(repeating:"a",count:64),"assurance":failed ? "unverified":"passive_authentication_only"]
        if failed {report["failureReason"]="sod_signature_invalid"}
        return data(["session_id":id,"nonce_id":"nonce-"+id,"status":failed ? "failed":"verified","validation":report,"holder_binding":String(repeating:"b",count:43)])
    }
    func client(_ probe:PassportHTTPProbe,assert:@escaping @Sendable(Data)async throws->PulseAppAttestAssertion = { hash in .init(keyID:"key",clientDataHash:hash.base64EncodedString(),assertionObject:"assertion") })->PulsePassportClient {
        let date=fixed
        return .init(baseURL:URL(string:"https://id.example.test")!,deviceID:"pulse_installation",attestation:.init(installationToken:{"token"},assert:assert),transport:probe,now:{date})
    }
    func service(_ probe:PassportHTTPProbe)->PulsePassportService {
        let value=client(probe);var sequence=0
        return .init(client:{value},now:{self.fixed},operationID:{sequence+=1;return "attempt-\(sequence)"})
    }
    func ready(_ probe:PassportHTTPProbe,_ id:String="session-1") async {
        await probe.enqueue("/identity/sessions",.json(201,session(id)))
        await probe.enqueue("/passport/nonce",.json(201,nonce(id)))
    }
    func proof()->PulsePassportRead<String> {.init(read:"read",proof:.init(securityObject:Data([1]),documentSigningCertificate:Data([2]),dataGroups:["DG1":Data([3]),"DG2":Data([4])],activeAuthenticationChallenge:nil,activeAuthenticationSignature:nil),chipAuthenticationResponse:nil)}
    func error<T>(_ operation:()async throws->T) async->Error {
        do {_ = try await operation();XCTFail("Expected failure");return PulsePassportFailure.invalidResponse} catch {return error}
    }
    func operations(_ requests:[PassportHTTPProbe.Request])->[(String,String)] {requests.filter{$0.path=="/identity/sessions"}.map{let body=try! JSONSerialization.jsonObject(with:$0.body) as! [String:Any];return(body["operation_id"] as! String,body["issued_at"] as! String)}}

    func testFirstPreparationThenPositioningRetryReusesThePreparedChallenge() async throws {
        let probe=PassportHTTPProbe();await ready(probe);let owner=service(probe)
        let first=try await owner.prepare(binding:"document");let retry=try await owner.prepare(binding:"document")
        XCTAssertEqual(first.nonce,retry.nonce);let requests=await probe.captured();XCTAssertEqual(requests.count,2)
    }
    func testAmbiguousTransportFailureReplaysTheExactCompleteAttempt() async throws {
        let probe=PassportHTTPProbe();await probe.enqueue("/identity/sessions",.failure(.unavailable));await ready(probe);let owner=service(probe)
        _ = await error{try await owner.prepare(binding:"document")};_ = try await owner.prepare(binding:"document")
        let attempts=operations(await probe.captured());XCTAssertEqual(attempts.count,2);XCTAssertEqual(attempts[0].0,attempts[1].0);XCTAssertEqual(attempts[0].1,attempts[1].1)
    }
    func testConflictAutomaticallyRotatesOnlyOnceAtTheOrchestrationBoundary() async {
        await boundedHTTP(status:409,code:"invalid_state_transition",reason:"identity_session_create_idempotency_conflict")
    }
    func testRepeatedStaleSignedAttemptStopsBeforeThirdAutomaticAttempt() async {
        await boundedHTTP(status:403,code:"verification_failed",reason:"invalid_issued_at")
    }
    func boundedHTTP(status:Int,code:String,reason:String) async {
        let probe=PassportHTTPProbe();let packet=data(["error":["code":code,"details":["reason":reason]]])
        for _ in 0..<3 {await probe.enqueue("/identity/sessions",.json(status,packet))}
        let failure=await error{try await self.service(probe).prepare(binding:"document")}
        XCTAssertEqual((failure as? PulsePassportHTTPFailure)?.reason,reason)
        let attempts=operations(await probe.captured());XCTAssertEqual(attempts.count,2);XCTAssertNotEqual(attempts[0].0,attempts[1].0)
    }
    func testExpiredPreparedChallengeRotatesTheWholeAttemptBeforeRetry() async throws {
        let probe=PassportHTTPProbe();await probe.enqueue("/identity/sessions",.json(201,session()))
        await probe.enqueue("/passport/nonce",.json(201,nonce(expiry:"2020-01-01T00:00:00Z")));await ready(probe,"fresh")
        let result=try await service(probe).prepare(binding:"document");XCTAssertEqual(result.session.sessionID,"fresh")
        let attempts=operations(await probe.captured());XCTAssertEqual(attempts.count,2);XCTAssertNotEqual(attempts[0].0,attempts[1].0)
    }
    func testRepeatedExpiredPreparedChallengeStopsWithTheTruthfulExpiryError() async {
        let probe=PassportHTTPProbe()
        for _ in 0..<3 {await probe.enqueue("/identity/sessions",.json(201,session()));await probe.enqueue("/passport/nonce",.json(201,nonce(expiry:"2020-01-01T00:00:00Z")))}
        let failure=await error{try await self.service(probe).prepare(binding:"document")}
        XCTAssertEqual(failure as? PulsePassportFailure,.challengeExpired);let attempts=operations(await probe.captured());XCTAssertEqual(attempts.count,2)
    }
    func testStaleSignedAttemptRotatesToFreshTimestampAndRetries() async throws {
        let probe=PassportHTTPProbe();await probe.enqueue("/identity/sessions",.json(403,data(["error":["code":"verification_failed","details":["reason":"invalid_issued_at"]]])));await ready(probe)
        let client=client(probe);var clock=fixed;var sequence=0
        let owner=PulsePassportService(client:{client},now:{defer{clock=clock.addingTimeInterval(1)};return clock},operationID:{sequence+=1;return "operation-\(sequence)"})
        _ = try await owner.prepare(binding:"document")
        let attempts=operations(await probe.captured());XCTAssertEqual(attempts.count,2);XCTAssertNotEqual(attempts[0].0,attempts[1].0)
        XCTAssertNotEqual(attempts[0].1,attempts[1].1)
        XCTAssertGreaterThan(try XCTUnwrap(PulsePassportClock.date(attempts[1].1)),try XCTUnwrap(PulsePassportClock.date(attempts[0].1)))
    }
    func testConcurrentPreparationCoalescesAndStaleFailureCannotOverwriteCurrentPreparation() async throws {
        let probe=PassportHTTPProbe();await probe.enqueue("/identity/sessions",.paused(503,data(["error":["code":"temporarily_unavailable"]])));let owner=service(probe)
        let stale=Task {try await owner.prepare(binding:"old")};await probe.waitUntilPaused()
        await ready(probe,"fresh");let current=try await owner.prepare(binding:"new")
        await probe.release();let staleError=await error{try await stale.value};XCTAssertTrue(staleError is CancellationError)
        let reused=try await owner.prepare(binding:"new");XCTAssertEqual(current.nonce,reused.nonce)
    }
    func testDuplicateConcurrentPrepareUsesOneRequestPair() async throws {
        let probe=PassportHTTPProbe();await probe.enqueue("/identity/sessions",.paused(201,session()));await probe.enqueue("/passport/nonce",.json(201,nonce()));let owner=service(probe)
        let first=Task{try await owner.prepare(binding:"document")};await probe.waitUntilPaused()
        let second=Task{try await owner.prepare(binding:"document")};await Task.yield();await probe.release()
        let a=try await first.value,b=try await second.value;XCTAssertEqual(a.nonce,b.nonce);let requests=await probe.captured();XCTAssertEqual(requests.count,2)
    }
    func testDeliveredReadAdmissionFailureRetiresNonceWithoutHTTPVerification() async throws {
        enum Admission:Error {case mismatch}
        let probe=PassportHTTPProbe();await ready(probe);await ready(probe,"next");let owner=service(probe);let prepared=try await owner.prepare(binding:"document")
        let failure=await error{try await owner.verify(self.proof(),prepared:prepared,admit:{_ in throw Admission.mismatch})}
        XCTAssertTrue(failure is Admission);let next=try await owner.prepare(binding:"document");XCTAssertNotEqual(next.nonce,prepared.nonce)
        let requests=await probe.captured();XCTAssertFalse(requests.contains{$0.path=="/passport/verify"})
    }
    func testLateVerificationSuccessAndFailureCannotAcceptIntoNewPreparation() async throws {
        for failed in [false,true] {
            let probe=PassportHTTPProbe();await ready(probe);let owner=service(probe);let prepared=try await owner.prepare(binding:"document")
            await probe.enqueue("/passport/verify",.paused(failed ? 403:200,verdict(failed:failed)))
            let old=Task{try await owner.verify(self.proof(),prepared:prepared,admit:{_ in})};await probe.waitUntilPaused()
            await ready(probe,"next");let current=try await owner.prepare(binding:"document");await probe.release()
            let failure=await error{try await old.value};XCTAssertTrue(failure is CancellationError)
            let retry=try await owner.prepare(binding:"document");XCTAssertEqual(current.nonce,retry.nonce)
        }
    }
    func testServerExpiredCAChallengeRetiresCachedNonceWithoutStartingSessionInsideRead() async throws {
        let probe=PassportHTTPProbe();await ready(probe);let owner=service(probe);let prepared=try await owner.prepare(binding:"document")
        await probe.enqueue("/passport/chip-authentication",.json(410,data(["error":["code":"challenge_expired"]])))
        _ = await error{try await owner.chipAuthenticationChallenge(prepared:prepared,dg14:Data([1]))}
        let before=await probe.captured();XCTAssertEqual(before.count,3)
        await ready(probe,"next");let next=try await owner.prepare(binding:"document");XCTAssertNotEqual(next.nonce,prepared.nonce)
    }
    func testCapabilityAndExactVerifiedDTOStayOutOfPublicReportExport() async throws {
        let probe=PassportHTTPProbe();await ready(probe);await probe.enqueue("/passport/verify",.json(200,verdict()));let owner=service(probe)
        let accepted=try await owner.runRead(binding:"document",read:{_,_ in self.proof()},admit:{_ in})
        XCTAssertEqual(accepted.verification.holderBinding,String(repeating:"b",count:43))
        let capability=try XCTUnwrap(accepted.acceptance.holderCapability);let bytes=try capability.protectedRepresentation()
        XCTAssertEqual(try PulsePassportHolderCapability.restore(bytes,expectedOrigin:accepted.acceptance.origin,installationID:accepted.acceptance.installationID,securityObjectSHA256:accepted.acceptance.securityObjectSHA256),capability)
        XCTAssertThrowsError(try PulsePassportHolderCapability.restore(bytes,expectedOrigin:accepted.acceptance.origin,installationID:"other",securityObjectSHA256:accepted.acceptance.securityObjectSHA256))
        XCTAssertThrowsError(try PulsePassportHolderCapability.restore(bytes,expectedOrigin:URL(string:"https://other.example.test")!,installationID:accepted.acceptance.installationID,securityObjectSHA256:accepted.acceptance.securityObjectSHA256))
        XCTAssertThrowsError(try PulsePassportHolderCapability.restore(bytes,expectedOrigin:accepted.acceptance.origin,installationID:accepted.acceptance.installationID,securityObjectSHA256:String(repeating:"f",count:64)))
        let exported=try JSONSerialization.data(withJSONObject:accepted.acceptance.report.exportObject)
        XCTAssertFalse(String(decoding:exported,as:UTF8.self).contains(String(repeating:"b",count:43)))
    }
    func testClientRejectsMalformedExpiryButClassifiesParsedExpiredSession() async {
        for expiry in ["not-a-date","2020-01-01T00:00:00Z"] {
            let probe=PassportHTTPProbe();await probe.enqueue("/identity/sessions",.json(201,session(expiry:expiry)))
            let failure=await error{try await self.client(probe).openSession(operationID:"attempt",issuedAt:self.fixed)}
            XCTAssertEqual(failure as? PulsePassportFailure,expiry=="not-a-date" ? .invalidResponse:.challengeExpired)
        }
    }
    func testPublicTransportSeamValidatesOriginAndIndependentResponseBound() async {
        let probe=PassportHTTPProbe();await probe.enqueue("/anything",.json(200,Data(repeating:32,count:65_537)))
        let failure=await error{try await self.client(probe).postJSON("anything",token:nil,body:Data(),expecting:[200])}
        XCTAssertEqual(failure as? PulsePassportFailure,.invalidResponse)
        let invalid=PulsePassportClient(baseURL:URL(string:"http://id.example.test")!,deviceID:"device",attestation:.init(installationToken:{"token"},assert:{_ in throw PulsePassportFailure.invalidResponse}),transport:probe)
        let refused=await error{try await invalid.postJSON("anything",token:nil,body:Data(),expecting:[200])}
        XCTAssertEqual(refused as? PulsePassportFailure,.invalidRequest)
        let requests=await probe.captured();XCTAssertEqual(requests.count,1)
    }
    func testCancellationAfterAssertionDoesNotCreateASessionOrNonce() async {
        let probe=PassportHTTPProbe()
        let value=client(probe,assert:{hash in
            withUnsafeCurrentTask{$0?.cancel()}
            return .init(keyID:"key",clientDataHash:hash.base64EncodedString(),assertionObject:"assertion")
        })
        let owner=PulsePassportService(client:{value})
        let failure=await error{try await owner.prepare(binding:"document")}
        XCTAssertTrue(failure is CancellationError);let requests=await probe.captured();XCTAssertTrue(requests.isEmpty)
    }
    func testCancellationBeforeDeadKeyFailureDoesNotRecoverOrContinuePreparation() async {
        #if canImport(DeviceCheck)
        let probe=PassportHTTPProbe();var recoveries=0
        let value=client(probe,assert:{_ in
            withUnsafeCurrentTask{$0?.cancel()}
            throw NSError(domain:DCError.errorDomain,code:DCError.Code.invalidKey.rawValue)
        })
        let owner=PulsePassportService(client:{value},recoverDeadKey:{_ in recoveries+=1;return value})
        let failure=await error{try await owner.prepare(binding:"document")}
        XCTAssertTrue(failure is CancellationError);XCTAssertEqual(recoveries,0)
        let requests=await probe.captured();XCTAssertTrue(requests.isEmpty)
        #endif
    }
    func testRecoveredIdentityFlowsThroughCreateAndNonceWithTheOriginalAttempt() async throws {
        #if canImport(DeviceCheck)
        let probe=PassportHTTPProbe();await ready(probe);let date=fixed
        let stale=client(probe,assert:{_ in throw NSError(domain:DCError.errorDomain,code:DCError.Code.invalidKey.rawValue)})
        let fresh=PulsePassportClient(baseURL:URL(string:"https://id.example.test")!,deviceID:"fresh-installation",attestation:.init(installationToken:{"fresh-token"},assert:{hash in .init(keyID:"fresh-key",clientDataHash:hash.base64EncodedString(),assertionObject:"assertion")}),transport:probe,now:{date})
        var recoveries=0
        var recoveringOwner:PulsePassportService?
        let owner=PulsePassportService(client:{stale},recoverDeadKey:{_ in
            recoveries+=1;recoveringOwner?.installationDidChange(to:fresh.deviceID);return fresh
        },now:{date},operationID:{"exact-attempt"})
        recoveringOwner=owner
        let prepared=try await owner.prepare(binding:"document");XCTAssertEqual(prepared.installationID,"fresh-installation");XCTAssertEqual(recoveries,1)
        let requests=await probe.captured();XCTAssertEqual(requests.count,2)
        for request in requests {let body=try JSONSerialization.jsonObject(with:request.body) as! [String:Any];XCTAssertEqual(body["device_id"] as? String,"fresh-installation")}
        XCTAssertEqual(operations(requests).first?.0,"exact-attempt")
        #endif
    }
    func testPreparationBoundariesPreserveOriginalTypedErrors() async {
        struct Marker:Error {}
        let probe=PassportHTTPProbe();let owner=PulsePassportService(client:{throw Marker()});var stage:PulsePassportPreparationStage?
        let load=await error{try await owner.prepare(binding:"document",onStage:{stage=$0})};XCTAssertTrue(load is Marker);XCTAssertEqual(stage,.credentials)
        let value=client(probe,assert:{_ in throw Marker()})
        let assertionOwner=PulsePassportService(client:{value})
        let assertion=await error{try await assertionOwner.prepare(binding:"document",onStage:{stage=$0})};XCTAssertTrue(assertion is Marker);XCTAssertEqual(stage,.appAttestAssertion)
        #if canImport(DeviceCheck)
        let dead=client(probe,assert:{_ in throw NSError(domain:DCError.errorDomain,code:DCError.Code.invalidKey.rawValue)})
        let recoveryOwner=PulsePassportService(client:{dead},recoverDeadKey:{_ in throw Marker()})
        let recovery=await error{try await recoveryOwner.prepare(binding:"document",onStage:{stage=$0})};XCTAssertTrue(recovery is Marker);XCTAssertEqual(stage,.recoverIdentity)
        #endif
        for path in ["/identity/sessions","/passport/nonce"] {
            let other=PassportHTTPProbe();if path=="/passport/nonce" {await other.enqueue("/identity/sessions",.json(201,session()))}
            await other.enqueue(path,.json(503,data(["error":["code":"temporarily_unavailable","details":["reason":"passport_validator_unavailable"]]])))
            let failure=await error{try await self.service(other).prepare(binding:"document",onStage:{stage=$0})}
            XCTAssertEqual((failure as? PulsePassportHTTPFailure)?.statusCode,503)
            XCTAssertEqual(stage,path=="/identity/sessions" ? .session:.nonce)
        }
    }
    func testInstallationChangeInvalidatesRetainedCeremony() async throws {
        let probe=PassportHTTPProbe();await ready(probe);let owner=service(probe);let prepared=try await owner.prepare(binding:"document")
        owner.installationDidChange(to:"replacement-installation")
        let failure=await error{try await owner.verify(self.proof(),prepared:prepared,admit:{_ in})}
        guard case PulsePassportServiceFailure.invalidated=failure else {return XCTFail("Expected invalidation")}
        let requests=await probe.captured();XCTAssertEqual(requests.count,2)
    }

    func testExternalInstallationRotationDuringCreateOrNonceCannotPublishPreparedCeremony() async throws {
        for path in ["/identity/sessions","/passport/nonce"] {
            let probe=PassportHTTPProbe()
            if path=="/identity/sessions" {await probe.enqueue(path,.paused(201,session()))}
            else {await probe.enqueue("/identity/sessions",.json(201,session()));await probe.enqueue(path,.paused(201,nonce()))}
            let service=service(probe)
            let preparing=Task{try await service.prepare(binding:"document")};await probe.waitUntilPaused()
            service.installationDidChange(to:"rotated-installation");await probe.release()
            let failure=await error{try await preparing.value}
            guard case PulsePassportServiceFailure.invalidated=failure else {XCTFail("Stale preparation must be invalidated");continue}
            let requests=await probe.captured();XCTAssertEqual(requests.count,path=="/identity/sessions" ? 1:2)
        }
    }

    func testDiagnosticContainsOnlyStableEndpointAndWorkerClassification() async {
        let probe=PassportHTTPProbe(),diagnostics=PassportDiagnosticProbe()
        await probe.enqueue("/identity/sessions",.json(503,data(["error":["code":"temporarily_unavailable","message":"private-document-provider-prose","details":["reason":"private-document-reason"]]])))
        let value=PulsePassportClient(baseURL:URL(string:"https://id.example.test")!,deviceID:"private-installation",attestation:.init(installationToken:{"private-token"},assert:{hash in .init(keyID:"private-key",clientDataHash:hash.base64EncodedString(),assertionObject:"private-assertion")}),transport:probe,diagnostic:{diagnostics.append($0)})
        let failure=await error{try await value.openSession(operationID:"private-operation",issuedAt:self.fixed)}
        XCTAssertEqual((failure as? PulsePassportHTTPFailure)?.reason,"private-document-reason")
        let messages=diagnostics.messages().joined(separator:"\n")
        XCTAssertTrue(messages.contains("endpoint=/identity/sessions http=503 reason=unknown:sha256:"))
        for secret in ["private-document","private-installation","private-token","private-key","private-assertion","private-operation"] {XCTAssertFalse(messages.contains(secret))}
    }

    func testTypedStagesFollowActualPreparationAndReentrantObserverCannotSubmit() async throws {
        let probe=PassportHTTPProbe();await ready(probe);let owner=service(probe);var stages:[PulsePassportPreparationStage]=[]
        _ = try await owner.prepare(binding:"document",onStage:{stages.append($0)})
        XCTAssertEqual(stages,[.credentials,.appAttestAssertion,.session,.nonce])
        let other=PassportHTTPProbe(),cancelled=service(other)
        let failure=await error{try await cancelled.prepare(binding:"document",onStage:{stage in if stage == .appAttestAssertion {cancelled.invalidate()}})}
        XCTAssertTrue(failure is CancellationError);let requests=await other.captured();XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationAfterDeliveredReadRetiresOnlyItsCurrentChallengeWithoutVerification() async throws {
        let probe=PassportHTTPProbe();await ready(probe);await ready(probe,"next");let owner=service(probe)
        let prepared=try await owner.prepare(binding:"document")
        let cancelled=Task {
            withUnsafeCurrentTask{$0?.cancel()}
            return try await owner.verify(self.proof(),prepared:prepared,admit:{_ in XCTFail("Cancelled read cannot enter admission")})
        }
        let failure=await error{try await cancelled.value};XCTAssertTrue(failure is CancellationError)
        let next=try await owner.prepare(binding:"document");XCTAssertNotEqual(next.nonce,prepared.nonce)
        let requests=await probe.captured();XCTAssertFalse(requests.contains{$0.path=="/passport/verify"})
        let foreign=Task {
            withUnsafeCurrentTask{$0?.cancel()}
            return try await owner.verify(self.proof(),prepared:prepared,admit:{_ in XCTFail("Foreign read cannot enter admission")})
        }
        _ = await error{try await foreign.value}
        let stillCurrent=try await owner.prepare(binding:"document");XCTAssertEqual(stillCurrent.nonce,next.nonce)
    }

    func testIssuedNonceAcceptedReadPreservesWorkflowCommitmentAndUsesOnlyExistingVerify() async throws {
        let probe=PassportHTTPProbe();await probe.enqueue("/passport/verify",.json(200,verdict("qr-session")))
        let issued=PulsePassportNonce(sessionID:"qr-session",nonceID:"nonce-qr-session",nonce:"qr-challenge",expiresAt:fresh,iacKeyID:"qr-key",workflow:"nfc_passport",payloadCommitmentHash:"exact-commitment")
        let accepted=try await PulsePassportService.verifyIssuedRead(proof(),nonce:issued,client:client(probe),admit:{_ in},now:{self.fixed})
        XCTAssertEqual(accepted.acceptance.sessionID,issued.sessionID);XCTAssertEqual(accepted.acceptance.nonceID,issued.nonceID);XCTAssertEqual(accepted.acceptance.clientReceivedAt,fixed)
        XCTAssertEqual(accepted.verification.validationReport,accepted.acceptance.report);XCTAssertNotNil(accepted.acceptance.holderCapability)
        let requests=await probe.captured();XCTAssertEqual(requests.map(\.path),["/passport/verify"])
        let body=try JSONSerialization.jsonObject(with:requests[0].body) as! [String:Any]
        let payload=try JSONSerialization.jsonObject(with:Data((body["payload_json"] as! String).utf8)) as! [String:Any]
        XCTAssertEqual(payload["workflow"] as? String,"nfc_passport");XCTAssertEqual(payload["payload_commitment_hash"] as? String,"exact-commitment")
    }
    func testIssuedNonceAdmissionAndForeignResponseCannotManufactureAcceptance() async throws {
        enum Refusal:Error {case mismatch}
        let probe=PassportHTTPProbe();await probe.enqueue("/passport/verify",.json(200,verdict("foreign")))
        let nonce=PulsePassportNonce(sessionID:"qr-session",nonceID:"nonce-qr-session",nonce:"challenge",expiresAt:fresh,iacKeyID:"qr-key",workflow:"passport_identity",payloadCommitmentHash:nil)
        let denied=await error{try await PulsePassportService.verifyIssuedRead(self.proof(),nonce:nonce,client:self.client(probe),admit:{_ in throw Refusal.mismatch})}
        XCTAssertTrue(denied is Refusal);let before=await probe.captured();XCTAssertTrue(before.isEmpty)
        let foreign=await error{try await PulsePassportService.verifyIssuedRead(self.proof(),nonce:nonce,client:self.client(probe),admit:{_ in})}
        XCTAssertEqual(foreign as? PulsePassportFailure,.invalidResponse)
    }
    func testVerifiedHTTPAndStoredReportRejectContradictoryFailureReason() async throws {
        let probe=PassportHTTPProbe();var packet=try JSONSerialization.jsonObject(with:verdict()) as! [String:Any]
        var report=packet["validation"] as! [String:Any];report["failureReason"]="sod_signature_invalid";packet["validation"]=report
        await ready(probe);await probe.enqueue("/passport/verify",.json(200,data(packet)))
        let failure=await error{try await self.service(probe).runRead(binding:"document",read:{_,_ in self.proof()},admit:{_ in})}
        XCTAssertEqual(failure as? PulsePassportFailure,.invalidResponse)
        let decoded=try JSONDecoder().decode(PulsePassportValidationReport.self,from:data(report));XCTAssertThrowsError(try decoded.validate())
    }

    func testDeliveredLocalRefusalDiscardsOnlyExactGenerationEvenWhenCancelled() async throws {
        let probe=PassportHTTPProbe();await ready(probe);await ready(probe,"next");let owner=service(probe)
        let old=try await owner.prepare(binding:"document")
        let refusal=Task {withUnsafeCurrentTask{$0?.cancel()};try owner.discardDeliveredRead(prepared:old)}
        try await refusal.value
        let current=try await owner.prepare(binding:"document");XCTAssertNotEqual(current.nonce,old.nonce)
        let stale=await error{try owner.discardDeliveredRead(prepared:old)}
        guard case PulsePassportServiceFailure.invalidated=stale else {return XCTFail("Old delivery consumed newer ceremony")}
        let stillCurrent=try await owner.prepare(binding:"document");XCTAssertEqual(current.nonce,stillCurrent.nonce)
        let requests=await probe.captured();XCTAssertFalse(requests.contains{$0.path=="/passport/verify"})
    }
    func testPositioningCancellationWithoutDeliveredResultRetainsPreparedChallenge() async throws {
        let probe=PassportHTTPProbe();await ready(probe);let owner=service(probe)
        let first=try await owner.prepare(binding:"document")
        let failure=await error{try await owner.runRead(binding:"document",read:{_,_ -> PulsePassportRead<String> in throw CancellationError()},admit:{_ in})}
        XCTAssertTrue(failure is CancellationError)
        let next=try await owner.prepare(binding:"document");XCTAssertEqual(first.nonce,next.nonce)
        let requests=await probe.captured();XCTAssertEqual(requests.count,2)
    }
    func testCoalescedWaitersReplayStageAndCancelledObserverCannotReceiveLaterFailureStage() async throws {
        let probe=PassportHTTPProbe();await probe.enqueue("/identity/sessions",.paused(201,session()))
        await probe.enqueue("/passport/nonce",.json(503,data(["error":["code":"temporarily_unavailable"]])))
        let owner=service(probe);var firstStages:[PulsePassportPreparationStage]=[],secondStages:[PulsePassportPreparationStage]=[]
        let first=Task{try await owner.prepare(binding:"document",onStage:{firstStages.append($0)})};await probe.waitUntilPaused()
        let replay=expectation(description:"Coalesced waiter receives current session stage")
        let second=Task{try await owner.prepare(binding:"document",onStage:{stage in secondStages.append(stage);if stage == .session {replay.fulfill()}})}
        await fulfillment(of:[replay],timeout:2)
        first.cancel();await probe.release()
        let cancelled=await error{try await first.value},current=await error{try await second.value}
        XCTAssertTrue(cancelled is CancellationError);XCTAssertEqual((current as? PulsePassportHTTPFailure)?.statusCode,503)
        XCTAssertEqual(secondStages,[.session,.nonce]);XCTAssertFalse(firstStages.contains(.nonce))
        let requests=await probe.captured();XCTAssertEqual(requests.count,2)
    }
    func testDelayedOwnRecoveryNoticeWorksButInterveningForeignNoticeRemainsAuthoritative() async throws {
        #if canImport(DeviceCheck)
        for foreign in [false,true] {
            let probe=PassportHTTPProbe();await ready(probe);let date=fixed
            let old=client(probe,assert:{_ in throw NSError(domain:DCError.errorDomain,code:DCError.Code.invalidKey.rawValue)})
            let fresh=PulsePassportClient(baseURL:URL(string:"https://id.example.test")!,deviceID:"fresh-installation",attestation:.init(installationToken:{"fresh-token"},assert:{hash in .init(keyID:"fresh-key",clientDataHash:hash.base64EncodedString(),assertionObject:"assertion")}),transport:probe,now:{date})
            var owned:PulsePassportService?
            let owner=PulsePassportService(client:{old},recoverDeadKey:{_ in if foreign {owned?.installationDidChange(to:"foreign-installation")};return fresh},now:{date})
            owned=owner;owner.installationDidChange(to:old.deviceID)
            if foreign {
                let failure=await error{try await owner.prepare(binding:"document")}
                guard case PulsePassportServiceFailure.invalidated=failure else {XCTFail("Foreign notification was overwritten");continue}
                let requests=await probe.captured();XCTAssertTrue(requests.isEmpty)
            } else {
                let prepared=try await owner.prepare(binding:"document");XCTAssertEqual(prepared.installationID,fresh.deviceID)
                owner.installationDidChange(to:fresh.deviceID)
                let reused=try await owner.prepare(binding:"document");XCTAssertEqual(prepared.nonce,reused.nonce)
            }
        }
        #endif
    }

}
