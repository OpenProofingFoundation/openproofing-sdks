import Foundation

/// Versioned engineering policy for depth-based presentation-attack checks; blink supplies
/// expression evidence. These defaults are not population calibration.
/// All distances are metres. The complete policy travels with the observation.
public struct SelfieDepthPolicy: Codable, Sendable, Equatable {
  public let identifier: String
  public let minimumResidualRMS: Double
  public let minimumSamples: Int
  public let nearLimit: Double
  public let farLimit: Double
  public let maximumDepthAge: TimeInterval
  public let samplesPerAxis: Int

  public static let engineeringV1 = Self(
    identifier: "truedepth-plane-2026-10-07-v1", minimumResidualRMS: 0.004,
    minimumSamples: 64, nearLimit: 0.15, farLimit: 1.2,
    maximumDepthAge: 0.25, samplesPerAxis: 16)

  public init(
    identifier: String, minimumResidualRMS: Double, minimumSamples: Int,
    nearLimit: Double, farLimit: Double, maximumDepthAge: TimeInterval, samplesPerAxis: Int
  ) {
    self.identifier = identifier
    self.minimumResidualRMS = minimumResidualRMS
    self.minimumSamples = minimumSamples
    self.nearLimit = nearLimit
    self.farLimit = farLimit
    self.maximumDepthAge = maximumDepthAge
    self.samplesPerAxis = samplesPerAxis
  }

  var isValid: Bool {
    !identifier.isEmpty && minimumResidualRMS.isFinite && minimumResidualRMS > 0
      && minimumSamples >= 3 && nearLimit.isFinite && nearLimit > 0
      && farLimit.isFinite && farLimit > nearLimit
      && maximumDepthAge.isFinite && maximumDepthAge > 0
      && samplesPerAxis > 1 && samplesPerAxis <= 64
  }

  /// Apple reports zero when this frame has no captured depth; the two timestamps may differ.
  /// https://developer.apple.com/documentation/arkit/arframe/captureddepthdatatimestamp
  func fresh(depthTimestamp: TimeInterval, imageTimestamp: TimeInterval) -> Bool {
    let age = imageTimestamp - depthTimestamp
    return isValid && depthTimestamp.isFinite && depthTimestamp > 0
      && age.isFinite && age >= 0 && age <= maximumDepthAge
  }
}

/// Evaluation vocabulary, not an identity or certification claim. Both depth and expression
/// must be live; a planar depth observation takes precedence over a completed blink.
public enum SelfieLivenessAssessment: String, Codable, Sendable {
  case live, flat, insufficientData

  public static func combine(expression: Self, depth: Self) -> Self {
    if depth == .flat { return .flat }
    return expression == .live && depth == .live ? .live : .insufficientData
  }
}

public struct SelfieDepthSample: Sendable, Equatable {
  public let x: Double
  public let y: Double
  public let z: Double
  public init(x: Double, y: Double, z: Double) {
    self.x = x
    self.y = y
    self.z = z
  }
}

/// Measured face-region relief; no pixels or raw depth map escape this value.
public struct SelfieDepthMeasurement: Codable, Sendable, Equatable {
  public let policy: SelfieDepthPolicy
  public let sampleCount: Int
  public let residualRMS: Double?

  public var assessment: SelfieLivenessAssessment {
    guard policy.isValid, sampleCount >= policy.minimumSamples,
      let residualRMS, residualRMS.isFinite, residualRMS >= 0
    else { return .insufficientData }
    return residualRMS >= policy.minimumResidualRMS ? .live : .flat
  }
}

/// Least-squares z = ax + by + c in the paired image’s pixel coordinates. Removes a tilted
/// plane before measuring RMS relief; this is not metric 3D reconstruction.
/// Apple’s depth maps are nonrectilinear:
/// https://developer.apple.com/documentation/avfoundation/avdepthdata
public enum SelfieDepthEvaluator {
  public static func measure(
    samples: [SelfieDepthSample], policy: SelfieDepthPolicy = .engineeringV1
  ) -> SelfieDepthMeasurement {
    let valid = samples.filter {
      $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
        && $0.z >= policy.nearLimit && $0.z <= policy.farLimit
    }
    return .init(
      policy: policy, sampleCount: valid.count,
      residualRMS: policy.isValid && valid.count >= policy.minimumSamples ? residual(valid) : nil)
  }

  // Centering and Double accumulation avoid cancellation when the face sits far from the
  // map origin while solving the least-squares plane.
  static func residual(_ samples: [SelfieDepthSample]) -> Double? {
    guard samples.count >= 3 else { return nil }
    let count = Double(samples.count)
    let mx = samples.reduce(0) { $0 + $1.x } / count
    let my = samples.reduce(0) { $0 + $1.y } / count
    let mz = samples.reduce(0) { $0 + $1.z } / count
    var xx = 0.0
    var yy = 0.0
    var xy = 0.0
    var xz = 0.0
    var yz = 0.0
    for point in samples {
      let x = point.x - mx
      let y = point.y - my
      let z = point.z - mz
      xx += x * x
      yy += y * y
      xy += x * y
      xz += x * z
      yz += y * z
    }
    let determinant = xx * yy - xy * xy
    guard determinant.isFinite, determinant > Double.ulpOfOne * xx * yy else { return nil }
    let a = (xz * yy - yz * xy) / determinant
    let b = (yz * xx - xz * xy) / determinant
    let sum = samples.reduce(0.0) { total, point in
      let delta = point.z - mz - a * (point.x - mx) - b * (point.y - my)
      return total + delta * delta
    }
    let rms = sqrt(sum / count)
    return rms.isFinite ? rms : nil
  }
}

/// Depth provenance bound to the exact oriented PNG used for comparison. The original map is
/// transient; hosts may retain these observations with the encoded image under their own custody contract.
/// Hash linkage is integrity evidence, not a sensor signature or a claim of certified PAD.
public struct SelfieDepthEvidence: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let measurement: SelfieDepthMeasurement
  public let imageTimestamp: TimeInterval
  public let depthTimestamp: TimeInterval
  public let orientation: UInt32
  public let mapWidth: Int
  public let mapHeight: Int
  /// Apple may temporally smooth/fill samples. Unfiltered missing values are NaN and excluded.
  /// Filtered depth is refused by this engineering capture policy: smoothing and hole filling can manufacture or
  /// erase relief, so a filtered map assesses as `insufficientData` whatever it measured.
  /// https://developer.apple.com/documentation/avfoundation/avdepthdata/isdepthdatafiltered
  public let filtered: Bool
  public var ageAtAdmission: TimeInterval
  public var imageSHA256: String

  public var assessment: SelfieLivenessAssessment {
    guard schemaVersion == 1, !filtered, mapWidth > 0, mapHeight > 0,
      [1, 3, 6, 8].contains(orientation),
      measurement.policy.fresh(depthTimestamp: depthTimestamp, imageTimestamp: imageTimestamp),
      ageAtAdmission.isFinite, ageAtAdmission >= imageTimestamp - depthTimestamp,
      ageAtAdmission <= measurement.policy.maximumDepthAge
    else { return .insufficientData }
    return measurement.assessment
  }
}

extension SelfieAdmissionReceipt {
  /// Legacy blink-only receipts decode unchanged, but supply no depth evidence for a new match.
  public func depthAssessment(imageSHA256: String) -> SelfieLivenessAssessment {
    guard let depthEvidence, let frameEvidence,
      depthEvidence.imageTimestamp == frameTimestamp,
      depthEvidence.orientation == frameEvidence.orientation,
      depthEvidence.imageSHA256 == imageSHA256, !imageSHA256.isEmpty,
      depthEvidence.ageAtAdmission == frameEvidence.frameAgeAtAdmission
        + frameTimestamp - depthEvidence.depthTimestamp
    else { return .insufficientData }
    return .combine(expression: admissionValid ? .live : .insufficientData, depth: depthEvidence.assessment)
  }
}
