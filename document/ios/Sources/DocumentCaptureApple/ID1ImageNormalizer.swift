import CoreGraphics
import CoreImage
import Foundation
import DocumentOpenCVBridge

enum ID1ImageNormalizer {
  static func render(_ image: CIImage, geometry: ID1CardGeometry) throws -> CGImage {
    guard geometry.valid,
      Int(image.extent.width) == geometry.sourcePixelWidth,
      Int(image.extent.height) == geometry.sourcePixelHeight,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let source = CIContext(options: [.cacheIntermediates: false]).createCGImage(
        image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
    else { throw ID1GeometryError.renderingFailed }
    let stride = source.width * 4
    var pixels = [UInt8](repeating: 0, count: stride * source.height)
    let bitmapInfo =
      CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: source.width,
          height: source.height, bitsPerComponent: 8, bytesPerRow: stride,
          space: colorSpace, bitmapInfo: bitmapInfo)
      else { return false }
      context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
      return true
    }
    guard drawn else { throw ID1GeometryError.renderingFailed }
    let width = ID1CardGeometry.pixelWidth
    let height = ID1CardGeometry.pixelHeight
    var output = [UInt8](repeating: 0, count: width * height * 4)
    let matrix = geometry.sourceToOutputPixelCenters
    let rendered = pixels.withUnsafeBufferPointer { input in
      output.withUnsafeMutableBufferPointer { destination in
        IEOpenCVWarpRGBA(
          input.baseAddress, Int32(source.width), Int32(source.height), stride,
          matrix, destination.baseAddress, Int32(width), Int32(height), width * 4)
      }
    }
    guard rendered, let provider = CGDataProvider(data: Data(output) as CFData),
      let result = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw ID1GeometryError.renderingFailed }
    return result
  }
}
