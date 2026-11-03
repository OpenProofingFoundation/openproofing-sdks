package com.kenshikilabs.biometric

import kotlin.math.acos
import kotlin.math.sqrt

enum class PrimitiveFailure(val wireValue: String) {
    INVALID_DIGEST("invalid_digest"),
    INVALID_SPACE("invalid_space"),
    DIMENSION_MISMATCH("dimension_mismatch"),
    NONFINITE_FEATURE("nonfinite_feature"),
    INVALID_NORM("invalid_norm"),
    INCOMPATIBLE_SPACE("incompatible_space")
}

class PrimitiveException(val reason: PrimitiveFailure) : IllegalArgumentException()

enum class EmbeddingDomain(val wireValue: String) {
    FACE_IDENTITY("face_identity"),
    DOCUMENT_REVISION("document_revision")
}

data class ArtifactDigest(val hex: String) {
    init {
        if (hex.length != 64 || !hex.all { it in '0'..'9' || it in 'a'..'f' }) {
            throw PrimitiveException(PrimitiveFailure.INVALID_DIGEST)
        }
    }
}

data class EmbeddingSpace(
    val artifactManifest: ArtifactDigest,
    val domain: EmbeddingDomain,
    val dimensions: Int,
    val minimumNorm: Double
) {
    init {
        if (dimensions <= 0 || !minimumNorm.isFinite() || minimumNorm <= 0.0) {
            throw PrimitiveException(PrimitiveFailure.INVALID_SPACE)
        }
    }
}

class RawFeatureVector(components: FloatArray) {
    private val values = components.copyOf()
    fun components(): FloatArray = values.copyOf()
}

class UnitEmbedding private constructor(
    val space: EmbeddingSpace,
    val rawFeatureNorm: Double,
    components: DoubleArray
) {
    private val values = components.copyOf()
    fun components(): DoubleArray = values.copyOf()

    companion object {
        internal fun normalized(raw: RawFeatureVector, space: EmbeddingSpace): UnitEmbedding {
            val components = raw.components()
            if (components.size != space.dimensions) {
                throw PrimitiveException(PrimitiveFailure.DIMENSION_MISMATCH)
            }
            if (!components.all { it.isFinite() }) {
                throw PrimitiveException(PrimitiveFailure.NONFINITE_FEATURE)
            }
            val squaredNorm = components.fold(0.0) { sum, value ->
                val promoted = value.toDouble()
                sum + promoted * promoted
            }
            val norm = sqrt(squaredNorm)
            if (!norm.isFinite() || norm <= 0.0 || norm < space.minimumNorm) {
                throw PrimitiveException(PrimitiveFailure.INVALID_NORM)
            }
            return UnitEmbedding(space, norm, DoubleArray(components.size) { components[it].toDouble() / norm })
        }
    }
}

class CosineSimilarity private constructor(val value: Double, val space: EmbeddingSpace) {
    val angularDistanceRadians: Double get() = acos(value)

    companion object {
        internal fun compare(left: UnitEmbedding, right: UnitEmbedding): CosineSimilarity {
            if (left.space != right.space) {
                throw PrimitiveException(PrimitiveFailure.INCOMPATIBLE_SPACE)
            }
            val a = left.components(); val b = right.components()
            val dot = a.indices.fold(0.0) { sum, index -> sum + a[index] * b[index] }
            return CosineSimilarity(dot.coerceIn(-1.0, 1.0), left.space)
        }
    }
}

object EmbeddingMath {
    fun normalize(raw: RawFeatureVector, space: EmbeddingSpace): UnitEmbedding = UnitEmbedding.normalized(raw, space)
    fun compare(left: UnitEmbedding, right: UnitEmbedding): CosineSimilarity = CosineSimilarity.compare(left, right)
}
