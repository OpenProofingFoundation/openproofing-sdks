import Foundation

/// One camera opening, independent of the evidence attempt that may outlive it.
/// Keep this value unchanged while its presentation is being dismissed.
public struct SelfieCapturePresentation: Identifiable, Sendable, Hashable {
  public let id: UUID

  fileprivate init() { id = UUID() }
}

/// Fences host presentation callbacks across camera dismissal and reopening.
/// The host still owns acquisition intent, consent, and its workflow state.
@MainActor
public final class SelfieCapturePresentationState {
  public private(set) var current: SelfieCapturePresentation?

  public init() {}

  /// Every opening gets a fresh identity, including a retry of retained evidence.
  @discardableResult
  public func open() -> SelfieCapturePresentation {
    let presentation = SelfieCapturePresentation()
    current = presentation
    return presentation
  }

  /// Retire presentation callbacks before moving to processing or another screen.
  public func close() { current = nil }

  /// An outgoing camera cannot capture, fail, or dismiss a subsequent opening.
  public func receive(from id: UUID, _ callback: () -> Void) {
    guard current?.id == id else { return }
    callback()
  }
}
