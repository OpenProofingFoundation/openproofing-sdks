import XCTest

@testable import KenshikiPulsePassport

final class PulsePassportSessionStateTests: XCTestCase {
    typealias State = PulsePassportSessionState<String, String>

    func testPreparedLiveCeremonyIsReusedWithoutAnotherServerPreparation() throws {
        var state = State()
        let preparation = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        XCTAssertTrue(state.acceptPrepared(ceremony: "ceremony-1", generation: preparation.generation))

        let retry = try XCTUnwrap(state.begin(using: "unused-attempt").reuse)
        XCTAssertEqual(state.attempt, "attempt-1")
        XCTAssertEqual(retry.ceremony, "ceremony-1")
        XCTAssertNil(state.failurePresentation)
    }

    func testTransportFailurePreservesTheCompleteAttempt() throws {
        var state = State()
        let preparation = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        let resolution = PulsePassportPreparationFailureClassifier.classify(.transport)

        XCTAssertNil(
            state.resolvePreparationFailure(
                resolution,
                generation: preparation.generation,
                replacementAttempt: "unused-attempt"))

        let retry = try XCTUnwrap(state.begin(using: "another-unused-attempt").preparation)
        XCTAssertEqual(retry.attempt, "attempt-1")
        XCTAssertEqual(state.failurePresentation, nil)
    }

    func testCancelledPreparationReturnsToIdleAndPreservesTheCompleteAttempt() throws {
        var state = State()
        let preparation = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        let resolution = PulsePassportPreparationFailureClassifier.classify(.cancelled)

        XCTAssertNil(
            state.resolvePreparationFailure(
                resolution,
                generation: preparation.generation,
                replacementAttempt: "unused-attempt"))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.failurePresentation)

        let retry = try XCTUnwrap(state.begin(using: "another-unused-attempt").preparation)
        XCTAssertEqual(retry.attempt, "attempt-1")
    }

    func testRateLimitAndServerFailurePreserveTheCompleteAttempt() throws {
        for status in [429, 503] {
            var state = State()
            let preparation = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
            let resolution = PulsePassportPreparationFailureClassifier.classify(
                .http(status: status, code: nil, reason: nil))

            XCTAssertNil(
                state.resolvePreparationFailure(
                    resolution,
                    generation: preparation.generation,
                    replacementAttempt: "unused-attempt"))

            let retry = try XCTUnwrap(state.begin(using: "another-unused-attempt").preparation)
            XCTAssertEqual(retry.attempt, "attempt-1")
        }
    }

    func testExpiryInvalidatesCeremonyAndRotatesTheAttempt() throws {
        var state = State()
        let preparation = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        XCTAssertTrue(state.acceptPrepared(ceremony: "ceremony-1", generation: preparation.generation))

        let replacement = state.expireChallenge(replacingWith: "attempt-2")

        XCTAssertEqual(replacement.attempt, "attempt-2")
        XCTAssertEqual(state.attempt, "attempt-2")
        XCTAssertNil(state.ceremony)
        XCTAssertEqual(state.phase, .preparing)
    }

    func testTakingCeremonyForVerificationInvalidatesItsAttemptImmediately() throws {
        var state = State()
        let preparation = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        XCTAssertTrue(state.acceptPrepared(ceremony: "ceremony-1", generation: preparation.generation))

        XCTAssertEqual(state.takeCeremonyForVerification(), "ceremony-1")
        XCTAssertNil(state.attempt)
        XCTAssertNil(state.ceremony)
        XCTAssertEqual(state.phase, .completed)
    }

    func testStalePreparationCompletionCannotReplaceNewerAttempt() throws {
        var state = State()
        let stale = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        let expired = PulsePassportPreparationFailureClassifier.classify(
            .http(status: 410, code: "challenge_expired", reason: nil))
        let current = try XCTUnwrap(
            state.resolvePreparationFailure(
                expired,
                generation: stale.generation,
                replacementAttempt: "attempt-2"))

        XCTAssertFalse(state.acceptPrepared(ceremony: "stale-ceremony", generation: stale.generation))
        XCTAssertEqual(state.attempt, "attempt-2")
        XCTAssertNil(state.ceremony)
        XCTAssertTrue(state.acceptPrepared(ceremony: "current-ceremony", generation: current.generation))
    }

    func testTakingCeremonyOutsideChallengeReadyDoesNothing() throws {
        var state = State()
        _ = try XCTUnwrap(state.begin(using: "attempt-1").preparation)

        XCTAssertNil(state.takeCeremonyForVerification())
        XCTAssertEqual(state.phase, .preparing)
        XCTAssertEqual(state.attempt, "attempt-1")
    }

    func testConflictAutomaticallyRotatesAtMostOnce() throws {
        var state = State()
        let first = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        let conflict = PulsePassportPreparationFailureClassifier.classify(
            .http(
                status: 409,
                code: "invalid_state_transition",
                reason: "identity_session_create_idempotency_conflict"))

        let recovery = try XCTUnwrap(
            state.resolvePreparationFailure(
                conflict,
                generation: first.generation,
                replacementAttempt: "attempt-2"))
        XCTAssertEqual(recovery.attempt, "attempt-2")

        XCTAssertNil(
            state.resolvePreparationFailure(
                conflict,
                generation: recovery.generation,
                replacementAttempt: "attempt-3"))
        XCTAssertEqual(state.attempt, "attempt-2")
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.failurePresentation, .internalFailure)

        let explicitRetry = try XCTUnwrap(state.begin(using: "attempt-3").preparation)
        XCTAssertEqual(explicitRetry.attempt, "attempt-3")
        XCTAssertEqual(state.phase, .preparing)

        let secondFlowRecovery = try XCTUnwrap(
            state.resolvePreparationFailure(
                conflict,
                generation: explicitRetry.generation,
                replacementAttempt: "attempt-4"))
        XCTAssertEqual(secondFlowRecovery.attempt, "attempt-4")
    }

    func testExpiredServerResponseAutomaticallyRotatesAtMostOnce() throws {
        var state = State()
        let first = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        let expired = PulsePassportPreparationFailureClassifier.classify(
            .http(status: 410, code: "challenge_expired", reason: nil))

        let recovery = try XCTUnwrap(
            state.resolvePreparationFailure(
                expired,
                generation: first.generation,
                replacementAttempt: "attempt-2"))
        XCTAssertEqual(recovery.attempt, "attempt-2")

        XCTAssertNil(
            state.resolvePreparationFailure(
                expired,
                generation: recovery.generation,
                replacementAttempt: "attempt-3"))
        XCTAssertEqual(state.attempt, "attempt-2")
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.failurePresentation, .challengeExpired)

        let explicitRetry = try XCTUnwrap(state.begin(using: "attempt-3").preparation)
        XCTAssertEqual(explicitRetry.attempt, "attempt-3")
        XCTAssertEqual(state.phase, .preparing)

        let secondFlowRecovery = try XCTUnwrap(
            state.resolvePreparationFailure(
                expired,
                generation: explicitRetry.generation,
                replacementAttempt: "attempt-4"))
        XCTAssertEqual(secondFlowRecovery.attempt, "attempt-4")
    }

    func testStaleSignedAttemptAutomaticallyRotatesAtMostOnce() throws {
        var state = State()
        let first = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        let stale = PulsePassportPreparationFailureClassifier.classify(
            .http(status: 403, code: "verification_failed", reason: "invalid_issued_at"))

        let recovery = try XCTUnwrap(
            state.resolvePreparationFailure(
                stale,
                generation: first.generation,
                replacementAttempt: "attempt-2"))
        XCTAssertEqual(recovery.attempt, "attempt-2")

        XCTAssertNil(
            state.resolvePreparationFailure(
                stale,
                generation: recovery.generation,
                replacementAttempt: "attempt-3"))
        XCTAssertEqual(state.attempt, "attempt-2")
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.failurePresentation, .challengeExpired)

        let explicitRetry = try XCTUnwrap(state.begin(using: "attempt-3").preparation)
        XCTAssertEqual(explicitRetry.attempt, "attempt-3")
    }

    func testStoppedFailureRetriesTheSameAttempt() throws {
        var state = State()
        let preparation = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        let stopped = PulsePassportPreparationFailureClassifier.classify(.invalidResponse)

        XCTAssertNil(
            state.resolvePreparationFailure(
                stopped,
                generation: preparation.generation,
                replacementAttempt: "unused-attempt"))

        let retry = try XCTUnwrap(state.begin(using: "another-unused-attempt").preparation)
        XCTAssertEqual(retry.attempt, "attempt-1")
    }

    func testCompletedFlowStartsWithFreshAttemptAndRecoveryBudgets() throws {
        var state = State()
        let first = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        let conflict = PulsePassportPreparationFailureClassifier.classify(
            .http(
                status: 409,
                code: "invalid_state_transition",
                reason: "identity_session_create_idempotency_conflict"))
        let recovered = try XCTUnwrap(
            state.resolvePreparationFailure(
                conflict,
                generation: first.generation,
                replacementAttempt: "attempt-2"))
        XCTAssertTrue(state.acceptPrepared(ceremony: "ceremony-1", generation: recovered.generation))
        XCTAssertEqual(state.takeCeremonyForVerification(), "ceremony-1")

        let next = try XCTUnwrap(state.begin(using: "attempt-3").preparation)
        XCTAssertEqual(next.attempt, "attempt-3")
        XCTAssertEqual(state.phase, .preparing)

        let nextRecovery = try XCTUnwrap(
            state.resolvePreparationFailure(
                conflict,
                generation: next.generation,
                replacementAttempt: "attempt-4"))
        XCTAssertEqual(nextRecovery.attempt, "attempt-4")
    }

    func testStaleFailureCannotReplaceCurrentPreparation() throws {
        var state = State()
        let stale = try XCTUnwrap(state.begin(using: "attempt-1").preparation)
        let current = state.expireChallenge(replacingWith: "attempt-2")
        let failure = PulsePassportPreparationFailureClassifier.classify(.transport)

        XCTAssertNil(
            state.resolvePreparationFailure(
                failure,
                generation: stale.generation,
                replacementAttempt: "unused-attempt"))
        XCTAssertEqual(state.phase, .preparing)
        XCTAssertEqual(state.attempt, "attempt-2")
        XCTAssertTrue(state.acceptPrepared(ceremony: "ceremony-2", generation: current.generation))
    }
}

extension PulsePassportPreparationDecision {
    fileprivate var preparation: PulsePassportPreparationWork<Attempt>? {
        guard case .prepare(let work) = self else { return nil }
        return work
    }

    fileprivate var reuse: PulsePassportScanWork<Ceremony>? {
        guard case .reuse(let work) = self else { return nil }
        return work
    }
}
