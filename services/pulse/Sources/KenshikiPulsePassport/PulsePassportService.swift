import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

public enum PulsePassportPreparationStage:String,Sendable {case credentials,appAttestAssertion,recoverIdentity,session,nonce}

/// Immutable read challenge. Only its owning service generation can submit it.
public struct PulsePreparedPassport:Sendable {
    public let session:PulsePassportSession
    public let nonce:PulsePassportNonce
    public let installationID:String
    public let origin:URL
    fileprivate let owner:UUID
    fileprivate let generation:Int
    fileprivate let client:PulsePassportClient
    public func hasLiveChallenge(at date:Date = Date())->Bool {PulsePassportClock.date(nonce.expiresAt).map{$0>date} ?? false}
}
public enum PulsePassportServiceFailure:Error,Sendable {
    case invalidated,verificationFailed(PulsePassportVerification)
}

private final class PulsePreparationWaiterCancellation:@unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    func cancel() {lock.lock();cancelled=true;lock.unlock()}
    var isCancelled:Bool {lock.lock();defer{lock.unlock()};return cancelled}
}

/// One Pulse preparation/retry owner, shared by both adopters. It owns no radio, UI or model.
/// Adapted whole from Pulse's IdentityPassportSessionState/PreparationController/Coordinator.
@MainActor public final class PulsePassportService {
    private struct Attempt {let operationID:String;let issuedAt:Date}
    private var state=PulsePassportSessionState<Attempt,PulsePreparedPassport>()
    private var binding:String?
    private var owner=UUID()
    private struct PreparationObserver {
        let callback:@MainActor @Sendable(PulsePassportPreparationStage)->Void
        let cancellation:PulsePreparationWaiterCancellation
    }
    private struct PreparationFlight {
        let id:UUID;let binding:String;let task:Task<PulsePreparedPassport,Error>
        var observers:[UUID:PreparationObserver]
        var stage:PulsePassportPreparationStage?
    }
    private var preparationFlight:PreparationFlight?
    private var verificationTicket:UUID?
    private var verificationInstallationID:String?
    private var observedInstallationID:String?
    private var identityNoticeRevision:UInt64=0
    private let makeClient:@MainActor ()async throws->PulsePassportClient
    private let recoverDeadKey:(@MainActor (Error)async throws->PulsePassportClient)?
    private let now:@MainActor ()->Date
    private let operationID:@MainActor ()->String
    public init(client:@escaping @MainActor ()async throws->PulsePassportClient,
        recoverDeadKey:(@MainActor (Error)async throws->PulsePassportClient)? = nil,
        now:@escaping @MainActor ()->Date = {Date()},operationID:@escaping @MainActor ()->String = {UUID().uuidString.lowercased()}) {
        makeClient=client;self.recoverDeadKey=recoverDeadKey;self.now=now;self.operationID=operationID
    }
    public func invalidate() {preparationFlight?.task.cancel();preparationFlight=nil;verificationTicket=nil;verificationInstallationID=nil;owner=UUID();binding=nil;state = .init()}
    /// Host credential-owner notifications fence retained/ submitted work; an in-flight preparation
    /// may still complete its own one-time exact-dead-key recovery through the bound client.
    public func installationDidChange(to installationID:String) {
        identityNoticeRevision &+= 1
        observedInstallationID=installationID
        if let cached=state.ceremony,cached.installationID != installationID {invalidate()}
        else if let submitting=verificationInstallationID,submitting != installationID {invalidate()}
    }
    private func attempt()->Attempt {.init(operationID:operationID(),issuedAt:now())}
    public func prepare(binding:String,onStage:@escaping @MainActor @Sendable(PulsePassportPreparationStage)->Void = {_ in}) async throws->PulsePreparedPassport {
        try Task.checkCancellation()
        if let running=preparationFlight,running.binding==binding {
            return try await waitForPreparation(running.id,task:running.task,onStage:onStage)
        }
        if preparationFlight != nil || self.binding != binding {invalidate();self.binding=binding}
        let id=UUID()
        let task=Task {try await self.performPreparation(binding:binding,flightID:id)}
        preparationFlight = .init(id:id,binding:binding,task:task,observers:[:],stage:nil)
        return try await waitForPreparation(id,task:task,onStage:onStage)
    }
    private func waitForPreparation(_ id:UUID,task:Task<PulsePreparedPassport,Error>,onStage:@escaping @MainActor @Sendable(PulsePassportPreparationStage)->Void) async throws->PulsePreparedPassport {
        let caller=UUID(),cancellation=PulsePreparationWaiterCancellation()
        if preparationFlight?.id==id {preparationFlight?.observers[caller] = .init(callback:onStage,cancellation:cancellation)}
        defer {removeWaiter(caller,flight:id,cancelled:false)}
        if let stage=preparationFlight?.stage {onStage(stage)}
        return try await withTaskCancellationHandler(operation:{
            do {
                let result=try await task.value
                try Task.checkCancellation()
                return result
            } catch {try Task.checkCancellation();throw error}
        },onCancel:{
            cancellation.cancel()
            Task {@MainActor [weak self] in self?.removeWaiter(caller,flight:id,cancelled:true)}
        })
    }
    private func removeWaiter(_ caller:UUID,flight id:UUID,cancelled:Bool) {
        guard preparationFlight?.id==id else {return}
        preparationFlight?.observers.removeValue(forKey:caller)
        if preparationFlight?.observers.isEmpty==true {
            if cancelled {preparationFlight?.task.cancel()}
            preparationFlight=nil
        }
    }
    private func performPreparation(binding:String,flightID:UUID) async throws->PulsePreparedPassport {
        try Task.checkCancellation()
        verificationTicket=nil
        let epoch=owner
        var work:PulsePassportPreparationWork<Attempt>
        if let ready=state.ceremony,!ready.hasLiveChallenge(at:now()) {work=state.expireChallenge(replacingWith:attempt())}
        else {switch state.begin(using:attempt()) {case .reuse(let value):return value.ceremony;case .prepare(let value):work=value}}
        var usedDeadKeyRecovery=false
        var recoveredClient:PulsePassportClient?
        while true {
            do {
                try Task.checkCancellation()
                try observe(.credentials,flightID:flightID,owner:epoch,generation:work.generation)
                let client:PulsePassportClient
                if let recoveredClient {client=recoveredClient} else {client=try await makeClient()}
                try requireOwner(epoch,generation:work.generation)
                try requireCurrentClient(client)
                let generation=work.generation
                let session=try await client.openSession(operationID:work.attempt.operationID,issuedAt:work.attempt.issuedAt,onStage:{[weak self] stage in
                    guard let self else {throw CancellationError()}
                    try await self.observe(stage,flightID:flightID,owner:epoch,generation:generation)
                })
                try requireOwner(epoch,generation:work.generation)
                try requireCurrentClient(client)
                try observe(.nonce,flightID:flightID,owner:epoch,generation:work.generation)
                let nonce=try await client.issueNonce(for:session)
                try requireOwner(epoch,generation:work.generation)
                _ = try await client.installationToken()
                try requireOwner(epoch,generation:work.generation)
                try requireCurrentClient(client)
                let value=PulsePreparedPassport(session:session,nonce:nonce,installationID:client.deviceID,origin:client.baseURL,owner:epoch,generation:work.generation,client:client)
                guard value.hasLiveChallenge(at:now()) else {throw PulsePassportHTTPFailure(statusCode:410,code:"challenge_expired",reason:nil,classification:.challengeExpired)}
                guard state.acceptPrepared(ceremony:value,generation:work.generation) else {throw CancellationError()}
                return value
            } catch {
                try requireOwner(epoch,generation:work.generation)
                if Self.isDeadAppAttestKeyError(error),!usedDeadKeyRecovery,let recoverDeadKey {
                    usedDeadKeyRecovery=true
                    try observe(.recoverIdentity,flightID:flightID,owner:epoch,generation:work.generation)
                    let noticeRevision=identityNoticeRevision
                    let recovered=try await recoverDeadKey(error)
                    try requireOwner(epoch,generation:work.generation)
                    // Own authenticated recovery may precede its host notification. A notice that
                    // arrived during recovery remains authoritative and can never be overwritten.
                    if identityNoticeRevision==noticeRevision {observedInstallationID=recovered.deviceID}
                    try requireCurrentClient(recovered)
                    recoveredClient=recovered
                    continue
                }
                let failure=PulsePassportPreparationFailureClassifier.failure(from:error)
                let resolution=PulsePassportPreparationFailureClassifier.classify(failure)
                if let recovery=state.resolvePreparationFailure(resolution,generation:work.generation,replacementAttempt:attempt()) {work=recovery;continue}
                if error is CancellationError {throw CancellationError()}
                // Preserve the original typed HTTP/platform error; presentation is host-owned.
                throw error
            }
        }
    }
    public func chipAuthenticationChallenge(prepared:PulsePreparedPassport,dg14:Data) async throws->PulseChipAuthenticationChallenge {
        try requirePrepared(prepared)
        do {
            let value=try await prepared.client.chipAuthenticationChallenge(nonce:prepared.nonce,dg14:dg14)
            try requirePrepared(prepared)
            return value
        } catch {
            if PulsePassportClient.classification(error) == .challengeExpired, owner==prepared.owner {invalidate()}
            throw error
        }
    }
    /// A delivered SDK result refused locally still consumes only its own ready challenge.
    /// Positioning cancellation without a returned SDK result must not call this method.
    public func discardDeliveredRead(prepared:PulsePreparedPassport) throws {
        try requirePrepared(prepared,checkCancellation:false)
        guard state.takeCeremonyForVerification() != nil else {throw PulsePassportServiceFailure.invalidated}
    }
    public func verify<Read:Sendable>(_ input:PulsePassportRead<Read>,prepared:PulsePreparedPassport,
        admit:@MainActor(Read)throws->Void) async throws->PulsePassportAcceptedRead<Read> {
        // Validate ownership before cancellation: only this delivered read's current challenge
        // may retire, and cancellation must never leave it available for another chip read.
        try requirePrepared(prepared,checkCancellation:false)
        // A delivered chip result retires its challenge even when local admission refuses it.
        guard state.takeCeremonyForVerification() != nil else {throw PulsePassportServiceFailure.invalidated}
        let ticket=UUID();verificationTicket=ticket;verificationInstallationID=prepared.installationID
        defer {if verificationTicket==ticket {verificationTicket=nil;verificationInstallationID=nil}}
        try Task.checkCancellation()
        try admit(input.read)
        try Task.checkCancellation()
        guard owner==prepared.owner,verificationTicket==ticket else {throw CancellationError()}
        // The request may consume its nonce even when its answer is lost. Never put it back.
        let verdict:PulsePassportVerification
        do {verdict=try await prepared.client.verify(input.proof,nonce:prepared.nonce,chipAuthenticationResponse:input.chipAuthenticationResponse)}
        catch {
            guard owner==prepared.owner,verificationTicket==ticket else {throw CancellationError()}
            throw error
        }
        try Task.checkCancellation()
        _ = try await prepared.client.installationToken()
        try Task.checkCancellation()
        guard owner==prepared.owner,verificationTicket==ticket else {throw CancellationError()}
        try requireCurrentClient(prepared.client)
        guard verdict.status == .verified else {throw PulsePassportServiceFailure.verificationFailed(verdict)}
        return try .init(read:input.read,acceptance:.init(client:prepared.client,prepared:prepared,proof:input.proof,verdict:verdict,now:now()),verification:verdict)
    }
    /// Accepts an existing host-issued ceremony (for example a Bond QR session) without creating
    /// another session or nonce. The host retains its existing single-use/generation ownership.
    public static func verifyIssuedRead<Read:Sendable>(_ input:PulsePassportRead<Read>,nonce:PulsePassportNonce,
        client:PulsePassportClient,admit:@MainActor(Read)throws->Void,now:@MainActor()->Date = {Date()}) async throws->PulsePassportAcceptedRead<Read> {
        try Task.checkCancellation()
        try admit(input.read)
        try Task.checkCancellation()
        let verdict=try await client.verify(input.proof,nonce:nonce,chipAuthenticationResponse:input.chipAuthenticationResponse)
        try Task.checkCancellation()
        _ = try await client.installationToken()
        try Task.checkCancellation()
        guard verdict.status == .verified else {throw PulsePassportServiceFailure.verificationFailed(verdict)}
        return try .init(read:input.read,acceptance:.init(client:client,nonce:nonce,proof:input.proof,verdict:verdict,now:now()),verification:verdict)
    }
    public func runRead<Read:Sendable>(binding:String,
        read:@MainActor(PulsePreparedPassport,@escaping @Sendable(Data)async throws->PulseChipAuthenticationChallenge)async throws->PulsePassportRead<Read>,
        admit:@MainActor(Read)throws->Void) async throws->PulsePassportAcceptedRead<Read> {
        let prepared=try await prepare(binding:binding)
        let input=try await read(prepared,{[weak self] dg14 in guard let self else {throw CancellationError()};return try await self.chipAuthenticationChallenge(prepared:prepared,dg14:dg14)})
        return try await verify(input,prepared:prepared,admit:admit)
    }
    private func observe(_ stage:PulsePassportPreparationStage,flightID:UUID,owner:UUID,generation:Int) throws {
        try requireOwner(owner,generation:generation)
        guard preparationFlight?.id==flightID,let observers=preparationFlight?.observers,
              observers.values.contains(where:{!$0.cancellation.isCancelled}) else {throw CancellationError()}
        preparationFlight?.stage=stage
        for observer in observers.values where !observer.cancellation.isCancelled {
            try requireOwner(owner,generation:generation)
            guard preparationFlight?.id==flightID else {throw CancellationError()}
            observer.callback(stage)
        }
        try requireOwner(owner,generation:generation)
    }
    private func requireCurrentClient(_ client:PulsePassportClient) throws {
        guard observedInstallationID==nil || observedInstallationID==client.deviceID else {throw PulsePassportServiceFailure.invalidated}
    }
    private func requirePrepared(_ value:PulsePreparedPassport,checkCancellation:Bool = true) throws {
        try requireCurrentClient(value.client)
        if checkCancellation {try Task.checkCancellation()}
        guard owner==value.owner,state.ceremony?.generation==value.generation else {throw PulsePassportServiceFailure.invalidated}
        guard value.hasLiveChallenge(at:now()) else {throw PulsePassportFailure.challengeExpired}
    }
    private func requireOwner(_ value:UUID,generation:Int) throws {
        try Task.checkCancellation()
        guard owner==value,state.isCurrentPreparation(generation:generation) else {throw CancellationError()}
    }
    public nonisolated static func isDeadAppAttestKeyError(_ error:Error)->Bool {
        #if canImport(DeviceCheck)
        let value=((error as? PulsePassportKeyFailure)?.underlyingError ?? error) as NSError
        return value.domain==DCError.errorDomain && value.code==DCError.Code.invalidKey.rawValue
        #else
        return false
        #endif
    }
}
