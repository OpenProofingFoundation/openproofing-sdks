import Foundation
import XCTest
@testable import BiometricSDK

final class SharedEmbeddingVectorsTests: XCTestCase {
    private func number(_ value: Any) throws -> Double {
        if let value = value as? NSNumber { return value.doubleValue }
        switch value as? String {
        case "nan": return .nan
        case "positive_infinity": return .infinity
        case "negative_infinity": return -.infinity
        default: throw PrimitiveFailure.invalidSpace
        }
    }
    private func space(_ fields: [String: Any]) throws -> EmbeddingSpace {
        try EmbeddingSpace(artifactManifest: ArtifactDigest(hex: XCTUnwrap(fields["artifactManifestSHA256"] as? String)),
            domain: XCTUnwrap(EmbeddingDomain(rawValue: XCTUnwrap(fields["domain"] as? String))),
            dimensions: XCTUnwrap(fields["dimensions"] as? Int), minimumNorm: number(XCTUnwrap(fields["minimumNorm"])))
    }
    func testSharedNumericalAndFailureVectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("contracts/embedding-math-v1.vectors.json"))) as? [String: Any])
        let base = try XCTUnwrap(fixture["baseSpace"] as? [String: Any])
        let vectors = try XCTUnwrap(fixture["vectors"] as? [[String: Any]])
        let absolute = try number(XCTUnwrap(fixture["absoluteTolerance"]))
        let relative = try number(XCTUnwrap(fixture["normRelativeTolerance"]))
        XCTAssertEqual(vectors.count, 30)
        for vector in vectors {
            let id = try XCTUnwrap(vector["id"] as? String)
            let expected = try XCTUnwrap(vector["expect"] as? [String: Any])
            do {
                let fields = base.merging(vector["spaceOverrides"] as? [String: Any] ?? [:]) { _, new in new }
                let leftSpace = try space(fields)
                let left = try EmbeddingMath.normalize(RawFeatureVector(components:
                    XCTUnwrap(vector["leftFeatures"] as? [Any]).map { Float(try number($0)) }), in: leftSpace)
                if vector["operation"] as? String == "compare" {
                    let rightSpace = try space(fields.merging(vector["rightSpaceOverrides"] as? [String: Any] ?? [:]) { _, new in new })
                    let right = try EmbeddingMath.normalize(RawFeatureVector(components:
                        XCTUnwrap(vector["rightFeatures"] as? [Any]).map { Float(try number($0)) }), in: rightSpace)
                    let score = try EmbeddingMath.compare(left, right)
                    XCTAssertEqual(score.value, try number(XCTUnwrap(expected["cosine"])), accuracy: absolute, id)
                    XCTAssertEqual(score.angularDistanceRadians, try number(XCTUnwrap(expected["angularDistanceRadians"])), accuracy: absolute, id)
                } else {
                    let norm = try number(XCTUnwrap(expected["norm"]))
                    XCTAssertLessThanOrEqual(abs(left.rawFeatureNorm - norm), abs(norm) * relative, id)
                    let components = try XCTUnwrap(expected["components"] as? [Any]).map { try number($0) }
                    XCTAssertEqual(left.components.count, components.count, id)
                    for (actual, wanted) in zip(left.components, components) { XCTAssertEqual(actual, wanted, accuracy: absolute, id) }
                }
                XCTAssertNil(expected["failure"], id)
            } catch let failure as PrimitiveFailure {
                XCTAssertEqual(failure.rawValue, expected["failure"] as? String, id)
            }
        }
    }
}
