import Foundation

public struct EmpiricalDistribution: Equatable, Sendable {
    public let count: Int
    public let rootMeanSquare: Double
    public let median: Double
    public let p95: Double
    public let maximum: Double

    public init?(values: [Double]) {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        let sorted = values.sorted()
        count = sorted.count
        rootMeanSquare = sqrt(sorted.reduce(0) { $0 + ($1 * $1) } / Double(sorted.count))
        median = Self.r7Quantile(0.5, sorted: sorted)
        p95 = Self.r7Quantile(0.95, sorted: sorted)
        maximum = sorted[sorted.count - 1]
    }

    /// Hyndman-Fan type 7, matching the default quantile definition in R.
    private static func r7Quantile(_ probability: Double, sorted: [Double]) -> Double {
        guard sorted.count > 1 else { return sorted[0] }
        let position = Double(sorted.count - 1) * probability
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + ((sorted[upper] - sorted[lower]) * fraction)
    }
}
