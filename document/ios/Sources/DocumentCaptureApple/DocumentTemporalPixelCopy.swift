import CoreVideo
import CryptoKit
import Foundation

/// Copies only meaningful 420f plane bytes, excluding uninitialized row padding.
/// Dimensions and original strides remain in the manifest for reconstruction.
enum DocumentTemporalPixelCopy {
  enum Failure: String, Error { case unsupportedFormat, invalidPlane, capacity, lockFailed }
  struct Copy {
    let data: Data
    let planes: [DocumentTemporalPlane]
    let sha256: String
    let attachments: Data?
    let attachmentSerializationFailed: Bool
  }

  static func byteCount(_ buffer: CVPixelBuffer) throws -> Int {
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      CVPixelBufferGetPlaneCount(buffer) == 2
    else { throw Failure.unsupportedFormat }
    var total = 0
    for plane in 0..<2 {
      let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
      let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
      let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: plane == 0 ? 1 : 2)
      let (size, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
      let (sum, totalOverflow) = total.addingReportingOverflow(size)
      guard width > 0, height > 0, !rowOverflow, !sizeOverflow, !totalOverflow,
        CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) >= rowBytes
      else { throw Failure.invalidPlane }
      total = sum
    }
    return total
  }

  static func copy(_ buffer: CVPixelBuffer, maximumBytes: Int) throws -> Copy {
    let total = try byteCount(buffer)
    guard total <= maximumBytes else { throw Failure.capacity }
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
      throw Failure.lockFailed
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    var data = Data(count: total)
    var planes: [DocumentTemporalPlane] = []
    try data.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
      var offset = 0
      for plane in 0..<2 {
        guard let source = CVPixelBufferGetBaseAddressOfPlane(buffer, plane),
          let target = destination.baseAddress
        else { throw Failure.invalidPlane }
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let packed = width * (plane == 0 ? 1 : 2)
        for row in 0..<height {
          target.advanced(by: offset + row * packed).copyMemory(
            from: source.advanced(by: row * stride), byteCount: packed)
        }
        planes.append(
          DocumentTemporalPlane(
            offset: offset, byteCount: packed * height, width: width, height: height,
            sourceBytesPerRow: stride, packedBytesPerRow: packed))
        offset += packed * height
      }
    }
    let sourceAttachments = CVBufferCopyAttachments(buffer, .shouldPropagate)
    let attachments = sourceAttachments.flatMap {
      try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
    }
    return Copy(
      data: data, planes: planes,
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      attachments: attachments,
      attachmentSerializationFailed: sourceAttachments != nil && attachments == nil)
  }
}
