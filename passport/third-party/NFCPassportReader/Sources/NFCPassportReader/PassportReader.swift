//
//  PassportReader.swift
//  NFCTest
//
//  Created by Andy Qua on 11/06/2019.
//  Copyright © 2019 Andy Qua. All rights reserved.
//

import Foundation
import OSLog

#if !os(macOS)
import UIKit
import CoreNFC

/// Owns the actual detected-tag task, including an awaited remote terminal. Cancellation of
/// the outer read must cancel this task too; a matching invalidation drains it before release.
/// The host terminal must use bounded, cancellation-aware transport (the Pulse transport does).
final class PassportTagTaskOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    @discardableResult
    func start(_ operation: @escaping () async -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        let previous = task
        task = Task {
            await withTaskCancellationHandler {
                await previous?.value
            } onCancel: {
                previous?.cancel()
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let retired = task
        lock.unlock()
        retired?.cancel()
    }

    private func currentTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    func drain() async { await currentTask()?.value }
}

@available(iOS 15, *)
public protocol PassportReaderTrackingDelegate: AnyObject {
    func nfcTagDetected()
    func readCardAccess(cardAccess: CardAccess)
    func paceStarted()
    func paceSucceeded()
    func paceFailed()
    func bacStarted()
    func bacSucceeded()
    func bacFailed()
}

@available(iOS 15, *)
extension PassportReaderTrackingDelegate {
    func nfcTagDetected() { /* default implementation */ }
    func readCardAccess(cardAccess: CardAccess) { /* default implementation */ }
    func paceStarted() { /* default implementation */ }
    func paceSucceeded() { /* default implementation */ }
    func paceFailed() { /* default implementation */ }
    func bacStarted() { /* default implementation */ }
    func bacSucceeded() { /* default implementation */ }
    func bacFailed() { /* default implementation */ }
}

@available(iOS 15, *)
public struct UnverifiedPassportRead {
    public let passport: NFCPassportModel

    init(passport: NFCPassportModel) {
        self.passport = passport
    }
}

/// Everything owned by one detected physical tag. Replacing this object guarantees a retry cannot
/// inherit a partial model, secure-channel handler, current data group, or mutated group queue.
final class PassportTagAttemptState {
    let generation: Int
    var passport = NFCPassportModel()
    var currentlyReadingDataGroup: DataGroupId?
    var dataGroupsToRead: [DataGroupId]
    var bacHandler: BACHandler?
    var caHandler: ChipAuthenticationHandler?

    init(generation: Int, requestedDataGroups: [DataGroupId]) {
        self.generation = generation
        dataGroupsToRead = requestedDataGroups.isEmpty ? [.COM, .SOD] : requestedDataGroups
    }
}

/// CoreNFC-free state machine for one reader session's detected-tag attempts.
///
/// CoreNFC owns the bounded session lifetime. This value owns only whether a detected tag may
/// start work, whether a physical loss may resume polling, and which terminal contender is still
/// allowed to settle the read. Attempt generations prevent a late task from one physical tag from
/// changing the state of a later tag detected after polling restarts.
struct PassportTagAttemptLifecycle {
    enum Event {
        case tagDetected([DataGroupId])
        case transientLoss(Int)
        case success(Int)
        case fatalFailure(Int)
        case cancellation
        case invalidation
    }

    enum Effect: Equatable {
        case beginAttempt(Int)
        case restartPolling
        case settleSuccess
        case settleFailure
        case none
    }

    private(set) var attemptState: PassportTagAttemptState?
    private(set) var lastAttempt = 0
    private(set) var isTerminal = false

    var activeAttempt: Int? { isTerminal ? nil : attemptState?.generation }

    mutating func handle(_ event: Event) -> Effect {
        switch event {
        case .tagDetected(let requestedDataGroups):
            guard !isTerminal, attemptState == nil else { return .none }
            lastAttempt += 1
            attemptState = PassportTagAttemptState(
                generation: lastAttempt, requestedDataGroups: requestedDataGroups)
            return .beginAttempt(lastAttempt)
        case .transientLoss(let attempt):
            guard !isTerminal, activeAttempt == attempt else { return .none }
            attemptState = nil
            return .restartPolling
        case .success(let attempt):
            guard !isTerminal, activeAttempt == attempt else { return .none }
            attemptState = nil
            isTerminal = true
            return .settleSuccess
        case .fatalFailure(let attempt):
            guard !isTerminal, activeAttempt == attempt else { return .none }
            attemptState = nil
            isTerminal = true
            return .settleFailure
        case .cancellation, .invalidation:
            guard !isTerminal else { return .none }
            isTerminal = true
            return .settleFailure
        }
    }
}

@available(iOS 15, *)
public class PassportReader : NSObject {
    // Record one terminal outcome before invalidating the session. Its matching callback
    // releases the continuation so passive authentication cannot overlap CoreNFC teardown.
    private var settlement = NFCReadSettlement<UnverifiedPassportRead>()
    private let tagTasks = PassportTagTaskOwner()

    public weak var trackingDelegate: PassportReaderTrackingDelegate?
    private let readStateLock = NSLock()
    private var readerSession: NFCTagReaderSession?
    // PassportReader owns mutable protocol state throughout an asynchronous tag task. Keep each
    // instance single-use once a CoreNFC session has been installed so a late task from one read
    // can never observe or settle a later read's state.
    private var readHasStarted = false
    private var tagAttemptLifecycle = PassportTagAttemptLifecycle()
    private var cancellationRequested = false
    /// The caller's immutable read policy. Protected-group recovery mutates the working
    /// `dataGroupsToRead` queue, so every newly detected physical tag must begin from
    /// this original list rather than inheriting a previous tag attempt's partial state.
    private var requestedDataGroups : [DataGroupId] = []
    private var readAllDatagroups = false
    private var skipSecureElements = true
    private var skipCA = false
    private var skipPACE = false
    
    // Extended mode is used for reading eMRTD's that support extended length APDUs
    private var useExtendedMode = false

    private var mrzKey : String = ""
    private var aaChallenge: [UInt8]?
    // A configured remote terminal owns Chip Authentication keys. Its exchange must be last,
    // because the reader cannot use the resulting secure channel for further data-group reads.
    private var chipAuthenticationTerminal: ChipAuthenticationTerminal?
    private var dataAmountToReadOverride : Int? = nil
    
    private var scanCompletedHandler: ((NFCPassportModel?, NFCPassportReaderError?)->())!
    private var nfcViewDisplayMessageHandler: ((NFCViewDisplayMessage) -> String?)?
    private var masterListURL : URL?

    /// Selects OpenSSL CMS verification instead of the default RFC 5652 SOD verification path.
    public var passiveAuthenticationUsesOpenSSL : Bool = false

    public init( masterListURL: URL? = nil ) {
        super.init()
        
        self.masterListURL = masterListURL
    }
    
    // Internal transport harness supplies the same detected-tag lifecycle as CoreNFC.
    convenience init(tagAttemptLifecycle: PassportTagAttemptLifecycle,
                     aaChallenge: [UInt8]? = nil,
                     chipAuthenticationTerminal: ChipAuthenticationTerminal? = nil) {
        self.init()
        self.tagAttemptLifecycle = tagAttemptLifecycle
        self.aaChallenge = aaChallenge
        self.chipAuthenticationTerminal = chipAuthenticationTerminal
    }

    public func setMasterListURL( _ masterListURL : URL ) {
        self.masterListURL = masterListURL
    }
    
    // This function allows you to override the amount of data the TagReader tries to read from the NFC
    // chip. NOTE - this really shouldn't be used for production but is useful for testing as different
    // passports support different data amounts.
    // It appears that the most reliable is 0xA0 (160 chars) but some will support arbitary reads (0xFF or 256)
    public func overrideNFCDataAmountToRead( amount: Int ) {
        dataAmountToReadOverride = amount
    }
    
    public func readPassport( mrzKey : String, tags : [DataGroupId] = [], aaChallenge: [UInt8]? = nil, skipSecureElements : Bool = true, skipCA : Bool = false, skipPACE : Bool = false, useExtendedMode : Bool = false, customDisplayMessage : ((NFCViewDisplayMessage) -> String?)? = nil) async throws -> NFCPassportModel {
        let read = try await readPassportUnverified(
            mrzKey: mrzKey, tags: tags, aaChallenge: aaChallenge,
            skipSecureElements: skipSecureElements, skipCA: skipCA, skipPACE: skipPACE,
            useExtendedMode: useExtendedMode, customDisplayMessage: customDisplayMessage)
        read.passport.verifyPassport(
            masterListURL: masterListURL,
            useCMSVerification: passiveAuthenticationUsesOpenSSL)
        return read.passport
    }

    /// Reads every requested data group and closes the CoreNFC session before returning. The
    /// returned model has NOT undergone passive authentication; callers must explicitly verify it.
    ///
    /// When configured, `chipAuthenticationTerminal`
    /// replaces local Chip Authentication. DG14 is read with the other groups under the access
    /// channel, Active Authentication runs, and only then is the terminal asked for its challenge,
    /// its public key sent to the chip and its protected command relayed; the chip's raw answer is
    /// kept in `chipAuthenticationTerminalResponse`. That step is last because afterwards the chip
    /// speaks only under keys the terminal holds.
    public func readPassportUnverified( mrzKey : String, tags : [DataGroupId] = [], aaChallenge: [UInt8]? = nil, skipSecureElements : Bool = true, skipCA : Bool = false, skipPACE : Bool = false, useExtendedMode : Bool = false, chipAuthenticationTerminal: ChipAuthenticationTerminal? = nil, customDisplayMessage : ((NFCViewDisplayMessage) -> String?)? = nil) async throws -> UnverifiedPassportRead {

        // Reserve this single-use reader before touching any per-read state. A concurrent caller
        // therefore cannot corrupt an active read before it is rejected. The cancellation handler
        // is installed only AFTER this call owns the lease: an already-cancelled second caller must
        // not run a shared handler that would invalidate the first caller's live session.
        guard beginRead() else {
            throw NFCPassportReaderError.ReaderAlreadyInUse
        }

        return try await withTaskCancellationHandler(operation: {
        guard !isCancellationRequested else {
            throw CancellationError()
        }

        // No session exists on availability failure, so release the single-use reservation.
        // A retry can acquire it without leaving a suspended continuation behind.
        guard NFCNDEFReaderSession.readingAvailable,
              NFCTagReaderSession.readingAvailable else {
            abandonRead()
            throw NFCPassportReaderError.NFCNotSupported
        }

        settlement = NFCReadSettlement<UnverifiedPassportRead>(onSettled: { settler, won in
            Logger.passportReader.info(
                "read settled by \(settler.rawValue, privacy: .public) won=\(won, privacy: .public)")
        })
        self.mrzKey = mrzKey
        self.aaChallenge = aaChallenge
        self.chipAuthenticationTerminal = chipAuthenticationTerminal
        self.skipCA = skipCA
        self.skipPACE = skipPACE
        self.useExtendedMode = useExtendedMode
        
        self.requestedDataGroups = tags
        self.nfcViewDisplayMessageHandler = customDisplayMessage
        self.skipSecureElements = skipSecureElements
        
        // If no tags specified, read all
        if self.requestedDataGroups.count == 0 {
            self.readAllDatagroups = true
        } else {
            // We are reading specific datagroups
            self.readAllDatagroups = false
        }
        
        guard let session = NFCTagReaderSession(
            pollingOption: [.iso14443], delegate: self, queue: nil)
        else {
            abandonRead()
            throw NFCPassportReaderError.UnexpectedError
        }
        session.alertMessage = self.nfcViewDisplayMessageHandler?(.requestPresentPassport)
            ?? NFCViewDisplayMessage.requestPresentPassport.description

        // Arm the continuation before beginning the session so even immediate invalidation
        // has a waiting caller to settle. armAndBegin serializes this with cancellation.
        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<UnverifiedPassportRead, Error>) in
            self.armAndBegin(continuation, session: session)
        })
        }, onCancel: {
            self.requestCancellation()
        })
    }

    private func beginRead() -> Bool {
        readStateLock.lock()
        defer { readStateLock.unlock() }
        guard !readHasStarted else { return false }
        readHasStarted = true
        return true
    }

    private var isCancellationRequested: Bool {
        readStateLock.lock()
        defer { readStateLock.unlock() }
        return cancellationRequested
    }

    private func armAndBegin(
        _ continuation: CheckedContinuation<UnverifiedPassportRead, Error>,
        session: NFCTagReaderSession
    ) {
        readStateLock.lock()
        guard !cancellationRequested else {
            readStateLock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        readerSession = session
        settlement.arm(continuation)
        // Keep installation and begin atomic with respect to requestCancellation(). `begin()` only
        // schedules CoreNFC work; delegate callbacks arrive on the session queue after it returns.
        // The handler therefore either wins before a session is live, or sees this exact live
        // session and invalidates it.
        session.begin()
        readStateLock.unlock()
    }

    private func requestCancellation() {
        readStateLock.lock()
        cancellationRequested = true
        let session = readerSession
        let effect = tagAttemptLifecycle.handle(.cancellation)
        let cancellationWon = effect == .settleFailure
            && session != nil
            && settlement.record(.failure(CancellationError()), by: .taskCancellation)
        readStateLock.unlock()

        tagTasks.cancel()

        guard let session, cancellationWon else { return }
        // Cancellation is a terminal contender just like a read error. It must win BEFORE the
        // exact session is invalidated; only that session's callback may release the continuation.
        session.invalidate()
    }

    private func abandonRead() {
        readStateLock.lock()
        // Availability or session construction failed, so there can be no delegate callback or
        // tag task retaining this generation. Retrying this otherwise single-use instance is safe.
        if !cancellationRequested {
            readHasStarted = false
        }
        readStateLock.unlock()
    }

    private func claimTagTask(for session: NFCTagReaderSession) -> Int? {
        readStateLock.lock()
        defer { readStateLock.unlock() }
        guard readerSession === session, !cancellationRequested,
              !settlement.isSettled else { return nil }
        guard case .beginAttempt(let attempt) = tagAttemptLifecycle.handle(
            .tagDetected(requestedDataGroups))
        else { return nil }
        return attempt
    }

    private var attemptState: PassportTagAttemptState {
        guard let state = tagAttemptLifecycle.attemptState else {
            preconditionFailure("passport protocol state accessed outside a detected-tag attempt")
        }
        return state
    }

    private var passport: NFCPassportModel { attemptState.passport }

    private var currentlyReadingDataGroup: DataGroupId? {
        get { attemptState.currentlyReadingDataGroup }
        set { attemptState.currentlyReadingDataGroup = newValue }
    }

    private var dataGroupsToRead: [DataGroupId] {
        get { attemptState.dataGroupsToRead }
        set { attemptState.dataGroupsToRead = newValue }
    }

    private var bacHandler: BACHandler? {
        get { attemptState.bacHandler }
        set { attemptState.bacHandler = newValue }
    }

    private var caHandler: ChipAuthenticationHandler? {
        get { attemptState.caHandler }
        set { attemptState.caHandler = newValue }
    }

    /// A physical RF miss is scoped to the detected tag, not the whole CoreNFC session. Release
    /// that attempt and resume polling while the same bounded system session remains live. The
    /// session timeout and cancellation still own terminal settlement and release.
    private func restartPollingAfterTransientTagLoss(
        in session: NFCTagReaderSession,
        attempt: Int
    ) {
        readStateLock.lock()
        let shouldRestart = readerSession === session
            && !cancellationRequested
            && !settlement.isSettled
            && tagAttemptLifecycle.handle(.transientLoss(attempt)) == .restartPolling
        readStateLock.unlock()

        guard shouldRestart else { return }
        session.alertMessage = self.nfcViewDisplayMessageHandler?(.requestPresentPassport)
            ?? NFCViewDisplayMessage.requestPresentPassport.description
        // Do not call CoreNFC while holding the state lock. If cancellation or invalidation wins
        // after the transition, CoreNFC documents restartPolling() on the invalid session as a
        // no-op and its callback remains the terminal authority.
        session.restartPolling()
        Logger.passportReader.info("transient tag loss; restarted polling in the live session")
    }

    private func recordSuccessfulRead(
        _ passport: NFCPassportModel,
        in session: NFCTagReaderSession,
        attempt: Int
    ) -> Bool {
        readStateLock.lock()
        defer { readStateLock.unlock() }
        guard readerSession === session,
              tagAttemptLifecycle.handle(.success(attempt)) == .settleSuccess
        else { return false }
        return settlement.record(
            .success(UnverifiedPassportRead(passport: passport)), by: .readTask)
    }

    private func finish(_ session: NFCTagReaderSession) -> Bool {
        readStateLock.lock()
        defer { readStateLock.unlock() }
        guard readerSession === session else { return false }
        readerSession = nil
        _ = tagAttemptLifecycle.handle(.invalidation)
        return true
    }

    private var currentSession: NFCTagReaderSession? {
        readStateLock.lock()
        defer { readStateLock.unlock() }
        return readerSession
    }
}

@available(iOS 15, *)
extension PassportReader : NFCTagReaderSessionDelegate {
    // MARK: - NFCTagReaderSessionDelegate
    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        // If necessary, you may perform additional operations on session start.
        // At this point RF polling is enabled.
        Logger.passportReader.debug( "tagReaderSessionDidBecomeActive" )
    }
    
    public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        // If necessary, you may handle the error. Note session is no longer valid.
        // You must create a new session to restart RF polling.
        guard finish(session) else {
            Logger.passportReader.info("ignored invalidation from a stale reader session")
            return
        }

        // Invalidation releases the caller but cannot overwrite an outcome already recorded
        // by the read task or cancellation handler. If it arrives first, its reason wins.
        var userError = NFCPassportReaderError.UnexpectedError
        if let readerError = error as? NFCReaderError {
            switch (readerError.code) {
            case NFCReaderError.readerSessionInvalidationErrorUserCanceled:
                userError = NFCPassportReaderError.UserCanceled
            case NFCReaderError.readerSessionInvalidationErrorSessionTimeout:
                userError = NFCPassportReaderError.TimeOutError
            default:
                userError = NFCPassportReaderError.UnexpectedError
            }
        }
        _ = settlement.record(.failure(userError), by: .sessionInvalidation)
        tagTasks.cancel()
        let finishedSettlement = settlement
        let finishedTasks = tagTasks
        Task {
            await finishedTasks.drain()
            finishedSettlement.release()
        }
    }
    
    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let attempt = claimTagTask(for: session) else {
            Logger.passportReader.info("ignored duplicate or stale tag detection")
            return
        }
        if tags.count > 1 {

            let errorMessage = NFCViewDisplayMessage.error(.MoreThanOneTagFound)
            self.invalidateSession(
                session: session, attempt: attempt, errorMessage: errorMessage,
                error: NFCPassportReaderError.MoreThanOneTagFound)
            return
        }

        let tag = tags.first!
        var passportTag: NFCISO7816Tag
        switch tags.first! {
        case let .iso7816(tag):
            passportTag = tag
        default:
            Logger.passportReader.debug( "tagReaderSession:invalid tag detected!!!" )

            let errorMessage = NFCViewDisplayMessage.error(NFCPassportReaderError.TagNotValid)
            self.invalidateSession(
                session: session, attempt: attempt, errorMessage:errorMessage,
                error: NFCPassportReaderError.TagNotValid)
            return
        }
        
        tagTasks.start { [passportTag] in
            do {
                try Task.checkCancellation()
                try await session.connect(to: tag)
                try Task.checkCancellation()
                
                Logger.passportReader.debug( "tagReaderSession:connected to tag - starting authentication" )
                self.updateReaderSessionMessage( alertMessage: NFCViewDisplayMessage.authenticatingWithPassport(0) )
                
                let tagReader = TagReader(tag:passportTag)
                
                if let newAmount = self.dataAmountToReadOverride {
                    tagReader.overrideDataAmountToRead(newAmount: newAmount)
                }
                
                tagReader.progress = { [unowned self] (progress) in
                    if let dgId = self.currentlyReadingDataGroup {
                        self.updateReaderSessionMessage( alertMessage: NFCViewDisplayMessage.readingDataGroupProgress(dgId, progress) )
                    } else {
                        self.updateReaderSessionMessage( alertMessage: NFCViewDisplayMessage.authenticatingWithPassport(progress) )
                    }
                }
                
                let passportModel = try await self.startReading( tagReader : tagReader)
                // Record success before closing this exact session.
                // Its invalidation callback releases the continuation; verification cannot start
                // before that callback confirms the session is invalid.
                if self.recordSuccessfulRead(
                    passportModel, in: session, attempt: attempt)
                {
                    session.invalidate()
                }

                
            } catch {

                if Self.shouldRestartPolling(after: error) {
                    self.restartPollingAfterTransientTagLoss(in: session, attempt: attempt)
                    return
                }

                // A session-ending APDU error does not identify the termination reason.
                // Leave that outcome to this session's invalidation callback, which can
                // distinguish cancellation and timeout from a protocol failure.
                if let abort = Self.readTaskAbortError(for: error) {
                    let errorMessage = NFCViewDisplayMessage.error(abort)
                    self.invalidateSession(
                        session: session, attempt: attempt, errorMessage: errorMessage, error: abort)
                } else {
                    Logger.passportReader.info( "in-flight command failed because the session is already ending; its invalidation callback decides the outcome" )
                }
            }
        }
    }
    
    func updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage ) {
        self.currentSession?.alertMessage = self.nfcViewDisplayMessageHandler?(alertMessage) ?? alertMessage.description
    }

    /// Classifies whether the tag task can settle a failure or must await session invalidation.
    ///
    /// Returns the error the task should abort the session with, or nil when the task must NOT
    /// decide — the session itself is already ending, and only its `didInvalidateWithError`
    /// callback knows why (`CoreNFC/NFCError.h`: transceive 103 `sessionInvalidated` is what an
    /// in-flight `sendCommand` throws; the 200-family invalidation reasons go to the delegate).
    /// A nil here never hangs the read: CoreNFC always delivers the invalidation callback for a
    /// begun session, and the settlement holds the caller until that callback releases it.
    static func readTaskAbortError(for error: Error) -> NFCPassportReaderError? {
        if let readerError = error as? NFCPassportReaderError {
            if case .Unknown(let underlyingError) = readerError {
                return readTaskAbortError(for: underlyingError)
            }
            return readerError
        }
        guard let nfcError = error as? NFCReaderError else { return .Unknown(error) }
        switch nfcError.code {
        // Preserve a typed fallback for callers of this decision function. The live tag task
        // routes these same physical transport errors through `shouldRestartPolling` first.
        case .readerTransceiveErrorTagConnectionLost,
             .readerTransceiveErrorRetryExceeded,
             .readerTransceiveErrorTagResponseError,
             .readerTransceiveErrorTagNotConnected:
            return .ConnectionError
        case .readerTransceiveErrorSessionInvalidated,
             .readerSessionInvalidationErrorUserCanceled,
             .readerSessionInvalidationErrorSessionTimeout,
             .readerSessionInvalidationErrorSessionTerminatedUnexpectedly,
             .readerSessionInvalidationErrorSystemIsBusy:
            return nil
        default:
            return .Unknown(error)
        }
    }

    /// Only physical RF loss is retryable inside a live session. Session-ending errors must still
    /// be decided by `didInvalidateWithError`; reader/protocol failures remain terminal.
    static func shouldRestartPolling(after error: Error) -> Bool {
        if let readerError = error as? NFCPassportReaderError {
            if case .ConnectionError = readerError { return true }
            if case .Unknown(let underlyingError) = readerError {
                return shouldRestartPolling(after: underlyingError)
            }
            return false
        }
        guard let nfcError = error as? NFCReaderError else { return false }
        switch nfcError.code {
        case .readerTransceiveErrorTagConnectionLost,
             .readerTransceiveErrorRetryExceeded,
             .readerTransceiveErrorTagResponseError,
             .readerTransceiveErrorTagNotConnected:
            return true
        default:
            return false
        }
    }

    /// Transport loss must escape PACE/CA fallback so the outer tag-attempt lifecycle can restart
    /// polling; a dead session must escape so its invalidation callback remains the sole decider.
    static func shouldEscapeProtocolFallback(after error: Error) -> Bool {
        if error is CancellationError { return true }
        if case NFCPassportReaderError.Unknown(let underlying) = error {
            return shouldEscapeProtocolFallback(after: underlying)
        }
        return shouldRestartPolling(after: error) || readTaskAbortError(for: error) == nil
    }
}

@available(iOS 15, *)
extension PassportReader {
    
    /// Shared access-control path for CoreNFC and the synthetic APDU harness.
    func establishAccessControl(tagReader: TagReader, mrzKey: String) async throws -> NFCPassportModel {
        if !skipPACE {
            var paceStage = "cardAccess"
            var paceHandler: PACEHandler?
            do {
                trackingDelegate?.paceStarted()

                let data = try await tagReader.readCardAccess { paceStage = $0 }
                paceStage = "parameters"
                let cardAccess = try CardAccess(data)
                passport.cardAccess = cardAccess

                trackingDelegate?.readCardAccess(cardAccess: cardAccess)

                Logger.passportReader.info( "Starting Password Authenticated Connection Establishment (PACE)" )
                 
                let handler = try PACEHandler( cardAccess: cardAccess, tagReader: tagReader )
                paceHandler = handler
                paceStage = "authentication"
                try await handler.doPACE(mrzKey: mrzKey )
                passport.PACEStatus = .success
                Logger.passportReader.debug( "PACE Succeeded" )

                trackingDelegate?.paceSucceeded()
            } catch {
                trackingDelegate?.paceFailed()

                if Self.shouldEscapeProtocolFallback(after: error) {
                    throw error
                }

                passport.PACEStatus = .failed
                passport.paceFailureStage = paceHandler?.stage ?? paceStage
                // Closed diagnostic categories and APDU status only; never keys, payloads or error text.
                passport.paceFailureCode = "other"
                if let failure = error as? NFCPassportReaderError {
                    switch failure {
                    case .ResponseError(_, let sw1, let sw2):
                        let status = Int(sw1) << 8 | Int(sw2)
                        passport.paceFailureStatusWord = status
                        passport.paceFailureCode = paceStage == "cardAccess" && status == 0x6A82
                            ? "cardAccessAbsent" : "cardResponse"
                    case .NotYetSupported:
                        passport.paceFailureCode = paceStage == "parameters" && passport.cardAccess?.paceInfo == nil
                            ? "noRecognizedPACEInfo" : "unsupportedParameters"
                    case .UnsupportedCipherAlgorithm, .UnsupportedMappingType, .NotImplemented:
                        passport.paceFailureCode = "unsupportedParameters"
                    case .PACEError:
                        passport.paceFailureCode = "protocolFailure"
                    case .CannotDecodeASN1Length, .InvalidASN1Value, .MissingMandatoryFields:
                        passport.paceFailureCode = "invalidParameters"
                    default: break
                    }
                }
                Logger.passportReader.error( "PACE Failed - falling back to BAC" )
            }
            
            _ = try await tagReader.selectPassportApplication()
        }
        
        // If either PACE isn't supported, we failed whilst doing PACE or we didn't even attempt it, then fall back to BAC
        if passport.PACEStatus != .success {
            do {
                trackingDelegate?.bacStarted()
                try await doBACAuthentication(tagReader: tagReader, accessKey: mrzKey)
                trackingDelegate?.bacSucceeded()
            } catch {
                trackingDelegate?.bacFailed()
                throw error
            }
        }
        
        return passport
    }

    func startReading(tagReader : TagReader) async throws -> NFCPassportModel {
        trackingDelegate?.nfcTagDetected()

        _ = try await establishAccessControl(tagReader: tagReader, mrzKey: mrzKey)

        // Read data groups under the established access-control channel.
        try await readDataGroups(tagReader: tagReader)

        try await finishAuthentication(tagReader: tagReader)
        return self.passport
    }

    /// The production post-read sequence is shared with the synthetic APDU harness.
    /// Remote CA is last because its replacement channel belongs exclusively to the terminal.
    func finishAuthentication(tagReader: TagReader) async throws {
        try await doActiveAuthenticationIfNeccessary(tagReader : tagReader)

        // Run terminal Chip Authentication last; the terminal owns the replacement channel.
        try await doTerminalChipAuthenticationIfNecessary(tagReader: tagReader)

        self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.successfulRead)
        // No NFC work remains. Passive authentication runs after the session closes, outside
        // CoreNFC's timeout budget. The caller resumes only after matching invalidation.
    }
    
    
    func doActiveAuthenticationIfNeccessary( tagReader : TagReader) async throws {
        guard self.passport.activeAuthenticationSupported else {
            return
        }
        self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.activeAuthentication)

        Logger.passportReader.info( "Performing Active Authentication" )

        let challenge = aaChallenge ?? generateRandomUInt8Array(8)
        let response = try await tagReader.doInternalAuthentication(challenge: challenge, useExtendedMode: useExtendedMode)
        self.passport.verifyActiveAuthentication( challenge:challenge, signature:response.data )
    }
    

    /// Relays the terminal's public key and protected command, then retains the chip response.
    /// The terminal derives and verifies its own channel; this reader cannot certify that result.
    func doTerminalChipAuthenticationIfNecessary(tagReader: TagReader) async throws {
        guard let terminal = chipAuthenticationTerminal,
              let dg14 = passport.getDataGroup(.DG14) as? DataGroup14 else { return }
        let handler = ChipAuthenticationHandler(dg14: dg14, tagReader: tagReader)
        guard handler.isChipAuthenticationSupported else { return }
        let challenge = try await terminal(dg14.data)
        try await handler.sendTerminalPublicKey(
            oid: challenge.protocolOID, keyId: challenge.keyID, publicKey: challenge.terminalPublicKey)
        tagReader.secureMessaging = nil
        guard let command = NFCISO7816APDU(data: Data(challenge.protectedCommand)) else {
            throw NFCPassportReaderError.InvalidDataPassed("Protected command is not an APDU")
        }
        let (data, sw1, sw2) = try await tagReader.transmit(command)
        passport.chipAuthenticationTerminalResponse = [UInt8](data) + [sw1, sw2]
    }

    func doBACAuthentication(tagReader : TagReader, accessKey: String? = nil) async throws {
        self.currentlyReadingDataGroup = nil

        Logger.passportReader.info( "Starting Basic Access Control (BAC)" )
        
        self.passport.BACStatus = .failed

        self.bacHandler = BACHandler( tagReader: tagReader )
        try await bacHandler?.performBACAndGetSessionKeys( mrzKey: accessKey ?? mrzKey )
        Logger.passportReader.info( "Basic Access Control (BAC) - SUCCESS!" )

        self.passport.BACStatus = .success
    }

    func readDataGroups( tagReader: TagReader ) async throws {
        
        // Read COM
        var DGsToRead = [DataGroupId]()

        self.updateReaderSessionMessage( alertMessage: NFCViewDisplayMessage.readingDataGroupProgress(.COM, 0) )
        
        if let com = try await readDataGroup(tagReader:tagReader, dgId:.COM) as? COM {
            self.passport.addDataGroup( .COM, dataGroup:com )
            self.addDatagroupsToRead(com: com, to: &DGsToRead)
        }
        
        if DGsToRead.contains( .DG14 ) && chipAuthenticationTerminal != nil {
            // Retain DG14 under the access channel. The terminal uses it after all reads finish.
            DGsToRead.removeAll { $0 == .DG14 }
            if let dg14 = try await readDataGroup(tagReader:tagReader, dgId:.DG14) as? DataGroup14 {
                self.passport.addDataGroup( .DG14, dataGroup:dg14 )
            }
        } else if DGsToRead.contains( .DG14 ) {

            if !skipCA {
                // If we have been explicitly asked to read DG14 and we will be remove it from the list as we are reading it now.
                DGsToRead.removeAll { $0 == .DG14 }

                // Do Chip Authentication
                if let dg14 = try await readDataGroup(tagReader:tagReader, dgId:.DG14) as? DataGroup14 {
                    self.passport.addDataGroup( .DG14, dataGroup:dg14 )
                    self.caHandler = ChipAuthenticationHandler(dg14: dg14, tagReader: tagReader)

                    if let caHandler = self.caHandler, caHandler.isChipAuthenticationSupported {
                        do {
                            // Do Chip authentication and then continue reading datagroups
                            try await caHandler.doChipAuthentication()
                            self.passport.chipAuthenticationStatus = .success
                        } catch {
                            if Self.shouldEscapeProtocolFallback(after: error) {
                                throw error
                            }
                            Logger.passportReader.info( "Chip Authentication failed - re-establishing BAC")
                            self.passport.chipAuthenticationStatus = .failed
                            
                            // Failed Chip Auth, need to re-establish BAC
                            try await doBACAuthentication(tagReader: tagReader)
                        }
                    }
                }
            }
        }

        // If we are skipping secure elements then remove .DG3 and .DG4
        if self.skipSecureElements {
            DGsToRead = DGsToRead.filter { $0 != .DG3 && $0 != .DG4 }
        }

        if self.readAllDatagroups != true {
            DGsToRead = DGsToRead.filter { dataGroupsToRead.contains($0) }
        }
        for dgId in DGsToRead {
            self.updateReaderSessionMessage( alertMessage: NFCViewDisplayMessage.readingDataGroupProgress(dgId, 0) )
            if let dg = try await readDataGroup(tagReader:tagReader, dgId:dgId) {
                self.passport.addDataGroup( dgId, dataGroup:dg )
            }
        }
    }
    
    func readDataGroup( tagReader : TagReader, dgId : DataGroupId ) async throws -> DataGroup?  {

        self.currentlyReadingDataGroup = dgId
        var readAttempts = 0
        var nfcPassportReaderError: NFCPassportReaderError
        
        self.updateReaderSessionMessage( alertMessage: NFCViewDisplayMessage.readingDataGroupProgress(dgId, 0) )

        repeat {
            do {
                let response = try await tagReader.readDataGroup(dataGroup:dgId)
                let dg = try DataGroupParser().parseDG(data: response)
                return dg
            } catch let error as NFCPassportReaderError {
                nfcPassportReaderError = error

                if Self.shouldEscapeProtocolFallback(after: error) {
                    throw error
                }

                // OK we had an error - depending on what happened, we may want to try to re-read this
                // E.g. we failed to read the last Datagroup because its protected and we can't
                let errMsg = error.value
                var redoBAC = false
                if errMsg == "Session invalidated" || errMsg == "Class not supported" || errMsg == "Tag connection lost" || errMsg == "Tag response error / no response" {
                    // Check if we have done Chip Authentication, if so, set it to nil and try to redo BAC
                    if self.caHandler != nil {
                        self.caHandler = nil
                        redoBAC = true
                    } else {
                        // Can't go any more!
                        throw error
                    }
                } else if errMsg == "Security status not satisfied" || errMsg == "File not found" {
                    // Drop a pending protected group before retrying BAC. Repeated refusals can
                    // exhaust the queue, so removal requires a remaining element.
                    if !self.dataGroupsToRead.isEmpty {
                        self.dataGroupsToRead.removeFirst()
                    }
                    redoBAC = true
                } else if errMsg == "SM data objects incorrect" || errMsg == "Class not supported" {
                    // Can't read this element security objects now invalid - and return out so we re-do BAC
                    redoBAC = true
                } else if errMsg.hasPrefix( "Wrong length" ) || errMsg.hasPrefix( "End of file" ) {  // Should now handle errors 0x6C xx, and 0x67 0x00
                    // OK passport can't handle max length so drop it down
                    tagReader.reduceDataReadingAmount()
                    redoBAC = true
                } else if errMsg == "UnsupportedDataGroup" {
                    // OK, this DataGroup is not supported, lets skip it
                    return nil
                }
                
                if redoBAC {
                    // Redo BAC and try again
                    try await doBACAuthentication(tagReader : tagReader)
                } else {
                    // Some other error lets have another try
                }
            }
            readAttempts += 1
        } while ( readAttempts < 2 )

        // The error will be thrown after n attempts
        throw nfcPassportReaderError
    }

    func invalidateSession(
        session: NFCTagReaderSession,
        attempt: Int,
        errorMessage: NFCViewDisplayMessage,
        error: NFCPassportReaderError
    ) {
        // Record the outcome before closing this session. Its invalidation callback releases
        // the continuation; callbacks from a different session cannot settle this read.
        readStateLock.lock()
        let shouldInvalidate = readerSession === session
            && tagAttemptLifecycle.handle(.fatalFailure(attempt)) == .settleFailure
            && settlement.record(.failure(error), by: .readerAbort)
        readStateLock.unlock()
        if shouldInvalidate {
            session.invalidate(
                errorMessage: self.nfcViewDisplayMessageHandler?(errorMessage) ?? errorMessage.description)
        }
    }
    
    internal func addDatagroupsToRead(com: COM, to DGsToRead: inout [DataGroupId]) {
        DGsToRead += com.dataGroupsPresent.compactMap { DataGroupId.getIDFromName(name:$0) }
        DGsToRead.removeAll { $0 == .COM }
        
        // SOD should not be present in COM, but just in case we check before adding it so its not read twice
        if !DGsToRead.contains(.SOD) { DGsToRead.insert(.SOD, at: 0) }
    }
}
#endif
