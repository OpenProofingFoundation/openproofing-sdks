import Foundation

/// A native request failed to execute; this is not a negative document observation.
/// Error descriptions and userInfo are excluded because they can contain input content.
public struct DocumentPhotoAnalysisFailure: Codable, Equatable, Sendable {
  public enum Stage: String, Codable, Sendable {
    case textRecognition, barcodeDetection
  }

  public let stage: Stage
  public let requestRevision: Int
  public let domain: String
  public let code: Int
  public let domainWasTruncated: Bool

  init(stage: Stage, requestRevision: Int, error: Error) {
    let native = error as NSError
    var bytes = Array(native.domain.utf8.prefix(128))
    while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
    self.stage = stage
    self.requestRevision = requestRevision
    domain = String(bytes: bytes, encoding: .utf8) ?? ""
    code = native.code
    domainWasTruncated = bytes.count < native.domain.utf8.count
  }
}
