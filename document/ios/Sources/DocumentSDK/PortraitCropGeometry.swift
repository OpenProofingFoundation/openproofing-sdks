import Foundation

// swiftlint:disable identifier_name
// Rectangles follow the standard x/y coordinate labels.
public struct PortraitNormalizedRect: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// Bounding box is normalized, lower-left, on the already upright analyzed image.
public struct PortraitFaceObservation: Codable, Equatable, Sendable {
  public let boundingBox: PortraitNormalizedRect
  public let confidence: Double

  public init(boundingBox: PortraitNormalizedRect, confidence: Double) {
    self.boundingBox = boundingBox
    self.confidence = confidence
  }
}

/// Integer crop coordinates on the same upright raster, with a top-left origin.
public struct PortraitPixelRect: Codable, Equatable, Sendable {
  public let x: Int
  public let y: Int
  public let width: Int
  public let height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

// swiftlint:enable identifier_name

public struct PortraitCropCandidate: Codable, Equatable, Sendable {
  public enum Role: String, Codable, Sendable { case faceRegion }

  public let faceIndex: Int
  public let confidence: Double
  public let role: Role
  /// Clipped requested bounds; pixelRect is the actual outward-rounded crop.
  public let normalizedTopLeft: PortraitNormalizedRect
  public let pixelRect: PortraitPixelRect
  public let wasClipped: Bool
}

public struct PortraitCropAssessment: Codable, Equatable, Sendable {
  public enum Outcome: String, Codable, Sendable {
    case noFace, provisionalSingleFace, ambiguous, invalidInput
  }

  public let schemaVersion: Int
  public let policyVersion: String
  public let outcome: Outcome
  public let imageWidth: Int
  public let imageHeight: Int
  public let paddingFraction: Double?
  public let candidates: [PortraitCropCandidate]
  public let unselectedFaceIndices: [Int]
  /// Index in candidates, not a statement that this is the entire main photograph.
  public let selectedCandidateIndex: Int?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case policyVersion
    case outcome
    case imageWidth
    case imageHeight
    case paddingFraction
    case candidates
    case unselectedFaceIndices = "rejectedFaceIndices"
    case selectedCandidateIndex
  }
}

/// Vision's normalized lower-left bounds become upright top-left integer crops.
/// Source: Apple's Detecting Objects in Still Images and VNDetectedObjectObservation.boundingBox.
/// The sample's UI transforms/640-pixel resize are not used for extraction.
/// All detections are retained. This policy does not identify printed photo edges,
/// rank faces by size, identify people, or distinguish main and ghost portraits.
public enum PortraitCropPolicy {
  public static func evaluate(
    faces: [PortraitFaceObservation], imageWidth: Int, imageHeight: Int,
    paddingFraction: Double = PortraitCropDefaults.paddingFraction
  ) -> PortraitCropAssessment {
    let validImage = imageWidth > 0 && imageHeight > 0
      && Int(exactly: Double(imageWidth)) == imageWidth
      && Int(exactly: Double(imageHeight)) == imageHeight
      && paddingFraction.isFinite && paddingFraction >= 0
    var candidates: [PortraitCropCandidate] = []
    var rejected: [Int] = []
    for (index, face) in faces.enumerated() {
      if validImage, let candidate = crop(
        face, index: index, imageWidth: imageWidth, imageHeight: imageHeight,
        paddingFraction: paddingFraction) {
        candidates.append(candidate)
      } else {
        rejected.append(index)
      }
    }
    let outcome: PortraitCropAssessment.Outcome
    if !validImage || (!faces.isEmpty && candidates.isEmpty) {
      outcome = .invalidInput
    } else if faces.isEmpty {
      outcome = .noFace
    } else if candidates.count == 1 && rejected.isEmpty && !candidates[0].wasClipped {
      outcome = .provisionalSingleFace
    } else {
      outcome = .ambiguous
    }
    return PortraitCropAssessment(
      schemaVersion: 1, policyVersion: "vision-face-region-v1", outcome: outcome,
      imageWidth: imageWidth, imageHeight: imageHeight,
      paddingFraction: paddingFraction.isFinite ? paddingFraction : nil,
      candidates: candidates, unselectedFaceIndices: rejected,
      selectedCandidateIndex: outcome == .provisionalSingleFace ? 0 : nil)
  }

  private static func crop(
    _ face: PortraitFaceObservation, index: Int, imageWidth: Int, imageHeight: Int,
    paddingFraction: Double
  ) -> PortraitCropCandidate? {
    let box = face.boundingBox
    guard [box.x, box.y, box.width, box.height, face.confidence].allSatisfy(\.isFinite),
      box.width > 0, box.height > 0, (0...1).contains(face.confidence)
    else { return nil }
    let lowX = box.x - box.width * paddingFraction
    let lowY = box.y - box.height * paddingFraction
    let highX = box.x + box.width * (1 + paddingFraction)
    let highY = box.y + box.height * (1 + paddingFraction)
    guard [lowX, lowY, highX, highY].allSatisfy(\.isFinite) else { return nil }
    // Padding has no upper bound: the requested window is clamped to the image here and to
    // pixel bounds below, so a large fraction means "as much surrounding context as this
    // image actually has" and reports wasClipped. The detector needs the face to be a small
    // part of its input; a 0...1 cap could not express that (root-cause investigation,
    // 2026-09-08). Negative and non-finite padding remain invalid.
    let left = max(0, lowX)
    let bottom = max(0, lowY)
    let right = min(1, highX)
    let top = min(1, highY)
    guard right > left, top > bottom else { return nil }
    let pixelLeft = max(0, Int(floor(left * Double(imageWidth))))
    let pixelTop = max(0, Int(floor((1 - top) * Double(imageHeight))))
    let pixelRight = min(imageWidth, Int(ceil(right * Double(imageWidth))))
    let pixelBottom = min(imageHeight, Int(ceil((1 - bottom) * Double(imageHeight))))
    guard pixelRight > pixelLeft, pixelBottom > pixelTop else { return nil }
    return PortraitCropCandidate(
      faceIndex: index, confidence: face.confidence, role: .faceRegion,
      normalizedTopLeft: .init(x: left, y: 1 - top, width: right - left, height: top - bottom),
      pixelRect: .init(
        x: pixelLeft, y: pixelTop, width: pixelRight - pixelLeft, height: pixelBottom - pixelTop),
      wasClipped: left != lowX || bottom != lowY || right != highX || top != highY)
  }
}
