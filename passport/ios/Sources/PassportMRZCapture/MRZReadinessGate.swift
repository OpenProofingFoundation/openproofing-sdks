import Foundation
import CoreGraphics
import PassportSDK

/// Engineering acquisition policy: a complete, unambiguous two-row read, wholly inside
/// the displayed guide, repeated across at least three frames and half a second.
/// This measures OCR consistency and framing, not issuer authenticity.
struct MRZReadinessGate {
  enum Status: String { case waiting, invalidFrame, outsideGuide, incomplete, inconsistentRows, holding, ready }
  private(set) var status: Status = .waiting
  private(set) var insideRowCount = 0
  var stableFrameCount: Int { count }
  private var candidate: PassportMRZObservation?
  private var firstTimestamp: TimeInterval = 0
  private var lastTimestamp: TimeInterval = 0
  private var count = 0
  private var emitted = false

  mutating func reset() { self = Self() }

  static func validRegion(_ rect: CGRect) -> Bool {
    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
      && rect.width > 0 && rect.height > 0 && rect.minX >= 0 && rect.minY >= 0
      && rect.maxX <= 1 && rect.maxY <= 1
  }

  /// Metadata coordinates are top-left in unrotated pixels. Vision coordinates are
  /// lower-left in the oriented image. Keep the conversion shared with the tested gate.
  /// https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer/metadataoutputrectconverted(fromlayerrect:)
  /// https://developer.apple.com/documentation/vision/vnimagebasedrequest/regionofinterest
  static func visionRegion(_ raw: CGRect, orientation: MRZCaptureOrientation) -> CGRect {
    let topLeft: CGRect
    switch orientation {
    case .portrait:
      topLeft = CGRect(x: 1 - raw.maxY, y: raw.minX, width: raw.height, height: raw.width)
    case .portraitUpsideDown:
      topLeft = CGRect(x: raw.minY, y: 1 - raw.maxX, width: raw.height, height: raw.width)
    case .landscapeLeft:
      topLeft = CGRect(x: 1 - raw.maxX, y: 1 - raw.maxY, width: raw.width, height: raw.height)
    case .landscapeRight: topLeft = raw
    }
    return CGRect(x: topLeft.minX, y: 1 - topLeft.maxY,
                  width: topLeft.width, height: topLeft.height)
  }

  mutating func ingest(_ frame: MRZOCRFrame, rawGuideRegion: CGRect) -> PassportMRZObservation? {
    guard !emitted else { return nil }
    guard frame.timestamp.isFinite, frame.timestamp >= 0,
      Self.validRegion(rawGuideRegion), frame.rowBounds.count == frame.candidates.count
    else { reset(); status = .invalidFrame; return nil }
    let guide = Self.visionRegion(rawGuideRegion, orientation: frame.orientation)
    // A small interior margin refuses text touching the visible cut-off edge.
    let interior = guide.insetBy(dx: guide.width * 0.01, dy: guide.height * 0.01)
    let rows = zip(frame.candidates, frame.rowBounds).filter {
      Self.validRegion($0.1) && interior.contains($0.1)
    }
    guard let value = PassportMRZOCRParser.parseComplete(candidates: rows.map(\.0)) else {
      reset()
      insideRowCount = rows.count
      status = rows.isEmpty ? .outsideGuide : .incomplete
      return nil
    }
    insideRowCount = rows.count
    guard Self.hasCoherentRows(rows, observation: value) else {
      reset(); insideRowCount = rows.count; status = .inconsistentRows; return nil
    }
    if candidate?.captureComparisonLines != value.captureComparisonLines || frame.timestamp <= lastTimestamp
      || frame.timestamp - lastTimestamp > 0.75 {
      candidate = value
      firstTimestamp = frame.timestamp
      count = 0
    }
    lastTimestamp = frame.timestamp
    count += 1
    status = .holding
    guard count >= 3, frame.timestamp - firstTimestamp >= 0.5 else { return nil }
    emitted = true
    status = .ready
    candidate = nil
    return value
  }

  private static func hasCoherentRows(
    _ rows: [([String], CGRect)], observation: PassportMRZObservation
  ) -> Bool {
    // Vision sometimes returns the entire two-line region as one 88-character observation.
    if rows.contains(where: {
      PassportMRZOCRParser.parseComplete(candidates: [$0.0]) == observation
    }) { return true }
    for (topCandidates, top) in rows {
      for (bottomCandidates, bottom) in rows {
        guard top.minY >= bottom.maxY,
          bottomCandidates.contains(where: {
            PassportMRZOCRParser.parse(candidates: [[$0]])?.normalizedLines.last
              == observation.normalizedLines.last
          }),
          PassportMRZOCRParser.parseComplete(candidates: [topCandidates, bottomCandidates]) == observation
        else { continue }
        let gap = top.minY - bottom.maxY
        let narrow = min(top.width, bottom.width), wide = max(top.width, bottom.width)
        let overlap = min(top.maxX, bottom.maxX) - max(top.minX, bottom.minX)
        // Two equal-length TD3 rows must be vertically adjacent and horizontally aligned.
        if gap <= 2 * max(top.height, bottom.height), narrow / wide >= 0.75,
          overlap / narrow >= 0.9 { return true }
      }
    }
    return false
  }

}
