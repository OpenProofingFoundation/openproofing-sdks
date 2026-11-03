import Foundation

public enum DocumentSpatialError: Error, Equatable, Sendable {
  case invalidInput
  case resourceLimit
  case processingFailure
  case analysisInProgress
}

// Pixel coordinates retain the conventional x/y names used by the native bridge.
// swiftlint:disable identifier_name
/// Full-resolution pixel observations. The candidate mask classifies display strokes,
/// not material, document authenticity, or an accepted physical card perimeter.
public struct DocumentSpatialAnalysis: Sendable {
  public struct Pixel: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
  }
  public let sourceSHA256: String
  public let width: Int
  public let height: Int
  public let points: [Pixel]
  public let offsets: [Int]
  public let mask: [UInt8]

  public init(sourceSHA256: String, width: Int, height: Int,
              points: [Pixel], offsets: [Int], mask: [UInt8]) throws {
    let pixelCount = try Self.checkedPixelCount(width: width, height: height)
    guard sourceSHA256.count == 64, sourceSHA256.allSatisfy({ $0.isHexDigit }),
      mask.count == pixelCount, mask.allSatisfy({ $0 <= 1 }),
      offsets.first == 0, offsets.last == points.count,
      points.allSatisfy({ $0.x >= 0 && $0.x < width && $0.y >= 0 && $0.y < height })
    else { throw DocumentSpatialError.invalidInput }
    for index in 1..<offsets.count {
      let start = offsets[index - 1], end = offsets[index]
      guard start >= 0, end > start, end <= points.count else { throw DocumentSpatialError.invalidInput }
      for point in (start + 1)..<end {
        guard abs(points[point].x - points[point - 1].x) <= 1,
          abs(points[point].y - points[point - 1].y) <= 1 else { throw DocumentSpatialError.invalidInput }
      }
    }
    self.sourceSHA256 = sourceSHA256
    self.width = width; self.height = height
    self.points = points; self.offsets = offsets; self.mask = mask
  }

  // GrabCut stores graph indices and intermediate edge counts in signed int32.
  // This is arithmetic representability, not a device memory or photo-size budget.
  static func checkedPixelCount(width: Int, height: Int) throws -> Int {
    guard width > 0, height > 0 else { throw DocumentSpatialError.invalidInput }
    guard width <= Int(Int32.max), height <= Int(Int32.max) else { throw DocumentSpatialError.resourceLimit }
    let (count, overflow) = width.multipliedReportingOverflow(by: height)
    guard !overflow, count <= Int(Int32.max) / 4 else { throw DocumentSpatialError.resourceLimit }
    let perimeter = 3 * (width + height)
    let halfEdges = 4 * count - perimeter + 2
    guard perimeter <= Int(Int32.max), halfEdges >= 0,
      halfEdges <= (Int(Int32.max) - 2) / 2 else { throw DocumentSpatialError.resourceLimit }
    return count
  }

  public func maskContains(x: Double, y: Double) -> Bool {
    guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(width), y < Double(height) else { return false }
    return mask[Int(y.rounded(.down)) * width + Int(x.rounded(.down))] != 0
  }
}
// swiftlint:enable identifier_name
