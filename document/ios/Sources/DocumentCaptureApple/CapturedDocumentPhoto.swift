import Foundation
import DocumentSDK

/// Exact media time reported by AVFoundation for a captured image.
///
/// This value is synchronized to the owning capture session's synchronization
/// clock. It is not a wall-clock date and must not be represented as one
/// without a separately measured clock correlation.
public struct DocumentCaptureClockTimestamp: Codable, Equatable, Sendable {
  public enum Clock: String, Codable, Equatable, Sendable {
    case captureSessionSynchronizationClock
  }

  public let value: Int64
  public let timescale: Int32
  public let flags: UInt32
  public let epoch: Int64
  public let clock: Clock

  public init(
    value: Int64,
    timescale: Int32,
    flags: UInt32,
    epoch: Int64,
    clock: Clock
  ) {
    self.value = value
    self.timescale = timescale
    self.flags = flags
    self.epoch = epoch
    self.clock = clock
  }
}

/// Original encoded photo bytes and capture facts from one live document presentation.
public struct CapturedDocumentPhoto: Sendable {
  public let sessionID: CaptureSessionID
  public let side: DocumentSide
  public let origin: MediaOrigin
  public let requestedAt: Date
  public let captureTimestamp: DocumentCaptureClockTimestamp
  public let processedAt: Date
  public let data: Data
  public let fidelity: PhotoFidelityMetadata
  public let admission: DocumentCaptureAdmissionSnapshot?
  /// Every platform metadata value retained whole, alongside the curated
  /// `fidelity` subset. Nil when the retained bytes yielded none.
  public let platformMetadata: CapturedPhotoPlatformMetadata?
  /// A host-supplied location and what the capture path did with it. Nil when
  /// no location was supplied, which is the default.
  public let location: CaptureLocationRecord?
  public let temporalEvidence: DocumentTemporalEvidence?
  public let motionEvidence: DocumentMotionEvidence?

  init(
    sessionID: CaptureSessionID,
    side: DocumentSide,
    requestedAt: Date,
    captureTimestamp: DocumentCaptureClockTimestamp,
    processedAt: Date,
    data: Data,
    fidelity: PhotoFidelityMetadata,
    admission: DocumentCaptureAdmissionSnapshot?,
    platformMetadata: CapturedPhotoPlatformMetadata? = nil,
    location: CaptureLocationRecord? = nil,
    temporalEvidence: DocumentTemporalEvidence? = nil,
    motionEvidence: DocumentMotionEvidence? = nil
  ) {
    self.sessionID = sessionID
    self.side = side
    self.origin = .liveSensor
    self.requestedAt = requestedAt
    self.captureTimestamp = captureTimestamp
    self.processedAt = processedAt
    self.data = data
    self.fidelity = fidelity
    self.admission = admission
    self.platformMetadata = platformMetadata
    self.location = location
    self.temporalEvidence = temporalEvidence
    self.motionEvidence = motionEvidence
  }
}


extension CapturedDocumentPhoto {
  func retainingMotion(_ evidence: DocumentMotionEvidence?) -> Self {
    Self(sessionID: sessionID, side: side, requestedAt: requestedAt,
      captureTimestamp: captureTimestamp, processedAt: processedAt, data: data,
      fidelity: fidelity, admission: admission, platformMetadata: platformMetadata,
      location: location, temporalEvidence: temporalEvidence, motionEvidence: evidence)
  }
}
