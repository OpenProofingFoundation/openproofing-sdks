import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Testing

/// Generated non-sensitive raster fixture, never a live or physical document.
/// Uses Apple's built-in perspectiveTransform, inspected 2026-09-17:
/// https://developer.apple.com/documentation/coreimage/cifilter-swift.class/perspectivetransform()
/// Gray CGContext pattern follows the existing DocumentImagePreparerTests fixture mechanism.
struct DocumentSyntheticPerspectivePixels {
  let context = CIContext(options: [.cacheIntermediates: false])
  let card: CIImage
  let bounds = CGRect(x: 0, y: 0, width: 640, height: 480)

  init() throws {
    let drawing = try #require(
      CGContext(
        data: nil, width: 360, height: 220, bitsPerComponent: 8,
        bytesPerRow: 360, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue))
    drawing.setFillColor(gray: 0.9, alpha: 1)
    drawing.fill(CGRect(x: 0, y: 0, width: 360, height: 220))
    drawing.setFillColor(gray: 0.22, alpha: 1)
    for row in 0..<8 {
      drawing.fill(CGRect(x: 105, y: 25 + row * 20, width: 215 - row * 9, height: 5))
    }
    drawing.fill(CGRect(x: 25, y: 70, width: 55, height: 95))
    card = CIImage(cgImage: try #require(drawing.makeImage()))
  }

  /// Independent vertical edge lengths define only a synthetic 2D projection, never a physical angle.
  func pixels(logRatio: Double?, horizontalOffset: Double = 0) throws -> CVPixelBuffer {
    let background = CIImage(color: CIColor(red: 0.15, green: 0.15, blue: 0.15)).cropped(to: bounds)
    var image = background
    if let logRatio {
      let left = 220 * exp(-logRatio / 2)
      let right = 220 * exp(logRatio / 2)
      let filter = CIFilter.perspectiveTransform()
      filter.inputImage = card
      filter.topLeft = CGPoint(x: 140 + horizontalOffset, y: 240 + left / 2)
      filter.topRight = CGPoint(x: 500 + horizontalOffset, y: 240 + right / 2)
      filter.bottomLeft = CGPoint(x: 140 + horizontalOffset, y: 240 - left / 2)
      filter.bottomRight = CGPoint(x: 500 + horizontalOffset, y: 240 - right / 2)
      image = try #require(filter.outputImage).composited(over: background).cropped(to: bounds)
    }
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    try #require(
      CVPixelBufferCreate(
        kCFAllocatorDefault, 640, 480,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &buffer) == kCVReturnSuccess)
    let result = try #require(buffer)
    context.render(image, to: result, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
    return result
  }
}
