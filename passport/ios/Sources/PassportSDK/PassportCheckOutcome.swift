/// A check's outcome. An unavailable or unperformed check never implies success.
/// These values describe individual observations; identity acceptance belongs to the host.
public enum PassportCheckOutcome: String, Codable, CaseIterable, Sendable {
    case pass
    case fail
    case inconclusive
    case unavailable
    case unsupported
    case notPerformed = "not_performed"
}
