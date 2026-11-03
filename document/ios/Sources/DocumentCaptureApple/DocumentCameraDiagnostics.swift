import Foundation

extension DocumentCamera {
  /// Native diagnostic intents use the same serial owner as normal acquisition.
  /// Manual controls suspend adaptive decisions until explicitly re-enabled.
  public func performDiagnostic(
    _ command: DocumentCameraDiagnosticCommand
  ) async throws -> DocumentCameraNativeSnapshot {
    try Task.checkCancellation()
    guard isRunning, !isCaptureInFlight,
      let controller = sessionController as? any CameraSessionDiagnosticsControlling
    else { throw PhotoCaptureError.cameraNotReady }
    let operationGeneration = generation
    let result = try await withCheckedThrowingContinuation { continuation in
      controller.performDiagnostic(command) { result in
        continuation.resume(with: result)
      }
    }
    try ensureCurrent(operationGeneration)
    return result
  }
}
