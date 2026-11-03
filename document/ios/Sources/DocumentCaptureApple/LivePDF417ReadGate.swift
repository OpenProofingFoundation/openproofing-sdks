import CoreGraphics
import Foundation

/// A live PDF417 read counts only when the whole symbol lies inside the on-screen guide.
/// The code's corners and the guide share AVCaptureMetadataOutput's normalized, top-left,
/// unrotated capture-device space; both are read on the controller's session queue.
enum LivePDF417GuideContainment {
  /// AVMetadataMachineReadableCodeObject reports a decoded symbol as its four corners; anything
  /// else is not a decoded symbol.
  static func contains(corners: [CGPoint], in guide: CGRect?) -> Bool {
    guard corners.count == 4, let guide else { return false }
    return corners.allSatisfy { corner in
      (guide.minX...guide.maxX).contains(corner.x) && (guide.minY...guide.maxY).contains(corner.y)
    }
  }
}

/// Consecutive identical counted reads within the confirmation interval. A refused read,
/// a different payload or a longer gap restarts the count.
struct LivePDF417ReadConfirmation: Equatable, Sendable {
  let requiredReads = DocumentCaptureTuning.AutoCapture.livePDF417RequiredReads
  let maximumIntervalMilliseconds =
    DocumentCaptureTuning.AutoCapture.maximumConfirmationIntervalMilliseconds
  private var payload: String?
  private var lastReadAt: Date?
  private var count = 0

  /// Nil is a refused read. Returns true once the required identical reads are confirmed.
  mutating func observe(_ counted: String?, at time: Date) -> Bool {
    guard let counted else {
      payload = nil
      lastReadAt = nil
      count = 0
      return false
    }
    let continues =
      counted == payload
      && lastReadAt.map {
        (0...maximumIntervalMilliseconds).contains(
          Int((time.timeIntervalSince($0) * 1_000).rounded()))
      } == true
    count = continues ? min(count + 1, requiredReads) : 1
    payload = counted
    lastReadAt = time
    return count >= requiredReads
  }
}
