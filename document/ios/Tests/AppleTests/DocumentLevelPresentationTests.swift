import Foundation
import Testing
@testable import DocumentCaptureApple
import DocumentCapturePreview

@Suite("Front level is a fresh, advisory gravity projection")
struct DocumentLevelPresentationTests {
  @Test func directionsAndAngularScaleUseGravityRatherThanTranslation() throws {
    let angle = Double.pi / 180
    let right = try #require(DocumentLevelPresentation.state(
      sample: sample(x: sin(angle), y: 0, z: -cos(angle)), uptime: 10.1).offset)
    let top = try #require(DocumentLevelPresentation.state(
      sample: sample(x: 0, y: sin(angle), z: -cos(angle)), uptime: 10.1).offset)
    #expect(abs(right.width + 0.1) < 0.000001)
    #expect(abs(right.height) < 0.000001)
    #expect(abs(top.height - 0.1) < 0.000001)
    #expect(DocumentLevelPresentation.state(sample: sample(x: 0, y: 0, z: -1), uptime: 10.1)
      == .init(offset: .zero, tone: .centered))
  }

  @Test func diagonalResponseClampsRadiallyWithoutChangingDirection() throws {
    let state = DocumentLevelPresentation.state(sample: sample(x: 0.5, y: 0.5, z: -0.707), uptime: 10.1)
    let offset = try #require(state.offset)
    #expect(abs(hypot(offset.width, offset.height) - 1) < 0.000001)
    #expect(offset.width < 0 && offset.height > 0)
    #expect(abs(offset.width + offset.height) < 0.000001)
    #expect(state.tone == .tilted)
  }

  @Test func visibleRingAndWarningBoundariesRemainDisplayOnly() {
    #expect(tilted(degrees: 3.74).tone == .centered)
    #expect(tilted(degrees: 3.76).tone == .warning)
    #expect(tilted(degrees: 7.49).tone == .warning)
    #expect(tilted(degrees: 7.51).tone == .tilted)
  }

  @Test func unavailableSamplesCannotMasqueradeAsFlat() {
    let flat = sample(x: 0, y: 0, z: -1)
    #expect(DocumentLevelPresentation.state(sample: flat, uptime: 10.5).offset == .zero)
    #expect(DocumentLevelPresentation.state(sample: flat, uptime: 10.500001) == .unavailable)
    #expect(DocumentLevelPresentation.state(sample: flat, uptime: 9.9) == .unavailable)
    #expect(DocumentLevelPresentation.state(sample: flat, uptime: .nan) == .unavailable)
    #expect(DocumentLevelPresentation.state(sample: nil, uptime: 10.1) == .unavailable)
    #expect(DocumentLevelPresentation.state(sample: sample(x: 0, y: 0, z: 1), uptime: 10.1) == .unavailable)
    #expect(DocumentLevelPresentation.state(sample: sample(x: 0, y: 1, z: 0), uptime: 10.1) == .unavailable)
    #expect(DocumentLevelPresentation.state(sample: sample(x: .nan, y: 0, z: -1), uptime: 10.1) == .unavailable)
    #expect(DocumentLevelPresentation.state(sample: sample(x: 0, y: .infinity, z: -1), uptime: 10.1) == .unavailable)
    #expect(DocumentLevelPresentation.state(sample: sample(x: 0, y: 0, z: -.infinity), uptime: 10.1) == .unavailable)
  }

  private func tilted(degrees: Double) -> DocumentLevelState {
    let angle = degrees * Double.pi / 180
    return DocumentLevelPresentation.state(sample: sample(x: sin(angle), y: 0, z: -cos(angle)), uptime: 10.1)
  }

  private func sample(x: Double, y: Double, z: Double) -> DocumentTemporalMotionSample {
    .init(bootTimeSeconds: 10, attitude: .init(x: 0, y: 0, z: 0, w: 1),
      rotationRate: .init(x: 0, y: 0, z: 0), gravity: .init(x: x, y: y, z: z),
      userAcceleration: .init(x: 100, y: -100, z: 100), referenceFrame: "synthetic-gravity-projection")
  }
}
