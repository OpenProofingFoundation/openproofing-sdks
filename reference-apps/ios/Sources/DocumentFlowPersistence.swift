import Foundation

public enum DocumentFlowPersistenceState: Equatable, Sendable {
    case transient, saving, saved, restored
}

/// The exact reviewed optical observations. A saved revision is historical local evidence.
public struct DocumentFlowSnapshot: Codable, Sendable {
    public let workflowID: UUID
    public let revision: UInt64
    public let front: DocumentFlowObservation
    public let back: DocumentFlowObservation?

    public init(workflowID: UUID, revision: UInt64, front: DocumentFlowObservation, back: DocumentFlowObservation?) {
        self.workflowID = workflowID; self.revision = revision; self.front = front; self.back = back
    }

    func hasExactContent(of other: Self) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(front) == encoder.encode(other.front)
            && encoder.encode(back) == encoder.encode(other.back)
    }
}

/// Storage owns authenticated publication and returns only committed, independently verified bytes.
/// load never starts capture or processing. Deletion is explicit, separate from session reset.
public protocol DocumentFlowPersistence: Sendable {
    func save(_ snapshot: DocumentFlowSnapshot) async throws -> DocumentFlowSnapshot
    func load() async throws -> DocumentFlowSnapshot?
    func delete() async throws
}
