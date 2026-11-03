import XCTest
@testable import BiometricSDK

final class EmbeddingMathTests: XCTestCase {
    func space(domain: EmbeddingDomain = .faceIdentity, digest: String = String(repeating: "a", count: 64), dimensions: Int = 2, floor: Double = 0.01) throws -> EmbeddingSpace {
        try EmbeddingSpace(artifactManifest: ArtifactDigest(hex: digest), domain: domain, dimensions: dimensions, minimumNorm: floor)
    }

    func embedding(_ values: [Float], in space: EmbeddingSpace) throws -> UnitEmbedding {
        try EmbeddingMath.normalize(RawFeatureVector(components: values), in: space)
    }

    func testKnownNormAndOrthogonalPair() throws {
        let contract = try space()
        let a = try embedding([3, 4], in: contract)
        let b = try embedding([4, -3], in: contract)
        XCTAssertEqual(a.rawFeatureNorm, 5)
        XCTAssertEqual(a.components[0], 0.6, accuracy: 1e-12)
        XCTAssertEqual(a.components[1], 0.8, accuracy: 1e-12)
        let score = try EmbeddingMath.compare(a, b)
        XCTAssertEqual(score.value, 0, accuracy: 1e-12)
        XCTAssertEqual(score.angularDistanceRadians, Double.pi / 2, accuracy: 1e-12)
    }

    func testParallelAndOppositeVectorsStayInDomain() throws {
        let contract = try space()
        let a = try embedding([3, 4], in: contract)
        XCTAssertEqual(try EmbeddingMath.compare(a, embedding([6, 8], in: contract)).value, 1, accuracy: 1e-12)
        let opposite = try EmbeddingMath.compare(a, embedding([-3, -4], in: contract))
        XCTAssertEqual(opposite.value, -1, accuracy: 1e-12)
        XCTAssertEqual(opposite.angularDistanceRadians, Double.pi, accuracy: 1e-12)
    }

    func testInvalidFeaturesAreErrorsRatherThanLowSimilarity() throws {
        let contract = try space()
        for values: [Float] in [[], [1], [1, 2, 3], [.nan, 1], [.infinity, 1], [0, 0]] {
            XCTAssertThrowsError(try embedding(values, in: contract))
        }
    }

    func testNormFloorIsExplicitAndInclusive() throws {
        let contract = try space(floor: 5)
        XCTAssertNoThrow(try embedding([3, 4], in: contract))
        XCTAssertThrowsError(try embedding([1, 1], in: contract)) { XCTAssertEqual($0 as? PrimitiveFailure, .invalidNorm) }
    }

    func testDifferentModelOrDomainCannotBeCompared() throws {
        let a = try embedding([3, 4], in: space())
        for contract in [try space(domain: .documentRevision), try space(digest: String(repeating: "b", count: 64)), try space(floor: 0.02)] {
            XCTAssertThrowsError(try EmbeddingMath.compare(a, embedding([3, 4], in: contract))) {
                XCTAssertEqual($0 as? PrimitiveFailure, .incompatibleSpace)
            }
        }
    }

    func testPromotedAccumulationHandlesFiniteFP32Extremes() throws {
        let tiny = Float.leastNonzeroMagnitude
        let contract = try space(floor: Double(tiny) / 2)
        let small = try embedding([tiny, 0], in: contract)
        let large = try embedding([Float.greatestFiniteMagnitude, 0], in: contract)
        XCTAssertEqual(try EmbeddingMath.compare(small, large).value, 1)
        XCTAssertTrue(small.rawFeatureNorm > 0)
        XCTAssertTrue(large.rawFeatureNorm.isFinite)
    }

    func testInvalidManifestIdentityAndAdmissionContractAreRejected() throws {
        for value in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            XCTAssertThrowsError(try ArtifactDigest(hex: value))
        }
        XCTAssertThrowsError(try space(dimensions: 0))
        for floor in [0.0, -1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try space(floor: floor))
        }
    }
}
