import CoreVideo

/// Owns a separate analysis image so Vision cannot hold the capture pool hostage.
/// Only one such image is admitted by DocumentFrameAnalyzer.analysisSlot.
enum DocumentAnalysisPixelCopy {
  static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      CVPixelBufferGetPlaneCount(source) == 2 else { return nil }
    var destination: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source),
      CVPixelBufferGetHeight(source), CVPixelBufferGetPixelFormatType(source), nil, &destination) == kCVReturnSuccess,
      let destination,
      CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(destination, []) }
    for plane in 0..<2 {
      guard let input = CVPixelBufferGetBaseAddressOfPlane(source, plane),
        let output = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { return nil }
      let rowBytes = CVPixelBufferGetWidthOfPlane(source, plane) * (plane == 0 ? 1 : 2)
      let inputStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
      let outputStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
      for row in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
        output.advanced(by: row * outputStride).copyMemory(
          from: input.advanced(by: row * inputStride), byteCount: rowBytes)
      }
    }
    CVBufferPropagateAttachments(source, destination)
    return destination
  }
}
