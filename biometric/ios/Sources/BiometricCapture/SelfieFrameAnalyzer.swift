#if os(iOS)
  import CoreImage
  import UIKit
  import Vision

  /// Owns a private deep-copied camera buffer for one background analysis operation.
  public final class SelfieFrameInput: @unchecked Sendable {
    let buffer: CVPixelBuffer
    public let orientation: CGImagePropertyOrientation
    public let depth: SelfieDepthMap?
    public init(buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, depth: SelfieDepthMap? = nil) throws {
      self.buffer = try SelfieFrameSnapshot.copy(buffer)
      self.orientation = orientation
      self.depth = depth
    }
  }

  public struct SelfieFrameAnalysis: Sendable {
    let faceCount: Int
    let quality: Float?
    /// Vision normalized lower-left coordinates in the oriented image.
    let faceBox: CGRect?
    let revision: Int
    let elapsed: TimeInterval
    /// A failed request is distinct from a successful observation containing no faces.
    var failure: SelfieCameraFailure? = nil
    var depthEvidence: SelfieDepthEvidence? = nil
  }

  public enum SelfieFrameAnalyzer {
    public static func analyze(
      _ input: SelfieFrameInput, depthPolicy: SelfieDepthPolicy = .engineeringV1,
      monotonicClock: @Sendable () -> TimeInterval
    ) -> SelfieFrameAnalysis {
      let start = monotonicClock()
      let request = VNDetectFaceCaptureQualityRequest()
      request.revision = VNDetectFaceCaptureQualityRequestRevision3
      do {
        try VNImageRequestHandler(cvPixelBuffer: input.buffer, orientation: input.orientation)
          .perform([request])
        let faces = request.results ?? []
        let depth = faces.count == 1 ? faces.first.flatMap {
          input.depth?.measure(faceBox: $0.boundingBox, orientation: input.orientation, policy: depthPolicy)
        } : nil
        return SelfieFrameAnalysis(
          faceCount: faces.count,
          quality: faces.count == 1 ? faces.first?.faceCaptureQuality : nil,
          faceBox: faces.count == 1 ? faces.first?.boundingBox : nil,
          revision: request.revision, elapsed: monotonicClock() - start, depthEvidence: depth)
      } catch {
        return SelfieFrameAnalysis(
          faceCount: 0, quality: nil, faceBox: nil,
          revision: request.revision, elapsed: monotonicClock() - start,
          failure: .analysis(error as NSError))
      }
    }
  }
#endif
