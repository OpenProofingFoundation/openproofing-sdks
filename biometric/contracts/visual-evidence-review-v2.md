# Visual evidence review v2

Historical contract. The unpublished product and runtime were removed on
22 October 2026. This record explains existing archived data; the APIs below
are no longer available. See [the removal scope](README.md).

The optional `BiometricVisualAssessment` product exposes a separate `review`
operation. The original `assess` operation and v1 output remain available.

```swift
let engine = LiquidFaceAssessment(modelDirectory: weights,
                                  promptContractDirectory: promptResources)
let report = try await engine.review(reference: portrait, referenceSHA256: portraitSHA256,
    selfie: selfie, selfieSHA256: selfieSHA256, measurements: measurements, aura: aura)
```

`promptResources` preserves the relative paths in
[`PROMPT-CONTRACT.md`](../../contracts/PROMPT-CONTRACT.md). The SDK verifies the
compiled manifest digest and every named resource before use. It supplies the
task, full response schema, three balanced examples, actual images and actual
context to the model. A separately pinned structural decoder schema configures
MLXGuidedGeneration; the complete output schema and source-aware semantic checks
validate the result afterward. Unsupported or missing bundles fail explicitly.

`CaptureMeasurements` is independent of the capture SDK. The host maps its admitted
receipt into numeric depth, blink, tracking and quality values, optional aligned
motion summaries and exact image/source bindings. Missing modalities remain null.
Motion summaries retain the shared Pulse field meanings, units and window bounds;
a device-motion window does not make visual temporal evidence available. No
sensor or authentication proof is inferred from a supplied hash.

Optional `AuraContext` carries an actual source-bound cosine and its interpretation.
It neither invents a threshold nor makes the model an independent corroborator.
No DOB or known-age context is fabricated; visible apparent-age estimates remain
qualified model observations. BFF request/challenge identities stay outside this
native payload.

The returned `VisualEvidenceReviewObservation` contains the six typed report
sections, original-image digests, context digest, prompt message digest, response
schema digest, prompt-contract digest, model/profile identity and elapsed time.
The host can independently compute the expected context digest with
`LiquidFaceAssessment.contextSHA256` before accepting a report.

The actor serializes v1/v2 work and retains its operation gate until native GPU
work settles. Input/output/token bounds, exact-image verification and fixed
aspect-preserving preprocessing still apply. Rich model text is inert operator
content; no returned field is an identity or PAD acceptance decision. Native
execution and measured usefulness require their own evidence.

The native runtime temporarily lowers MLX's process-wide allocator cache budget
to at most 128 MiB while loading/reviewing, clears reusable buffers at prefill and
bounded decode intervals, then synchronizes and restores the previous budget.
The reference host uses one serialized MLX model; other simultaneous MLX users
would share this temporary cache policy. This changes buffer recycling, not the
model, prompt, output schema or greedy sampling. Exact values are pinned in the
profile's `runtimeMemory` record. An optional diagnostic callback exposes only
stages, counts and allocation bytes; the SDK does not log content.

The pinned decoder suppresses repetitive whitespace after three consecutive
whitespace-only tokens, using the upstream whitespace classifier and run tracker.
Its minus-200 logit penalty remains active for that generation. Grammar exclusions
remain absolute; the 2,048-token limit and full output validation still apply.
Scalar output diagnostics report byte counts and JSON nesting without retaining
the generated text.
