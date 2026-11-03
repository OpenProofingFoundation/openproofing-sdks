import Foundation

public enum VisualFaceAssessment: String, Codable, Sendable {
    case consistent
    case inconsistent
    case uncertain
}

public enum VisualFaceQualityIssue: String, Codable, Sendable {
    case blur
    case poorLighting = "poor_lighting"
    case occlusion
    case pose
    case lowResolution = "low_resolution"
    case other
}

public enum VisualFaceAssessmentFailure: String, Error, Sendable {
    case invalidImage = "invalid_image"
    case resourceLimit = "resource_limit"
    case sourceMismatch = "source_mismatch"
    case modelUnavailable = "model_unavailable"
    case modelMismatch = "model_mismatch"
    case runtimeUnavailable = "runtime_unavailable"
    case invalidOutput = "invalid_output"
    case assessmentInProgress = "assessment_in_progress"
}

/// A model observation bound to exact original inputs. No identity decision or calibrated probability.
public struct VisualFaceAssessmentObservation: Sendable {
    public let referenceSHA256: String
    public let selfieSHA256: String
    public let artifactSHA256: String
    public let profileID: String
    public let assessment: VisualFaceAssessment
    public let qualityIssues: [VisualFaceQualityIssue]
    public let durationMilliseconds: Double
}

/// Frozen limits for validating previously stored evidence; never generation settings.
enum LiquidProfile {
    static let weightsSHA256 = "bf86cc6b16e4f6a870336d5e0ebad0c5cf1d63214efef8efeb8b9655174b3913"
    static let maximumEncodedBytes = 33_554_432
    static let maximumDimension = 4096
    static let maximumPixels = 8_388_608
}
