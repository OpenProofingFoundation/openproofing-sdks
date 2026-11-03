import XCTest
@testable import BiometricInference

final class FaceFrameSelectionTests: XCTestCase {
    private typealias Selector = FaceFrameSelection
    private let sourceDigest = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)

    private func configuration(_ policy: Selector.Policy = .highestNativeUQS) -> Selector.Configuration {
        let identity = Selector.Identity(identifier: "test-artifact-v1", sha256: sourceDigest)
        return .init(policy: policy, identities: .init(policy: identity, qualityArtifact: identity, matcherArtifact: identity))
    }
    private func candidate(_ index: UInt32, score: Double = 10) -> Selector.Candidate {
        .init(source: .init(identifier: "frame-\(index)", originalFrameIndex: index, sha256: sourceDigest),
              quality: .init(sourceSHA256: sourceDigest, returnCode: 0, faceCount: 1,
                             score: .init(code: 0, native: score, mapped: 50)),
              matcher: .init(sourceSHA256: sourceDigest, status: .passed, alignedSHA256: other))
    }
    private func selected(_ report: Selector.Report, file: StaticString = #filePath, line: UInt = #line) throws -> Selector.Selection {
        guard case .selected(let selection) = report.outcome else {
            XCTFail("Expected selected source", file: file, line: line)
            throw Selector.Failure.invalidBuffers
        }
        return selection
    }
    func testBothPoliciesUseOriginalIndexAndNativeScoreThroughSharedCore() throws {
        let inputs = [candidate(12, score: 40), candidate(2, score: 30)]
        let first = try Selector.select(inputs, configuration: configuration(.firstEligible))
        let best = try Selector.select(inputs, configuration: configuration())
        XCTAssertEqual(try selected(first).source.originalFrameIndex, 2)
        XCTAssertEqual(try selected(first).inputOffset, 1)
        XCTAssertEqual(try selected(best).source.originalFrameIndex, 12)
        XCTAssertEqual(try selected(best).alignedSHA256, other)
        XCTAssertEqual(best.configuration, configuration())
        XCTAssertTrue(best.candidates.allSatisfy { $0.exclusions.isEmpty })
    }
    func testNativeTieUsesEarliestOriginalIndexRegardlessOfInputOrder() throws {
        for inputs in [[candidate(8), candidate(1)], [candidate(1), candidate(8)]] {
            XCTAssertEqual(try selected(Selector.select(inputs, configuration: configuration())).source.originalFrameIndex, 1)
        }
    }
    func testEmptyAndIneligibleBatchesHaveNoFallback() throws {
        XCTAssertEqual(try Selector.select([], configuration: configuration()).outcome, .noSelection)
        let original = candidate(0)
        let failed = Selector.Candidate(source: original.source, quality: original.quality,
                                       matcher: .init(sourceSHA256: sourceDigest, status: .failed))
        let report = try Selector.select([failed], configuration: configuration())
        XCTAssertEqual(report.outcome, .noSelection)
        XCTAssertEqual(report.candidates[0].exclusions, [.matcherPreparationUnavailable, .alignedUnavailable])
    }
    func testSourceBindingsExcludeSubstitutedAndUnavailableObservations() throws {
        let original = candidate(0)
        let input = Selector.Candidate(source: original.source,
            quality: .init(sourceSHA256: other, returnCode: 0, faceCount: 1, score: original.quality.score),
            matcher: .init(sourceSHA256: nil, status: .passed, alignedSHA256: other))
        let report = try Selector.select([input], configuration: configuration())
        XCTAssertEqual(report.outcome, .noSelection)
        XCTAssertEqual(report.candidates[0].exclusions, [.qualitySourceMismatch, .matcherSourceMismatch])
    }
    func testQualityFailuresRetainEveryExclusion() throws {
        let original = candidate(0)
        let input = Selector.Candidate(source: original.source,
            quality: .init(sourceSHA256: sourceDigest, returnCode: 2, faceCount: 2, score: .init(code: 3, native: .nan, mapped: 101)),
            matcher: original.matcher)
        let report = try Selector.select([input], configuration: configuration())
        XCTAssertEqual(report.outcome, .noSelection)
        XCTAssertEqual(report.candidates[0].exclusions, [.qualityFailed, .faceCount, .uqsFailed, .invalidUQS])
    }
    func testMalformedPresentDigestRejectsBatchRatherThanSilentlyExcluding() {
        let original = candidate(0)
        let input = Selector.Candidate(source: original.source, quality: original.quality,
                                      matcher: .init(sourceSHA256: "bad", status: .failed))
        XCTAssertThrowsError(try Selector.select([candidate(1), input], configuration: configuration())) {
            XCTAssertEqual($0 as? Selector.Failure, .invalidCandidate)
        }
    }
    func testDuplicateIdentityOrIndexRejectsWholeBatchEvenWhenFrameFails() {
        let original = candidate(0)
        let duplicateID = Selector.Candidate(source: .init(identifier: original.source.identifier, originalFrameIndex: 1, sha256: sourceDigest),
                                            quality: original.quality, matcher: .init(sourceSHA256: nil, status: .failed))
        XCTAssertThrowsError(try Selector.select([original, duplicateID], configuration: configuration())) {
            XCTAssertEqual($0 as? Selector.Failure, .duplicateIdentifier)
        }
        let duplicateIndex = Selector.Candidate(source: .init(identifier: "another", originalFrameIndex: 0, sha256: sourceDigest),
                                               quality: original.quality, matcher: original.matcher)
        XCTAssertThrowsError(try Selector.select([original, duplicateIndex], configuration: configuration())) {
            XCTAssertEqual($0 as? Selector.Failure, .duplicateIndex)
        }
    }
    func testIdenticalPixelsWithDistinctFrameIdentitiesArePermitted() throws {
        let report = try Selector.select([candidate(1), candidate(0)], configuration: configuration())
        XCTAssertEqual(try selected(report).source.originalFrameIndex, 0)
    }
    func testResourceBoundaryAccepts32AndRejects33() throws {
        XCTAssertEqual(Selector.maximumCandidates, 32)
        let inputs = (0..<32).map { candidate(UInt32($0)) }
        XCTAssertEqual(try selected(Selector.select(inputs, configuration: configuration())).source.originalFrameIndex, 0)
        XCTAssertThrowsError(try Selector.select(inputs + [candidate(32)], configuration: configuration())) {
            XCTAssertEqual($0 as? Selector.Failure, .tooManyCandidates)
        }
    }
    func testInvalidLineageAndEmbeddedNulNeverTruncateAcrossBridge() {
        let invalid = Selector.Identity(identifier: "invalid\0trailing", sha256: sourceDigest)
        let configuration = Selector.Configuration(policy: .firstEligible,
            identities: .init(policy: invalid, qualityArtifact: invalid, matcherArtifact: invalid))
        XCTAssertThrowsError(try Selector.select([], configuration: configuration)) {
            XCTAssertEqual($0 as? Selector.Failure, .invalidConfiguration)
        }
        let original = candidate(0)
        let input = Selector.Candidate(source: .init(identifier: String(repeating: "x", count: 129), originalFrameIndex: 0, sha256: sourceDigest),
                                       quality: original.quality, matcher: original.matcher)
        XCTAssertThrowsError(try Selector.select([input], configuration: self.configuration())) {
            XCTAssertEqual($0 as? Selector.Failure, .invalidCandidate)
        }
    }
}
