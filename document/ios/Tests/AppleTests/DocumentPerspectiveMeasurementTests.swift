import Foundation
import Testing

@testable import DocumentCaptureApple

@Suite struct DocumentPerspectiveMeasurementTests {
  private let corners: [DocumentPixelPoint] = [
    .init(x: 450, y: 500), .init(x: 850, y: 550),
    .init(x: 800, y: 850), .init(x: 500, y: 780)
  ]
  private let timestamp = DocumentCaptureClockTimestamp(
    value: Int64.max - 15, timescale: 60_000, flags: 3, epoch: 7,
    clock: .captureSessionSynchronizationClock)

  @Test func measuresKnownPixelEdgesAndPreservesExactSource() throws {
    let value = try measure(corners)
    let top = hypot(400.0, 50.0)
    let right = hypot(50.0, 300.0)
    let bottom = hypot(300.0, 70.0)
    let left = hypot(50.0, 280.0)
    close(value.rightToLeftEdgeLogRatio, log(right / left))
    close(value.bottomToTopEdgeLogRatio, log(bottom / top))
    close(value.meanHorizontalEdgePixels, (top + bottom) / 2)
    close(value.meanVerticalEdgePixels, (left + right) / 2)
    close(value.horizontalToVerticalEdgeRatio, (top + bottom) / (left + right))
    close(value.cornerMeanPixels.x, 650)
    close(value.cornerMeanPixels.y, 670)
    close(value.imagePlaneAngleRadians, atan2(120, 700))
    #expect(value.captureTimestamp == timestamp)
    #expect(value.deliveredTopLeftQuadrilateral == quad(corners))
    #expect(value.pixelWidth == 1320 && value.pixelHeight == 1760)
    #expect(value.uncertaintyStatus == .notEstimated)
  }

  @Test func translationChangesOnlyCenter() throws {
    let baseline = try measure(corners)
    let moved = try measure(corners.map { .init(x: $0.x + 70, y: $0.y - 80) })
    invariantShape(baseline, moved)
    close(moved.meanHorizontalEdgePixels, baseline.meanHorizontalEdgePixels)
    close(moved.meanVerticalEdgePixels, baseline.meanVerticalEdgePixels)
    close(moved.imagePlaneAngleRadians, baseline.imagePlaneAngleRadians)
    close(moved.cornerMeanPixels.x, baseline.cornerMeanPixels.x + 70)
    close(moved.cornerMeanPixels.y, baseline.cornerMeanPixels.y - 80)
  }

  @Test func uniformScaleIsSeparateFromProjectedShape() throws {
    let baseline = try measure(corners)
    let scale = 1.25
    let scaled = try measure(corners.map { .init(x: $0.x * scale, y: $0.y * scale) })
    invariantShape(baseline, scaled)
    close(scaled.meanHorizontalEdgePixels, baseline.meanHorizontalEdgePixels * scale)
    close(scaled.meanVerticalEdgePixels, baseline.meanVerticalEdgePixels * scale)
    close(scaled.imagePlaneAngleRadians, baseline.imagePlaneAngleRadians)
  }

  @Test func portraitAndLandscapeRasterAxesUseActualPixelDimensions() throws {
    let portrait = try measure(corners)
    let landscape = try measure(corners, width: 1760, height: 1320)
    invariantShape(portrait, landscape)
    close(portrait.meanHorizontalEdgePixels, landscape.meanHorizontalEdgePixels)
    close(portrait.meanVerticalEdgePixels, landscape.meanVerticalEdgePixels)
    close(portrait.imagePlaneAngleRadians, landscape.imagePlaneAngleRadians)
    close(portrait.cornerMeanPixels.x, landscape.cornerMeanPixels.x)
    close(portrait.cornerMeanPixels.y, landscape.cornerMeanPixels.y)
  }

  @Test func inPlaneRotationDoesNotBecomePerspectiveChange() throws {
    let baseline = try measure(corners)
    let angle = 0.63
    let rotated = try measure(
      corners.map { point in
        let horizontal = point.x - 650
        let vertical = point.y - 670
        return .init(
          x: 650 + horizontal * cos(angle) - vertical * sin(angle),
          y: 670 + horizontal * sin(angle) + vertical * cos(angle))
      })
    invariantShape(baseline, rotated)
    close(rotated.meanHorizontalEdgePixels, baseline.meanHorizontalEdgePixels)
    close(rotated.meanVerticalEdgePixels, baseline.meanVerticalEdgePixels)
    close(rotated.imagePlaneAngleRadians, baseline.imagePlaneAngleRadians + angle)
    close(rotated.cornerMeanPixels.x, baseline.cornerMeanPixels.x)
    close(rotated.cornerMeanPixels.y, baseline.cornerMeanPixels.y)
  }

  @Test func malformedQuadrilateralsAreUnavailable() {
    let invalid: [[DocumentPixelPoint]] = [
      [corners[0], corners[0], corners[2], corners[3]],
      [corners[0], corners[2], corners[1], corners[3]],
      [
        .init(x: 100, y: 100), .init(x: 200, y: 200),
        .init(x: 300, y: 300), .init(x: 400, y: 400)
      ],
      [
        .init(x: 100, y: 100), .init(x: 400, y: 100),
        .init(x: 200, y: 150), .init(x: 100, y: 400)
      ],
      [.init(x: -.infinity, y: 100), corners[1], corners[2], corners[3]],
      [.init(x: .nan, y: 100), corners[1], corners[2], corners[3]],
      [.init(x: -1, y: 100), corners[1], corners[2], corners[3]]
    ]
    for points in invalid {
      #expect(throws: DocumentPerspectiveMeasurementError.invalidQuadrilateral) {
        try measure(points)
      }
    }
  }

  @Test func invalidDimensionsAndNonnumericTimeAreUnavailable() {
    for size in [0, -1] {
      #expect(throws: DocumentPerspectiveMeasurementError.invalidDimensions) {
        try DocumentPerspectiveMeasurement(
          deliveredTopLeftQuadrilateral: quad(corners), pixelWidth: size, pixelHeight: 1760,
          captureTimestamp: timestamp)
      }
      #expect(throws: DocumentPerspectiveMeasurementError.invalidDimensions) {
        try DocumentPerspectiveMeasurement(
          deliveredTopLeftQuadrilateral: quad(corners), pixelWidth: 1320, pixelHeight: size,
          captureTimestamp: timestamp)
      }
    }
    for invalidTime in [
      DocumentCaptureClockTimestamp(
        value: 1, timescale: 0, flags: 1, epoch: 0, clock: .captureSessionSynchronizationClock),
      .init(
        value: 1, timescale: 600, flags: 0, epoch: 0, clock: .captureSessionSynchronizationClock),
      .init(
        value: 1, timescale: 600, flags: 17, epoch: 0, clock: .captureSessionSynchronizationClock)
    ] {
      #expect(throws: DocumentPerspectiveMeasurementError.invalidTimestamp) {
        try DocumentPerspectiveMeasurement(
          deliveredTopLeftQuadrilateral: quad(corners), pixelWidth: 1320, pixelHeight: 1760,
          captureTimestamp: invalidTime)
      }
    }
  }

  private func measure(
    _ points: [DocumentPixelPoint], width: Int = 1320, height: Int = 1760
  ) throws -> DocumentPerspectiveMeasurement {
    try .init(
      deliveredTopLeftQuadrilateral: quad(points, width: width, height: height),
      pixelWidth: width, pixelHeight: height, captureTimestamp: timestamp)
  }

  private func quad(
    _ points: [DocumentPixelPoint], width: Int = 1320, height: Int = 1760
  ) -> DocumentQuadrilateral {
    let normalized = points.map {
      DocumentNormalizedPoint(x: $0.x / Double(width), y: $0.y / Double(height))
    }
    return .init(
      topLeft: normalized[0], topRight: normalized[1],
      bottomRight: normalized[2], bottomLeft: normalized[3])
  }

  private func invariantShape(
    _ first: DocumentPerspectiveMeasurement, _ second: DocumentPerspectiveMeasurement
  ) {
    close(first.rightToLeftEdgeLogRatio, second.rightToLeftEdgeLogRatio)
    close(first.bottomToTopEdgeLogRatio, second.bottomToTopEdgeLogRatio)
    close(first.horizontalToVerticalEdgeRatio, second.horizontalToVerticalEdgeRatio)
  }

  private func close(_ actual: Double, _ expected: Double) {
    #expect(abs(actual - expected) < 1e-9)
  }
}
