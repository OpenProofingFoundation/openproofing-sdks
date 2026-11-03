# Source-bound portrait and selfie contract v1

Status: **portable pixel, request/binding, model-scoped observation and operation-fence primitives implemented in Swift, Kotlin and C++20 with shared adversarial fixtures**. Image decoders, capture, full source/derivation record verification, custody and proof verification remain separate implementations. The [reference validator](../quality/portrait_contract.py) defines the fixture oracle; native consumers execute the same fixtures. This contract is separate from [demonstration workflow v1](presentation-v1.md).

Authority: APP-ARCH-001 CON-01–03 and SPEC-IDBIO-200 §§3.3, 5.1–5.2 and 7. The [research method notes](../governance/research/method-notes.md) provide equation-level sources and identify our engineering choices. Implementation sequencing remains in the architecture appendix.

## Three layers, three consumers

| Layer | Required content | Consumers |
| --- | --- | --- |
| Source and derivation | Original capture/credential artifact identity and exact-byte digest; selected portrait identity/digest; coordinate/orientation/transform chain; producer and selection lineage | Document/passport producers, biometric adapters, authorized evidence composition |
| Portable pixels and model operation | Bounded immutable grayscale/RGB pixels; explicit dimensions/layout; exact consumed-byte digest; model/preprocessing manifest; typed observation or failure | Swift, Kotlin and **C++20/Linux NIST** processing |
| Interactive ceremony | Session, attempt and operation identities; selected reference/probe bindings; separately verified acquisition/admission/custody/proof receipts; cancellation and recovery | Native host controllers and product adapters/BFF |

The NIST adapter consumes the portable layer without requiring mobile capture, SQLite, attestation, a BFF or a live-selfie ceremony. NIST enrollment/verification roles and multi-image/multi-face outputs remain explicit adapter semantics. A batch image is not labelled a live selfie. Conversely, successful batch comparison cannot satisfy an interactive admission requirement.

## Artifacts and ownership

`SourceArtifact` identifies the producer's immutable original using capture/credential ID, artifact ID, SHA-256 of **exact retained bytes**, encoding/format, byte count and applicable dimensions. These identifiers are opaque, bounded technical identifiers, not names or document numbers. A declared hash is not verification: the consumer rehashes the bytes it actually consumes. A verified source binding establishes byte consistency, not issuer authenticity.

`PortraitSelection` names the source artifact, the exact selected portrait artifact and its ordered derivations. Every link records input/output digests, operation/producer manifest, input/output extent, orientation, forward mapping, inverse where defined, coordinate convention, interpolation/border/alpha/color handling and valid-data-mask identity where applicable. Multiple stages are retained; decoding, rectification, alignment, masking and restoration must not collapse into an undocumented crop label. Ambiguous/missing selection has an explicit outcome and supplies no selected portrait.

The original portrait remains identifiable when a restored portrait is supplied. Restoration is a distinct derivative with its own model/producer identity. A policy must explicitly authorize each route; restored bytes cannot replace original lineage silently. Vendor DTOs, vendor model-pack names, URLs and filesystem paths do not appear in the neutral handoff.

The producer transfers an immutable byte snapshot or an explicit read-only lease. The operation owns the snapshot/lease until it acknowledges completion or cancellation. Swift value buffers and Kotlin defensive copies must provide that ownership; C++ uses a bounded `std::span<const std::byte>` backed by a live owner. A borrowed pointer's lifetime is not extended by its span. Mutable caller storage cannot be retained and hashed later. Implementations document resource release and do not log pixels, embeddings or custody material.

## Portable pixel profile v1

[The vocabulary and limits](portrait-selfie-v1.json) define this initial comparison-input profile. Source archives may have additional encodings; they need a separately supported decoder/profile. The portable core receives decoded pixels rather than guessing an image format.

- `rgb8`: interleaved RGB, unsigned eight-bit channels, three channels per pixel; `gray8`: one unsigned eight-bit luminance channel. Alpha/YUV/BGRA/float/depth inputs require an explicit conversion adapter; no reinterpretation or inferred channel order.
- A portable buffer is tightly packed, row-major, with `rowStrideBytes = width × channels` and `byteLength = rowStrideBytes × height`. SHA-256 covers exactly those bytes; no row padding, uninitialized memory or trailing bytes are included. Adapters may use bounded strided views internally, but must define their logical-byte hashing and canonical export before crossing this boundary.
- All five integer metadata fields use positive signed 64-bit integers (`1…9,223,372,036,854,775,807`); booleans, floating-point values and larger integers return `invalid_pixels` before resource/layout checks. Width/height are positive integers, each at most 16,384; at most 67,108,864 pixels and 268,435,456 bytes. These are explicit v1 resource ceilings, not model dimensions or quality thresholds. A runtime may enforce a stricter declared ceiling. Oversized original captures remain intact and return a typed resource failure; silently replacing them with resized bytes is forbidden.
- Orientation is explicit EXIF orientation `1…8` describing the supplied buffer. Core code must not infer whether it was already applied. Display mirroring is separate from pixel mirroring. Each orientation/resize/alignment operation appears exactly once in derivation/preprocessing lineage.
- Raster coordinates use top-left **pixel-edge** origin, x right, y down, pixel centers `(i+0.5,j+0.5)`, extents `[0,width]×[0,height]`. Landmarks are finite points in a named raster frame. Geometry adapters must explicitly convert other conventions. Five-landmark order, template, target size, fitting/degeneracy behavior and fit residuals belong to the selected preprocessing manifest.
- Projective mappings use row-major 3×3 homogeneous matrices; `(u,v,w)=H(x,y,1)`, output `(u/w,v/w)`. Record scale normalization, inverse validity and invalid-data masks. Reject nonfinite/degenerate mappings; numerical tolerances are declared and tested by the geometry implementation. The Kabsch-Umeyama reference supports an orientation-preserving rigid fit, not an unqualified projective or scale estimator.

C++ readers validate fixed-width metadata and multiplication bounds **before** allocation or pointer arithmetic; reject buffer/dimension mismatch, unsupported layout and nonfinite geometry. Never serialize native structs, padding, `size_t`, pointers or host-endian fields. NIST `Image` decoding maps its actual dimensions/depth and packed RGB/grayscale bytes to this profile with checked lengths; supplied eye coordinates and face associations remain attached. NIST failure/empty-template semantics are mapped separately, rather than inventing a low similarity score.

## Interactive binding and admission

An interactive `ComparisonRequest` binds one operation to a session/attempt, both capture and selected-artifact identities, original source digests, selected reference/probe digests, derivation-lineage manifest digests and exact artifact/preprocessing manifests. Lineage manifest digests cover exact retained versioned manifest bytes, not a reserialized dictionary. The executable fixture profile represents these identifiers as canonical lowercase UUIDs and SHA-256 digests. Real operations additionally carry the lease/bytes and the corresponding source/derivation records described above.

Selfie admission is a **separate typed observation** tied to those exact probe bytes, capture identity, session/attempt, method/manifest and applicable clock domain/time. Preserve measured, failed, unavailable, unsupported and not-performed states. Depth, RGB PAD, injection checks and attestation are distinct methods/receipts; a shared interface does not establish equal iOS/Android assurance. A caller-supplied `live=true` flag, a norm or a successful digest check is not admission evidence. Policy and BFF validate the required receipts and binding.

Completions repeat the complete request binding. A controller accepts them only for its current outstanding operation, with the exact requested manifest and input digests. Cancellation/invalidation occurs before requesting resource cancellation; late, duplicate, prior-attempt, wrong-input and foreign completions cannot advance state. Invalid input/binding produces a typed failure and no ordinary similarity. Durable retry revalidates retained input and receipt lineage; process-death recovery is a separate foundation implementation.

The fixture validator deliberately cannot prove capture freshness, a signed receipt, source authenticity or a live human. It checks structural/digest/binding invariants using synthetic bytes. Production adapters must add those actual mechanism tests with their implementation.

## Artifact-specific model and result contract

`ArtifactManifest` binds architecture/graph/weights and deployment precision, detector/alignment/preprocessing, color order/range/layout, input/output shapes, quantization and embedding numerical admission. The manifest must distinguish operations baked into a graph from operations applied by an adapter. Do not normalize twice. An RGB 112×112 input is an artifact profile, not this generic handoff's universal size. The proposed custom normalization and an upstream checkpoint's normalization cannot be interchanged.

An identity embedding uses [embedding-math-v1](embedding-math-v1.md): explicit domain, dimension, complete manifest identity and norm floor; finite FP32 features admitted and normalized/compared in FP64. Its output is a dimensionless cosine observation and optional radians, with explicit failures. It is not a PAD score or identity probability. Face/document spaces remain distinct. Quality norms remain model-dependent observations. Calibration and authorized original/restored route aggregation have separate version identities.

The result records exact input/derivative digests, artifact/preprocessing identity, acquisition/admission availability, observation type/units and typed failure/recovery. Optional timings identify clock and units. No unqualified identity-acceptance boolean, BFF credential or authored user-facing prose belongs here. A NIST adapter maps the declared observation to its required matcher return type; final product acceptance stays server-side.

## Portable templates and conformance delivery

Before portable templates are written, freeze a separate encoding version with magic/version, domain, manifest identity, dimension, scalar format/endianness, lengths, norm/admission identity and exact payload bytes. Include truncated/oversized/unknown-version, NaN/infinite/zero-norm and incompatible-artifact vectors. Preserve unnormalized quality metadata where the chosen artifact needs it. Do not dump Swift/Kotlin/C++ object memory or silently reuse historical templates.

The existing NIST null-reference template is neither this encoding nor a Kenshiki embedding. C++ now implements the shared pixel/binding and math vectors. The algorithm/harness track must next freeze and implement template encoding vectors, then selected preprocessing/inference, initialization-before-fork, thread behavior, multi-image roles and official error semantics. Python/MPS/Core ML smoke results cannot close that track.

[Conformance fixtures](portrait-selfie-v1.vectors.json) cover packed RGB/grayscale, exact-byte identity, bounds/layout/orientation, malformed digests and wrong session/attempt/operation/source/model completion bindings. The fixture profile contains no real people or images. Swift, Kotlin and C++20 execute the same portrait and embedding fixtures. Native ownership/lifecycle tests and sanitizer/mutation evidence remain distinct from inference, physical capture or proof verification.

`operation_unavailable` rejects begin while busy and completion/cancel without the matching outstanding operation; `operation_reused` rejects a previously begun operation ID for that fence lifetime. A wrong completion preserves the current request. Fences serialize state changes and invalidate before invoking cancellation callbacks outside the lock, even when callbacks throw. Their in-memory operation history does not establish durable replay protection. A bound numerical observation retains embedding-space identity and requires the request artifact manifest and face domain; structural binding does not prove that an inference engine produced features from those pixels.
