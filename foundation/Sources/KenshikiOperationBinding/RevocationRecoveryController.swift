import Foundation

/// A durable authorization must exist before the caller may erase its ordinary credentials.
/// Ports authenticate the service and validate exact request/result binding; this controller
/// owns ordering, restart recovery and immutable preparation, without storing a general bearer.
public enum RevocationRecoveryError: Error, Equatable {
    case authorizationExpiredUncommitted(serverTime: Int64)
}

public actor RevocationRecoveryController {
    public struct Preparation: Sendable {
        public let operation: SealedOperation
        public let bytes: Data
        public init(operation: SealedOperation, bytes: Data) { self.operation = operation; self.bytes = bytes }
    }
    public enum Recovery: Sendable {
        case notAuthorized
        case notAuthorizedExpired(serverTime: Int64)
        case authorized(Data)
        case completed(Data)
    }
    public enum Outcome: Sendable { case authorized; case completed(Data) }
    public struct Ports: Sendable {
        public let prepare: @Sendable (JournalRecord) async throws -> Preparation
        public let authorize: @Sendable (JournalRecord) async throws -> Data
        public let recover: @Sendable (JournalRecord) async throws -> Recovery
        public let execute: @Sendable (JournalRecord) async throws -> Data
        public let validateAuthorization: @Sendable (JournalRecord, Data) throws -> Void
        public let validateCompletion: @Sendable (JournalRecord, Data) throws -> Bool
        public init(
            prepare: @escaping @Sendable (JournalRecord) async throws -> Preparation,
            authorize: @escaping @Sendable (JournalRecord) async throws -> Data,
            recover: @escaping @Sendable (JournalRecord) async throws -> Recovery,
            execute: @escaping @Sendable (JournalRecord) async throws -> Data,
            validateAuthorization: @escaping @Sendable (JournalRecord, Data) throws -> Void,
            validateCompletion: @escaping @Sendable (JournalRecord, Data) throws -> Bool
        ) {
            self.prepare = prepare; self.authorize = authorize; self.recover = recover; self.execute = execute
            self.validateAuthorization = validateAuthorization; self.validateCompletion = validateCompletion
        }
    }
    private struct Flight {
        let id: UUID
        let intentID: String
        let execute: Bool
        let task: Task<Outcome, Error>
    }
    private let journal: OperationJournal
    private var flight: Flight?
    public init(journal: OperationJournal) { self.journal = journal }

    public func authorize(_ intent: JournalIntent, ports: Ports) async throws -> Outcome {
        try await run(intent, execute: false, ports: ports)
    }
    public func executeAuthorized(_ intent: JournalIntent, ports: Ports) async throws -> Outcome {
        try await run(intent, execute: true, ports: ports)
    }
    public func quiesce() async {
        if let active = flight {
            active.task.cancel()
            do { _ = try await active.task.value } catch { /* The durable record remains retryable. */ }
            if flight?.id == active.id { flight = nil }
        }
    }
    private func run(_ intent: JournalIntent, execute: Bool, ports: Ports) async throws -> Outcome {
        if let active = flight {
            if active.intentID == intent.id && active.execute == execute { return try await active.task.value }
            do { _ = try await active.task.value } catch { /* Continue the caller's stronger phase. */ }
            if flight?.id == active.id { flight = nil }
            return try await run(intent, execute: execute, ports: ports)
        }
        let id = UUID()
        let journal = self.journal
        let task = Task { try await Self.perform(journal, intent: intent, execute: execute, ports: ports) }
        flight = Flight(id: id, intentID: intent.id, execute: execute, task: task)
        defer { if flight?.id == id { flight = nil } }
        return try await task.value
    }
    private static func record(_ journal: OperationJournal, _ intent: JournalIntent) throws -> JournalRecord {
        try Task.checkCancellation()
        try journal.validate(intent)
        guard let record = try journal.current(resourceID: intent.resourceID), intent.revoking,
              record.recoveryData != nil else { throw OperationJournalError.missingIntent }
        return record
    }
    private static func perform(_ journal: OperationJournal, intent: JournalIntent, execute: Bool, ports: Ports) async throws -> Outcome {
        var saved = try record(journal, intent)
        if let result = saved.result {
            guard try ports.validateCompletion(saved, result) else { throw OperationBindingError.responseMismatch }
            return .completed(result)
        }
        if saved.prepared == nil {
            guard !execute else { throw OperationJournalError.missingIntent }
            let preparation = try await ports.prepare(saved)
            _ = try record(journal, intent)
            try journal.savePrepared(intent, operation: preparation.operation, bytes: preparation.bytes)
            saved = try record(journal, intent)
        }
        if execute {
            guard let acknowledgement = saved.authorization else { throw OperationJournalError.missingIntent }
            try ports.validateAuthorization(saved, acknowledgement)
            if saved.state == "dispatching" {
                switch try await ports.recover(saved) {
                case .completed(let result):
                    let current = try record(journal, intent)
                    if try ports.validateCompletion(current, result) {
                        try journal.accepted(intent, result: result)
                        return .completed(result)
                    }
                case .authorized: break
                case .notAuthorized, .notAuthorizedExpired: throw OperationJournalError.missingIntent
                }
            }
            _ = try record(journal, intent)
            try journal.beginDispatch(intent)
            let result = try await ports.execute(saved)
            let current = try record(journal, intent)
            if try ports.validateCompletion(current, result) {
                try journal.accepted(intent, result: result)
                return .completed(result)
            }
            return .authorized
        }
        if let acknowledgement = saved.authorization {
            try ports.validateAuthorization(saved, acknowledgement)
            return .authorized
        }
        if saved.state == "authorizing" {
            switch try await ports.recover(saved) {
            case .authorized(let acknowledgement):
                let current = try record(journal, intent)
                try ports.validateAuthorization(current, acknowledgement)
                try journal.authorized(intent, acknowledgement: acknowledgement)
                return .authorized
            case .completed(let result):
                let current = try record(journal, intent)
                if try ports.validateCompletion(current, result) {
                    try journal.accepted(intent, result: result)
                    return .completed(result)
                }
                try journal.authorized(intent, acknowledgement: result)
                return .authorized
            case .notAuthorizedExpired(let serverTime):
                guard let operation = saved.operation, serverTime > operation.expiresAt else { throw OperationJournalError.staleIntent }
                throw RevocationRecoveryError.authorizationExpiredUncommitted(serverTime: serverTime)
            case .notAuthorized: break
            }
        }
        _ = try record(journal, intent)
        try journal.beginAuthorization(intent)
        let acknowledgement = try await ports.authorize(saved)
        let current = try record(journal, intent)
        try ports.validateAuthorization(current, acknowledgement)
        try journal.authorized(intent, acknowledgement: acknowledgement)
        return .authorized
    }
}
