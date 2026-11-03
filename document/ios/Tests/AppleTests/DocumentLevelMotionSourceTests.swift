import Foundation
import Testing

@testable import DocumentCaptureApple

@MainActor
private final class LevelMotionCollectorProbe: DocumentLevelMotionCollecting {
  var handlers: [@MainActor @Sendable (DocumentTemporalMotionSample?) -> Void] = []
  var starts = 0
  var stops = 0

  func startLevelMotion(
    handler: @escaping @MainActor @Sendable (DocumentTemporalMotionSample?) -> Void
  ) {
    starts += 1
    handlers.append(handler)
  }

  func stopLevelMotion() { stops += 1 }
}

@MainActor
struct DocumentLevelMotionSourceTests {
  @Test func startAndStopAreIdempotentAndStopClearsPublication() {
    let collector = LevelMotionCollectorProbe()
    var publications: [DocumentTemporalMotionSample?] = []
    let source = DocumentLevelMotionSource(collector: collector) { publications.append($0) }
    #expect(source.latestSample == nil)
    #expect(publications.isEmpty)
    source.start()
    source.start()
    #expect(collector.starts == 1)
    let value = sample(at: 1)
    collector.handlers[0](value)
    #expect(source.latestSample == value)
    #expect(publications == [value])
    source.stop()
    source.stop()
    #expect(collector.stops == 1)
    #expect(source.latestSample == nil)
    #expect(publications == [value, nil])
  }

  @Test func callbacksAfterStopCannotPublishOrRestoreLatestSample() {
    let collector = LevelMotionCollectorProbe()
    var publications: [DocumentTemporalMotionSample?] = []
    let source = DocumentLevelMotionSource(collector: collector) { publications.append($0) }
    source.start()
    source.stop()
    collector.handlers[0](sample(at: 2))
    collector.handlers[0](nil)
    #expect(source.latestSample == nil)
    #expect(publications == [nil])
  }

  @Test func retiredGenerationCannotReplaceOrClearRestartedSample() {
    let collector = LevelMotionCollectorProbe()
    var publications: [DocumentTemporalMotionSample?] = []
    let source = DocumentLevelMotionSource(collector: collector) { publications.append($0) }
    source.start()
    source.stop()
    source.start()
    #expect(collector.starts == 2)
    let current = sample(at: 3)
    collector.handlers[1](current)
    collector.handlers[0](sample(at: 1))
    collector.handlers[0](nil)
    #expect(source.latestSample == current)
    #expect(publications == [nil, current])
    source.stop()
  }

  @Test func unavailablePublicationClearsPreviouslyAvailableMotion() {
    let collector = LevelMotionCollectorProbe()
    var publications: [DocumentTemporalMotionSample?] = []
    let source = DocumentLevelMotionSource(collector: collector) { publications.append($0) }
    source.start()
    collector.handlers[0](nil)
    #expect(source.latestSample == nil)
    let value = sample(at: 4)
    collector.handlers[0](value)
    collector.handlers[0](nil)
    #expect(source.latestSample == nil)
    #expect(publications == [nil, value, nil])
    source.stop()
  }

  private func sample(at time: Double) -> DocumentTemporalMotionSample {
    DocumentTemporalMotionSample(
      bootTimeSeconds: time,
      attitude: .init(x: 0, y: 0, z: 0, w: 1),
      rotationRate: .init(x: 0, y: 0, z: 0),
      gravity: .init(x: 0, y: 0, z: -1),
      userAcceleration: .init(x: 0, y: 0, z: 0),
      referenceFrame: "xArbitraryZVertical_rotation_radians_per_second_acceleration_g")
  }
}
