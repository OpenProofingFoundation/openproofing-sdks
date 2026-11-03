package com.kenshiki.presentation

import com.kenshikilabs.biometric.BoundComparisonObservation
import com.kenshikilabs.biometric.ComparisonOperationFence
import com.kenshikilabs.biometric.ComparisonRequest
import com.kenshikilabs.biometric.ArtifactDigest
import com.kenshikilabs.biometric.EmbeddingDomain
import com.kenshikilabs.biometric.EmbeddingMath
import com.kenshikilabs.biometric.EmbeddingSpace
import com.kenshikilabs.biometric.PortraitBinding
import com.kenshikilabs.biometric.PortraitPixels
import com.kenshikilabs.biometric.RawFeatureVector
import java.util.UUID

/** Serialized reference-host engine using synthetic pixels/features, never capture or inference. */
class SyntheticBiometricEngine : WorkflowEngine {
    private val identifiers = PortraitBinding.fieldNames.filter { !it.endsWith("SHA256") && it != "operationID" && it != "sessionID" }
        .associateWith { UUID.randomUUID().toString() }
    private val submitted = mutableSetOf<OperationToken>()
    private val fence = ComparisonOperationFence()
    private var pending: Pair<OperationToken, String>? = null

    override fun resolve(request: OperationRequest, completion: (OperationToken, StubCompletion) -> Unit) {
        if (request.capability != Capability.BIOMETRIC || request.token.capability != Capability.BIOMETRIC || !submitted.add(request.token)) {
            completion(request.token, StubCompletion.Recoverable(RecoveryReason.INVALID_INPUT))
            return
        }
        val result = try {
            val pixels = PortraitPixels(1, 1, "rgb8", 3, 3, 1, pixelDigest, byteArrayOf(0, 1, 2))
            val binding = makeBinding(request.token)
            fence.begin(ComparisonRequest(binding, pixels, pixels))
            pending = request.token to binding.fields().getValue("operationID")
            val space = EmbeddingSpace(ArtifactDigest(artifactDigest), EmbeddingDomain.FACE_IDENTITY, 2, 0.01)
            val left = EmbeddingMath.normalize(RawFeatureVector(floatArrayOf(3f, 4f)), space)
            val right = EmbeddingMath.normalize(RawFeatureVector(floatArrayOf(4f, -3f)), space)
            BoundComparisonObservation(binding, EmbeddingMath.compare(left, right))
            fence.complete(binding)
            pending = null
            StubCompletion.Observed
        } catch (_: IllegalArgumentException) {
            cancel(request.token)
            StubCompletion.Recoverable(RecoveryReason.INVALID_INPUT)
        }
        completion(request.token, result)
    }

    override fun cancel(token: OperationToken) {
        val current = pending ?: return
        if (current.first != token) return
        pending = null
        fence.cancel(current.second) {}
    }

    private fun makeBinding(token: OperationToken): PortraitBinding {
        val fields = PortraitBinding.fieldNames.associateWith { name ->
            if (name.endsWith("SHA256")) lineageDigest else UUID.randomUUID().toString()
        }.toMutableMap()
        fields.putAll(identifiers)
        fields["sessionID"] = token.sessionID.lowercase(java.util.Locale.ROOT)
        fields["referenceSourceSHA256"] = pixelDigest
        fields["probeSourceSHA256"] = pixelDigest
        fields["referenceSHA256"] = pixelDigest
        fields["probeSHA256"] = pixelDigest
        fields["artifactManifestSHA256"] = artifactDigest
        fields["preprocessingManifestSHA256"] = preprocessingDigest
        return PortraitBinding(fields)
    }

    private companion object {
        const val pixelDigest = "ae4b3280e56e2faf83f414a6e3dabe9d5fbe18976544c05fed121accb85b53fc"
        const val artifactDigest = "c7fccc34d85b04f6acb8511494ea7935b049245d3948e0ea7115586054e8bf09"
        const val preprocessingDigest = "47dbe0ef56a7cdd1dde118d5744e3a2eb2ffbda13f9e887529ec96c9b238781d"
        const val lineageDigest = "8d541b33f2748e4fb2eb3b30c5f695f6fcaa14ecd84d547898c21bb5946fa456"
    }
}
