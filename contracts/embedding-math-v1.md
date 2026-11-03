# Embedding primitives v1

This contract is the first implemented numerical slice. It covers mathematical types and operations before model selection or orchestration extraction. SPEC-IDBIO-200 sections 5.1–5.3 govern its meaning. Current native implementations live in BiometricSDK; a shared foundation extraction requires the same contracts/tests, not divergent copies for document classification.

| Type | Meaning and invariant |
| --- | --- |
| `ArtifactDigest` | Exactly 64 lowercase ASCII hexadecimal characters identifying an immutable artifact manifest. That manifest binds model, preprocessing, precision and relevant numerical admission parameters. |
| `EmbeddingDomain` | `face_identity` or `document_revision`. Shared operators do not create a common face/document embedding space. PAD observations are a separate contract and are not identity similarities. |
| `EmbeddingSpace` | Manifest digest, domain, positive declared dimension and finite positive minimum raw-feature norm. Every parameter is explicit; no default match threshold or quality cutoff. |
| `RawFeatureVector` | Unadmitted FP32 model features. Construction does not establish finiteness, shape, quality or validity. Native arrays have value/copy semantics across the public boundary. |
| `UnitEmbedding` | Only numerical admission/normalization constructs this type. Contains its space, raw-feature L2 norm and normalized coordinates. No public unchecked initializer or mutation of admitted components. |
| `CosineSimilarity` | Bounded mathematical observation in `[-1,1]`, with angular distance in radians in `[0,π]`. No identity probability, accept/review decision or calibrated error-rate claim. |
| `PrimitiveFailure` | Typed failures: `invalid_digest`, `invalid_space`, `dimension_mismatch`, `nonfinite_feature`, `invalid_norm`, `incompatible_space`. Swift throws the error enum; Kotlin throws an exception carrying the same reason enum. No authored user-facing prose. |

Admission first checks feature count against the declared dimension, then rejects every nonfinite component. Let `v` be the FP32 features promoted to FP64. Compute `q = sqrt(sum(vᵢ²))` using FP64 products and accumulation. Reject a nonfinite/zero norm or `q < minimumNorm`; equality at the explicit floor is admitted. Normalize with `xᵢ = vᵢ/q` in FP64. For FP32 finite inputs this avoids the overflow/underflow of an FP32 sum of squares. The raw norm is an artifact-dependent learned quality proxy, not physical metrology or a universal quality scale.

Comparison requires equal complete `EmbeddingSpace` values. It computes `s = clamp(sum(xᵢyᵢ), -1, 1)` with FP64 products/accumulation and returns `θ = acos(s)` in radians. A different domain, digest, dimension or numerical admission contract is incompatible even if vectors happen to have the same length. There is no legacy `-1` invalid-vector sentinel: antipodal valid vectors can produce `-1`, while invalid inputs produce typed failures.

This v1 numerical choice is explicit new behavior. It does not silently replace the existing product's Accelerate/FP32 comparator, weights, crop routes, stored verdicts or thresholds. Serialization or FP32 quantization of normalized coordinates is not specified by this primitive contract; the future portable/NIST template encoding must declare it and demonstrate parity. C++ implementation and model preprocessing parity remain planned.

Swift and Kotlin tests cover known norms, parallel/antipodal/orthogonal vectors, incompatible spaces, wrong dimensions, NaN/infinity/zero, floor equality, finite FP32 extremes and immutable ownership. Compiler API snapshots cover the new public types. No model, camera, datastore, BFF or presentation is required to execute this slice.

Implementation sequencing remains in the governing architecture appendices; this document specifies the primitive contract.
