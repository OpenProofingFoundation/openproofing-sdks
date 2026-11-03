# Shared contracts and conformance

[Sensor measurement/window v1](sensor-measurement-window-v1.md) defines the shared
sensor evidence boundary, including measurement classes, units/gravity, coordinate
and clock identities, coverage/omissions, retained inputs and versioned derivations.
The independently consumed [Sensors foundation](../foundation/sensors/README.md)
implements the first Swift slice with shared conformance vectors and preserved
Pulse mathematical semantics. It does not establish sensor authenticity or liveness.

The proposed [Liquid prompt contract](PROMPT-CONTRACT.md) binds task instructions,
input/output schemas, balanced examples and generation settings for contextual
review of the passport/selfie evidence. Its offline assembly and conformance
tools do not change the installed app or implement a BFF.

Implemented shared contracts include [embedding math](embedding-math-v1.md) and the optional [presentation demonstration contract](presentation-v1.md), whose Swift/Kotlin controllers consume the same positive and negative [transition vectors](presentation-v1.vectors.tsv). Demonstration outcomes are explicitly scoped and cannot serve as identity evidence or BFF authorization.

This directory owns common source/portrait, operation/receipt, key lifecycle and BFF boundary schemas and positive/negative vectors. Current capability conventions remain indexed at [document](../document/contracts/README.md), [passport](../passport/contracts/README.md) and [biometric](../biometric/contracts/README.md). Typed outcome parity is already guarded in each capability; the operation and receipt schemas below already have conformance vectors; additional product and derivation contracts remain separate work.

[Source-bound portrait/selfie v1](portrait-selfie-v1.md) specifies source/derivation, portable pixel and interactive-binding boundaries for Swift, Kotlin and C++20/NIST. Its [profile](portrait-selfie-v1.json), 200 [portrait vectors](portrait-selfie-v1.vectors.json) and 30 [math vectors](embedding-math-v1.vectors.json) execute in Swift, Kotlin and C++20. Implemented primitives cover immutable packed pixels, exact-byte hashing, requests, complete bindings, model-scoped observations and cancellation/completion fences. The optional Apple decoder/alignment/inference route is implemented separately from this portable core; complete source/derivation verification and product proof adapters remain separate work.

Contracts explicitly version encoding, bounds, coordinates/clocks, lineage, cancellation and recovery. Preserve exact consumed portrait bytes and hashes. Shared contracts must not carry vendor DTOs or imply identical iOS/Android assurance. Schema changes require compatibility review and every affected consumer's validation in the same PR.

[Sealed operation v1](sealed-operation-v1.schema.json) binds closed product content digests, audience, installation/generation, operation identity and resource revision. Its [conformance vector](sealed-operation-v1.vectors.json) pins domain-separated hash bytes. The [result receipt](operation-receipt-v1.schema.json) binds the complete request digest and closed result digest. The Swift implementation is `../foundation/`; platform key custody, durable recovery and service-origin enforcement remain adapter requirements with separate evidence.

The optional [Apple face alignment route](apple-face-alignment-v1.md) records native decoding/landmarks, the shared C++ similarity fit/raster and operation-bound AuraFace observations. It introduces no recognition threshold.
