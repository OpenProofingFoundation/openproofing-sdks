import Foundation

/// Stable inputs for deciding what a failed passport-session preparation permits next.
///
/// The transport layer can populate these values once it exposes typed Worker failures. Keeping
/// the decision independent of a concrete SDK error prevents UI code from parsing response bodies
/// or guessing that every failure is a connectivity problem.
enum PulsePassportPreparationFailure: Equatable, Sendable {
    case cancelled
    case transport
    case http(status: Int, code: String?, reason: String?)
    case invalidResponse
}

/// The recovery operation allowed after session preparation fails.
enum PulsePassportPreparationRecovery: Equatable, Sendable {
    /// The signed attempt may be replayed byte-for-byte.
    case preserveAttempt
    /// The old challenge is definitively unusable, so the complete attempt must rotate.
    case rotateExpiredAttempt
    /// A server conflict permits one bounded rotation, never a retry loop.
    case rotateConflictedAttemptOnce
    /// The signed create timestamp is no longer admissible; replace the complete attempt once.
    case rotateStaleAttemptOnce
    /// Retrying without an explicit restart would be misleading or unsafe.
    case stop
}

/// Semantic holder-facing outcomes. Copy remains owned by the app's copy facade.
enum PulsePassportFailurePresentation: Equatable, Sendable {
    case connection
    case serviceUnavailable
    case deviceRegistration
    case challengeExpired
    case internalFailure
}

struct PulsePassportPreparationResolution: Equatable, Sendable {
    let recovery: PulsePassportPreparationRecovery
    let presentation: PulsePassportFailurePresentation?
}

enum PulsePassportPreparationFailureClassifier {
    static func failure(from error: Error) -> PulsePassportPreparationFailure {
        if error is CancellationError { return .cancelled }
        if let workerFailure = error as? PulsePassportHTTPFailure {
            return .http(
                status: workerFailure.statusCode,
                code: workerFailure.code,
                reason: workerFailure.reason)
        }
        if let value=PulsePassportClient.classification(error) {
            switch value {case .timedOut,.unavailable,.rateLimited:return .transport;case .challengeExpired:return .http(status:410,code:"challenge_expired",reason:nil);default:return .invalidResponse}
        }
        if error is URLError {return .transport}
        return .invalidResponse
    }

    static func classify(
        _ failure: PulsePassportPreparationFailure
    ) -> PulsePassportPreparationResolution {
        switch failure {
        case .cancelled:
            return PulsePassportPreparationResolution(
                recovery: .preserveAttempt,
                presentation: nil)
        case .transport:
            return PulsePassportPreparationResolution(
                recovery: .preserveAttempt,
                presentation: .connection)
        case .invalidResponse:
            return PulsePassportPreparationResolution(
                recovery: .stop,
                presentation: .internalFailure)
        case .http(let status, let code, let reason):
            return classifyHTTP(status: status, code: code, reason: reason)
        }
    }

    private static func classifyHTTP(
        status: Int,
        code: String?,
        reason: String?
    ) -> PulsePassportPreparationResolution {
        if status == 409, reason == "identity_session_create_idempotency_conflict" {
            return PulsePassportPreparationResolution(
                recovery: .rotateConflictedAttemptOnce,
                presentation: .internalFailure)
        }
        if status == 410 || code == "challenge_expired" {
            return PulsePassportPreparationResolution(
                recovery: .rotateExpiredAttempt,
                presentation: .challengeExpired)
        }
        if status == 403, reason == "invalid_issued_at" {
            return PulsePassportPreparationResolution(
                recovery: .rotateStaleAttemptOnce,
                presentation: .challengeExpired)
        }
        if status == 401 || status == 403 {
            return PulsePassportPreparationResolution(
                recovery: .stop,
                presentation: .deviceRegistration)
        }
        if status == 429 || (500...599).contains(status) {
            return PulsePassportPreparationResolution(
                recovery: .preserveAttempt,
                presentation: .serviceUnavailable)
        }
        return PulsePassportPreparationResolution(
            recovery: .stop,
            presentation: .internalFailure)
    }
}

