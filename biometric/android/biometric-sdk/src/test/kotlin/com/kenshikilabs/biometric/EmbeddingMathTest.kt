package com.kenshikilabs.biometric

import org.junit.Assert.*
import org.junit.Test

class EmbeddingMathTest {
    private fun space(domain: EmbeddingDomain = EmbeddingDomain.FACE_IDENTITY, digest: String = "a".repeat(64), dimensions: Int = 2, floor: Double = 0.01) =
        EmbeddingSpace(ArtifactDigest(digest), domain, dimensions, floor)

    private fun embedding(values: FloatArray, space: EmbeddingSpace) = EmbeddingMath.normalize(RawFeatureVector(values), space)

    private fun rejects(reason: PrimitiveFailure? = null, block: () -> Unit) {
        try { block(); fail("Expected a typed primitive failure") }
        catch (error: PrimitiveException) { if (reason != null) assertEquals(reason, error.reason) }
    }

    @Test fun knownNormAndOrthogonalPair() {
        val contract = space()
        val a = embedding(floatArrayOf(3f, 4f), contract)
        val b = embedding(floatArrayOf(4f, -3f), contract)
        assertEquals(5.0, a.rawFeatureNorm, 0.0)
        assertEquals(0.6, a.components()[0], 1e-12)
        assertEquals(0.8, a.components()[1], 1e-12)
        val score = EmbeddingMath.compare(a, b)
        assertEquals(0.0, score.value, 1e-12)
        assertEquals(Math.PI / 2, score.angularDistanceRadians, 1e-12)
    }

    @Test fun parallelAndOppositeVectorsStayInDomain() {
        val contract = space(); val a = embedding(floatArrayOf(3f, 4f), contract)
        assertEquals(1.0, EmbeddingMath.compare(a, embedding(floatArrayOf(6f, 8f), contract)).value, 1e-12)
        val opposite = EmbeddingMath.compare(a, embedding(floatArrayOf(-3f, -4f), contract))
        assertEquals(-1.0, opposite.value, 1e-12)
        assertEquals(Math.PI, opposite.angularDistanceRadians, 1e-12)
    }

    @Test fun invalidFeaturesAreErrorsRatherThanLowSimilarity() {
        val contract = space()
        for (values in listOf(floatArrayOf(), floatArrayOf(1f), floatArrayOf(1f, 2f, 3f), floatArrayOf(Float.NaN, 1f), floatArrayOf(Float.POSITIVE_INFINITY, 1f), floatArrayOf(0f, 0f))) {
            rejects { embedding(values, contract) }
        }
    }

    @Test fun normFloorIsExplicitAndInclusive() {
        val contract = space(floor = 5.0)
        embedding(floatArrayOf(3f, 4f), contract)
        rejects(PrimitiveFailure.INVALID_NORM) { embedding(floatArrayOf(1f, 1f), contract) }
    }

    @Test fun differentModelOrDomainCannotBeCompared() {
        val a = embedding(floatArrayOf(3f, 4f), space())
        for (contract in listOf(space(domain = EmbeddingDomain.DOCUMENT_REVISION), space(digest = "b".repeat(64)), space(floor = 0.02))) {
            rejects(PrimitiveFailure.INCOMPATIBLE_SPACE) { EmbeddingMath.compare(a, embedding(floatArrayOf(3f, 4f), contract)) }
        }
    }

    @Test fun promotedAccumulationHandlesFiniteFP32Extremes() {
        val contract = space(floor = Float.MIN_VALUE.toDouble() / 2)
        val small = embedding(floatArrayOf(Float.MIN_VALUE, 0f), contract)
        val large = embedding(floatArrayOf(Float.MAX_VALUE, 0f), contract)
        assertEquals(1.0, EmbeddingMath.compare(small, large).value, 0.0)
        assertTrue(small.rawFeatureNorm > 0)
        assertTrue(large.rawFeatureNorm.isFinite())
    }

    @Test fun invalidManifestAndContractAreRejected() {
        for (value in listOf("", "A".repeat(64), "g".repeat(64), "a".repeat(63))) {
            rejects(PrimitiveFailure.INVALID_DIGEST) { ArtifactDigest(value) }
        }
        rejects(PrimitiveFailure.INVALID_SPACE) { space(dimensions = 0) }
        for (floor in listOf(0.0, -1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            rejects(PrimitiveFailure.INVALID_SPACE) { space(floor = floor) }
        }
    }

    @Test fun callerArrayMutationCannotCorruptAdmittedVectors() {
        val input = floatArrayOf(3f, 4f); val raw = RawFeatureVector(input)
        input[0] = Float.NaN
        val unit = EmbeddingMath.normalize(raw, space())
        val exposed = unit.components(); exposed[0] = Double.NaN
        assertEquals(0.6, unit.components()[0], 1e-12)
    }
}
