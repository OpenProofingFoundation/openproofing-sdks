/// How media entered the identity-evidence system.
public enum MediaOrigin: String, Codable, Sendable {
  /// Media produced by the active capture session.
  case liveSensor

  /// Media supplied from outside the active capture session.
  case imported
}
