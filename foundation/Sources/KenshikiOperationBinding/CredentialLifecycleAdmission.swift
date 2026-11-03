import Foundation

/// Distinguishes admission of new work from settlement of an already admitted authority response.
public struct CredentialLifecycleAdmission: Sendable {
    public let validate: @Sendable () async throws -> Void
    public let persist: @Sendable () async throws -> Void
    public init(validate: @escaping @Sendable () async throws -> Void = { try Task.checkCancellation() }) {
        self.validate = validate
        self.persist = validate
    }
    public init(validate: @escaping @Sendable () async throws -> Void,
        persist: @escaping @Sendable () async throws -> Void) {
        self.validate = validate
        self.persist = persist
    }
}
