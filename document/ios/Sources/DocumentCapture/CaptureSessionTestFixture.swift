#if DEBUG && os(iOS)
  import Foundation
  import DocumentCaptureApple
  @_spi(CaptureTestFixture) import CaptureEvidenceCustody

  extension CaptureSession {
    /// Explicit synthetic fixtures only. Public init never selects this mechanism on a simulator,
    /// under XCTest, or following a hardware failure. This entry point is absent from Release.
    @_spi(CaptureTestFixture)
    public static func testing(configuration: CaptureSessionConfiguration,
      telemetry: DocumentCameraTelemetry = .disabled,
      processingOperations: CaptureDocumentOperations = .init(),
      onEvent: @escaping @MainActor (CaptureSessionEvent) -> Void = { _ in
        // A fixture that does not observe session events ignores them.
      }) throws -> CaptureSession
    {
      // Validate synthetic namespace before constructing the camera/controller.
      guard ["synthetic.", "test."].contains(where: configuration.custody.applicationID.hasPrefix),
        ["synthetic.", "test."].contains(where: configuration.custody.keychainService.hasPrefix),
        configuration.custody.accessGroup.hasPrefix("TEST.") else {
        throw CaptureEvidenceStoreError.invalidRecord
      }
      let session = CaptureSession(configuration: configuration, telemetry: telemetry,
        processingOperations: processingOperations, onEvent: onEvent)
      session.makeCustody = { try CaptureCustodyRuntime.testing(configuration: $0, signing: $1) }
      session.makeErasureCustody = { try CaptureCustodyRuntime.testingForErasure(configuration: $0) }
      return session
    }
  }
#endif
