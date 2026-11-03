import Foundation
import CryptoKit

/// Compatibility constants and hashing for already committed records, not a prompt or runtime.
enum LiquidReviewProfile {
    static let maximumOutputBytes = 16384
    static let motionMinimumSamples = 2
    static let motionMaximumSamples = 300
    static let motionMaximumDuration = 5.000001
    static let motionSampleRate = 50.0
    static let motionMaximumFrameGap = 0.2
    static let clockTolerance = 0.000001
}
enum LiquidPromptContract {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
