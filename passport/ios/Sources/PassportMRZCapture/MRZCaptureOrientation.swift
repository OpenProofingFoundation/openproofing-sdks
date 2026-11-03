import Foundation

#if os(iOS)
  import ImageIO
#endif

/// Orientation of the displayed rear-camera image. Preview and OCR share this value while
/// video output stays unrotated, so rotating a host does not leave Vision interpreting portrait.
/// Apple documents the sensor's native landscape pixels and the clockwise portrait correction:
/// https://developer.apple.com/documentation/imageio/cgimagepropertyorientation
/// https://developer.apple.com/documentation/avfoundation/avcaptureconnection/videorotationangle
public enum MRZCaptureOrientation: String, CaseIterable, Sendable {
  case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

  public var videoRotationDegrees: Double {
    switch self {
    case .portrait: 90
    case .portraitUpsideDown: 270
    case .landscapeLeft: 180
    case .landscapeRight: 0
    }
  }

  #if os(iOS)
    var imageOrientation: CGImagePropertyOrientation {
      switch self {
      case .portrait: .right
      case .portraitUpsideDown: .left
      case .landscapeLeft: .down
      case .landscapeRight: .up
      }
    }
  #endif
}
