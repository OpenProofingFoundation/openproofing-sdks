/// The physical side of a document presented to the capture system.
public enum DocumentSide: String, Codable, CaseIterable, Hashable, Sendable {
  case front
  case back
}
