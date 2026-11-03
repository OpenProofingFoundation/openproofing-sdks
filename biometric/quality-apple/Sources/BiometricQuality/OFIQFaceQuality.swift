import Foundation
import CryptoKit
import BiometricSDK
import OFIQNative

public enum FaceQualityFailure: String, Error, Sendable {
    case missingAsset = "missing_asset"
    case invalidAssets = "invalid_assets"
    case artifactIntegrity = "artifact_integrity"
    case initializationFailed = "initialization_failed"
    case invalidPixels = "invalid_pixels"
    case resourceLimit = "resource_limit"
    case assessmentFailed = "assessment_failed"
    case closed
}

public enum FaceQualityMeasure: Int32, Sendable {
    case unifiedQualityScore = 0x41, backgroundUniformity, illuminationUniformity, luminanceMean
    case luminanceVariance, underExposurePrevention, overExposurePrevention, dynamicRange
    case sharpness, compressionArtifacts, naturalColour, singleFacePresent, eyesOpen, mouthClosed
    case eyesVisible, mouthOcclusionPrevention, faceOcclusionPrevention, interEyeDistance, headSize
    case leftwardCropOfTheFaceImage, rightwardCropOfTheFaceImage, marginAboveOfTheFaceImage
    case marginBelowOfTheFaceImage, headPoseYaw, headPosePitch, headPoseRoll, expressionNeutrality, noHeadCoverings
    public var canonicalName: String {
        Self.names[Int(rawValue - 0x41)]
    }
    private static let names = ["UnifiedQualityScore", "BackgroundUniformity", "IlluminationUniformity", "LuminanceMean",
        "LuminanceVariance", "UnderExposurePrevention", "OverExposurePrevention", "DynamicRange", "Sharpness",
        "CompressionArtifacts", "NaturalColour", "SingleFacePresent", "EyesOpen", "MouthClosed", "EyesVisible",
        "MouthOcclusionPrevention", "FaceOcclusionPrevention", "InterEyeDistance", "HeadSize", "LeftwardCropOfTheFaceImage",
        "RightwardCropOfTheFaceImage", "MarginAboveOfTheFaceImage", "MarginBelowOfTheFaceImage", "HeadPoseYaw",
        "HeadPosePitch", "HeadPoseRoll", "ExpressionNeutrality", "NoHeadCoverings"]
}
public struct FaceQualityComponent: Sendable {
    public let measure: FaceQualityMeasure
    public var measureID: Int32 { measure.rawValue }
    public let code: Int32
    public let native: Double?
    public let mapped: Double?
}
public struct FaceQualityAssessment: Sendable {
    public let sourceSHA256: String
    public let rasterSHA256: String
    public let width: Int
    public let height: Int
    public let artifactManifestSHA256: String
    public let returnCode: Int32
    public let faceCount: Int32
    public let components: [FaceQualityComponent]
}

/// Serialized local OFIQ assessment. The host supplies a read-only profile directory;
/// iOS uses an immutable signed application bundle. The Mac development host must
/// preserve its supplied directory against mutation; before/after hashes detect drift,
/// but do not authenticate an adversarial mutable filesystem or training provenance.
public actor OFIQFaceQuality {
    public static let artifactManifestSHA256 = "154433c5e66cfb80f8bd1fdf91b92c4aa212c6eea3c9ea1624bbca3b4a8e4557"
    private var native: NativeSession?

    public init(assetDirectory: URL) throws {
        guard assetDirectory.isFileURL else { throw FaceQualityFailure.invalidAssets }
        let directory = assetDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let manifest = try Self.readManifest(directory)
        try Self.verifyAssets(manifest, directory: directory)
        let session = try NativeSession(directory: directory)
        try Self.verifyAssets(manifest, directory: directory)
        native = session
    }

    /// The supplied source digest names the encoded producer artifact; the independent
    /// raster digest names exact consumed RGB bytes. This binding is not source attestation.
    public func assess(_ pixels: PortraitPixels, sourceSHA256: String) async throws -> FaceQualityAssessment {
        try Task.checkCancellation()
        guard let native else { throw FaceQualityFailure.closed }
        try Self.validatePixels(pixels, sourceSHA256: sourceSHA256)
        let result = try native.assess(pixels)
        try Task.checkCancellation()
        return FaceQualityAssessment(sourceSHA256: sourceSHA256, rasterSHA256: pixels.sha256,
            width: pixels.width, height: pixels.height, artifactManifestSHA256: Self.artifactManifestSHA256,
            returnCode: result.return_code, faceCount: result.face_count, components: try Self.components(result))
    }

    /// Runs after any synchronous assessment on this actor has settled. No reinitialization
    /// follows closure; hosts create one explicit owner for a later independent attempt.
    public func close() { native = nil }

    static func validatePixels(_ pixels: PortraitPixels, sourceSHA256: String) throws {
        guard sourceSHA256.utf8.count == 64, sourceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            pixels.format == "rgb8", pixels.orientation == 1 else { throw FaceQualityFailure.invalidPixels }
        guard pixels.width <= 4096, pixels.height <= 4096, pixels.width <= 8_388_608 / pixels.height
        else { throw FaceQualityFailure.resourceLimit }
    }

    private struct Manifest: Decodable {
        let configurationFile: String
        let files: [Asset]
    }
    private struct Asset: Decodable {
        let path: String
        let bytes: Int
        let sha256: String
    }
    private static func readManifest(_ directory: URL) throws -> Manifest {
        let url = directory.appendingPathComponent("quality-profile.json")
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
            values.isSymbolicLink == false, values.isRegularFile == true,
            let handle = try? FileHandle(forReadingFrom: url) else { throw FaceQualityFailure.missingAsset }
        defer { try? handle.close() }
        let data: Data
        do { data = try handle.read(upToCount: 65_537) ?? Data() }
        catch { throw FaceQualityFailure.missingAsset }
        guard data.count <= 65_536 else { throw FaceQualityFailure.invalidAssets }
        guard digest(data) == artifactManifestSHA256 else { throw FaceQualityFailure.artifactIntegrity }
        do { return try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw FaceQualityFailure.invalidAssets }
    }
    private static func verifyAssets(_ manifest: Manifest, directory: URL) throws {
        guard manifest.configurationFile == "ofiq_config.jaxn" else { throw FaceQualityFailure.invalidAssets }
        for asset in manifest.files {
            let parts = asset.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), asset.bytes >= 0
            else { throw FaceQualityFailure.invalidAssets }
            var url = directory
            for part in parts {
                url.appendPathComponent(String(part))
                guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == false
                else { throw FaceQualityFailure.missingAsset }
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { throw FaceQualityFailure.missingAsset }
            defer { try? handle.close() }
            var hash = SHA256()
            var count = 0
            while true {
                let chunk: Data
                do { chunk = try handle.read(upToCount: 1_048_576) ?? Data() }
                catch { throw FaceQualityFailure.missingAsset }
                if chunk.isEmpty { break }
                guard count <= asset.bytes - chunk.count else { throw FaceQualityFailure.artifactIntegrity }
                count += chunk.count
                hash.update(data: chunk)
            }
            guard count == asset.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256
            else { throw FaceQualityFailure.artifactIntegrity }
        }
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func components(_ result: OFIQNativeResult) throws -> [FaceQualityComponent] {
        var fields = result.components
        return try withUnsafeBytes(of: &fields) { buffer in
            let values = buffer.bindMemory(to: OFIQNativeComponent.self)
            guard values.count == Int(OFIQ_NATIVE_COMPONENT_COUNT) else { throw FaceQualityFailure.assessmentFailed }
            return try values.map { value in
                guard let measure = FaceQualityMeasure(rawValue: value.measure_id) else { throw FaceQualityFailure.assessmentFailed }
                return FaceQualityComponent(measure: measure, code: value.code,
                    native: value.native_value.isFinite ? value.native_value : nil,
                    mapped: value.mapped_value.isFinite ? value.mapped_value : nil)
            }
        }
    }

    private final class NativeSession: @unchecked Sendable {
        private let pointer: UnsafeMutableRawPointer
        init(directory: URL) throws {
            var failure: Int32 = 0
            let session = directory.path.withCString { ofiq_native_create($0, &failure) }
            guard let session else {
                throw failure == 2 ? FaceQualityFailure.resourceLimit : FaceQualityFailure.initializationFailed
            }
            pointer = session
        }
        deinit { ofiq_native_destroy(pointer) }
        func assess(_ pixels: PortraitPixels) throws -> OFIQNativeResult {
            var result = OFIQNativeResult()
            let rgb = pixels.bytes
            let code = rgb.withUnsafeBufferPointer { buffer in
                ofiq_native_assess(pointer, buffer.baseAddress, buffer.count, UInt32(pixels.width), UInt32(pixels.height), &result)
            }
            guard code == 0 else {
                throw code == 2 ? FaceQualityFailure.resourceLimit : FaceQualityFailure.assessmentFailed
            }
            return result
        }
    }
}
