import Foundation

public enum PrimitiveFailure: String, Error, Sendable {
    case invalidDigest = "invalid_digest"
    case invalidSpace = "invalid_space"
    case dimensionMismatch = "dimension_mismatch"
    case nonfiniteFeature = "nonfinite_feature"
    case invalidNorm = "invalid_norm"
    case incompatibleSpace = "incompatible_space"
}

public enum EmbeddingDomain: String, Sendable {
    case faceIdentity = "face_identity"
    case documentRevision = "document_revision"
}

/// Identifies the immutable manifest, including model and preprocessing identity.
public struct ArtifactDigest: Sendable, Equatable, Hashable {
    public let hex: String

    public init(hex: String) throws {
        guard hex.utf8.count == 64,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw PrimitiveFailure.invalidDigest }
        self.hex = hex
    }
}

/// All numerical admission parameters are explicit; there is no recognition threshold here.
public struct EmbeddingSpace: Sendable, Equatable {
    public let artifactManifest: ArtifactDigest
    public let domain: EmbeddingDomain
    public let dimensions: Int
    public let minimumNorm: Double

    public init(artifactManifest: ArtifactDigest, domain: EmbeddingDomain,
                dimensions: Int, minimumNorm: Double) throws {
        guard dimensions > 0, minimumNorm.isFinite, minimumNorm > 0
        else { throw PrimitiveFailure.invalidSpace }
        self.artifactManifest = artifactManifest
        self.domain = domain
        self.dimensions = dimensions
        self.minimumNorm = minimumNorm
    }
}

/// Unadmitted model output. No serialization or logging representation is supplied.
public struct RawFeatureVector: Sendable {
    public let components: [Float]

    public init(components: [Float]) {
        self.components = components
    }
}

/// Constructible only by numerical admission and normalization.
public struct UnitEmbedding: Sendable {
    public let space: EmbeddingSpace
    public let rawFeatureNorm: Double
    public let components: [Double]

    fileprivate init(space: EmbeddingSpace, rawFeatureNorm: Double, components: [Double]) {
        self.space = space
        self.rawFeatureNorm = rawFeatureNorm
        self.components = components
    }
}

/// A mathematical observation; no probability, quality band or acceptance policy.
public struct CosineSimilarity: Sendable {
    public let value: Double
    public let space: EmbeddingSpace
    public var angularDistanceRadians: Double { acos(value) }

    fileprivate init(value: Double, space: EmbeddingSpace) {
        self.value = value
        self.space = space
    }
}

public enum EmbeddingMath {
    /// FP32 model features, FP64 norm/coordinates/accumulation; floor equality is admitted.
    public static func normalize(_ raw: RawFeatureVector, in space: EmbeddingSpace) throws -> UnitEmbedding {
        guard raw.components.count == space.dimensions
        else { throw PrimitiveFailure.dimensionMismatch }
        guard raw.components.allSatisfy(\.isFinite)
        else { throw PrimitiveFailure.nonfiniteFeature }
        let squaredNorm = raw.components.reduce(0.0) { sum, value in
            let promoted = Double(value)
            return sum + promoted * promoted
        }
        let norm = sqrt(squaredNorm)
        guard norm.isFinite, norm > 0, norm >= space.minimumNorm
        else { throw PrimitiveFailure.invalidNorm }
        return UnitEmbedding(space: space, rawFeatureNorm: norm,
                             components: raw.components.map { Double($0) / norm })
    }

    public static func compare(_ left: UnitEmbedding, _ right: UnitEmbedding) throws -> CosineSimilarity {
        guard left.space == right.space else { throw PrimitiveFailure.incompatibleSpace }
        let dot = zip(left.components, right.components).reduce(0.0) { $0 + $1.0 * $1.1 }
        return CosineSimilarity(value: min(1, max(-1, dot)), space: left.space)
    }
}
