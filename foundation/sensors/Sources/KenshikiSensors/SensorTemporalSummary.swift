import Foundation

/// Pure temporal evidence derived from already validated, strictly ordered sample times.
///
/// Acquisition paths retain ownership of clock domains, routing, rejection accounting, and
/// provenance. This kernel owns only the shared support, gap, delivered-rate, and quality math.
struct SensorTemporalSummary: Equatable, Sendable {
    let expectedSampleCount: Int
    let temporalCoverageFraction: Double
    let maximumSampleGapSeconds: TimeInterval?
    let leadingGapSeconds: TimeInterval?
    let trailingGapSeconds: TimeInterval?
    let observedMedianSampleHz: Double?
    let acquisitionQuality: SensorWindowAcquisitionQuality

    init(
        orderedTimestamps: [TimeInterval],
        bounds: Range<TimeInterval>,
        specification: SensorWindowSpecification
    ) {
        let expected = specification.expectedSampleCount
        let coverage = Self.temporalCoverage(
            orderedTimestamps: orderedTimestamps,
            bounds: bounds,
            nominalPeriod: specification.nominalPeriod,
            duration: specification.duration)
        let gaps = Self.gaps(orderedTimestamps: orderedTimestamps, bounds: bounds)
        let minimumCount = Int(
            ceil(Double(expected) * specification.qualityPolicy.minimumExpectedCountFraction))
        let maximumAllowedGap =
            specification.nominalPeriod * specification.qualityPolicy.maximumGapPeriods

        expectedSampleCount = expected
        temporalCoverageFraction = coverage
        maximumSampleGapSeconds = gaps.maximum
        leadingGapSeconds = gaps.leading
        trailingGapSeconds = gaps.trailing
        observedMedianSampleHz = Self.observedMedianSampleHz(
            orderedTimestamps: orderedTimestamps)

        if orderedTimestamps.isEmpty {
            acquisitionQuality = .empty
        } else if orderedTimestamps.count >= minimumCount,
            coverage >= specification.qualityPolicy.minimumTemporalCoverageFraction,
            (gaps.maximum ?? .infinity) <= maximumAllowedGap
        {
            acquisitionQuality = .observed
        } else {
            acquisitionQuality = .partial
        }
    }

    private static func temporalCoverage(
        orderedTimestamps: [TimeInterval],
        bounds: Range<TimeInterval>,
        nominalPeriod: TimeInterval,
        duration: TimeInterval
    ) -> Double {
        guard let first = orderedTimestamps.first else { return 0 }
        let halfPeriod = nominalPeriod / 2
        var unionStart = max(bounds.lowerBound, first - halfPeriod)
        var unionEnd = min(bounds.upperBound, first + halfPeriod)
        var covered: TimeInterval = 0

        for timestamp in orderedTimestamps.dropFirst() {
            let cellStart = max(bounds.lowerBound, timestamp - halfPeriod)
            let cellEnd = min(bounds.upperBound, timestamp + halfPeriod)
            if cellStart <= unionEnd {
                unionEnd = max(unionEnd, cellEnd)
            } else {
                covered += max(0, unionEnd - unionStart)
                unionStart = cellStart
                unionEnd = cellEnd
            }
        }
        covered += max(0, unionEnd - unionStart)
        return min(1, max(0, covered / duration))
    }

    private static func gaps(
        orderedTimestamps: [TimeInterval],
        bounds: Range<TimeInterval>
    ) -> (maximum: TimeInterval?, leading: TimeInterval?, trailing: TimeInterval?) {
        guard let first = orderedTimestamps.first, let last = orderedTimestamps.last else {
            return (nil, nil, nil)
        }
        let leading = max(0, first - bounds.lowerBound)
        let trailing = max(0, bounds.upperBound - last)
        var maximum = max(leading, trailing)
        for (lhs, rhs) in zip(orderedTimestamps, orderedTimestamps.dropFirst()) {
            maximum = max(maximum, rhs - lhs)
        }
        return (maximum, leading, trailing)
    }

    private static func observedMedianSampleHz(
        orderedTimestamps: [TimeInterval]
    ) -> Double? {
        let gaps = zip(orderedTimestamps, orderedTimestamps.dropFirst())
            .map { $1 - $0 }
            .filter { $0 > 0 && $0.isFinite }
            .sorted()
        guard !gaps.isEmpty else { return nil }
        let middle = gaps.count / 2
        let median =
            gaps.count.isMultiple(of: 2)
            ? (gaps[middle - 1] + gaps[middle]) / 2
            : gaps[middle]
        return median > 0 ? 1 / median : nil
    }
}
