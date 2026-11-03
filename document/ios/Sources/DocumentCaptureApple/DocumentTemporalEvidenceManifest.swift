import Foundation

public struct DocumentTemporalBinding: Codable, Equatable, Sendable {
  public let sessionID: String
  public let attemptID: String?
  public let side: String
  public let stillSHA256: String
  public let stillTimestamp: DocumentCaptureClockTimestamp
  public let stillHostTimeSeconds: Double?

  public init(
    sessionID: String, attemptID: String?, side: String, stillSHA256: String,
    stillTimestamp: DocumentCaptureClockTimestamp, stillHostTimeSeconds: Double?
  ) {
    self.sessionID = sessionID
    self.attemptID = attemptID
    self.side = side
    self.stillSHA256 = stillSHA256
    self.stillTimestamp = stillTimestamp
    self.stillHostTimeSeconds = stillHostTimeSeconds
  }
}

/// Bracketed host-clock reads around a boot-time read. This is a measured
/// correlation, not an assertion that the two clocks have identical epochs.
public struct DocumentTemporalClockCorrelation: Codable, Equatable, Sendable {
  public let hostBeforeSeconds: Double
  public let bootTimeSeconds: Double
  public let hostAfterSeconds: Double
  public let method: String
}

// Standard Cartesian and quaternion component names preserve the platform vocabulary.
// swiftlint:disable identifier_name
public struct DocumentTemporalVector3: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let z: Double
}

public struct DocumentTemporalQuaternion: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let z: Double
  public let w: Double
}

// swiftlint:enable identifier_name

public struct DocumentTemporalMotionSample: Codable, Equatable, Sendable {
  public let bootTimeSeconds: Double
  public let attitude: DocumentTemporalQuaternion
  public let rotationRate: DocumentTemporalVector3
  public let gravity: DocumentTemporalVector3
  public let userAcceleration: DocumentTemporalVector3
  public let referenceFrame: String

  var isFinite: Bool {
    let attitudeValues = [attitude.x, attitude.y, attitude.z, attitude.w]
    let rotationValues = [rotationRate.x, rotationRate.y, rotationRate.z]
    let gravityValues = [gravity.x, gravity.y, gravity.z]
    let accelerationValues = [userAcceleration.x, userAcceleration.y, userAcceleration.z]
    return bootTimeSeconds.isFinite && attitudeValues.allSatisfy(\.isFinite)
      && rotationValues.allSatisfy(\.isFinite) && gravityValues.allSatisfy(\.isFinite)
      && accelerationValues.allSatisfy(\.isFinite)
  }
}

public struct DocumentTemporalGap: Codable, Equatable, Sendable {
  public let reason: String
  public let timestamp: DocumentCaptureClockTimestamp?
  public let count: Int
}

public struct DocumentTemporalManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sequenceID: UUID
  public let binding: DocumentTemporalBinding
  public let configuration: DocumentTemporalConfiguration
  public let frames: [DocumentTemporalFrameMetadata]
  public let motionSamples: [DocumentTemporalMotionSample]
  public let clockCorrelation: DocumentTemporalClockCorrelation?
  /// `recorded` means the requested time interval was bracketed by observations.
  /// It never means the sequence is suitable for physical-document classification.
  public let status: String
  public let termination: String
  public let issues: [String]
  public let gaps: [DocumentTemporalGap]
  public let omittedDiagnosticCount: Int
  public let evictedFrameCount: Int
  public let evictedMotionSampleCount: Int
}
