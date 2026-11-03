import Foundation

/// Synchronous, bounded admission only. Implementations must not perform disk IO,
/// encoding, or blocking waits on the camera callback. Reservation precedes copying.
public protocol DocumentJourneyRecordingSink: Sendable {
  func reserveFrame(byteCount: Int) -> UUID?
  func reserveFrame(byteCount: Int, failure: DocumentJourneyRecordingEvent) -> UUID?
  func appendFrame(_ frame: DocumentTemporalFrame, reservation: UUID)
  func cancelReservation(_ reservation: UUID, reason: String)
  func cancelReservation(_ reservation: UUID, failure: DocumentJourneyRecordingEvent)
  func appendMotion(_ sample: DocumentTemporalMotionSample)
  func appendEvent(_ event: DocumentJourneyRecordingEvent)
  func finish(reason: String) async throws -> DocumentJourneyRecordingReceipt
}

public struct DocumentJourneyRecordingEvent: Codable, Equatable, Sendable {
  public let kind: String
  public let hostTimeSeconds: Double
  public let sessionID: String?
  public let timestamp: DocumentCaptureClockTimestamp?
  public let clockCorrelation: DocumentTemporalClockCorrelation?
  public let geometry: DocumentTemporalGeometry?
  public let liveGeometry: DocumentLiveGeometryObservation?
  public let tiltGuidance: DocumentTiltUpdate?
  public let binding: DocumentTemporalBinding?
  public let contextCode: String?

  public init(
    kind: String, hostTimeSeconds: Double, sessionID: String? = nil,
    timestamp: DocumentCaptureClockTimestamp? = nil,
    clockCorrelation: DocumentTemporalClockCorrelation? = nil,
    geometry: DocumentTemporalGeometry? = nil, binding: DocumentTemporalBinding? = nil,
    contextCode: String? = nil, liveGeometry: DocumentLiveGeometryObservation? = nil,
    tiltGuidance: DocumentTiltUpdate? = nil
  ) {
    self.kind = kind
    self.sessionID = sessionID
    self.hostTimeSeconds = hostTimeSeconds
    self.timestamp = timestamp
    self.clockCorrelation = clockCorrelation
    self.geometry = geometry
    self.liveGeometry = liveGeometry
    self.tiltGuidance = tiltGuidance
    self.binding = binding
    self.contextCode = contextCode
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case hostTimeSeconds
    case sessionID
    case timestamp
    case clockCorrelation
    case geometry
    case liveGeometry
    case tiltGuidance
    case binding
    case contextCode = "detail"
  }
}

public struct DocumentJourneyRecordingReceipt: Codable, Equatable, Sendable {
  public let recordingID: UUID
  public let status: String
  public let frameCount: Int
  public let motionSampleCount: Int

  public init(recordingID: UUID, status: String, frameCount: Int, motionSampleCount: Int) {
    self.recordingID = recordingID
    self.status = status
    self.frameCount = frameCount
    self.motionSampleCount = motionSampleCount
  }
}

extension DocumentJourneyRecordingSink {
  public func reserveFrame(byteCount: Int, failure: DocumentJourneyRecordingEvent) -> UUID? {
    let token = reserveFrame(byteCount: byteCount)
    if token == nil { appendEvent(failure) }
    return token
  }

  public func cancelReservation(_ reservation: UUID, failure: DocumentJourneyRecordingEvent) {
    cancelReservation(reservation, reason: failure.contextCode ?? failure.kind)
    appendEvent(failure)
  }
}
