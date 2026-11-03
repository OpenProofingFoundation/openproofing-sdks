import Foundation
import XCTest
@testable import BiometricSDK

final class PortraitContractTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("contracts/portrait-selfie-v1.vectors.json"))) as? [String: Any])
    }
    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
    func testAllSharedVectorsExecuteNativeContracts() throws {
        let fixtures = try fixture()
        let pixel = try XCTUnwrap(fixtures["pixelBase"] as? [String: Any])
        let binding = try XCTUnwrap(fixtures["bindingBase"] as? [String: Any])
        let vectors = try XCTUnwrap(fixtures["vectors"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(vectors.count, 188)
        for vector in vectors {
            let kind = try XCTUnwrap(vector["kind"] as? String)
            var fields = kind == "pixels" ? try XCTUnwrap(pixel["descriptor"] as? [String: Any]) : binding
            fields.merge(vector["overrides"] as? [String: Any] ?? [:]) { _, new in new }
            for name in vector["removeFields"] as? [String] ?? [] { fields.removeValue(forKey: name) }
            var actual = "valid"
            do {
                if kind == "pixels" {
                    let payload = try XCTUnwrap(vector["payloadHex"] as? String ?? pixel["payloadHex"] as? String)
                    _ = try PortraitPixels.fromFields(fields, bytes: bytes(payload))
                } else {
                    try PortraitBinding.fromFields(binding).requireMatches(PortraitBinding.fromFields(fields))
                }
            } catch let reason as PortraitFailure { actual = reason.rawValue }
            XCTAssertEqual(actual, vector["expect"] as? String, vector["id"] as? String ?? "")
        }
    }
    func testDirectLayoutRejectsUntrustedMetadataBeforeDigestValidation() throws {
        let fixtures = try fixture()
        let pixel = try XCTUnwrap(fixtures["pixelBase"] as? [String: Any])
        let fields = try XCTUnwrap(pixel["descriptor"] as? [String: Any])
        let payload = bytes(try XCTUnwrap(pixel["payloadHex"] as? String))
        let width = try XCTUnwrap(fields["width"] as? Int)
        let height = try XCTUnwrap(fields["height"] as? Int)
        let row = try XCTUnwrap(fields["rowStrideBytes"] as? Int)
        let orientation = try XCTUnwrap(fields["orientation"] as? Int)
        let format = try XCTUnwrap(fields["format"] as? String)
        let digest = try XCTUnwrap(fields["sha256"] as? String)
        let valid = PortraitPixels.Layout(width: width, height: height, format: format,
            rowStrideBytes: row, byteLength: payload.count, orientation: orientation)
        XCTAssertEqual(try PortraitPixels(layout: valid, sha256: digest, bytes: payload).bytes, payload)
        let invalid: [(PortraitPixels.Layout, PortraitFailure)] = [
            (.init(width: 0, height: height, format: format, rowStrideBytes: row,
                   byteLength: payload.count, orientation: orientation), .invalidPixels),
            (.init(width: Int.max, height: Int.max, format: format, rowStrideBytes: row,
                   byteLength: payload.count, orientation: orientation), .resourceLimit),
            (.init(width: width, height: height, format: "unknown", rowStrideBytes: row,
                   byteLength: payload.count, orientation: orientation), .unsupportedFormat),
            (.init(width: width, height: height, format: format, rowStrideBytes: row + 1,
                   byteLength: payload.count, orientation: orientation), .invalidPixels),
            (.init(width: width, height: height, format: format, rowStrideBytes: row,
                   byteLength: payload.count + 1, orientation: orientation), .invalidPixels),
            (.init(width: width, height: height, format: format, rowStrideBytes: row,
                   byteLength: payload.count, orientation: 9), .invalidPixels),
        ]
        for (layout, expected) in invalid {
            XCTAssertThrowsError(try PortraitPixels(layout: layout, sha256: "invalid", bytes: payload)) {
                XCTAssertEqual($0 as? PortraitFailure, expected)
            }
        }
        XCTAssertThrowsError(try PortraitPixels(layout: valid, sha256: digest, bytes: [])) {
            XCTAssertEqual($0 as? PortraitFailure, .invalidPixels)
        }
    }
    func testOwnedSnapshotSurvivesCallerAndReturnedArrayMutation() throws {
        let fixtures = try fixture()
        let pixel = try XCTUnwrap(fixtures["pixelBase"] as? [String: Any])
        let fields = try XCTUnwrap(pixel["descriptor"] as? [String: Any])
        var source = bytes(try XCTUnwrap(pixel["payloadHex"] as? String))
        let owned = try PortraitPixels.fromFields(fields, bytes: source)
        source[0] = 255
        var exposed = owned.bytes
        exposed[1] = 255
        XCTAssertEqual(owned.bytes, Array(0...11).map(UInt8.init))
        XCTAssertThrowsError(try PortraitPixels.fromFields(fields, bytes: source)) {
            XCTAssertEqual($0 as? PortraitFailure, .integrityFailure)
        }
    }
    func testWireIntegerIngressRejectsBeyondSigned64WithoutNarrowing() throws {
        let fixtures = try fixture()
        let pixel = try XCTUnwrap(fixtures["pixelBase"] as? [String: Any])
        let descriptor = try XCTUnwrap(pixel["descriptor"] as? [String: Any])
        let payload = bytes(try XCTUnwrap(pixel["payloadHex"] as? String))
        for (numeric, expected) in [("9223372036854775807", PortraitFailure.resourceLimit),
                                     ("9223372036854775808", .invalidPixels),
                                     ("18446744073709551615", .invalidPixels)] {
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(("{\"width\":" + numeric + "}").utf8)) as? [String: Any])
            let fields = descriptor.merging(parsed) { _, new in new }
            XCTAssertThrowsError(try PortraitPixels.fromFields(fields, bytes: payload)) {
                XCTAssertEqual($0 as? PortraitFailure, expected, numeric)
            }
        }
    }
    func testExtremeMetadataCannotOverflowOrTriggerAllocation() throws {
        let fixtures = try fixture()
        let pixel = try XCTUnwrap(fixtures["pixelBase"] as? [String: Any])
        var fields = try XCTUnwrap(pixel["descriptor"] as? [String: Any])
        fields["width"] = Int.max
        fields["height"] = Int.max
        XCTAssertThrowsError(try PortraitPixels.fromFields(fields, bytes: [])) {
            XCTAssertEqual($0 as? PortraitFailure, .resourceLimit)
        }
    }
}

extension PortraitContractTests {
    func testObservationsRejectForeignModelAndDocumentDomain() throws {
        let fixtures = try fixture()
        let binding = try PortraitBinding.fromFields(XCTUnwrap(fixtures["bindingBase"] as? [String: Any]))
        for (domain, digest) in [(EmbeddingDomain.faceIdentity, String(repeating: "c", count: 64)),
                                 (.documentRevision, String(repeating: "b", count: 64))] {
            let space = try EmbeddingSpace(artifactManifest: ArtifactDigest(hex: digest), domain: domain,
                                           dimensions: 2, minimumNorm: 0.01)
            let feature = try EmbeddingMath.normalize(RawFeatureVector(components: [3, 4]), in: space)
            let score = try EmbeddingMath.compare(feature, feature)
            XCTAssertThrowsError(try BoundComparisonObservation(binding: binding, similarity: score)) {
                XCTAssertEqual($0 as? PortraitFailure, .bindingMismatch)
            }
        }
        let space = try EmbeddingSpace(artifactManifest: ArtifactDigest(hex: String(repeating: "b", count: 64)),
                                       domain: .faceIdentity, dimensions: 2, minimumNorm: 0.01)
        let feature = try EmbeddingMath.normalize(RawFeatureVector(components: [3, 4]), in: space)
        XCTAssertNoThrow(try BoundComparisonObservation(binding: binding, similarity: EmbeddingMath.compare(feature, feature)))
    }
}
