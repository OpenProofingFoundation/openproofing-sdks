import Foundation

public struct DocumentCaptureConfiguration: Equatable, Sendable {
  public enum Encoding: Equatable, Sendable {
    case heicWithJPEGFallback
    case jpeg
  }

  public enum DistortionCorrection: Equatable, Sendable {
    case disabled
    case systemDefault
  }

  public let livePDF417: Bool
  public let encoding: Encoding
  public let distortionCorrection: DistortionCorrection
  public let temporalEvidence: DocumentTemporalConfiguration

  public init(
    livePDF417: Bool = false,
    encoding: Encoding = .heicWithJPEGFallback,
    distortionCorrection: DistortionCorrection = .disabled,
    temporalEvidence: DocumentTemporalConfiguration = .init()
  ) {
    self.livePDF417 = livePDF417
    self.encoding = encoding
    self.distortionCorrection = distortionCorrection
    self.temporalEvidence = temporalEvidence
  }

  /// Every document capture requests balanced prioritization and the largest
  /// dimensions supported by the photo preset. Delivery is verified separately;
  /// requesting a high resolution does not establish calibration or pixel accuracy.
  public static let geometry = Self()
}
