package com.kenshikilabs.biometric

import java.security.MessageDigest
import java.util.UUID

enum class PortraitFailure(val wireValue: String) {
    INVALID_SCHEMA("invalid_schema"), INVALID_PIXELS("invalid_pixels"),
    UNSUPPORTED_FORMAT("unsupported_format"), RESOURCE_LIMIT("resource_limit"),
    INTEGRITY_FAILURE("integrity_failure"), BINDING_MISMATCH("binding_mismatch"),
    OPERATION_UNAVAILABLE("operation_unavailable"), OPERATION_REUSED("operation_reused")
}

class PortraitException(val reason: PortraitFailure) : IllegalArgumentException(reason.wireValue)

/** Packed pixels own a defensive snapshot; access never exposes mutable internal storage. */
class PortraitPixels(
    val width: Long, val height: Long, val format: String, val rowStrideBytes: Long,
    byteLength: Long, val orientation: Long, val sha256: String, bytes: ByteArray
) {
    private val snapshot: ByteArray
    init {
        val channels = when (format) {
            "rgb8" -> 3L
            "gray8" -> 1L
            else -> throw PortraitException(PortraitFailure.UNSUPPORTED_FORMAT)
        }
        if (width <= 0 || height <= 0 || rowStrideBytes <= 0 || byteLength <= 0 || orientation !in 1L..8L) {
            throw PortraitException(PortraitFailure.INVALID_PIXELS)
        }
        // Ceilings precede multiplication, allocation and hashing.
        if (width > 16384 || height > 16384 || width > 67108864 / height) {
            throw PortraitException(PortraitFailure.RESOURCE_LIMIT)
        }
        val row = width * channels
        val size = row * height
        if (size > 268435456) throw PortraitException(PortraitFailure.RESOURCE_LIMIT)
        if (rowStrideBytes != row || byteLength != size || bytes.size.toLong() != size) {
            throw PortraitException(PortraitFailure.INVALID_PIXELS)
        }
        if (!isDigest(sha256)) throw PortraitException(PortraitFailure.INVALID_SCHEMA)
        snapshot = bytes.copyOf()
        val digest = MessageDigest.getInstance("SHA-256").digest(snapshot)
        val hex = digest.joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
        if (hex != sha256) throw PortraitException(PortraitFailure.INTEGRITY_FAILURE)
    }
    fun bytes(): ByteArray = snapshot.copyOf()

    companion object {
        private val pixelFields = setOf("width", "height", "format", "rowStrideBytes", "byteLength", "sha256", "orientation")
        internal fun isDigest(value: String): Boolean = value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
        private fun integer(value: Any?): Long {
            val result = when (value) {
                is Long -> value
                is Int -> value.toLong()
                else -> throw PortraitException(PortraitFailure.INVALID_PIXELS)
            }
            if (result <= 0) throw PortraitException(PortraitFailure.INVALID_PIXELS)
            return result
        }
        fun fromFields(fields: Map<String, Any?>, bytes: ByteArray): PortraitPixels {
            if (fields.keys != pixelFields) throw PortraitException(PortraitFailure.INVALID_SCHEMA)
            val format = fields["format"] as? String
            if (format !in setOf("rgb8", "gray8")) throw PortraitException(PortraitFailure.UNSUPPORTED_FORMAT)
            return PortraitPixels(integer(fields["width"]), integer(fields["height"]), format!!,
                integer(fields["rowStrideBytes"]), integer(fields["byteLength"]), integer(fields["orientation"]),
                fields["sha256"] as? String ?: "", bytes)
        }
    }
}

/** Binding integrity does not establish acquisition authenticity or liveness. */
class PortraitBinding(fields: Map<String, String>) {
    private val snapshot: Map<String, String>
    init {
        val owned = fields.toMap()
        if (owned.keys != fieldNames) throw PortraitException(PortraitFailure.INVALID_SCHEMA)
        for ((name, content) in owned) {
            val valid = if (name.endsWith("SHA256")) PortraitPixels.isDigest(content) else {
                try { UUID.fromString(content).toString() == content }
                catch (_: IllegalArgumentException) { false }
            }
            if (!valid) throw PortraitException(PortraitFailure.INVALID_SCHEMA)
        }
        snapshot = owned
    }
    fun fields(): Map<String, String> = snapshot.toMap()
    internal fun value(name: String): String? = snapshot[name]
    fun requireMatches(completion: PortraitBinding) {
        if (snapshot != completion.snapshot) throw PortraitException(PortraitFailure.BINDING_MISMATCH)
    }
    companion object {
        val fieldNames: Set<String> get() = setOf(
            "sessionID", "attemptID", "operationID", "referenceCaptureID", "probeCaptureID",
            "referenceArtifactID", "probeArtifactID", "referenceSourceSHA256", "probeSourceSHA256",
            "referenceSHA256", "probeSHA256", "referenceLineageSHA256", "probeLineageSHA256",
            "artifactManifestSHA256", "preprocessingManifestSHA256")
        fun fromFields(fields: Map<String, Any?>): PortraitBinding {
            val strings = fields.mapValues { (_, value) -> value as? String ?: throw PortraitException(PortraitFailure.INVALID_SCHEMA) }
            return PortraitBinding(strings)
        }
    }
}

class ComparisonRequest(val binding: PortraitBinding, val reference: PortraitPixels, val probe: PortraitPixels) {
    init {
        if (binding.value("referenceSHA256") != reference.sha256 || binding.value("probeSHA256") != probe.sha256) {
            throw PortraitException(PortraitFailure.INTEGRITY_FAILURE)
        }
    }
}

/** A model-scoped observation, never an identity-acceptance policy. */
class BoundComparisonObservation(val binding: PortraitBinding, val similarity: CosineSimilarity) {
    init {
        if (similarity.space.domain != EmbeddingDomain.FACE_IDENTITY ||
            similarity.space.artifactManifest.hex != binding.value("artifactManifestSHA256")) {
            throw PortraitException(PortraitFailure.BINDING_MISMATCH)
        }
    }
}

/** Serialized lifecycle; callers invoke callbacks outside the monitor after invalidation. */
class ComparisonOperationFence {
    private var outstanding: ComparisonRequest? = null
    private val usedOperations = mutableSetOf<String>()
    @Synchronized fun begin(request: ComparisonRequest) {
        if (outstanding != null) throw PortraitException(PortraitFailure.OPERATION_UNAVAILABLE)
        val operationID = request.binding.value("operationID")
            ?: throw PortraitException(PortraitFailure.INVALID_SCHEMA)
        if (!usedOperations.add(operationID)) throw PortraitException(PortraitFailure.OPERATION_REUSED)
        outstanding = request
    }
    fun cancel(operationID: String, onCancel: () -> Unit) {
        synchronized(this) {
            if (outstanding?.binding?.value("operationID") != operationID) throw PortraitException(PortraitFailure.OPERATION_UNAVAILABLE)
            outstanding = null
        }
        onCancel()
    }
    @Synchronized fun complete(binding: PortraitBinding): ComparisonRequest {
        val request = outstanding ?: throw PortraitException(PortraitFailure.OPERATION_UNAVAILABLE)
        request.binding.requireMatches(binding)
        outstanding = null
        return request
    }
}
