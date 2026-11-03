#if os(iOS)
  import DocumentCaptureJournal
  import Foundation
  import DocumentCaptureApple

  public enum DocumentPresencePolicyError: Error, Equatable, Sendable {
    /// An empty name or attribution, or a value that is not a finite positive number.
    case invalidValue
  }

  /// The document presence check (S-02; RFC-0002 §4.5 live capture/document presence). When a host
  /// configures one, tilt guidance runs on every two-sided front without being asked and the temporal
  /// window is retained around the still. Under `.enforce`, the default, the still is admitted only
  /// after that guidance completes. Under `.observe` the same guidance runs and is recorded, but the
  /// still is never refused on it: capture-now and skip stay available, and an exhausted reserve
  /// releases capture instead of stopping it.
  ///
  /// Every value is the host's, named and attributed (boundary contract Rule 4). The SDK ships no
  /// instance: owner decision 13 (9 October 2026) has tilt and capture timing measured on a device
  /// before any value is set, and none has been measured yet. Without a policy capture is unchanged.
  public struct DocumentPresencePolicy: Codable, Equatable, Sendable {
    /// Whether the tilt step gates the front still or is only observed and recorded.
    public enum Enforcement: String, Codable, Equatable, Sendable {
      /// Tilt runs and is recorded; the still is never refused on it.
      case observe
      /// The still is taken only after tilt guidance completes (S-02's gate).
      case enforce
    }

    /// Recorded with every capture this policy admitted.
    public let identifier: String
    /// Whose measurement set these values: the device, the date and who measured.
    public let attribution: String
    /// Tilt guidance starts, and keeps running, only while the journey recording has more than this
    /// much disk and time left. It must fit inside the recording policy, or guidance never starts.
    public let tiltReserveBytes: Int
    public let tiltReserveSeconds: Double
    /// The temporal window retained around the still.
    public let windowBeforeStillSeconds: Double
    public let windowAfterStillSeconds: Double
    public let windowMaximumBytes: Int
    /// `.enforce` unless the host asks only to observe, with `observed()`.
    public private(set) var enforcement = Enforcement.enforce

    /// An enforced policy, as S-02 built it.
    public init(
      identifier: String, attribution: String, tiltReserveBytes: Int, tiltReserveSeconds: Double,
      windowBeforeStillSeconds: Double, windowAfterStillSeconds: Double, windowMaximumBytes: Int
    ) throws {
      let durations = [tiltReserveSeconds, windowBeforeStillSeconds, windowAfterStillSeconds]
      guard !identifier.isEmpty, !attribution.isEmpty, tiltReserveBytes > 0, windowMaximumBytes > 0,
        durations.allSatisfy({ $0.isFinite && $0 > 0 })
      else { throw DocumentPresencePolicyError.invalidValue }
      self.identifier = identifier
      self.attribution = attribution
      self.tiltReserveBytes = tiltReserveBytes
      self.tiltReserveSeconds = tiltReserveSeconds
      self.windowBeforeStillSeconds = windowBeforeStillSeconds
      self.windowAfterStillSeconds = windowAfterStillSeconds
      self.windowMaximumBytes = windowMaximumBytes
    }

    /// The same policy, observed rather than enforced: tilt runs and is recorded, and the still is
    /// never refused on it.
    public func observed() -> Self {
      var policy = self
      policy.enforcement = .observe
      return policy
    }

    private enum CodingKeys: String, CodingKey {
      case identifier, attribution, tiltReserveBytes, tiltReserveSeconds, windowBeforeStillSeconds
      case windowAfterStillSeconds, windowMaximumBytes, enforcement
    }

    /// A policy encoded before `enforcement` existed was enforced.
    public init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(
        identifier: values.decode(String.self, forKey: .identifier),
        attribution: values.decode(String.self, forKey: .attribution),
        tiltReserveBytes: values.decode(Int.self, forKey: .tiltReserveBytes),
        tiltReserveSeconds: values.decode(Double.self, forKey: .tiltReserveSeconds),
        windowBeforeStillSeconds: values.decode(Double.self, forKey: .windowBeforeStillSeconds),
        windowAfterStillSeconds: values.decode(Double.self, forKey: .windowAfterStillSeconds),
        windowMaximumBytes: values.decode(Int.self, forKey: .windowMaximumBytes))
      enforcement = try values.decodeIfPresent(Enforcement.self, forKey: .enforcement) ?? .enforce
    }

    /// The tilt budget this policy names, in place of the fixed `provisionalV1` reserve.
    var tiltBudget: CaptureTiltBudgetPolicy {
      .init(version: identifier, coreReserveBytes: tiltReserveBytes, coreReserveSeconds: tiltReserveSeconds)
    }

    /// The temporal window this policy names, enabled. Frame, motion and diagnostic caps keep the
    /// capture stack's own bounds.
    var temporalWindow: DocumentTemporalConfiguration {
      .init(
        enabled: true, preCaptureDuration: windowBeforeStillSeconds,
        postCaptureDuration: windowAfterStillSeconds, maximumBytes: windowMaximumBytes)
    }
  }

  /// The presence policy that applied to a still, and whether it gated it. Under `.enforce` its tilt
  /// guidance completed before the still was taken; under `.observe` tilt was observed, not required,
  /// and the tilt guidance itself is in the journey recording. Either way the temporal window was
  /// requested around the still.
  public struct CaptureDocumentPresenceRecord: Codable, Equatable, Sendable {
    public let policyIdentifier: String
    public let attribution: String
    public let enforcement: DocumentPresencePolicy.Enforcement

    init(
      policyIdentifier: String, attribution: String,
      enforcement: DocumentPresencePolicy.Enforcement = .enforce
    ) {
      self.policyIdentifier = policyIdentifier
      self.attribution = attribution
      self.enforcement = enforcement
    }

    private enum CodingKeys: String, CodingKey { case policyIdentifier, attribution, enforcement }

    /// Records written before observe mode existed were all enforced.
    public init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      policyIdentifier = try values.decode(String.self, forKey: .policyIdentifier)
      attribution = try values.decode(String.self, forKey: .attribution)
      enforcement = try values.decodeIfPresent(DocumentPresencePolicy.Enforcement.self, forKey: .enforcement)
        ?? .enforce
    }
  }

  extension CaptureSession {
    /// A presence policy applies to two-sided fronts; backs and single-page documents are not tilted.
    var presenceApplies: Bool {
      configuration.documentPresence != nil && profile.twoSided && !profile.backSide
    }

    /// The policy applies and enforces: the still waits for completed tilt guidance.
    var presenceGatesCapture: Bool {
      presenceApplies && configuration.documentPresence?.enforcement == .enforce
    }

    /// The policy that applied to the still now being taken, or nil when none did.
    var presenceRecord: CaptureDocumentPresenceRecord? {
      guard presenceApplies, let policy = configuration.documentPresence else { return nil }
      return .init(
        policyIdentifier: policy.identifier, attribution: policy.attribution,
        enforcement: policy.enforcement)
    }

    /// The camera's capture configuration: the presence policy's temporal window when one is
    /// configured, otherwise the window stays off as before.
    static func captureConfiguration(livePDF417: Bool, presence: DocumentPresencePolicy?)
      -> DocumentCaptureConfiguration
    {
      .init(livePDF417: livePDF417, temporalEvidence: presence?.temporalWindow ?? .init(enabled: false))
    }
  }
#endif
