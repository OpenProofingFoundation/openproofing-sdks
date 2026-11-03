# AuraFace aligned-input profile v1

This development profile fixes the boundary between an already-aligned pixel
snapshot and the selected AuraFace embedding artifact. C++ is the implementation
track for this slice; Swift/Kotlin execution of these same vectors remains planned.
It defines neither face detection/alignment nor a complete portrait-to-embedding
pipeline. A 112×112 shape does not prove that a face was aligned correctly.

## Exact identities

The normative profile is [auraface-aligned-input-v1.json](auraface-aligned-input-v1.json).
Its SHA-256 is
`70da7b12bc90fda352222d941cc51e97288305de9522320fde8633b22a38e1d9`.
The combined model/preprocessing/runtime/numerical manifest is
[auraface-artifact-v1.json](auraface-artifact-v1.json); its SHA-256 is
`9db36f239a89adfa6794f616f7face61f5ba1b0ca0c7f26b93a6204001856347`.

Both identities cover the **exact retained UTF-8 file bytes**, including spaces,
key order and final LF. JSON reserialization is not equivalent. Neither manifest
contains its own digest, avoiding a self-referential hash. Implementations pin
these digests; new profile/model/runtime identities require explicit adoption,
not permissive parsing or fallback. These are closed documents, not arbitrary
caller-supplied configuration dictionaries.

## Input and preprocessing

The input is an owned [portable pixel snapshot](portrait-selfie-v1.md): exactly
112×112 packed RGB8, orientation1, row stride336, byte length37632. Its SHA-256
covers those exact consumed RGB bytes. Reject unsupported geometry, grayscale,
other orientation and layouts. Portable snapshot construction separately rejects
malformed lengths, metadata, resource overflow and invalid digests before this
profile is applied. No implicit EXIF operation, conversion, decoder, resizing,
landmark fit, crop, restoration or warp occurs here.

For pixel index `p` and channel `c` in RGB order, output position
`c × 12544 + p` is:

```
a = binary32(uint8_input[p × 3 + c])
b = binary32(a - binary32(127.5))
y = binary32(b × binary32(1.0 / 127.5))
```

Each operation rounds to nearest, ties to even. The reciprocal's IEEE754 bit
pattern is `0x3c008081`. Do not substitute division, fuse operations or enable
fast-math. Tensor layout is batch-one NCHW `[1,3,112,112]`. A tensor digest covers
the 150528 bytes of explicit little-endian IEEE754 binary32 channel-major
serialization; native-endian memory is not a portable encoding.

[Common synthetic vectors](auraface-aligned-input-v1.vectors.json) separately pin
RGB input and tensor digests for an asymmetric ramp, black and white. The ramp
uses `(pixel_index × 37 + channel_index × 83) mod 256` and exercises every byte
value in every channel. Negative vectors specify profile-layer failures after
valid portable pixels are constructed. Mobile implementation must consume these
same fixtures rather than invent alternative normalization.

## Model, output and binding

The combined manifest pins the selected ONNX byte length/digest, graph node
names/types/shapes, ONNX Runtime 1.22.0 CPU sequential execution and one intra/inter
thread. Verify the exact immutable model snapshot and load that same snapshot.
Weights remain outside Git. Runtime/dependency archive qualification is a
separate supply-chain gate; a version string alone does not authenticate a binary.

An inference result retains the consumed RGB digest and emits raw finite 512
FP32 features plus the existing [UnitEmbedding](embedding-math-v1.md) normalized
in FP64. Its `face_identity` embedding space uses the **combined manifest digest**,
so preprocessing identity remains part of compatibility. The inclusive norm floor
`1e-12` is a chosen development numerical admission floor, not an identity-match
threshold, calibration result or upstream training claim. Preserve raw norm.
Output must have FP32 type, shape `[1,512]` and 512 elements before accessing data.

This slice adds no interactive comparison API. A caller cannot choose a different
embedding manifest for this fixed adapter. Source/derivation provenance remains
caller supplied and unverified here: exact RGB hashing establishes consumed-byte
consistency, not origin, alignment correctness, authenticity, liveness or a
verified transform chain. Original/selected lineage belongs to the surrounding
portrait handoff and later adapters.

## Failure and lifecycle semantics

Failures are typed technical codes, never an ordinary embedding, zero similarity
or identity verdict. The fixed adapter exposes no caller override for profile or
manifest identity. `invalid_input` rejects unsupported geometry, format, orientation
or floating-point rounding mode; `artifact_size` and `artifact_integrity` distinguish
model length/hash errors. `runtime_version`, `runtime_failure`, `model_metadata`
and `output_metadata` distinguish runtime and tensor-contract failures. Allocation
failures use `resource_limit` and produce no successful result; they are not represented as a match or a
policy result. Existing portable validation and math failures retain their original
meanings, including `nonfinite_feature` and `invalid_norm`. Runtime exception prose, model
paths, pixels and embeddings must not become logs or UI strings.

Batch inference owns its input snapshot through execution. Calls on one session
serialize. The synchronous API provides no cancellation primitive; surrounding
operation fences control publication. Interactive
operation fences and proof/admission requirements remain separate. Any failure
produces no successful inference result. No detector, alignment, mobile inference,
trainable checkpoint or FRTE recognition performance is established by this
profile; sequencing remains in APP-ARCH-001 Appendix A.4.
