#if os(iOS)
  import AVFoundation
  import UIKit

  extension DocumentCameraOrientation {
    package init?(_ interfaceOrientation: UIInterfaceOrientation) {
      switch interfaceOrientation {
      case .portrait:
        self = .portrait
      case .portraitUpsideDown:
        self = .portraitUpsideDown
      case .landscapeLeft:
        self = .landscapeLeft
      case .landscapeRight:
        self = .landscapeRight
      case .unknown:
        return nil
      @unknown default:
        return nil
      }
    }

    package var videoRotationAngle: CGFloat {
      switch self {
      case .portrait:
        90
      case .portraitUpsideDown:
        270
      case .landscapeLeft:
        0
      case .landscapeRight:
        180
      }
    }

    package var legacyVideoOrientation: AVCaptureVideoOrientation {
      switch self {
      case .portrait:
        .portrait
      case .portraitUpsideDown:
        .portraitUpsideDown
      case .landscapeLeft:
        .landscapeLeft
      case .landscapeRight:
        .landscapeRight
      }
    }
  }
#endif
