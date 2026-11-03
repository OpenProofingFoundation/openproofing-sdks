#if os(iOS)
  import CoreVideo
  import Foundation

  /// Failures at the owned frame boundary, before asynchronous analysis or rendering.
  public enum SelfieFrameSnapshotError: Error, Sendable, Equatable {
    case unsupportedFormat, invalidDimensions, resourceLimit, invalidLayout
    case lockFailed, allocationFailed, depthCopyFailed
  }

  /// Copies only declared active plane bytes; source padding is never treated as image data.
  /// Inputs must remain unchanged during this synchronous copy. No source buffer escapes it.
  enum SelfieFrameSnapshot {
    /// Same resource limits as portrait-selfie-v1; these are allocation bounds, not calibration.
    private struct Bounds {
      let dimension: Int
      let pixels: Int
      let bytes: Int
    }
    private static let bounds = Bounds(
      dimension: 16_384, pixels: 67_108_864, bytes: 268_435_456)

    static func copy(_ source: CVPixelBuffer, depth: Bool = false) throws -> CVPixelBuffer {
      let width = CVPixelBufferGetWidth(source)
      let height = CVPixelBufferGetHeight(source)
      guard width > 0, height > 0 else { throw SelfieFrameSnapshotError.invalidDimensions }
      guard width <= bounds.dimension, height <= bounds.dimension,
        width <= bounds.pixels / height else { throw SelfieFrameSnapshotError.resourceLimit }
      let format = CVPixelBufferGetPixelFormatType(source)
      let bytesPerPixel: Int
      let planar: Bool
      if depth {
        switch format {
        case kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16: bytesPerPixel = 2
        case kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32: bytesPerPixel = 4
        default: throw SelfieFrameSnapshotError.unsupportedFormat
        }
        planar = false
      } else {
        switch format {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB: bytesPerPixel = 4; planar = false
        case kCVPixelFormatType_OneComponent8: bytesPerPixel = 1; planar = false
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
          guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw SelfieFrameSnapshotError.invalidLayout
          }
          bytesPerPixel = 1; planar = true
        default: throw SelfieFrameSnapshotError.unsupportedFormat
        }
      }
      guard CVPixelBufferGetDataSize(source) <= bounds.bytes else {
        throw SelfieFrameSnapshotError.resourceLimit
      }
      let expectedPlanes = planar ? 2 : 0
      guard CVPixelBufferGetPlaneCount(source) == expectedPlanes else {
        throw SelfieFrameSnapshotError.invalidLayout
      }
      let rowBytes = width * bytesPerPixel
      let total = rowBytes * height + (planar ? width * height / 2 : 0)
      guard total <= bounds.bytes else { throw SelfieFrameSnapshotError.resourceLimit }
      guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
        throw SelfieFrameSnapshotError.lockFailed
      }
      defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
      // Validate all source layouts before requesting destination storage.
      var sourceStorage = 0
      for plane in 0..<(planar ? 2 : 1) {
        let rows = planar && plane == 1 ? height / 2 : height
        let columns = planar && plane == 1 ? width / 2 : width
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
        let address = planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source)
        guard address != nil, stride >= rowBytes, stride <= bounds.bytes / rows,
          !planar || (CVPixelBufferGetWidthOfPlane(source, plane) == columns
            && CVPixelBufferGetHeightOfPlane(source, plane) == rows) else {
          throw SelfieFrameSnapshotError.invalidLayout
        }
        sourceStorage += stride * rows
        guard sourceStorage <= bounds.bytes else { throw SelfieFrameSnapshotError.resourceLimit }
      }
      var allocated: CVPixelBuffer?
      guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &allocated) == kCVReturnSuccess,
        let destination = allocated else { throw SelfieFrameSnapshotError.allocationFailed }
      guard CVPixelBufferGetDataSize(destination) <= bounds.bytes else {
        throw SelfieFrameSnapshotError.resourceLimit
      }
      guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
        throw SelfieFrameSnapshotError.lockFailed
      }
      defer { CVPixelBufferUnlockBaseAddress(destination, []) }
      for plane in 0..<(planar ? 2 : 1) {
        let rows = planar && plane == 1 ? height / 2 : height
        let sourceStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
        let destinationStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(destination, plane) : CVPixelBufferGetBytesPerRow(destination)
        let sourceBase = planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source)
        let destinationBase = planar ? CVPixelBufferGetBaseAddressOfPlane(destination, plane) : CVPixelBufferGetBaseAddress(destination)
        guard let sourceBase, let destinationBase, destinationStride >= rowBytes,
          destinationStride <= bounds.bytes / rows else { throw SelfieFrameSnapshotError.invalidLayout }
        for row in 0..<rows {
          let target = destinationBase.advanced(by: row * destinationStride)
          target.initializeMemory(as: UInt8.self, repeating: 0, count: destinationStride)
          target.copyMemory(from: sourceBase.advanced(by: row * sourceStride), byteCount: rowBytes)
        }
      }
      // AR YUV matrix, transfer function and primaries must follow the copied pixel values.
      CVBufferPropagateAttachments(source, destination)
      return destination
    }
  }
#endif
