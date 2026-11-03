#if os(iOS)
  @_spi(CaptureTestFixture) import CaptureEvidenceCustody
  @testable import DocumentCapture

  /// Explicit synthetic SDK composition; ordinary runtime construction still requires hardware.
  @MainActor
  extension CaptureSession {
    func withFixtureCustody() -> Self {
      makeCustody = { try CaptureCustodyRuntime.testing(configuration: $0, signing: $1) }
      makeErasureCustody = { try CaptureCustodyRuntime.testingForErasure(configuration: $0) }
      return self
    }
  }
#endif
