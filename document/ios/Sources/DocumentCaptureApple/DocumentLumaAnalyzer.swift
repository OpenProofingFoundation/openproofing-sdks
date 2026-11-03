import CoreVideo
import Foundation

struct DocumentLumaAnalysis {
  let samples: [UInt8]
  let motionSamples: [UInt8]
  let meanLuminance: Double
  let clippedHighlightRatio: Double
  let sharpness: Double

  static let empty = Self(
    samples: [],
    motionSamples: [],
    meanLuminance: 0,
    clippedHighlightRatio: 0,
    sharpness: 0
  )
}

enum DocumentLumaAnalyzer {
  private struct Plane {
    let baseAddress: UnsafeMutableRawPointer
    let width: Int
    let height: Int
    let bytesPerRow: Int
  }

  static func analyze(
    _ pixelBuffer: CVPixelBuffer,
    normalizedRegion: CGRect?
  ) -> DocumentLumaAnalysis {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let plane = lumaPlane(in: pixelBuffer) else {
      return DocumentLumaAnalysis(
        samples: [],
        motionSamples: [],
        meanLuminance: 0,
        clippedHighlightRatio: 0,
        sharpness: 0
      )
    }

    let samples = sampledLuma(from: plane, normalizedRegion: normalizedRegion)
    let motionSamples = averagedLuma(from: plane, normalizedRegion: normalizedRegion)
    let count = max(samples.count, 1)
    let sum = samples.reduce(0) { $0 + Int($1) }
    let clipped = samples.count(where: { $0 >= DocumentCaptureTuning.Quality.clippedLumaSample })
    return DocumentLumaAnalysis(
      samples: samples,
      motionSamples: motionSamples,
      meanLuminance: Double(sum) / Double(count * 255),
      clippedHighlightRatio: Double(clipped) / Double(count),
      sharpness: sharpness(of: samples)
    )
  }

  private static func lumaPlane(in pixelBuffer: CVPixelBuffer) -> Plane? {
    let plane = CVPixelBufferGetPlaneCount(pixelBuffer) > 0 ? 0 : -1
    let width =
      plane == 0 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
    let height =
      plane == 0
      ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow =
      plane == 0
      ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
      : CVPixelBufferGetBytesPerRow(pixelBuffer)
    let baseAddress =
      plane == 0
      ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
      : CVPixelBufferGetBaseAddress(pixelBuffer)
    guard let baseAddress, width > 0, height > 0 else { return nil }
    return Plane(
      baseAddress: baseAddress,
      width: width,
      height: height,
      bytesPerRow: bytesPerRow
    )
  }

  private static func sampledLuma(
    from plane: Plane,
    normalizedRegion: CGRect?
  ) -> [UInt8] {
    let gridWidth = 64
    let gridHeight = 48
    let region = clamped(normalizedRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1))
    let firstColumn = Int(region.minX * CGFloat(plane.width))
    let firstRow = Int(region.minY * CGFloat(plane.height))
    let regionWidth = max(Int(region.width * CGFloat(plane.width)), 1)
    let regionHeight = max(Int(region.height * CGFloat(plane.height)), 1)
    let bytes = plane.baseAddress.assumingMemoryBound(to: UInt8.self)
    var samples = [UInt8]()
    samples.reserveCapacity(gridWidth * gridHeight)

    for gridY in 0..<gridHeight {
      let sourceRow = min(
        firstRow + (gridY * regionHeight) / gridHeight,
        plane.height - 1
      )
      for gridX in 0..<gridWidth {
        let sourceColumn = min(
          firstColumn + (gridX * regionWidth) / gridWidth,
          plane.width - 1
        )
        samples.append(bytes[(sourceRow * plane.bytesPerRow) + sourceColumn])
      }
    }
    return samples
  }

  /// Produces a low-frequency grid for motion estimation. Averaging within
  /// each cell prevents a one-pixel shift across printed text from looking like
  /// whole-frame motion while preserving meaningful camera/card displacement.
  private static func averagedLuma(
    from plane: Plane,
    normalizedRegion: CGRect?
  ) -> [UInt8] {
    let gridWidth = 16
    let gridHeight = 12
    let samplesPerAxis = 4
    let region = clamped(normalizedRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1))
    let firstColumn = Int(region.minX * CGFloat(plane.width))
    let firstRow = Int(region.minY * CGFloat(plane.height))
    let regionWidth = max(Int(region.width * CGFloat(plane.width)), 1)
    let regionHeight = max(Int(region.height * CGFloat(plane.height)), 1)
    let bytes = plane.baseAddress.assumingMemoryBound(to: UInt8.self)
    var samples = [UInt8]()
    samples.reserveCapacity(gridWidth * gridHeight)

    for gridY in 0..<gridHeight {
      let cellMinRow = firstRow + (gridY * regionHeight) / gridHeight
      let cellMaxRow = firstRow + ((gridY + 1) * regionHeight) / gridHeight
      for gridX in 0..<gridWidth {
        let cellMinColumn = firstColumn + (gridX * regionWidth) / gridWidth
        let cellMaxColumn = firstColumn + ((gridX + 1) * regionWidth) / gridWidth
        var sum = 0
        for sampleY in 0..<samplesPerAxis {
          let sourceRow = min(
            cellMinRow + (sampleY * max(cellMaxRow - cellMinRow, 1)) / samplesPerAxis,
            plane.height - 1
          )
          for sampleX in 0..<samplesPerAxis {
            let sourceColumn = min(
              cellMinColumn
                + (sampleX * max(cellMaxColumn - cellMinColumn, 1)) / samplesPerAxis,
              plane.width - 1
            )
            sum += Int(bytes[(sourceRow * plane.bytesPerRow) + sourceColumn])
          }
        }
        samples.append(UInt8(sum / (samplesPerAxis * samplesPerAxis)))
      }
    }
    return samples
  }

  private static func clamped(_ region: CGRect) -> CGRect {
    region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  private static func sharpness(of samples: [UInt8]) -> Double {
    let gridWidth = 64
    let gridHeight = 48
    guard samples.count == gridWidth * gridHeight else { return 0 }
    var gradientSum = 0
    var gradientCount = 0
    for gridRow in 1..<gridHeight {
      for gridColumn in 1..<gridWidth {
        let index = (gridRow * gridWidth) + gridColumn
        gradientSum += abs(Int(samples[index]) - Int(samples[index - 1]))
        gradientSum += abs(Int(samples[index]) - Int(samples[index - gridWidth]))
        gradientCount += 2
      }
    }
    return Double(gradientSum) / Double(max(gradientCount, 1) * 255)
  }
}
