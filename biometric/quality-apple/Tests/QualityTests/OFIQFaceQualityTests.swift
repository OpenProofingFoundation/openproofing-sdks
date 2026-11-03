import XCTest
import Foundation
import CryptoKit
import BiometricSDK
import OFIQNative
@testable import BiometricQuality

final class OFIQFaceQualityTests: XCTestCase {
    func testNonFileAssetDirectoryRefusedBeforeNativeInitialization() {
        XCTAssertThrowsError(try OFIQFaceQuality(assetDirectory: URL(string: "https://example.invalid/quality")!)) {
            XCTAssertEqual($0 as? FaceQualityFailure, .invalidAssets)
        }
    }
    func testMissingManifestIsTypedAndDoesNotCreateAssets() throws {
        let directory = temporaryDirectory()
        XCTAssertThrowsError(try OFIQFaceQuality(assetDirectory: directory)) {
            XCTAssertEqual($0 as? FaceQualityFailure, .missingAsset)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testChangedOrEmptyManifestNeverReachesModelInitialization() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for data in [Data(), Data("{\"files\":[]}".utf8)] {
            try data.write(to: directory.appendingPathComponent("quality-profile.json"))
            XCTAssertThrowsError(try OFIQFaceQuality(assetDirectory: directory)) {
                XCTAssertEqual($0 as? FaceQualityFailure, .artifactIntegrity)
            }
        }
    }
    func testOversizedManifestHasIndependentReadBound() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0, count: 65_537).write(to: directory.appendingPathComponent("quality-profile.json"))
        XCTAssertThrowsError(try OFIQFaceQuality(assetDirectory: directory)) {
            XCTAssertEqual($0 as? FaceQualityFailure, .invalidAssets)
        }
    }
    func testManifestSymlinkCannotEscapeSuppliedDirectory() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("untrusted.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("quality-profile.json"), withDestinationURL: target)
        XCTAssertThrowsError(try OFIQFaceQuality(assetDirectory: directory)) {
            XCTAssertEqual($0 as? FaceQualityFailure, .missingAsset)
        }
    }
    func testComponentConversionRetainsFailedCodesAndFiniteSentinels() throws {
        var result = canonicalNativeResult()
        withUnsafeMutableBytes(of: &result.components) { bytes in
            let components = bytes.bindMemory(to: OFIQNativeComponent.self)
            components[0].code = 1
            components[0].native_value = 0
            components[0].mapped_value = -1
            components[1].code = 2
            components[1].native_value = .nan
            components[1].mapped_value = .infinity
        }
        let components = try OFIQFaceQuality.components(result)
        XCTAssertEqual(components.count, 28)
        XCTAssertEqual(components[0].measure, .unifiedQualityScore)
        XCTAssertEqual(components[0].code, 1)
        XCTAssertEqual(components[0].native, 0)
        XCTAssertEqual(components[0].mapped, -1)
        XCTAssertEqual(components[1].code, 2)
        XCTAssertNil(components[1].native)
        XCTAssertNil(components[1].mapped)
    }
    func testUnknownNativeMeasureCannotProduceAnAssessment() {
        var result = canonicalNativeResult()
        withUnsafeMutableBytes(of: &result.components) { bytes in
            bytes.bindMemory(to: OFIQNativeComponent.self)[0].measure_id = 0x99
        }
        XCTAssertThrowsError(try OFIQFaceQuality.components(result)) {
            XCTAssertEqual($0 as? FaceQualityFailure, .assessmentFailed)
        }
    }
    func testCanonicalIDsAndNamesMatchAll28OFIQComponents() throws {
        let names = ["UnifiedQualityScore", "BackgroundUniformity", "IlluminationUniformity", "LuminanceMean",
            "LuminanceVariance", "UnderExposurePrevention", "OverExposurePrevention", "DynamicRange", "Sharpness",
            "CompressionArtifacts", "NaturalColour", "SingleFacePresent", "EyesOpen", "MouthClosed", "EyesVisible",
            "MouthOcclusionPrevention", "FaceOcclusionPrevention", "InterEyeDistance", "HeadSize", "LeftwardCropOfTheFaceImage",
            "RightwardCropOfTheFaceImage", "MarginAboveOfTheFaceImage", "MarginBelowOfTheFaceImage", "HeadPoseYaw",
            "HeadPosePitch", "HeadPoseRoll", "ExpressionNeutrality", "NoHeadCoverings"]
        let components = try OFIQFaceQuality.components(canonicalNativeResult())
        XCTAssertEqual(components.map(\.measureID), (0x41...0x5c).map(Int32.init))
        XCTAssertEqual(components.map { $0.measure.canonicalName }, names)
        XCTAssertTrue(components.allSatisfy { $0.code == 0 && $0.native == 1.25 && $0.mapped == 50 })
    }
    func testPixelIngressRejectsUnorientedGrayAndInvalidSourceDigests() throws {
        for pixels in [try pixels(width: 1, height: 1, format: "gray8"), try pixels(width: 1, height: 1, orientation: 2)] {
            XCTAssertThrowsError(try OFIQFaceQuality.validatePixels(pixels, sourceSHA256: String(repeating: "a", count: 64))) {
                XCTAssertEqual($0 as? FaceQualityFailure, .invalidPixels)
            }
        }
        let valid = try pixels(width: 1, height: 1)
        for digest in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 63)] {
            XCTAssertThrowsError(try OFIQFaceQuality.validatePixels(valid, sourceSHA256: digest)) {
                XCTAssertEqual($0 as? FaceQualityFailure, .invalidPixels)
            }
        }
    }
    func testPixelIngressResourceCeilingsPrecedeNativeAllocation() throws {
        for pixels in [try pixels(width: 4097, height: 1), try pixels(width: 4096, height: 2049)] {
            XCTAssertThrowsError(try OFIQFaceQuality.validatePixels(pixels, sourceSHA256: String(repeating: "a", count: 64))) {
                XCTAssertEqual($0 as? FaceQualityFailure, .resourceLimit)
            }
        }
        XCTAssertNoThrow(try OFIQFaceQuality.validatePixels(pixels(width: 4096, height: 2048), sourceSHA256: String(repeating: "a", count: 64)))
    }
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ofiq-test-" + UUID().uuidString)
    }
    private func canonicalNativeResult() -> OFIQNativeResult {
        var result = OFIQNativeResult()
        withUnsafeMutableBytes(of: &result.components) { bytes in
            let components = bytes.bindMemory(to: OFIQNativeComponent.self)
            for index in components.indices {
                components[index] = OFIQNativeComponent(measure_id: Int32(0x41 + index), code: 0, native_value: 1.25, mapped_value: 50)
            }
        }
        return result
    }
    private func pixels(width: Int, height: Int, format: String = "rgb8", orientation: Int = 1) throws -> PortraitPixels {
        let channels = format == "gray8" ? 1 : 3
        let bytes = [UInt8](repeating: 0, count: width * height * channels)
        let hash = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        return try PortraitPixels(layout: .init(width: width, height: height, format: format,
            rowStrideBytes: width * channels, byteLength: bytes.count, orientation: orientation), sha256: hash, bytes: bytes)
    }
}
