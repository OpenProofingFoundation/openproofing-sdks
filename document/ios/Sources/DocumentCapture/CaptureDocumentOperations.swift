#if os(iOS)
  import Foundation
  import DocumentCaptureApple

  @MainActor
  public struct CaptureDocumentOperations {
    public let calibration: CaptureProcessingCalibration
    public var structured: (@Sendable (Data) async throws -> StructuredDocumentObservation)?
    public var extract: CaptureDocumentStages.Extract
    public var prepare:
      (CaptureDocumentSource) async throws -> AppleDocumentImagePreparer.PreparedImage
    public var portrait: (Data, DocumentImageDerivation) async throws -> PortraitExtractionResult
    public var afterWrite: CaptureDocumentStages.AfterWrite

    public init(
      calibration: CaptureProcessingCalibration = .source20260917,
      structured: (@Sendable (Data) async throws -> StructuredDocumentObservation)? = nil,
      extract: @escaping CaptureDocumentStages.Extract = CaptureDocumentStages.extract,
      prepare:
        @escaping (CaptureDocumentSource) async throws -> AppleDocumentImagePreparer.PreparedImage =
        { source in
          try await AppleDocumentImagePreparer(
            profile: source.profile == .passport
              ? .passport
              : (source.profile.frontProfile == .passportCardFront ? .passportCard : .license)
          ).prepareRetained(
            data: source.data, side: source.side, fidelity: source.fidelity,
            admission: source.admission)
        },
      portrait: ((Data, DocumentImageDerivation) async throws -> PortraitExtractionResult)? = nil,
      afterWrite: @escaping CaptureDocumentStages.AfterWrite = { _, _ in }
    ) {
      self.calibration = calibration
      self.structured = structured
      self.extract = extract
      self.prepare = prepare
      self.portrait =
        portrait ?? { data, derivation in
          try await ApplePortraitExtractor().extract(
            data: data, derivation: derivation, paddingFraction: calibration.portraitPaddingFraction
          )
        }
      self.afterWrite = afterWrite
    }
  }

  // Cancellation semantics retained from the source telemetry wrapper. No ambient
  // logging or holder data leaves the package; hosts observe typed processing stages.
  @MainActor
  public enum CaptureProcessingTelemetry {
    public static func measure<Value>(
      _ _: UUID, step _: String, operation: () async throws -> Value
    ) async throws -> Value {
      try Task.checkCancellation()
      let result = try await operation()
      try Task.checkCancellation()
      return result
    }
  }
#endif
