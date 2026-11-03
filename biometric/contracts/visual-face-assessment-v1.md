# Optional visual face assessment v1

Historical contract. The unpublished product and runtime were removed on
22 October 2026. This record explains existing archived data; the APIs below
are no longer available. See [the removal scope](README.md).

`BiometricVisualAssessment` is an optional iOS inference product, independent of
`BiometricSDK`, capture and AuraFace. Its actor is constructed with a host-supplied
local model directory. It has no network, downloader, storage or product-policy
API. The host provisions the exact frozen LFM2.5-VL-1.6B MLX affine 4-bit,
group-size-64 artifact and keeps that directory immutable while it is in use.

```swift
let assessor = LiquidFaceAssessment(modelDirectory: localDirectory)
let observation = try await assessor.assess(
    reference: originalPortrait, referenceSHA256: portraitDigest,
    selfie: admittedSelfie, selfieSHA256: selfieDigest)
```

Exact original encoded bytes are owned, hashed and checked before bounded
ImageIO decoding. Images must be complete, single-frame, upright (orientation1),
at most32MiB,4096pixels per dimension and8,388,608pixels total. ImageIO thumbnails
are bounded to512pixels, fitted without aspect-ratio distortion into a512square
sRGB tile with neutral-gray padding, then passed through the native processor's
sRGB normalization, patch extraction and two-image preparation. This route is a new
native profile; no parity with the earlier Python processor is implied.

Before local loading, eight exact model/configuration/tokenizer files are
verified using bounded1MiB streaming reads. The compiled file/digest table is
`LiquidArtifact.files`; the weight identity is
`bf86cc6b16e4f6a870336d5e0ebad0c5cf1d63214efef8efeb8b9655174b3913`.
No weight copy is added to the repository. Model replacement fails closed.

Profile `lfm25-vl16b-affine4-g64-mlx-pair-json-v1` fixes input order (reference,
selfie), labels (`Media-1`, `Media-2`), protocol prompt, greedy temperature0,
128new-token ceiling and2048output-byte ceiling. The model cannot see AuraFace's
score. Only a complete JSON object with `assessment` then `quality_issues` is
accepted. Assessment values are `consistent`, `inconsistent`, `uncertain`;
quality values are `blur`, `poor_lighting`, `occlusion`, `pose`, `low_resolution`,
`other`. Prose, fences, extra or duplicate keys, duplicate/unknown issues and
truncated output produce `invalidOutput`. This strict parser deliberately
requires the instructed field order. Raw generated prose is never returned.

The internal `LiquidProfile` declaration is a model protocol descriptor. Its
instruction text and fixed resource/preprocessing bounds are classified separately
from holder-facing copy and identity-acceptance policy. The shared wrapper applies
this classification only to that exact SHA-256-locked declaration for the authored
sentence and policy-number checks; every other source location and neutral rule
remains intact. Descriptor changes require a reviewed hash update. Adversarial
tests cover changes inside the descriptor and public copy, policy, ambient access
and verdict additions outside it. The imported upstream boundary engine is unchanged.

The observation returns the exact reference/selfie digests, pinned weight digest,
profile ID, typed assessment/quality issues and elapsed operation milliseconds.
Duration includes first-load verification/loading on a cold run. A visual
consistency observation is neither an identity verdict nor calibrated confidence.
The host keeps AuraFace's cosine independently visible and binds both observations
to the same admitted source pair. No SDK/model flag authorizes identity acceptance.

The actor serializes overlapping operations, retaining its gate until the prior
generation worker has settled. Cancellation is checked before/after
input preparation, during file verification, before/after model work and for each
output chunk. The generation task is explicitly cancelled and awaited on early
exit, including output overflow; a running native kernel may complete before
cancellation is observed. Cancelled results must also be fenced by the host's operation identity.
The runtime uses physical iOS devices; simulator and macOS calls explicitly throw
`runtimeUnavailable`. Parser, binding, image-boundary and artifact-verification
mechanisms remain testable on macOS. Native compilation and synthetic probes do
not establish live NFC/selfie acceptance, model accuracy or population calibration.

A separate [v2 evidence-review route](visual-evidence-review-v2.md) accepts
source-bound capture measurements and optional Aura context, with a richer pinned
prompt/schema bundle. It does not change the v1 request or observation meaning.
