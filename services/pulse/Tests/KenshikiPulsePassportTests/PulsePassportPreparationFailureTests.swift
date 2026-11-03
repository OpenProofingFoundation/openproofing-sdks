import XCTest

@testable import KenshikiPulsePassport

final class PulsePassportPreparationFailureTests: XCTestCase {
    func testTypedWorkerFailureMapsWithoutParsingServerProse() {
        let failure = PulsePassportHTTPFailure(
            statusCode: 409,
            code: "invalid_state_transition",
            reason: "identity_session_create_idempotency_conflict", classification: .conflict)

        XCTAssertEqual(
            PulsePassportPreparationFailureClassifier.failure(from: failure),
            .http(
                status: 409,
                code: "invalid_state_transition",
                reason: "identity_session_create_idempotency_conflict"))
    }

    func testNetworkFailureMapsToTransportAndOtherDeviceFailuresDoNot() {
        XCTAssertEqual(
            PulsePassportPreparationFailureClassifier.failure(
                from: URLError(.notConnectedToInternet)),
            .transport)
        XCTAssertEqual(
            PulsePassportPreparationFailureClassifier.failure(
                from: PulsePassportFailure.invalidResponse),
            .invalidResponse)
    }

    func testCancellationPreservesTheAttemptWithoutAnOwnerError() {
        let resolution = PulsePassportPreparationFailureClassifier.classify(.cancelled)

        XCTAssertEqual(resolution.recovery, .preserveAttempt)
        XCTAssertNil(resolution.presentation)
    }

    func testOnlyTransportFailureIsClassifiedAsAConnectionProblem() {
        let transport = PulsePassportPreparationFailureClassifier.classify(.transport)
        let service = PulsePassportPreparationFailureClassifier.classify(
            .http(status: 503, code: "temporarily_unavailable", reason: nil))

        XCTAssertEqual(transport.presentation, .connection)
        XCTAssertEqual(service.presentation, .serviceUnavailable)
    }

    func testRateLimitAndServerFailuresPreserveTheSignedAttempt() {
        for status in [429, 500, 503, 599] {
            let resolution = PulsePassportPreparationFailureClassifier.classify(
                .http(status: status, code: nil, reason: nil))

            XCTAssertEqual(resolution.recovery, .preserveAttempt)
            XCTAssertEqual(resolution.presentation, .serviceUnavailable)
        }
    }

    func testAuthenticationFailuresStopWithoutPretendingTheNetworkFailed() {
        for status in [401, 403] {
            let resolution = PulsePassportPreparationFailureClassifier.classify(
                .http(status: status, code: "unauthorized", reason: nil))

            XCTAssertEqual(resolution.recovery, .stop)
            XCTAssertEqual(resolution.presentation, .deviceRegistration)
        }
    }

    func testExpiredSignedAttemptRotatesInsteadOfBecomingADeviceRegistrationLoop() {
        let resolution = PulsePassportPreparationFailureClassifier.classify(
            .http(
                status: 403,
                code: "verification_failed",
                reason: "invalid_issued_at"))

        XCTAssertEqual(resolution.recovery, .rotateStaleAttemptOnce)
        XCTAssertEqual(resolution.presentation, .challengeExpired)
    }

    func testExpiredChallengeRotatesTheAttempt() {
        let resolution = PulsePassportPreparationFailureClassifier.classify(
            .http(status: 410, code: "challenge_expired", reason: nil))

        XCTAssertEqual(resolution.recovery, .rotateExpiredAttempt)
        XCTAssertEqual(resolution.presentation, .challengeExpired)
    }

    func testIdentitySessionConflictRequestsOneBoundedRotation() {
        let resolution = PulsePassportPreparationFailureClassifier.classify(
            .http(
                status: 409,
                code: "invalid_state_transition",
                reason: "identity_session_create_idempotency_conflict"))

        XCTAssertEqual(resolution.recovery, .rotateConflictedAttemptOnce)
        XCTAssertEqual(resolution.presentation, .internalFailure)
    }

    func testUnknownHTTPAndMalformedResponsesStop() {
        let unknown = PulsePassportPreparationFailureClassifier.classify(
            .http(status: 422, code: "unexpected", reason: nil))
        let malformed = PulsePassportPreparationFailureClassifier.classify(.invalidResponse)

        XCTAssertEqual(unknown.recovery, .stop)
        XCTAssertEqual(unknown.presentation, .internalFailure)
        XCTAssertEqual(malformed.recovery, .stop)
        XCTAssertEqual(malformed.presentation, .internalFailure)
    }

}
