import Foundation

/// Bounded native request provenance. It contains no error description, userInfo or image content.
public struct DocumentGeometryRequestFact: Codable, Equatable, Sendable {
  public enum Stage: String, Codable, CaseIterable, Sendable {
    case rectangleTracking, documentSegmentation, rectangleDetection

    var method: String {
      switch self {
      case .rectangleTracking: "VNTrackRectangleRequest"
      case .documentSegmentation: "VNDetectDocumentSegmentationRequest"
      case .rectangleDetection: "VNDetectRectanglesRequest"
      }
    }

    var maximumObservations: Int { self == .rectangleDetection ? 16 : 1 }
  }

  public enum Result: String, Codable, Sendable {
    case accepted, rejected, noObservation, failed
  }

  public struct Failure: Codable, Equatable, Sendable {
    public let domain: String
    public let code: Int
    public let domainWasTruncated: Bool

    init(_ error: NSError) {
      var bytes = Array(error.domain.utf8.prefix(128))
      while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
      domain = String(bytes: bytes, encoding: .utf8) ?? ""
      code = error.code
      domainWasTruncated = bytes.count < error.domain.utf8.count
    }

    var valid: Bool { domain.utf8.count <= 128 }
  }

  public let stage: Stage
  public let requestRevision: Int
  public let result: Result
  public let observationCount: Int?
  public let error: Failure?

  var valid: Bool {
    guard requestRevision > 0 else { return false }
    if result == .failed { return observationCount == nil && error?.valid == true }
    guard error == nil, let observationCount,
      (0...stage.maximumObservations).contains(observationCount)
    else { return false }
    return result == .noObservation ? observationCount == 0 : observationCount > 0
  }

  static func completed(
    _ stage: Stage, revision: Int, count: Int, accepted: Bool
  ) -> Self {
    .init(
      stage: stage, requestRevision: revision,
      result: accepted ? .accepted : (count == 0 ? .noObservation : .rejected),
      observationCount: count, error: nil)
  }

  static func failed(_ stage: Stage, revision: Int, error: Error) -> Self {
    .init(
      stage: stage, requestRevision: revision, result: .failed,
      observationCount: nil, error: .init(error as NSError))
  }
}

extension DocumentLiveGeometryObservation {
  var requestFactsAreValid: Bool {
    guard let requestFacts else { return true }
    guard requestFacts.count <= 3, requestFacts.allSatisfy(\.valid) else { return false }
    let order = requestFacts.compactMap {
      DocumentGeometryRequestFact.Stage.allCases.firstIndex(of: $0.stage)
    }
    guard zip(order, order.dropFirst()).allSatisfy({ $0 < $1 }),
      requestFacts.dropLast().allSatisfy({ $0.result != .accepted })
    else { return false }
    guard let last = requestFacts.last else {
      return availability == .guideUnavailable && requestRevision == nil
        && tracker.trackingOutcome == .notAttempted
    }
    guard availability != .guideUnavailable, requestRevision == last.requestRevision,
      (availability == .observed) == (last.result == .accepted)
    else { return false }
    if availability == .observed {
      guard geometry.method == last.stage.method else { return false }
    } else {
      guard last.stage == .rectangleDetection,
        (availability == .analysisFailed) == (last.result == .failed)
      else { return false }
    }
    let tracking = requestFacts.first { $0.stage == .rectangleTracking }
    switch tracker.trackingOutcome {
    case .notAttempted: return tracking == nil
    case .accepted: return tracking?.result == .accepted
    case .rejected: return tracking?.result == .rejected || tracking?.result == .noObservation
    case .failed: return tracking?.result == .failed
    }
  }
}
