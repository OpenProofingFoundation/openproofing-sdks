import CoreGraphics
import Foundation

/// Vision oriented lower-left -> raw sensor upper-left -> ARKit preview transform.
/// The same native oval used to draw the guide supplies the containment region.
enum SelfieGuideGeometry {
  static func matchesAnchor(
    face: CGRect, orientation: UInt32, displayTransform: CGAffineTransform,
    viewport: CGSize, anchor: CGPoint
  ) -> Bool {
    guard [1, 3, 6, 8].contains(orientation), face.width > 0, face.height > 0,
      viewport.width > 0, viewport.height > 0
    else { return false }
    let points = [CGPoint(x: face.minX, y: 1 - face.maxY), CGPoint(x: face.maxX, y: 1 - face.minY)]
    let mapped = points.map { point -> CGPoint in
      let raw: CGPoint
      switch orientation {
      case 6: raw = CGPoint(x: point.y, y: 1 - point.x)
      case 8: raw = CGPoint(x: 1 - point.y, y: point.x)
      case 3: raw = CGPoint(x: 1 - point.x, y: 1 - point.y)
      default: raw = point
      }
      let value = raw.applying(displayTransform)
      return CGPoint(x: value.x * viewport.width, y: value.y * viewport.height)
    }
    let box = CGRect(
      x: min(mapped[0].x, mapped[1].x), y: min(mapped[0].y, mapped[1].y),
      width: abs(mapped[1].x - mapped[0].x), height: abs(mapped[1].y - mapped[0].y))
    return anchor.x.isFinite && anchor.y.isFinite && box.contains(anchor)
  }

  static func contains(
    face: CGRect, orientation: UInt32, displayTransform: CGAffineTransform,
    viewport: CGSize, oval: CGRect
  ) -> Bool {
    guard face.width > 0, face.height > 0, viewport.width > 0, viewport.height > 0,
      oval.width > 0, oval.height > 0
    else { return false }
    let points = [
      CGPoint(x: face.minX, y: 1 - face.minY), CGPoint(x: face.maxX, y: 1 - face.minY),
      CGPoint(x: face.minX, y: 1 - face.maxY), CGPoint(x: face.maxX, y: 1 - face.maxY),
    ]
    return points.allSatisfy { point in
      let raw: CGPoint
      switch orientation {
      case 6: raw = CGPoint(x: point.y, y: 1 - point.x)  // right
      case 8: raw = CGPoint(x: 1 - point.y, y: point.x)  // left
      case 3: raw = CGPoint(x: 1 - point.x, y: 1 - point.y)  // down
      case 1: raw = point
      default: return false
      }
      let view = raw.applying(displayTransform)
      let x = (view.x * viewport.width - oval.midX) / (oval.width / 2)
      let y = (view.y * viewport.height - oval.midY) / (oval.height / 2)
      return x.isFinite && y.isFinite && x * x + y * y <= 1
    }
  }
}
