/// A face comparison observation under its declared model and policy.
/// This outcome alone does not establish document authenticity or identity acceptance.
public enum FaceComparisonOutcome: String, Codable, CaseIterable, Sendable {
    case pass
    case manualReview = "manual_review"
    case fail
    case unavailable
}
