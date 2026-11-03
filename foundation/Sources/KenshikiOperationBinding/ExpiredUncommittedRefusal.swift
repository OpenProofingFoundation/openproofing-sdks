import Foundation

/// Exact nonexecution evidence supplied only by an authenticated service adjudication.
/// Parsing binds the evidence; it does not authenticate an arbitrary caller's response bytes.
public struct ExpiredUncommittedRefusal: Equatable, Sendable {
    public let audience: String
    public let applicationID: String
    public let installationID: String
    public let operationKind: String
    public let operationID: String
    public let targetID: String
    public let generation: String
    public let requestDigest: String
    public let originalExpiresAt: Int64
    public let serverTime: Int64

    private struct Wire: Decodable {
        let v: String
        let status: String
        let audience: String
        let application_id: String
        let installation_id: String
        let operation_kind: String
        let operation_id: String
        let target_id: String
        let generation: String
        let request_digest: String
        let original_expires_at: Int64
        let server_time: Int64
    }

    public init(authenticatedResponse: Data, for operation: SealedOperation) throws {
        guard authenticatedResponse.count <= 16_384 else { throw OperationBindingError.responseMismatch }
        let canonical = try CanonicalJSON.canonicalize(authenticatedResponse)
        guard let object = try JSONSerialization.jsonObject(with: canonical) as? [String: Any],
            Set(object.keys) == ["v", "status", "audience", "application_id", "installation_id", "operation_kind",
                "operation_id", "target_id", "generation", "request_digest", "original_expires_at", "server_time"] else {
            throw OperationBindingError.responseMismatch
        }
        let wire = try JSONDecoder().decode(Wire.self, from: canonical)
        guard wire.v == "kenshiki.protective-expiry-refusal.v1", wire.status == "expired_uncommitted" else {
            throw OperationBindingError.responseMismatch
        }
        audience = wire.audience
        applicationID = wire.application_id
        installationID = wire.installation_id
        operationKind = wire.operation_kind
        operationID = wire.operation_id
        targetID = wire.target_id
        generation = wire.generation
        requestDigest = wire.request_digest
        originalExpiresAt = wire.original_expires_at
        serverTime = wire.server_time
        try validate(for: operation)
    }

    public func validate(for operation: SealedOperation) throws {
        try operation.validate()
        let digest = try operation.clientDataHash().map { String(format: "%02x", $0) }.joined()
        guard audience == operation.audience, applicationID == operation.applicationID,
            installationID == operation.installationID, operationKind == operation.operationKind,
            operationID == operation.operationID, targetID == operation.targetID, generation == operation.generation,
            requestDigest == digest, originalExpiresAt == operation.expiresAt,
            serverTime > originalExpiresAt, serverTime < 9_007_199_254_740_991 else {
            throw OperationBindingError.responseMismatch
        }
    }
}
