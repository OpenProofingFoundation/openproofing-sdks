import Foundation

/// Host operational clocks. Native capture timestamps retain their separate explicit clock domain.
public struct CaptureRecordingClock: Sendable {
  public let now: @Sendable () -> Date
  public let uptime: @Sendable () -> TimeInterval
  public init(
    now: @escaping @Sendable () -> Date,
    uptime: @escaping @Sendable () -> TimeInterval
  ) {
    self.now = now
    self.uptime = uptime
  }
}

/// Numeric parity with retained capture-stack journal behavior, not calibrated physical acceptance.
/// The identifier is retained in each new start record; old start records remain decodable.
public struct CaptureRecordingPolicy: Sendable {
  /// The original bounds: two minutes and eight gigabytes. Kept so records
  /// that name this version still describe the policy they were made under.
  public static let retainedV1 = Self(
    version: "capture-recording-retained-v1",
    maximumDuration: 120, maximumDiskBytes: 8_589_934_592, maximumPendingBytes: 67_108_864)
  /// Bounds fit to what a capture is: twenty seconds around the shutter and
  /// half a gigabyte at most. With the recorder pacing journey frames to two a
  /// second, a scan is tens of megabytes, not hundreds. The default.
  public static let retainedV2 = Self(
    version: "capture-recording-retained-v2",
    maximumDuration: 20, maximumDiskBytes: 536_870_912, maximumPendingBytes: 67_108_864)
  public let version: String
  public let maximumDuration: Double
  public let maximumDiskBytes: Int
  public let maximumPendingBytes: Int

  public init(
    version: String, maximumDuration: Double, maximumDiskBytes: Int,
    maximumPendingBytes: Int
  ) {
    self.version = version
    self.maximumDuration = maximumDuration
    self.maximumDiskBytes = maximumDiskBytes
    self.maximumPendingBytes = maximumPendingBytes
  }
}
