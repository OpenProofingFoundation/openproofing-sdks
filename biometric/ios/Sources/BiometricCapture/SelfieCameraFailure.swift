import Foundation

/// Camera availability only; no biometric data or framework userInfo is retained.
public struct SelfieCameraFailure: Codable, Equatable, Sendable {
  public enum Reason: String, Codable, Sendable {
    case unavailable, frameworkFailure, sensorInputFailed, noFrames
    case cameraPermissionDenied, cameraPermissionRestricted, invalidConfiguration
    case analysisFailed, analysisTimedOut, renderingFailed, renderingTimedOut
    case depthUnavailable, frameSnapshotFailed
    case captureWindowEmpty, captureWindowResourceLimit
  }
  public struct FrameworkError: Codable, Equatable, Sendable {
    public let domain: String
    public let code: Int
  }

  public let underlyingErrors: [FrameworkError]?
  public let reason: Reason
  public let domain: String?
  public let code: Int?

  public init(
    reason: Reason, domain: String? = nil, code: Int? = nil,
    underlyingErrors: [FrameworkError]? = nil
  ) {
    self.underlyingErrors = underlyingErrors
    self.reason = reason
    self.domain = domain
    self.code = code
  }

  public static func analysis(_ error: NSError) -> Self {
    sanitized(error, reason: .analysisFailed)
  }

  public static func framework(_ error: NSError) -> Self {
    sanitized(
      error,
      reason: error.domain == "com.apple.arkit.error" && error.code == 102
        ? .sensorInputFailed : .frameworkFailure)
  }

  private static func sanitized(_ error: NSError, reason: Reason) -> Self {
    var chain: [FrameworkError] = []
    var visited: Set<ObjectIdentifier> = [ObjectIdentifier(error)]
    var next = error.userInfo[NSUnderlyingErrorKey] as? NSError
    while let underlying = next, chain.count < 4,
      visited.insert(ObjectIdentifier(underlying)).inserted
    {
      chain.append(.init(domain: underlying.domain, code: underlying.code))
      next = underlying.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return .init(
      reason: reason,
      domain: error.domain, code: error.code, underlyingErrors: chain.isEmpty ? nil : chain)
  }

}
