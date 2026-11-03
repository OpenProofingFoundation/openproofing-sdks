import Foundation
import Testing
@testable import DocumentCaptureApple

final class RecordingSink: DocumentJourneyRecordingSink, @unchecked Sendable {
  private let lock = NSLock()
  private var accepts = true
  private var reservationTotal = 0
  private var activeReservations: Set<UUID> = []
  private var frames = 0
  private var motions = 0
  private var retainedEvents: [DocumentJourneyRecordingEvent] = []
  var acceptFrames: Bool {
    get { lock.withLock { accepts } }
    set { lock.withLock { accepts = newValue } }
  }
  var reservationsMade: Int { lock.withLock { reservationTotal } }
  var reservations: Set<UUID> { lock.withLock { activeReservations } }
  var motionCount: Int { lock.withLock { motions } }
  var frameCount: Int { lock.withLock { frames } }
  var events: [DocumentJourneyRecordingEvent] { lock.withLock { retainedEvents } }

  func reserveFrame(byteCount: Int) -> UUID? {
    lock.withLock {
      guard accepts else { return nil }
      let token = UUID()
      activeReservations.insert(token)
      reservationTotal += 1
      return token
    }
  }

  func appendFrame(_ frame: DocumentTemporalFrame, reservation: UUID) {
    lock.withLock {
      #expect(activeReservations.remove(reservation) != nil)
      #expect(frame.payload.count == 768)
      frames += 1
    }
  }

  func cancelReservation(_ reservation: UUID, reason: String) {
    _ = lock.withLock { activeReservations.remove(reservation) }
  }

  func appendMotion(_ sample: DocumentTemporalMotionSample) { lock.withLock { motions += 1 } }
  func appendEvent(_ event: DocumentJourneyRecordingEvent) {
    lock.withLock { retainedEvents.append(event) }
  }
  func finish(reason: String) async throws -> DocumentJourneyRecordingReceipt {
    .init(recordingID: UUID(), status: "fixture", frameCount: frameCount, motionSampleCount: 0)
  }
}
