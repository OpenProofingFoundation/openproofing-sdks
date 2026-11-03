import Foundation

/// Exact preparation, uncertain delivery recovery and current-intent result projection.
/// Service adapters own authenticated transport and closed product/result validation.
public actor JournaledOperationController {
    public struct Preparation: Sendable {
        public let operation: SealedOperation
        public let bytes: Data
        public init(operation: SealedOperation, bytes: Data) { self.operation = operation; self.bytes = bytes }
    }
    public enum Recovery: Sendable { case completed(Data); case notCompleted }
    public struct Ports: Sendable {
        public let prepare: @Sendable (JournalRecord) async throws -> Preparation
        public let recover: @Sendable (JournalRecord) async throws -> Recovery
        public let dispatch: @Sendable (JournalRecord) async throws -> Data
        public let validateRecord: @Sendable (JournalRecord) throws -> Void
        public let validateResult: @Sendable (JournalRecord, Data, Bool) throws -> Void
        public init(prepare: @escaping @Sendable (JournalRecord) async throws -> Preparation,
            recover: @escaping @Sendable (JournalRecord) async throws -> Recovery,
            dispatch: @escaping @Sendable (JournalRecord) async throws -> Data,
            validateRecord: @escaping @Sendable (JournalRecord) throws -> Void,
            validateResult: @escaping @Sendable (JournalRecord, Data, Bool) throws -> Void) {
            self.prepare = prepare; self.recover = recover; self.dispatch = dispatch
            self.validateRecord = validateRecord; self.validateResult = validateResult
        }
    }
    private struct Flight { let id: UUID; let task: Task<Data, Error> }
    private let journal: OperationJournal
    private var flights: [String: Flight] = [:]
    private var closed = false
    public init(journal: OperationJournal) { self.journal = journal }

    public func perform(_ intent: JournalIntent, ports: Ports) async throws -> Data {
        guard !closed else { throw OperationJournalError.staleIntent }
        let admissionEpoch = try journal.admissionEpoch()
        let record = try Self.current(journal, intent, admissionEpoch: admissionEpoch)
        if record.prepared != nil { try ports.validateRecord(record) }
        if let active = flights[intent.id] {
            let result = try await withTaskCancellationHandler(operation: { try await active.task.value }, onCancel: { active.task.cancel() })
            let current = try Self.current(journal, intent, admissionEpoch: admissionEpoch)
            guard !closed else { throw OperationJournalError.staleIntent }
            try ports.validateRecord(current)
            try ports.validateResult(current, result, true)
            _ = try Self.current(journal, intent, admissionEpoch: admissionEpoch)
            return result
        }
        let id = UUID(), journal = self.journal
        let task = Task { try await Self.execute(journal, intent: intent, ports: ports, admissionEpoch: admissionEpoch) }
        flights[intent.id] = Flight(id: id, task: task)
        defer { if flights[intent.id]?.id == id { flights.removeValue(forKey: intent.id) } }
        let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        _ = try Self.current(journal, intent, admissionEpoch: admissionEpoch)
        guard !closed else { throw OperationJournalError.staleIntent }
        return result
    }
    /// Persist preparation without dispatching; approval flows may separate these boundaries.
    public func prepare(_ intent: JournalIntent, ports: Ports) async throws -> Preparation {
        guard !closed else { throw OperationJournalError.staleIntent }
        let admissionEpoch = try journal.admissionEpoch()
        let record = try await Self.preparedRecord(journal, intent: intent, ports: ports, admissionEpoch: admissionEpoch)
        _ = try Self.current(journal, intent, admissionEpoch: admissionEpoch)
        guard !closed, let operation = record.operation, let bytes = record.prepared else { throw OperationJournalError.staleIntent }
        return Preparation(operation: operation, bytes: bytes)
    }
    /// Read-only outcome lookup. An absent receipt never triggers preparation or dispatch here.
    public func recover(_ intent: JournalIntent, ports: Ports) async throws -> Data? {
        guard !closed else { throw OperationJournalError.staleIntent }
        let admissionEpoch = try journal.admissionEpoch()
        var record = try Self.current(journal, intent, admissionEpoch: admissionEpoch)
        guard record.prepared != nil else { throw OperationJournalError.missingIntent }
        try ports.validateRecord(record)
        if let result = record.result {
            try ports.validateResult(record, result, true)
            _ = try Self.current(journal, intent, admissionEpoch: admissionEpoch)
            return result
        }
        let recovery = try await ports.recover(record)
        record = try Self.current(journal, intent, admissionEpoch: admissionEpoch)
        guard !closed else { throw OperationJournalError.staleIntent }
        try ports.validateRecord(record)
        if case .completed(let data) = recovery {
            return try Self.accept(journal, intent: intent, record: record, result: data, ports: ports, admissionEpoch: admissionEpoch)
        }
        return nil
    }
    public func closeAndDrain() async {
        closed = true
        let active = Array(flights.values)
        for item in active { item.task.cancel() }
        for item in active {
            do { _ = try await item.task.value } catch { /* Exact uncertain records remain durable. */ }
        }
        flights.removeAll()
    }
    /// Only the host's explicit admission boundary may reopen a controller.
    public func resume() { closed = false }

    private static func current(_ journal: OperationJournal, _ intent: JournalIntent, admissionEpoch: Int64) throws -> JournalRecord {
        try Task.checkCancellation()
        guard try journal.admissionEpoch() == admissionEpoch else { throw OperationJournalError.staleIntent }
        try journal.validateAdmitted(intent)
        guard let record = try journal.current(resourceID: intent.resourceID) else { throw OperationJournalError.missingIntent }
        return record
    }
    private static func preparedRecord(_ journal: OperationJournal, intent: JournalIntent, ports: Ports, admissionEpoch: Int64) async throws -> JournalRecord {
        var record = try current(journal, intent, admissionEpoch: admissionEpoch)
        if record.prepared == nil {
            let preparation = try await ports.prepare(record)
            _ = try current(journal, intent, admissionEpoch: admissionEpoch)
            do { try journal.savePrepared(intent, operation: preparation.operation, bytes: preparation.bytes, expectedAdmissionEpoch: admissionEpoch) }
            catch OperationJournalError.conflictingPreparation {
                guard try current(journal, intent, admissionEpoch: admissionEpoch).prepared != nil else { throw OperationJournalError.conflictingPreparation }
            }
            record = try current(journal, intent, admissionEpoch: admissionEpoch)
        }
        try ports.validateRecord(record)
        return record
    }
    private static func execute(_ journal: OperationJournal, intent: JournalIntent, ports: Ports, admissionEpoch: Int64) async throws -> Data {
        var record = try await preparedRecord(journal, intent: intent, ports: ports, admissionEpoch: admissionEpoch)
        if let result = record.result {
            try ports.validateResult(record, result, true)
            _ = try current(journal, intent, admissionEpoch: admissionEpoch)
            return result
        }
        if record.state == "dispatching" {
            let recovered = try await ports.recover(record)
            record = try current(journal, intent, admissionEpoch: admissionEpoch)
            try ports.validateRecord(record)
            if case .completed(let result) = recovered {
                return try accept(journal, intent: intent, record: record, result: result, ports: ports, admissionEpoch: admissionEpoch)
            }
        }
        _ = try current(journal, intent, admissionEpoch: admissionEpoch)
        try journal.beginDispatch(intent, expectedAdmissionEpoch: admissionEpoch)
        let result = try await ports.dispatch(record)
        record = try current(journal, intent, admissionEpoch: admissionEpoch)
        try ports.validateRecord(record)
        return try accept(journal, intent: intent, record: record, result: result, ports: ports, admissionEpoch: admissionEpoch)
    }
    private static func accept(_ journal: OperationJournal, intent: JournalIntent, record: JournalRecord, result: Data, ports: Ports, admissionEpoch: Int64) throws -> Data {
        try ports.validateResult(record, result, false)
        _ = try current(journal, intent, admissionEpoch: admissionEpoch)
        try journal.accepted(intent, result: result, expectedAdmissionEpoch: admissionEpoch)
        _ = try current(journal, intent, admissionEpoch: admissionEpoch)
        return result
    }
}
