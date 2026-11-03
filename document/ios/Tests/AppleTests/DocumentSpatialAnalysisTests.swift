import Foundation
import Testing
@testable import DocumentCaptureApple

struct DocumentSpatialAnalysisTests {
  private typealias Pixel = DocumentSpatialAnalysis.Pixel
  private let digest = String(repeating: "a", count: 64)

  private func analysis(width: Int = 5, height: Int = 5, points: [Pixel] = [],
                        offsets: [Int] = [0], mask: [UInt8]? = nil) throws -> DocumentSpatialAnalysis {
    try DocumentSpatialAnalysis(sourceSHA256: digest, width: width, height: height,
      points: points, offsets: offsets, mask: mask ?? [UInt8](repeating: 0, count: 25))
  }

  @Test func emptyEdgesRemainAnEmptyObservation() throws {
    let value = try analysis()
    #expect(value.points.isEmpty)
    #expect(value.offsets == [0])
    #expect(value.sourceSHA256 == digest)
  }

  @Test func singletonAndEveryChainPointSurviveExactly() throws {
    let points = [Pixel(x: 4, y: 4), Pixel(x: 0, y: 0), Pixel(x: 1, y: 0),
      Pixel(x: 2, y: 1), Pixel(x: 1, y: 2), Pixel(x: 0, y: 1)]
    let value = try analysis(points: points, offsets: [0, 1, 6])
    #expect(value.points == points)
    #expect(value.offsets == [0, 1, 6])
  }

  @Test func midpointSamplingUsesCenteredPixelCoordinatesAndFloor() throws {
    var mask = [UInt8](repeating: 0, count: 25)
    mask[1 * 5 + 2] = 1
    let value = try analysis(mask: mask)
    // Segment (1,1)->(2,0) becomes (1.5,1.5)->(2.5,0.5): midpoint (2,1).
    // Neither original point is inside; endpoint-based classification must fail this fixture.
    #expect(!value.maskContains(x: 1.5, y: 1.5))
    #expect(!value.maskContains(x: 2.5, y: 0.5))
    #expect(value.maskContains(x: 2, y: 1))
    #expect(!value.maskContains(x: 1.999_999, y: 1))
    #expect(!value.maskContains(x: 2, y: 0.999_999))
  }

  @Test func maskHoleAndDisconnectedLabelsAreNotReplacedByQuadContainment() throws {
    var mask = [UInt8](repeating: 1, count: 25)
    mask[12] = 0
    let value = try analysis(mask: mask)
    #expect(!value.maskContains(x: 2.5, y: 2.5))
    #expect(value.maskContains(x: 1.5, y: 2.5))
    #expect(value.maskContains(x: 3.5, y: 2.5))
  }

  @Test func nonfiniteAndOutsideCoordinatesRefuseClassification() throws {
    let value = try analysis(mask: [UInt8](repeating: 1, count: 25))
    for coordinate in [Double.nan, .infinity, -.infinity, -0.001, 5, Double.greatestFiniteMagnitude] {
      #expect(!value.maskContains(x: coordinate, y: 0.5))
      #expect(!value.maskContains(x: 0.5, y: coordinate))
    }
    #expect(value.maskContains(x: 0, y: 0))
    #expect(value.maskContains(x: 4.999_999, y: 4.999_999))
  }

  @Test func malformedOffsetsAreRejected() {
    let points = [Pixel(x: 0, y: 0), Pixel(x: 1, y: 0)]
    for offsets in [[], [1, 2], [0], [0, 1], [0, 3], [0, 1, 1, 2], [0, 2, 1, 2], [0, -1, 2], [0, Int.max, 2]] {
      #expect(throws: (any Error).self) { try analysis(points: points, offsets: offsets) }
    }
    #expect(throws: (any Error).self) { try analysis(offsets: [0, 0]) }
  }

  @Test func boundsAndDiscontinuousChainsAreRejected() {
    for point in [Pixel(x: -1, y: 0), Pixel(x: 0, y: -1), Pixel(x: 5, y: 0),
      Pixel(x: 0, y: 5), Pixel(x: Int.max, y: Int.min)] {
      #expect(throws: (any Error).self) { try analysis(points: [point], offsets: [0, 1]) }
    }
    #expect(throws: (any Error).self) {
      try analysis(points: [Pixel(x: 0, y: 0), Pixel(x: 2, y: 0)], offsets: [0, 2])
    }
  }

  @Test func maskLengthAndLabelsMustMatchExactRaster() {
    for mask in [[], [UInt8](repeating: 0, count: 24), [UInt8](repeating: 0, count: 26),
      [UInt8](repeating: 2, count: 25), [UInt8](repeating: 255, count: 25)] {
      #expect(throws: (any Error).self) { try analysis(mask: mask) }
    }
  }

  @Test func fullResolutionMaskBeyondFourMillionPixelsIsRetainedExactly() throws {
    let width = 2001, height = 2000
    var mask = [UInt8](repeating: 0, count: width * height)
    mask[mask.count - 1] = 1
    let value = try analysis(width: width, height: height, mask: mask)
    #expect(value.mask == mask)
    #expect(value.maskContains(x: Double(width) - 0.5, y: Double(height) - 0.5))
  }

  @Test func nativeRepresentabilityAdmitsFortyEightMegapixelsWithoutAllocatingRaster() throws {
    #expect(try DocumentSpatialAnalysis.checkedPixelCount(width: 8000, height: 6000) == 48_000_000)
    #expect(throws: (any Error).self) {
      try DocumentSpatialAnalysis.checkedPixelCount(width: Int.max, height: Int.max)
    }
    #expect(throws: (any Error).self) {
      try DocumentSpatialAnalysis.checkedPixelCount(width: Int(Int32.max), height: Int(Int32.max))
    }
    #expect(throws: (any Error).self) {
      try DocumentSpatialAnalysis.checkedPixelCount(width: Int(Int32.max) + 1, height: 1)
    }
  }

  @Test func malformedAndOverflowingDimensionsAreRejectedWithoutAllocation() {
    for (width, height) in [(0, 5), (5, 0), (-1, 5), (5, -1), (Int.max, 2), (2, Int.max), (Int(Int32.max) + 1, 1), (1, Int(Int32.max) + 1)] {
      #expect(throws: (any Error).self) { try analysis(width: width, height: height, mask: []) }
    }
  }
}
