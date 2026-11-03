package com.kenshikilabs.biometric

import java.util.Properties
import org.junit.Assert.*
import org.junit.Test

class PortraitContractTest {
    private fun fixture(): Properties = Properties().apply {
        requireNotNull(PortraitContractTest::class.java.getResourceAsStream("/portrait-vectors.properties")).use { load(it) }
    }
    private fun fields(fixture: Properties, prefix: String): Map<String, Any?> = fixture.stringPropertyNames()
        .filter { it.startsWith(prefix) }.associate { key ->
            val tagged = fixture.getProperty(key)
            val content = tagged.substring(2)
            val value: Any? = when (tagged.take(2)) {
                "s:" -> content
                "i:" -> content.toLong()
                "f:" -> content.toDouble()
                "j:" -> java.math.BigInteger(content)
                "b:" -> content.toBoolean()
                "n:" -> null
                else -> listOf<Any>()
            }
            key.removePrefix(prefix) to value
        }
    private fun bytes(hex: String): ByteArray = hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun allSharedVectorsExecuteNativeContracts() {
        val fixture = fixture()
        val pixels = fields(fixture, "pixel.")
        val binding = fields(fixture, "binding.")
        val count = fixture.getProperty("count").toInt()
        assertTrue(count >= 188)
        repeat(count) { index ->
            val prefix = "vector.$index."
            val kind = fixture.getProperty(prefix + "kind")
            val selected = (if (kind == "pixels") pixels else binding).toMutableMap()
            selected.putAll(fields(fixture, prefix + "override."))
            fixture.getProperty(prefix + "removeFields").split(',').filter { it.isNotEmpty() }.forEach { selected.remove(it) }
            val actual = try {
                if (kind == "pixels") {
                    PortraitPixels.fromFields(selected, bytes(fixture.getProperty(prefix + "payloadHex", fixture.getProperty("payloadHex"))))
                } else {
                    PortraitBinding.fromFields(binding).requireMatches(PortraitBinding.fromFields(selected))
                }
                "valid"
            } catch (error: PortraitException) { error.reason.wireValue }
            assertEquals(fixture.getProperty(prefix + "id"), fixture.getProperty(prefix + "expect"), actual)
        }
    }
    @Test fun ownedSnapshotSurvivesCallerAndReturnedArrayMutation() {
        val fixture = fixture()
        val fields = fields(fixture, "pixel.")
        val source = bytes(fixture.getProperty("payloadHex"))
        val owned = PortraitPixels.fromFields(fields, source)
        source[0] = 127
        val exposed = owned.bytes(); exposed[1] = 127
        assertArrayEquals(ByteArray(12) { it.toByte() }, owned.bytes())
        try { PortraitPixels.fromFields(fields, source); fail("Substitution accepted") }
        catch (error: PortraitException) { assertEquals(PortraitFailure.INTEGRITY_FAILURE, error.reason) }
    }
    @Test fun fixtureProjectionPreservesOutOfRangeIntegerLiterals() {
        val fixture = fixture()
        val count = fixture.getProperty("count").toInt()
        for ((id, exact) in listOf("width-above-signed64" to "9223372036854775808",
                                   "width-unsigned64-positive-wrap" to "18446744073709551618")) {
            val vectorIndex = (0 until count).single {
                fixture.getProperty("vector.$it.id") == id
            }
            val value = fields(fixture, "vector.$vectorIndex.override.").getValue("width")
            assertEquals(id, java.math.BigInteger(exact), value)
        }
    }
    @Test fun wireIntegerIngressRejectsBeyondSigned64WithoutNarrowing() {
        val fixture = fixture()
        val base = fields(fixture, "pixel.")
        val payload = bytes(fixture.getProperty("payloadHex"))
        for (value in listOf(java.math.BigInteger("9223372036854775808"),
                              java.math.BigInteger("18446744073709551615"))) {
            try { PortraitPixels.fromFields(base + ("width" to value), payload); fail("Unsigned narrowing accepted") }
            catch (error: PortraitException) { assertEquals(PortraitFailure.INVALID_PIXELS, error.reason) }
        }
        try { PortraitPixels.fromFields(base + ("width" to Long.MAX_VALUE), payload); fail("Oversize accepted") }
        catch (error: PortraitException) { assertEquals(PortraitFailure.RESOURCE_LIMIT, error.reason) }
    }
    @Test fun extremeMetadataCannotOverflowOrTriggerAllocation() {
        val fixture = fixture()
        val selected = fields(fixture, "pixel.").toMutableMap()
        selected["width"] = Long.MAX_VALUE; selected["height"] = Long.MAX_VALUE
        try { PortraitPixels.fromFields(selected, byteArrayOf()); fail("Overflow accepted") }
        catch (error: PortraitException) { assertEquals(PortraitFailure.RESOURCE_LIMIT, error.reason) }
    }
    @Test fun observationsRejectForeignModelAndDocumentDomain() {
        val fixture = fixture()
        val binding = PortraitBinding.fromFields(fields(fixture, "binding."))
        for ((domain, digest) in listOf(EmbeddingDomain.FACE_IDENTITY to "c".repeat(64),
                                       EmbeddingDomain.DOCUMENT_REVISION to "b".repeat(64))) {
            val space = EmbeddingSpace(ArtifactDigest(digest), domain, 2, 0.01)
            val feature = EmbeddingMath.normalize(RawFeatureVector(floatArrayOf(3f, 4f)), space)
            val score = EmbeddingMath.compare(feature, feature)
            try { BoundComparisonObservation(binding, score); fail("Foreign model/domain accepted") }
            catch (error: PortraitException) { assertEquals(PortraitFailure.BINDING_MISMATCH, error.reason) }
        }
        val space = EmbeddingSpace(ArtifactDigest("b".repeat(64)), EmbeddingDomain.FACE_IDENTITY, 2, 0.01)
        val feature = EmbeddingMath.normalize(RawFeatureVector(floatArrayOf(3f, 4f)), space)
        BoundComparisonObservation(binding, EmbeddingMath.compare(feature, feature))
    }
}
