import Foundation
import CryptoKit
import BiometricSDK
import AuraFaceNative
import CoreGraphics
import ImageIO
import Vision

public enum FaceInferenceFailure: String, Error, Sendable {
    case invalidImage = "invalid_image"
    case resourceLimit = "resource_limit"
    case sourceMismatch = "source_mismatch"
    case faceMissing = "face_missing"
    case multipleFaces = "multiple_faces"
    case landmarksUnavailable = "landmarks_unavailable"
    case modelUnavailable = "model_unavailable"
    case alignmentFailed = "alignment_failed"
    case inferenceFailed = "inference_failed"
}

/// Observations only; a cosine is neither a probability nor an identity verdict.
public struct FaceSimilarityObservation: Sendable {
    public let referenceSHA256: String
    public let selfieSHA256: String
    public let referenceAlignedSHA256: String
    public let selfieAlignedSHA256: String
    public let artifactManifestSHA256: String
    public let alignmentRoute: String
    public let similarity: CosineSimilarity
}

/// Exact source and alignment facts only. The manifest names the intended
/// embedding profile; preflight neither loads that model nor creates an embedding.
public struct FaceImagePreflightObservation: Sendable {
    public let sourceSHA256: String
    public let alignedSHA256: String
    public let artifactManifestSHA256: String
    public let alignmentRoute: String
    public let width: Int
    public let height: Int
    fileprivate let preparedFace: PreparedFace
}

/// Owned value snapshot; neither caller buffers nor Vision objects escape preparation.
fileprivate struct PreparedFace: Sendable {
    let rgb: [UInt8]
    let width: Int
    let height: Int
    let points: [Double]
}

/// Fixed graph dimensions and engineering decoder ceilings, not population calibration.
private struct AuraFaceProfile {
    static let manifest = "9db36f239a89adfa6794f616f7face61f5ba1b0ca0c7f26b93a6204001856347"
    static let route = "apple-vision-revision3-five-point-cpp-bilinear-v1"
    let maximumEncodedBytes: Int
    let maximumDimension: Int
    let maximumPixels: Int
    let dimensions: Int
    let minimumNorm: Double
    static let v1 = Self(maximumEncodedBytes: 33_554_432, maximumDimension: 4096,
                         maximumPixels: 8_388_608, dimensions: 512, minimumNorm: 1e-12)
}

/// Actor confines the synchronous native session. Publication/cancellation is fenced
/// by the host operation as well: cancellation cannot interrupt an ORT kernel.
public actor AuraFaceComparison {
    private let modelURL: URL
    private var native: NativeAuraSession?

    public init(modelURL: URL) { self.modelURL = modelURL }

    /// Runs the same decoder, Vision landmarks and C++ raster alignment as compare,
    /// without a reference portrait, model access or embedding inference.
    public func preflight(image: Data, sourceSHA256: String) async throws -> FaceImagePreflightObservation {
        try Task.checkCancellation()
        let prepared = try Self.prepare(image, expectedDigest: sourceSHA256)
        try Task.checkCancellation()
        var alignedDigest = [CChar](repeating: 0, count: 65)
        let result = prepared.rgb.withUnsafeBufferPointer { rgb in
            prepared.points.withUnsafeBufferPointer { points in
                face_aura_preflight(rgb.baseAddress, rgb.count, UInt32(prepared.width),
                                    UInt32(prepared.height), points.baseAddress, &alignedDigest)
            }
        }
        try Task.checkCancellation()
        guard result == 0 else { throw FaceInferenceFailure.alignmentFailed }
        let digest = String(decoding: alignedDigest.prefix(64).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return FaceImagePreflightObservation(sourceSHA256: sourceSHA256, alignedSHA256: digest,
            artifactManifestSHA256: AuraFaceProfile.manifest, alignmentRoute: AuraFaceProfile.route,
            width: prepared.width, height: prepared.height, preparedFace: prepared)
    }

    public func compare(reference: Data, referenceSHA256: String,
                        selfie: Data, selfieSHA256: String) throws -> FaceSimilarityObservation {
        try Task.checkCancellation()
        let left = try Self.prepare(reference, expectedDigest: referenceSHA256)
        try Task.checkCancellation()
        let right = try Self.prepare(selfie, expectedDigest: selfieSHA256)
        try Task.checkCancellation()
        return try comparePrepared(reference: left, referenceSHA256: referenceSHA256,
            selfie: right, selfieSHA256: selfieSHA256, expectedAlignedDigest: nil)
    }

    /// Uses the exact owned selfie pixels and geometry assessed by preflight.
    /// No second Vision request may silently change the selected face/alignment.
    public func compare(reference: Data, referenceSHA256: String,
                        preparedSelfie: FaceImagePreflightObservation) throws -> FaceSimilarityObservation {
        try Task.checkCancellation()
        let left = try Self.prepare(reference, expectedDigest: referenceSHA256)
        try Task.checkCancellation()
        return try comparePrepared(reference: left, referenceSHA256: referenceSHA256,
            selfie: preparedSelfie.preparedFace, selfieSHA256: preparedSelfie.sourceSHA256,
            expectedAlignedDigest: preparedSelfie.alignedSHA256)
    }

    private func comparePrepared(reference left: PreparedFace, referenceSHA256: String,
                                 selfie right: PreparedFace, selfieSHA256: String,
                                 expectedAlignedDigest: String?) throws -> FaceSimilarityObservation {
        if native == nil {
            guard modelURL.isFileURL else { throw FaceInferenceFailure.modelUnavailable }
            do { native = try NativeAuraSession(model: Data(contentsOf: modelURL, options: .mappedIfSafe)) }
            catch { throw FaceInferenceFailure.modelUnavailable }
        }
        guard let native else { throw FaceInferenceFailure.modelUnavailable }
        let first = try native.embed(left)
        try Task.checkCancellation()
        let second = try native.embed(right)
        try Task.checkCancellation()
        if let expectedAlignedDigest, second.digest != expectedAlignedDigest {
            throw FaceInferenceFailure.alignmentFailed
        }
        let space = try EmbeddingSpace(artifactManifest: ArtifactDigest(hex: AuraFaceProfile.manifest),
            domain: .faceIdentity, dimensions: AuraFaceProfile.v1.dimensions, minimumNorm: AuraFaceProfile.v1.minimumNorm)
        let similarity = try EmbeddingMath.compare(
            EmbeddingMath.normalize(RawFeatureVector(components: first.features), in: space),
            EmbeddingMath.normalize(RawFeatureVector(components: second.features), in: space))
        return FaceSimilarityObservation(referenceSHA256: referenceSHA256, selfieSHA256: selfieSHA256,
            referenceAlignedSHA256: first.digest, selfieAlignedSHA256: second.digest,
            artifactManifestSHA256: AuraFaceProfile.manifest, alignmentRoute: AuraFaceProfile.route,
            similarity: similarity)
    }


    private static func prepare(_ data: Data, expectedDigest: String) throws -> PreparedFace {
        guard !data.isEmpty, data.count <= AuraFaceProfile.v1.maximumEncodedBytes else {
            throw FaceInferenceFailure.resourceLimit
        }
        // Own before hashing and decoding; a bridged mutable NSData must not alter
        // ImageIO input after source admission.
        let owned = Data(Array(data))
        let digest = SHA256.hash(data: owned).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedDigest else { throw FaceInferenceFailure.sourceMismatch }
        guard let source = CGImageSourceCreateWithData(owned as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        else { throw FaceInferenceFailure.invalidImage }
        guard width <= AuraFaceProfile.v1.maximumDimension, height <= AuraFaceProfile.v1.maximumDimension,
            width <= AuraFaceProfile.v1.maximumPixels / height else { throw FaceInferenceFailure.resourceLimit }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCache: false] as CFDictionary), image.width == width, image.height == height,
            let color = CGColorSpace(name: CGColorSpace.sRGB) else { throw FaceInferenceFailure.invalidImage }
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) }
        catch { throw FaceInferenceFailure.landmarksUnavailable }
        guard let faces = request.results, !faces.isEmpty else { throw FaceInferenceFailure.faceMissing }
        guard faces.count == 1, let face = faces.first else { throw FaceInferenceFailure.multipleFaces }
        let points = try landmarkPoints(face, width: width, height: height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: color,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw FaceInferenceFailure.invalidImage }
        var rgb = [UInt8]()
        rgb.reserveCapacity(width * height * 3)
        for offset in stride(from: 0, to: rgba.count, by: 4) { rgb.append(contentsOf: rgba[offset..<(offset + 3)]) }
        return PreparedFace(rgb: rgb, width: width, height: height, points: points)
    }

    private static func landmarkPoints(_ face: VNFaceObservation, width: Int, height: Int) throws -> [Double] {
        guard let marks = face.landmarks else { throw FaceInferenceFailure.landmarksUnavailable }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.normalizedPoints.map { p in
                CGPoint(x: (face.boundingBox.minX + CGFloat(p.x) * face.boundingBox.width) * CGFloat(width),
                        y: (1 - face.boundingBox.minY - CGFloat(p.y) * face.boundingBox.height) * CGFloat(height))
            }
        }
        func centre(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            let values = points(region)
            guard !values.isEmpty else { return nil }
            return CGPoint(x: values.reduce(0) { $0 + $1.x } / CGFloat(values.count),
                           y: values.reduce(0) { $0 + $1.y } / CGFloat(values.count))
        }
        guard let eyeA = centre(marks.leftPupil) ?? centre(marks.leftEye),
              let eyeB = centre(marks.rightPupil) ?? centre(marks.rightEye) else {
            throw FaceInferenceFailure.landmarksUnavailable
        }
        let eyes = [eyeA, eyeB].sorted { $0.x < $1.x }
        let middle = CGPoint(x: (eyeA.x + eyeB.x) / 2, y: (eyeA.y + eyeB.y) / 2)
        let nose = points(marks.noseCrest).max {
            hypot($0.x - middle.x, $0.y - middle.y) < hypot($1.x - middle.x, $1.y - middle.y)
        }
        let mouth = points(marks.outerLips)
        guard let nose, let left = mouth.min(by: { $0.x < $1.x }),
              let right = mouth.max(by: { $0.x < $1.x }) else { throw FaceInferenceFailure.landmarksUnavailable }
        let selected = [eyes[0], eyes[1], nose, left, right]
        guard selected.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 &&
            $0.x <= CGFloat(width) && $0.y <= CGFloat(height) }) else { throw FaceInferenceFailure.landmarksUnavailable }
        return selected.flatMap { [Double($0.x), Double($0.y)] }
    }

    // Sendability is limited to ownership: this private wrapper never escapes its
    // actor. Session itself serializes ORT access and owns the verified model copy.
    private final class NativeAuraSession: @unchecked Sendable {
        private let pointer: UnsafeMutableRawPointer
        init(model: Data) throws {
            guard let created = model.withUnsafeBytes({ bytes in
                face_aura_create(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }) else { throw FaceInferenceFailure.modelUnavailable }
            pointer = created
        }
        deinit { face_aura_destroy(pointer) }
        func embed(_ face: PreparedFace) throws -> (features: [Float], digest: String) {
            var features = [Float](repeating: 0, count: AuraFaceProfile.v1.dimensions)
            var digest = [CChar](repeating: 0, count: 65)
            let result = face.rgb.withUnsafeBufferPointer { rgb in
                face.points.withUnsafeBufferPointer { points in
                    face_aura_embed(pointer, rgb.baseAddress, rgb.count, UInt32(face.width), UInt32(face.height),
                                       points.baseAddress, &features, &digest)
                }
            }
            guard result == 0 else {
                throw result == 1 ? FaceInferenceFailure.alignmentFailed : FaceInferenceFailure.inferenceFailed
            }
            return (features, String(decoding: digest.prefix(64).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
}
