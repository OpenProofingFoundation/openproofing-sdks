package com.kenshikilabs.biometric

import java.util.Properties
import kotlin.math.abs
import org.junit.Assert.*
import org.junit.Test

class SharedEmbeddingVectorsTest {
    private fun number(value: String): Double = when (value) {
        "nan" -> Double.NaN
        "positive_infinity" -> Double.POSITIVE_INFINITY
        "negative_infinity" -> Double.NEGATIVE_INFINITY
        else -> value.toDouble()
    }
    @Test fun sharedNumericalAndFailureVectors() {
        val fixture = Properties().apply {
            requireNotNull(SharedEmbeddingVectorsTest::class.java.getResourceAsStream("/portrait-vectors.properties")).use { load(it) }
        }
        fun fields(prefix: String): Map<String, String> = fixture.stringPropertyNames()
            .filter { it.startsWith(prefix) }.associate { it.removePrefix(prefix) to fixture.getProperty(it) }
        fun space(value: Map<String, String>) = EmbeddingSpace(ArtifactDigest(value.getValue("artifactManifestSHA256")),
            EmbeddingDomain.entries.single { it.wireValue == value.getValue("domain") },
            value.getValue("dimensions").toInt(), number(value.getValue("minimumNorm")))
        fun features(prefix: String) = FloatArray(fixture.getProperty(prefix + ".count").toInt()) {
            number(fixture.getProperty("$prefix.$it")).toFloat()
        }
        val base = fields("math.baseSpace.")
        val absolute = fixture.getProperty("math.absoluteTolerance").toDouble()
        val relative = fixture.getProperty("math.normRelativeTolerance").toDouble()
        val count = fixture.getProperty("math.vectors.count").toInt()
        assertEquals(30, count)
        repeat(count) { index ->
            val prefix = "math.vectors.$index."
            val id = fixture.getProperty(prefix + "id")
            val expected = fields(prefix + "expect.")
            try {
                val leftFields = base + fields(prefix + "spaceOverrides.")
                val left = EmbeddingMath.normalize(RawFeatureVector(features(prefix + "leftFeatures")), space(leftFields))
                if (fixture.getProperty(prefix + "operation") == "compare") {
                    val right = EmbeddingMath.normalize(RawFeatureVector(features(prefix + "rightFeatures")),
                        space(leftFields + fields(prefix + "rightSpaceOverrides.")))
                    val score = EmbeddingMath.compare(left, right)
                    assertEquals(id, number(expected.getValue("cosine")), score.value, absolute)
                    assertEquals(id, number(expected.getValue("angularDistanceRadians")), score.angularDistanceRadians, absolute)
                } else {
                    val norm = number(expected.getValue("norm"))
                    assertTrue(id, abs(left.rawFeatureNorm - norm) <= abs(norm) * relative)
                    val components = left.components()
                    assertEquals(id, expected.getValue("components.count").toInt(), components.size)
                    components.forEachIndexed { position, actual ->
                        assertEquals(id, number(expected.getValue("components.$position")), actual, absolute)
                    }
                }
                assertNull(id, expected["failure"])
            } catch (error: PrimitiveException) {
                assertEquals(id, expected["failure"], error.reason.wireValue)
            }
        }
    }
}
