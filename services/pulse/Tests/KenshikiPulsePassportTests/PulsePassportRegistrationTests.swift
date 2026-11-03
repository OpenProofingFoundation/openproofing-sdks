import CryptoKit
import Foundation
import KenshikiOperationBinding
import XCTest
#if canImport(DeviceCheck)
import DeviceCheck
#endif
@testable import KenshikiPulsePassport

private final class RegistrationOrderProbe:@unchecked Sendable {
    private let lock=NSLock()
    private var events:[String]=[]
    func record(_ event:String) {lock.lock();events.append(event);lock.unlock()}
    func snapshot()->[String] {lock.lock();defer{lock.unlock()};return events}
}

private actor RegistrationMemory {
    let order:RegistrationOrderProbe?
    var credentials:Data?
    var record:Data?
    var generated=0
    var erased=0
    var invalidKeys:Set<String>=[]
    var challengeGate:CheckedContinuation<Void,Never>?
    init(credentials:Data?,record:Data?,order:RegistrationOrderProbe? = nil) {self.credentials=credentials;self.record=record;self.order=order}
    func loadCredentials()->Data? {credentials}
    func saveCredentials(_ bytes:Data) {credentials=bytes;order?.record("save")}
    func deleteCredentials() {credentials=nil;order?.record("deleteCredentials")}
    func loadKey()->Data? {record}
    func saveKey(_ bytes:Data) {record=bytes}
    func eraseKey() {record=nil;erased+=1;order?.record("deleteKey")}
    func generate()->String {generated+=1;return "fresh-key-\(generated)"}
    func refuse(_ key:String) {invalidKeys.insert(key)}
    func sign(_ key:String,_ digest:Data) throws->Data {
        #if canImport(DeviceCheck)
        if invalidKeys.contains(key) {throw NSError(domain:DCError.errorDomain,code:DCError.Code.invalidKey.rawValue)}
        #endif
        return Data([1,2,3])
    }
    func counts()->(Int,Int) {(generated,erased)}
}
private actor RegistrationHTTP:PulseBoundedHTTPTransport {
    var paths:[String]=[]
    var sessions:[String:Data]=[:]
    var verifyCalls=0
    var recoveryCalls=0
    var pauseInitial=false
    var pauseRecovery=false
    var pauseRegistration=false
    var pauseNonce=false
    var pauseVerify=false
    var blocked:CheckedContinuation<Void,Never>?
    var observer:CheckedContinuation<Void,Never>?
    func pause() {pauseInitial=true}
    func pauseSameKeyRecovery() {pauseRecovery=true}
    func pauseAcceptedRegistration() {pauseRegistration=true}
    func pauseAtNonce() {pauseNonce=true}
    func pauseAtVerify() {pauseVerify=true;verifyCalls=1}
    func waitUntilPaused() async {if blocked != nil {return};await withCheckedContinuation{observer=$0}}
    func release() {blocked?.resume();blocked=nil}
    func post(to url:URL,headers:[String:String],body:Data,maxResponseBytes:Int) async throws->PulseBoundedHTTPResponse {
        paths.append(url.path)
        let value=try JSONSerialization.jsonObject(with:body) as! [String:Any]
        var status=200
        let reply:[String:Any]
        switch url.path {
        case "/api/v1/pulse/app-attest/challenge":
            if pauseInitial {pauseInitial=false;await withCheckedContinuation{blocked=$0;observer?.resume();observer=nil}}
            reply=["challenge":"registration-challenge","expiresAt":Date().addingTimeInterval(300).formatted(Date.ISO8601FormatStyle())]
        case "/api/v1/pulse/installations":
            if pauseRegistration {pauseRegistration=false;await withCheckedContinuation{blocked=$0;observer?.resume();observer=nil}}
            reply=["installationId":"pulse_"+(value["clientInstallationId"] as! String),"token":"registered-bearer","tokenType":"Bearer","expiresAt":NSNull()]
        case "/pulse/installations/key-recovery/v1/challenge":
            recoveryCalls+=1
            if pauseRecovery {pauseRecovery=false;await withCheckedContinuation{blocked=$0;observer?.resume();observer=nil}}
            let timestamp=Int64(Date().timeIntervalSince1970)
            reply=["v":"pulse.installation-key-recovery-challenge.v1","request_id":value["request_id"]!,"key_id_hash":SealedOperation.sha256(Data((value["key_id"] as! String).utf8)),"application_id":value["application_id"]!,"environment":value["environment"]!,"service_origin":value["service_origin"]!,"installation_id":"pulse_retained","client_installation_id":"retained","challenge_id":"763db989-b3df-4dab-861c-e4d214b685ff","challenge":String(repeating:"a",count:43),"issued_at":timestamp,"expires_at":timestamp+300]
        case "/pulse/installations/key-recovery/v1":
            let challenge=value["challenge"] as! [String:Any]
            var material=Data("pulse:installation-key-recovery:v1".utf8);material.append(0);material.append(try CanonicalJSON.data(withJSONObject:challenge))
            reply=["v":"pulse.installation-key-recovery.v1","request_id":challenge["request_id"]!,"request_digest":SealedOperation.sha256(material),"key_id_hash":challenge["key_id_hash"]!,"application_id":challenge["application_id"]!,"environment":challenge["environment"]!,"service_origin":challenge["service_origin"]!,"installation_id":challenge["installation_id"]!,"client_installation_id":challenge["client_installation_id"]!,"token":"recovered-bearer","token_type":"Bearer","expires_at":NSNull(),"credential_lifecycle":"recovered","production_ready":true]
        case "/identity/sessions":
            reply=["session_id":"session","nonce":"session-secret","expires_at":Date().addingTimeInterval(300).formatted(.iso8601)]
        case "/passport/nonce":
            if pauseNonce {pauseNonce=false;await withCheckedContinuation{blocked=$0;observer?.resume();observer=nil}}
            reply=["session_id":value["session_id"]!,"nonce_id":"nonce","nonce":"challenge","expires_at":Date().addingTimeInterval(300).formatted(.iso8601),"iac_key_id":"iac-key","workflow":value["workflow"]!,"payload_commitment_hash":value["payload_commitment_hash"]!]
        case "/passport/verify":
            if pauseVerify {pauseVerify=false;await withCheckedContinuation{blocked=$0;observer?.resume();observer=nil}}
            verifyCalls+=1
            if verifyCalls==1 {status=401;reply=["error":["code":"unauthorized"]]}
            else {
                let payload=try JSONSerialization.jsonObject(with:Data((value["payload_json"] as! String).utf8)) as! [String:Any]
                reply=["session_id":payload["session_id"]!,"nonce_id":payload["nonce_id"]!,"status":"verified","validation":["result":"verified","validator":"passport_validator","sodVerified":true,"dscVerified":true,"cscaVerified":true,"dataGroupHashesVerified":true,"chipAuthenticated":false,"activeAuthentication":false,"chipAuthentication":false,"crlChecked":true,"documentExpired":false,"trustBundleVersion":"fixture","trustManifestSha256":String(repeating:"a",count:64),"assurance":"passive_authentication_only"]]
            }
        default:throw PulsePassportFailure.invalidResponse
        }
        return .init(statusCode:status,body:try JSONSerialization.data(withJSONObject:reply),responseURL:url,mimeType:"application/json")
    }
    func counts()->(Int,Int,Int) {(paths.filter{$0=="/api/v1/pulse/installations"}.count,recoveryCalls,verifyCalls)}
}

private actor RegistrationLeaseProbe {
    var closed=false
    var admitted=0
    var ended=0
    func begin()->Bool {guard !closed else{return false};admitted+=1;return true}
    func end() {ended+=1}
    func close() {closed=true}
    func open() {closed=false}
    func counts()->(Int,Int) {(admitted,ended)}
}

private extension PulsePassportRegistration {
    func joinPausedMutation(releasing http:RegistrationHTTP,recovery:Bool) async throws->PulsePassportCredentials {
        // Inherit this actor explicitly: releasing HTTP cannot run until the direct same-actor
        // call joins the existing flight and suspends on its pending task.value. No yield or
        // task-start signal can establish that ordering from the test's MainActor instead.
        let release=Task { [self] in
            precondition(!self.erasing) // Synchronous actor state access also checks isolation at compile time.
            await http.release()
        }
        let value:PulsePassportCredentials
        if recovery {value=try await recoverUnknownInstallationBearer()}
        else {value=try await ensure()}
        await release.value
        return value
    }
}

@MainActor final class PulsePassportRegistrationTests:XCTestCase {
    let origin=URL(string:"https://id.example.test")!
    func retained()->PulsePassportCredentials {.init(installationID:"pulse_retained",clientInstallationID:"retained",appAttestKeyID:"retained-key",token:"old-bearer",expiresAt:nil,backendBaseURL:origin,mode:.appAttest,appAttestEnvironment:"production")}
    private func owner(_ memory:RegistrationMemory,_ http:RegistrationHTTP,lease:PulsePassportRegistrationMutationLease = .init(begin:{true},end:{}),onCustodyErased:@escaping @Sendable()->Void = {})->PulsePassportRegistration {
        .init(configuration:.init(baseURL:origin,appAttestEnvironment:"production",applicationIdentifier:"com.kenshiki.reference"),storage:.init(load:{await memory.loadCredentials()},save:{await memory.saveCredentials($0)},delete:{await memory.deleteCredentials()}),keys:.init(load:{await memory.loadKey()},save:{await memory.saveKey($0)},generate:{await memory.generate()},attest:{_,_ in Data([1,2,3])},assert:{try await memory.sign($0,$1)}),eraseKeys:{await memory.eraseKey()},transport:http,app:.init(platform:"ios",appVersion:"1",buildNumber:"1",sdkVersion:"1",locale:nil),device:.init(deviceClass:"iPhone",osMajorVersion:18,modelClass:"phone"),mutationLease:lease,onCustodyErased:onCustodyErased)
    }
    func error<T>(_ operation:()async throws->T) async->Error {do{_ = try await operation();XCTFail("Expected failure");return PulsePassportFailure.invalidResponse}catch{return error}}
    func testConcurrentInitialEnsureCoalescesWithoutGeneratingAnotherKey() async throws {
        let memory=RegistrationMemory(credentials:nil,record:nil),http=RegistrationHTTP();await http.pause();let registration=owner(memory,http)
        let first=Task{try await registration.ensure()};await http.waitUntilPaused()
        let second=Task{try await registration.joinPausedMutation(releasing:http,recovery:false)}
        let a=try await first.value,b=try await second.value;XCTAssertEqual(a,b)
        let keyCounts=await memory.counts(),wireCounts=await http.counts();XCTAssertEqual(keyCounts.0,1);XCTAssertEqual(keyCounts.1,0);XCTAssertEqual(wireCounts.0,1)
    }
    func testLegacyRawKeyReferenceMigratesWithoutChangingIdentityOrCallingNetwork() async throws {
        let original=retained(),http=RegistrationHTTP();let memory=RegistrationMemory(credentials:try JSONEncoder().encode(original),record:Data("retained-key".utf8))
        let actual=try await owner(memory,http).ensure();XCTAssertEqual(original,actual)
        let data=await memory.loadKey();let record=try JSONDecoder().decode(RegisteredKeyEnrollmentRecord.self,from:XCTUnwrap(data));XCTAssertEqual(record.keyID,original.appAttestKeyID);XCTAssertEqual(record.phase,.registered)
        let counts=await memory.counts(),wire=await http.counts();XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,0);XCTAssertEqual(wire.0,0)
    }
    func testLateInvalidKeyForOldClientCannotRotateFreshIdentityAgainOrMixBearer() async throws {
        #if canImport(DeviceCheck)
        let http=RegistrationHTTP(),memory=RegistrationMemory(credentials:try JSONEncoder().encode(retained()),record:Data("retained-key".utf8));await memory.refuse("retained-key")
        let registration=owner(memory,http),old=try await registration.client()
        let failure=await error{try await old.openSession(operationID:"operation",issuedAt:Date())}
        XCTAssertTrue(failure is PulsePassportKeyFailure)
        let fresh=try await registration.recoverDeadKey(after:failure)
        let again=try await registration.recoverDeadKey(after:failure)
        XCTAssertEqual(fresh.deviceID,again.deviceID);XCTAssertNotEqual(fresh.deviceID,old.deviceID)
        let counts=await memory.counts();XCTAssertEqual(counts.0,1);XCTAssertEqual(counts.1,1)
        let invalidated=await error{try await old.installationToken()}
        guard case PulsePassportServiceFailure.invalidated=invalidated else{return XCTFail("Old client must be invalidated")}
        #endif
    }
    func testNonKeyErrorCannotEraseCredentialsOrGenerateKey() async throws {
        let http=RegistrationHTTP(),memory=RegistrationMemory(credentials:try JSONEncoder().encode(retained()),record:Data("retained-key".utf8)),registration=owner(memory,http)
        let original=PulsePassportHTTPFailure(statusCode:403,code:"forbidden",reason:"invalid_issued_at",classification:.forbidden)
        let failure=await error{try await registration.recoverDeadKey(after:original)};XCTAssertEqual(failure as? PulsePassportHTTPFailure,original)
        let counts=await memory.counts();XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,0)
    }
    func testUnauthorizedBearerRecoversSameKeyAndRetriesSameBoundProofOnce() async throws {
        let http=RegistrationHTTP(),memory=RegistrationMemory(credentials:try JSONEncoder().encode(retained()),record:Data("retained-key".utf8)),registration=owner(memory,http)
        let client=try await registration.client()
        let proof=PulsePassportChipProof(securityObject:Data([1]),documentSigningCertificate:Data([2]),dataGroups:["DG1":Data([3])],activeAuthenticationChallenge:nil,activeAuthenticationSignature:nil)
        let nonce=PulsePassportNonce(sessionID:"session",nonceID:"nonce",nonce:"challenge",expiresAt:"2030-01-01T00:00:00Z",iacKeyID:"key",workflow:"passport_identity",payloadCommitmentHash:nil)
        let verdict=try await client.verify(proof,nonce:nonce,chipAuthenticationResponse:nil);XCTAssertEqual(verdict.status,.verified)
        let actual=try await registration.ensure();XCTAssertEqual(actual.appAttestKeyID,"retained-key");XCTAssertEqual(actual.installationID,"pulse_retained");XCTAssertEqual(actual.token,"recovered-bearer")
        let counts=await memory.counts(),wire=await http.counts();XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,0);XCTAssertEqual(wire.1,1);XCTAssertEqual(wire.2,2)
    }
    func testConcurrentSameKeyRecoveryCoalescesWithoutAttestingOrRotating() async throws {
        let http=RegistrationHTTP(),memory=RegistrationMemory(credentials:try JSONEncoder().encode(retained()),record:Data("retained-key".utf8)),registration=owner(memory,http)
        await http.pauseSameKeyRecovery()
        let first=Task{try await registration.recoverUnknownInstallationBearer()};await http.waitUntilPaused()
        let second=Task{try await registration.joinPausedMutation(releasing:http,recovery:true)}
        let a=try await first.value,b=try await second.value;XCTAssertEqual(a,b);XCTAssertEqual(a.appAttestKeyID,"retained-key")
        let counts=await memory.counts(),wire=await http.counts();XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,0);XCTAssertEqual(wire.1,1)
    }

    func testErasureDrainsAcceptedRegistrationFencesAllWaitersAndAllowsExplicitReenrollment() async throws {
        let memory=RegistrationMemory(credentials:nil,record:nil),http=RegistrationHTTP(),barrier=RegistrationLeaseProbe()
        let registration=owner(memory,http,lease:.init(begin:{await barrier.begin()},end:{await barrier.end()}))
        await http.pauseAcceptedRegistration()
        let initial=Task{try await registration.ensure()};await http.waitUntilPaused()
        await barrier.close()
        let erasure=Task{try await registration.eraseLocalCredentials()}
        for _ in 0..<100 {if await registration.erasing {break};await Task.yield()}
        let isErasing=await registration.erasing;XCTAssertTrue(isErasing)
        for kind in 0..<3 {
            let failure=await error {
                switch kind {case 0:return try await registration.ensure();case 1:return try await registration.recoverUnknownInstallationBearer();default:return try await registration.forceReregister()}
            }
            guard case PulsePassportServiceFailure.invalidated=failure else {XCTFail("Erasure must close all mutation admission");continue}
        }
        await http.release();try await erasure.value
        let stale=await error{try await initial.value}
        guard case PulsePassportServiceFailure.invalidated=stale else {return XCTFail("Old waiter published erased credentials")}
        let credentials=await memory.loadCredentials(),key=await memory.loadKey();XCTAssertNil(credentials);XCTAssertNil(key)
        let denied=await error{try await registration.ensure()}
        guard case PulsePassportServiceFailure.invalidated=denied else {return XCTFail("Host barrier must refuse reenrollment while raised")}
        let closedCounts=await barrier.counts();XCTAssertEqual(closedCounts.0,closedCounts.1)
        await barrier.open()
        let fresh=try await registration.ensure();XCTAssertFalse(fresh.installationID.isEmpty)
        let counts=await barrier.counts();XCTAssertEqual(counts.0,counts.1)
    }
    func testOldClientCannotReenrollOrRecoverAfterErasure() async throws {
        let http=RegistrationHTTP(),memory=RegistrationMemory(credentials:try JSONEncoder().encode(retained()),record:Data("retained-key".utf8)),registration=owner(memory,http)
        let old=try await registration.client();try await registration.eraseLocalCredentials()
        let failure=await error{try await old.installationToken()}
        guard case PulsePassportServiceFailure.invalidated=failure else {return XCTFail("Old client triggered reenrollment")}
        let counts=await memory.counts(),wire=await http.counts();XCTAssertEqual(counts.0,0);XCTAssertEqual(wire.0,0)
    }
    func testFailedDeleteRetainsBothSlotsAndNeverRunsAnEnsure() async throws {
        struct Refusal:Error {}
        let original=retained(),http=RegistrationHTTP(),memory=RegistrationMemory(credentials:try JSONEncoder().encode(retained()),record:Data("retained-key".utf8)),registration=owner(memory,http)
        let failure=await error{try await registration.deleteInstallation(using:{value in XCTAssertEqual(value,original);throw Refusal()})}
        XCTAssertTrue(failure is Refusal)
        let retained=try await registration.ensure();XCTAssertEqual(retained,original)
        let counts=await memory.counts(),wire=await http.counts();XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,0);XCTAssertEqual(wire.0,0)
    }
    func testStaleDeleteCannotClearCredentialsReplacedOutsideOwner() async throws {
        let http=RegistrationHTTP(),memory=RegistrationMemory(credentials:try JSONEncoder().encode(retained()),record:Data("retained-key".utf8)),registration=owner(memory,http)
        let replacement=PulsePassportCredentials(installationID:"pulse_other",clientInstallationID:"other",appAttestKeyID:"other-key",token:"other-token",expiresAt:nil,backendBaseURL:origin,mode:.appAttest,appAttestEnvironment:"production")
        let replacementBytes=try JSONEncoder().encode(replacement)
        let failure=await error{try await registration.deleteInstallation(using:{_ in await memory.saveCredentials(replacementBytes)})}
        guard case PulsePassportServiceFailure.invalidated=failure else {return XCTFail("DELETE cleared a replacement identity")}
        let bytes=await memory.loadCredentials();XCTAssertEqual(try JSONDecoder().decode(PulsePassportCredentials.self,from:XCTUnwrap(bytes)),replacement)
        let counts=await memory.counts();XCTAssertEqual(counts.1,0)
    }
    func testSuccessfulDeleteIsExclusiveAndEndsExactlyOneLeaseAfterClearing() async throws {
        let http=RegistrationHTTP(),memory=RegistrationMemory(credentials:try JSONEncoder().encode(retained()),record:Data("retained-key".utf8)),barrier=RegistrationLeaseProbe()
        let registration=owner(memory,http,lease:.init(begin:{await barrier.begin()},end:{await barrier.end()}))
        try await registration.deleteInstallation(using:{_ in
            do {_ = try await registration.forceReregister();XCTFail("Force entered deletion")}
            catch {guard case PulsePassportServiceFailure.invalidated=error else{return XCTFail("Wrong closed-admission error")}}
        })
        let credentials=await memory.loadCredentials(),key=await memory.loadKey();XCTAssertNil(credentials);XCTAssertNil(key)
        let counts=await barrier.counts();XCTAssertEqual(counts.0,1);XCTAssertEqual(counts.1,1)
    }

    func testFinalRetirementPublishesBeforeLeaseEndAndFreshEnrollmentButNeverForFailedDeleteOrForce() async throws {
        struct Refusal:Error {}
        for serverDelete in [false,true] {
            let order=RegistrationOrderProbe(),http=RegistrationHTTP()
            let memory=RegistrationMemory(credentials:try JSONEncoder().encode(retained()),record:Data("retained-key".utf8),order:order)
            let registration=owner(memory,http,lease:.init(begin:{true},end:{order.record("leaseEnd")}),onCustodyErased:{order.record("retired")})
            if serverDelete {
                let failure=await error{try await registration.deleteInstallation(using:{_ in throw Refusal()})}
                XCTAssertTrue(failure is Refusal);XCTAssertFalse(order.snapshot().contains("retired"))
                try await registration.deleteInstallation(using:{_ in order.record("serverDelete")})
            } else {try await registration.eraseLocalCredentials()}
            let beforeEnrollment=order.snapshot()
            XCTAssertEqual(beforeEnrollment.filter{$0=="retired"}.count,1)
            let retirement=try XCTUnwrap(beforeEnrollment.firstIndex(of:"retired"))
            XCTAssertLessThan(try XCTUnwrap(beforeEnrollment.firstIndex(of:"deleteCredentials")),retirement)
            XCTAssertLessThan(try XCTUnwrap(beforeEnrollment.firstIndex(of:"deleteKey")),retirement)
            if serverDelete {XCTAssertEqual(beforeEnrollment.last,"leaseEnd")}
            let fresh=try await registration.ensure();XCTAssertFalse(fresh.installationID.isEmpty)
            let afterEnrollment=order.snapshot()
            XCTAssertLessThan(try XCTUnwrap(afterEnrollment.firstIndex(of:"retired")),try XCTUnwrap(afterEnrollment.firstIndex(of:"save")))
            _ = try await registration.forceReregister()
            XCTAssertEqual(order.snapshot().filter{$0=="retired"}.count,1,"Transient key replacement must not publish final retirement")
        }
    }

    func testActualRetainedIdentityReadRejectsCustodyRotationAfterNonceAndVerification() async throws {
        for afterVerify in [false,true] {
            let http=RegistrationHTTP(),memory=RegistrationMemory(credentials:try JSONEncoder().encode(retained()),record:Data("retained-key".utf8)),registration=owner(memory,http)
            let client=try await registration.client(),service=PulsePassportService(client:{client})
            if afterVerify {await http.pauseAtVerify()} else {await http.pauseAtNonce()}
            let work=Task {
                try await service.runRead(binding:"document",read:{_,_ in
                    PulsePassportRead(read:"read",proof:PulsePassportChipProof(securityObject:Data([1]),documentSigningCertificate:Data([2]),dataGroups:["DG1":Data([3])],activeAuthenticationChallenge:nil,activeAuthenticationSignature:nil),chipAuthenticationResponse:nil)
                },admit:{_ in})
            }
            await http.waitUntilPaused()
            let replacement=PulsePassportCredentials(installationID:"pulse_other",clientInstallationID:"other",appAttestKeyID:"other-key",token:"other-token",expiresAt:nil,backendBaseURL:origin,mode:.appAttest,appAttestEnvironment:"production")
            await memory.saveCredentials(try JSONEncoder().encode(replacement))
            await memory.saveKey(try JSONEncoder().encode(RegisteredKeyEnrollmentRecord(version:1,keyID:"other-key",backendBaseURL:origin,environment:"production",clientInstallationID:"other",phase:.registered)))
            await http.release()
            let failure=await error{try await work.value}
            guard case PulsePassportServiceFailure.invalidated=failure else {return XCTFail("Stale custody published prepared/accepted evidence")}
            let counts=await memory.counts();XCTAssertEqual(counts.0,0);XCTAssertEqual(counts.1,0)
            let stored=await memory.loadCredentials();XCTAssertEqual(try JSONDecoder().decode(PulsePassportCredentials.self,from:XCTUnwrap(stored)),replacement)
        }
    }

}
