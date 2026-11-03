import Foundation

/// OCR defaults ported from the device-tested capture implementation on 2026-10-07.
/// These control candidate acquisition, not document authenticity or identity acceptance.
public struct MRZOCRPolicy: Equatable, Sendable {
  public let identifier: String
  public let candidatesPerRow: Int
  public let minimumTextHeight: Float
  public init(identifier: String, candidatesPerRow: Int, minimumTextHeight: Float) {
    self.identifier = identifier
    self.candidatesPerRow = candidatesPerRow
    self.minimumTextHeight = minimumTextHeight
  }
  public static let engineeringV1 = Self(
    identifier: "mrz-ocr-engineering-v1", candidatesPerRow: 5, minimumTextHeight: 0.02)
}

/// Alternatives remain grouped by their actual Vision observation; never treat alternatives
/// from one text row as separate document rows. No camera image is retained or transmitted.
public struct MRZOCRFrame: Sendable {
  public let candidates: [[String]]
  public let timestamp: TimeInterval
  public let policy: MRZOCRPolicy
  public let orientation: MRZCaptureOrientation
  /// Vision-normalized row rectangles, in the oriented image (lower-left origin).
  public let rowBounds: [CGRect]
  let guideRevision: UUID?

  init(
    candidates: [[String]], timestamp: TimeInterval, policy: MRZOCRPolicy,
    orientation: MRZCaptureOrientation = .portrait,
    rowBounds: [CGRect] = [], guideRevision: UUID? = nil
  ) {
    self.candidates = candidates
    self.timestamp = timestamp
    self.policy = policy
    self.orientation = orientation
    self.rowBounds = rowBounds
    self.guideRevision = guideRevision
  }
}

public enum MRZCameraFailure: String, Error, Sendable {
  case consentRequired, cameraPermissionDenied, unavailable, busy, interrupted, cancelled
  case invalidConfiguration, captureFailed, recognitionFailed
}
