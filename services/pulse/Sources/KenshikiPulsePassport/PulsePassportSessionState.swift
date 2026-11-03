struct PulsePassportPreparationWork<Attempt> {
    let attempt: Attempt
    let generation: Int
}

struct PulsePassportScanWork<Ceremony> {
    let ceremony: Ceremony
}

enum PulsePassportPreparationDecision<Attempt, Ceremony> {
    case prepare(PulsePassportPreparationWork<Attempt>)
    case reuse(PulsePassportScanWork<Ceremony>)
}

/// Pure server-preparation lifecycle for one holder-owned passport ceremony.
///
/// Attempt and ceremony are generic so this reducer owns transitions without duplicating SDK wire
/// types. NFC presentation and scan-task generations belong to the adopting host; this state
/// owns only the attempt sent to the server, its prepared challenge, and preparation recovery.
/// Every asynchronous preparation receives a generation, and only its current owner may complete.
struct PulsePassportSessionState<Attempt, Ceremony> {
    enum Phase: Equatable {
        case idle
        case preparing
        case challengeReady
        case failed
        case completed
    }

    private enum HolderRetryDisposition {
        case preserveAttempt
        case replaceAttemptAndResetRecovery
    }

    private(set) var phase: Phase = .idle
    private(set) var attempt: Attempt?
    private(set) var ceremony: Ceremony?
    private(set) var generation = 0
    private(set) var failurePresentation: PulsePassportFailurePresentation?
    private var didUseConflictRecovery = false
    private var didUseExpiryRecovery = false
    private var didUseStaleAttemptRecovery = false
    private var holderRetryDisposition = HolderRetryDisposition.preserveAttempt

    mutating func begin(using newAttempt: @autoclosure () -> Attempt)
        -> PulsePassportPreparationDecision<Attempt, Ceremony>
    {
        if phase == .failed, holderRetryDisposition == .replaceAttemptAndResetRecovery {
            return .prepare(restart(with: newAttempt()))
        }
        if let ceremony {
            phase = .challengeReady
            failurePresentation = nil
            return .reuse(PulsePassportScanWork(ceremony: ceremony))
        }

        if phase == .completed {
            attempt = nil
            didUseConflictRecovery = false
            didUseExpiryRecovery = false
            didUseStaleAttemptRecovery = false
        }
        if attempt == nil {
            attempt = newAttempt()
        }
        failurePresentation = nil
        return .prepare(startPreparation())
    }

    mutating func acceptPrepared(ceremony: Ceremony, generation: Int) -> Bool {
        guard phase == .preparing, owns(generation) else { return false }
        self.ceremony = ceremony
        failurePresentation = nil
        holderRetryDisposition = .preserveAttempt
        phase = .challengeReady
        return true
    }

    /// A delivered chip result must never leave its challenge available for a different read.
    /// Verification keeps the returned value, while local state immediately closes the attempt.
    mutating func takeCeremonyForVerification() -> Ceremony? {
        guard phase == .challengeReady, let ceremony else { return nil }
        advanceGeneration()
        attempt = nil
        self.ceremony = nil
        failurePresentation = nil
        holderRetryDisposition = .preserveAttempt
        phase = .completed
        return ceremony
    }

    /// Expiry is definitive: invalidate the challenge and rotate the complete attempt.
    mutating func expireChallenge(
        replacingWith replacement: Attempt
    ) -> PulsePassportPreparationWork<Attempt> {
        restart(with: replacement)
    }

    /// Applies one classified preparation failure and returns work only for a bounded auto-recovery.
    mutating func resolvePreparationFailure(
        _ resolution: PulsePassportPreparationResolution,
        generation: Int,
        replacementAttempt: @autoclosure () -> Attempt
    ) -> PulsePassportPreparationWork<Attempt>? {
        guard phase == .preparing, owns(generation) else { return nil }

        switch resolution.recovery {
        case .preserveAttempt:
            advanceGeneration()
            phase = resolution.presentation == nil ? .idle : .failed
            failurePresentation = resolution.presentation
            holderRetryDisposition = .preserveAttempt
            return nil
        case .rotateExpiredAttempt:
            guard !didUseExpiryRecovery else {
                advanceGeneration()
                phase = .failed
                failurePresentation = resolution.presentation
                holderRetryDisposition = .replaceAttemptAndResetRecovery
                return nil
            }
            didUseExpiryRecovery = true
            attempt = replacementAttempt()
            ceremony = nil
            failurePresentation = nil
            return startPreparation()
        case .rotateConflictedAttemptOnce:
            guard !didUseConflictRecovery else {
                advanceGeneration()
                phase = .failed
                failurePresentation = resolution.presentation
                holderRetryDisposition = .replaceAttemptAndResetRecovery
                return nil
            }
            didUseConflictRecovery = true
            attempt = replacementAttempt()
            ceremony = nil
            failurePresentation = nil
            return startPreparation()
        case .rotateStaleAttemptOnce:
            guard !didUseStaleAttemptRecovery else {
                advanceGeneration()
                phase = .failed
                failurePresentation = resolution.presentation
                holderRetryDisposition = .replaceAttemptAndResetRecovery
                return nil
            }
            didUseStaleAttemptRecovery = true
            attempt = replacementAttempt()
            ceremony = nil
            failurePresentation = nil
            return startPreparation()
        case .stop:
            advanceGeneration()
            phase = .failed
            failurePresentation = resolution.presentation
            holderRetryDisposition = .preserveAttempt
            return nil
        }
    }

    /// A holder-created replacement is a new logical flow with fresh bounded-recovery budgets.
    private mutating func restart(
        with replacement: Attempt
    ) -> PulsePassportPreparationWork<Attempt> {
        attempt = replacement
        ceremony = nil
        failurePresentation = nil
        didUseConflictRecovery = false
        didUseExpiryRecovery = false
        didUseStaleAttemptRecovery = false
        holderRetryDisposition = .preserveAttempt
        return startPreparation()
    }

    private mutating func startPreparation() -> PulsePassportPreparationWork<Attempt> {
        guard let attempt else { preconditionFailure("Passport preparation requires an attempt.") }
        advanceGeneration()
        phase = .preparing
        return PulsePassportPreparationWork(attempt: attempt, generation: generation)
    }

    private func owns(_ candidate: Int) -> Bool {
        candidate == generation
    }

    func isCurrentPreparation(generation candidate: Int) -> Bool {
        phase == .preparing && owns(candidate)
    }

    private mutating func advanceGeneration() {
        generation &+= 1
    }
}
