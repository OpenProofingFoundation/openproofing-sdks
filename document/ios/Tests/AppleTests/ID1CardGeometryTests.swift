import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import DocumentCaptureApple

@Test func id1CoordinateRoundTripsAndFeatureLengthsAreIndependentOfPerspective() throws {
  for tilt in [0.0, 0.002] {
    func project(_ horizontal: Double, _ vertical: Double) -> DocumentPixelPoint {
      .init(
        x: (100 + 9 * horizontal + 0.2 * vertical) / (1 + tilt * horizontal),
        y: (50 + 0.1 * horizontal + 8 * vertical) / (1 + tilt * horizontal))
    }
    let corners = [project(0, 0), project(85.6, 0), project(85.6, 53.98), project(0, 53.98)]
    let geometry = try ID1CardGeometry(observation: id1Observation(corners: corners))
    #expect(geometry.valid)
    let feature = try geometry.cardPoint(from: project(20, 15))
    #expect(abs(feature.x - 20) < 0.0001)
    #expect(abs(feature.y - 15) < 0.0001)
    #expect(
      abs(try geometry.distanceMillimeters(from: project(20, 15), to: project(30, 15)) - 10)
        < 0.0001)
    let restored = try geometry.sourcePoint(from: feature)
    #expect(hypot(restored.x - project(20, 15).x, restored.y - project(20, 15).y) < 0.0001)
    let decoded = try JSONDecoder().decode(
      ID1CardGeometry.self, from: JSONEncoder().encode(geometry))
    #expect(decoded == geometry)
    #expect(decoded.valid)
    #expect(throws: ID1GeometryError.self) { try geometry.sourcePoint(from: .init(x: -1, y: 0)) }
  }
}

@Test func id1RenderingPreservesOrientationAndUsesFixedSquareSampling() throws {
  let corners = [
    DocumentPixelPoint(x: 100, y: 50), .init(x: 900, y: 50),
    .init(x: 900, y: 550), .init(x: 100, y: 550)
  ]
  let geometry = try ID1CardGeometry(observation: id1Observation(corners: corners))
  let background = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 600))
  let upperHalf = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 300, width: 1000, height: 300))
  let input = upperHalf.composited(over: background)
  let rendered = try ID1ImageNormalizer.render(input, geometry: geometry)
  #expect(rendered.width == 4280 && rendered.height == 2699)
  let bytes = try #require(rendered.dataProvider?.data) as Data
  let upper = 100 * rendered.bytesPerRow + 100 * 4
  let lower = 2500 * rendered.bytesPerRow + 100 * 4
  #expect(bytes[upper] > 240 && bytes[upper + 2] < 10)
  #expect(bytes[lower + 2] > 240 && bytes[lower] < 10)
  let repeated = try ID1ImageNormalizer.render(input, geometry: geometry)
  #expect(bytes == (try #require(repeated.dataProvider?.data) as Data))
}

@Test func malformedID1GeometryCannotBeUsedAsAnAcceptedDerivation() throws {
  let corners = [
    DocumentPixelPoint(x: 100, y: 50), .init(x: 900, y: 50),
    .init(x: 900, y: 550), .init(x: 100, y: 550)
  ]
  let geometry = try ID1CardGeometry(observation: id1Observation(corners: corners))
  var encoded = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(geometry)) as? [String: Any])
  encoded["sourceToCardMillimeters"] = [0, 0]
  let malformed = try JSONDecoder().decode(
    ID1CardGeometry.self,
    from: JSONSerialization.data(withJSONObject: encoded))
  #expect(!malformed.valid)
  #expect(throws: ID1GeometryError.self) { try malformed.cardPoint(from: .init(x: 200, y: 200)) }
  #expect(throws: ID1GeometryError.self) {
    try ID1CardGeometry(
      observation: id1Observation(corners: [corners[0], corners[2], corners[1], corners[3]]))
  }
}

private func id1Observation(corners: [DocumentPixelPoint]) -> DocumentGeometryObservation {
  let points = corners.map { DocumentNormalizedPoint(x: $0.x / 1000, y: 1 - $0.y / 600) }
  return .init(
    method: .visionDocumentSegmentation, implementationVersion: "synthetic",
    requestRevision: nil, confidence: nil, normalizedCoordinateQuantization: nil,
    analysisPixelWidth: nil, analysisPixelHeight: nil,
    regionOfInterest: CGRect(x: 0, y: 0, width: 1, height: 1),
    orientedPixelWidth: 1000, orientedPixelHeight: 600,
    quadrilateral: .init(
      topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3]))
}
