# Shared contracts

The initial comparison vocabulary is `pass`, `manual_review`, `fail`, `unavailable`, matching the proposed face outcome in SPEC-IDBIO-200 Appendix A. Swift and Kotlin expose the same strings. A comparison outcome is scoped to its exact model, preprocessing, route and policy; it is not an overall identity verdict.

## Portrait handoff with the document SDK

The shared [portrait/selfie v1 contract](../../contracts/portrait-selfie-v1.md) defines source-bound portrait conventions for all capabilities and C++20/NIST. Its portable pixel/request/binding/observation primitives and in-memory operation fences are implemented in Swift, Kotlin and C++20 with common adversarial fixtures. Full producer lineage verification and custody/proof adapters remain separate work; optional Apple decoding/alignment/inference is implemented outside the portable core. Neither package depends on the other's implementation. Establish a shared synthetic fixture and freeze the public representation during extraction:

- Source capture identity/digest, portrait digest, encoding and dimensions.
- Coordinate convention, orientation, crop/warp/mask derivation and original/restored lineage.
- Exact selected reference and admitted-selfie identity.
- Explicit unavailable/error states for missing or incompatible inputs.

Face inference additionally pins detector and embedder identities, landmark ordering/alignment, input normalization, output normalization and comparison policy. Embeddings or thresholds from incompatible models cannot be silently reused. Preserve the current rule that only an authorized model-aligned route may pass, or explicitly replace it with evaluated policy.

The portrait producer can be the document SDK, another authorized source, or a synthetic fixture. Identity-product adapters bind it to document/issuer/phone/session evidence. No vendor-owned document object or mandatory server wire envelope belongs in this API.

## Pre-release Swift initializer migration

The unpublished 0.0.0 Swift API groups untrusted raster fields in `PortraitPixels.Layout`, passed with the digest and bytes to `PortraitPixels(layout:sha256:bytes:)`. Optional capture analyzer facts use `SelfieAdmissionGate.Observation.Measurements`. Existing flat read properties, wire fields, error ordering and shared vectors stay unchanged. These deliberate pre-release initializer replacements are recorded in the compiler API snapshots; no compatibility overload preserves the old oversized signatures.

## Retired experimental visual review

The unpublished `BiometricVisualAssessment` product and its runtime were removed
on 22 October 2026. This deliberately removes its experimental Swift API rather
than retaining executable compatibility overloads. Capture, motion and AuraFace
API contracts remain unchanged. Historical v1-v4 wire records retain their
original meanings; app-owned `LegacyVisualArchive` types validate and export
previously committed records without model, prompt loading or MLX dependencies.
No legacy report becomes a fresh verification result. Frozen prompt/schema
resources under the shared contracts directory are historical records and are
not packaged into the application.
