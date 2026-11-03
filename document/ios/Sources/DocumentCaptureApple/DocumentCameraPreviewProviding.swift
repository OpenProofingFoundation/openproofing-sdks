import Foundation

public struct DocumentCameraGuideRegion: Codable, Equatable, Sendable {
  public let minX: Double
  public let minY: Double
  public let width: Double
  public let height: Double

  public init(minX: Double, minY: Double, width: Double, height: Double) {
    self.minX = minX
    self.minY = minY
    self.width = width
    self.height = height
  }

  var normalizedTopLeftRect: CGRect? {
    let values = [minX, minY, width, height]
    guard
      values.allSatisfy(\.isFinite),
      minX >= 0,
      minY >= 0,
      width > 0,
      height > 0,
      minX + width <= 1,
      minY + height <= 1
    else { return nil }
    return CGRect(x: minX, y: minY, width: width, height: height)
  }

  func isEffectivelyEqual(to other: Self, tolerance: Double = DocumentCaptureDefaults.guideCoordinateTolerance) -> Bool {
    abs(minX - other.minX) <= tolerance
      && abs(minY - other.minY) <= tolerance
      && abs(width - other.width) <= tolerance
      && abs(height - other.height) <= tolerance
  }

  /// Converts AVFoundation's capture-device coordinate space into the coordinate
  /// space of a video output whose connection has the supplied rotation.
  /// Both spaces use a top-left origin and normalized coordinates.
  func convertedToVideoBuffer(orientation: DocumentCameraOrientation) -> Self {
    switch orientation {
    case .landscapeLeft:
      self
    case .portrait:
      Self(
        minX: 1 - minY - height,
        minY: minX,
        width: height,
        height: width
      )
    case .landscapeRight:
      Self(
        minX: 1 - minX - width,
        minY: 1 - minY - height,
        width: width,
        height: height
      )
    case .portraitUpsideDown:
      Self(
        minX: minY,
        minY: 1 - minX - width,
        width: height,
        height: width
      )
    }
  }

  /// Inverts `convertedToVideoBuffer`, retaining a native capture-device ROI
  /// for autofocus and later full-resolution derived crops.
  func convertedToCaptureDevice(orientation: DocumentCameraOrientation) -> Self {
    switch orientation {
    case .landscapeLeft:
      self
    case .portrait:
      Self(
        minX: minY,
        minY: 1 - minX - width,
        width: height,
        height: width
      )
    case .landscapeRight:
      Self(
        minX: 1 - minX - width,
        minY: 1 - minY - height,
        width: width,
        height: height
      )
    case .portraitUpsideDown:
      Self(
        minX: 1 - minY - height,
        minY: minX,
        width: height,
        height: width
      )
    }
  }
}

public enum DocumentCameraOrientation: String, CaseIterable, Codable, Equatable, Sendable {
  case portrait
  case portraitUpsideDown
  case landscapeLeft
  case landscapeRight

  /// Converts a top-left point in the physically rotated video buffer back to
  /// AVFoundation's native, unrotated capture-device point-of-interest space.
  func captureDevicePoint(fromVideoBuffer point: CGPoint) -> CGPoint {
    switch self {
    case .landscapeLeft:
      point
    case .portrait:
      CGPoint(x: point.y, y: 1 - point.x)
    case .landscapeRight:
      CGPoint(x: 1 - point.x, y: 1 - point.y)
    case .portraitUpsideDown:
      CGPoint(x: 1 - point.y, y: point.x)
    }
  }
}

public struct DocumentCameraPreviewGeometryDiagnostic: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case connectionUnavailable
    case rotationUnsupported
    case guideUnavailable
    case guideRejected
    case guideAccepted
  }

  public let status: Status
  public let orientation: DocumentCameraOrientation?
  public let previewWidth: Double
  public let previewHeight: Double
  public let guideMinX: Double?
  public let guideMinY: Double?
  public let guideWidth: Double?
  public let guideHeight: Double?
  public let nativeRegion: DocumentCameraGuideRegion?

  package init(status: Status, orientation: DocumentCameraOrientation?, previewWidth: Double,
    previewHeight: Double, guideMinX: Double?, guideMinY: Double?, guideWidth: Double?,
    guideHeight: Double?, nativeRegion: DocumentCameraGuideRegion?) {
    self.status = status; self.orientation = orientation
    self.previewWidth = previewWidth; self.previewHeight = previewHeight
    self.guideMinX = guideMinX; self.guideMinY = guideMinY
    self.guideWidth = guideWidth; self.guideHeight = guideHeight; self.nativeRegion = nativeRegion
  }

}

/// Preview authority is renewed after every source change and every rotation check.
/// A prior successful check cannot authorize a later failed refresh.
package struct DocumentPreviewGeometryAuthority: Equatable, Sendable {
  package init() {}
  package private(set) var sourceGeneration: UInt64?
  package private(set) var orientation: DocumentCameraOrientation?

  package mutating func invalidate(for generation: UInt64) -> Bool {
    if let sourceGeneration, generation < sourceGeneration { return false }
    sourceGeneration = generation
    orientation = nil
    return true
  }

  package mutating func beginRefresh() {
    orientation = nil
  }

  package mutating func acceptRotation(_ orientation: DocumentCameraOrientation) {
    guard sourceGeneration != nil else { return }
    self.orientation = orientation
  }

  package var canPublishGuide: Bool { sourceGeneration != nil && orientation != nil }
}

#if os(iOS)
  import AVFoundation

  @MainActor
  public protocol DocumentCameraPreviewProviding: AnyObject {
    func setCaptureFeedbackHandler(
      _ handler: @escaping @MainActor @Sendable (DocumentCaptureFeedback) -> Void
    )
    func attachPreview(to previewLayer: AVCaptureVideoPreviewLayer)
    func setPreviewGeometryInvalidationHandler(
      _ handler: @escaping @MainActor @Sendable (UInt64) -> Void
    )
    func updatePreviewGeometry(
      orientation: DocumentCameraOrientation, region: DocumentCameraGuideRegion?,
      sourceGeneration: UInt64
    )
    func updateCaptureOrientation(_ orientation: DocumentCameraOrientation)
    /// Supplies a native, unrotated capture-device ROI. Passing `nil` clears
    /// stale geometry and makes capture fail closed.
    func updateDocumentGuideRegion(_ region: DocumentCameraGuideRegion?)
    func recordPreviewGeometry(_ diagnostic: DocumentCameraPreviewGeometryDiagnostic)
  }
#endif
