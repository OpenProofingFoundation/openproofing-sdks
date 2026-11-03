# Face comparison BFF contract v1

**Status: proposed contract for review.** The native reference app currently runs
AuraFace and Liquid locally. This proposal does not add a live BFF, attestation
adapter, acceptance threshold or richer model output to that app. The two model
contracts are [AuraFace](auraface-bff-observation-v1.md) and
[Liquid](liquid-bff-observation-v1.md); their schemas and synthetic examples are
under `schemas/` and `examples/`. Schema IDs are identifiers, not deployed URLs.

This contract implements the design obligations in APP-ARCH-001 CON-01–03,
ATTEST-01–02 and BFF-01–05. Existing [portrait bindings](portrait-selfie-v1.md),
[sealed operations](sealed-operation-v1.schema.json) and
[result receipts](operation-receipt-v1.schema.json) retain their own encodings
and trust boundaries. These proposed adapter DTOs do not change their signed bytes.

## Authority and request plan

The BFF authenticates the application/installation, resolves the admitted original
passport portrait and reviewed live selfie, and stores an immutable request plan.
It MUST validate producer receipts and attempt/session/generation associations
through the selected evidence adapters. An echoed ID, image hash, SDK flag or
client claim of NFC authentication is insufficient evidence by itself.

The [shared schema](schemas/face-comparison-bff-common-v1.schema.json) describes
that plan and common model-result fields. The plan contains:

- `schemaVersion: 1`, complete `context`, `issuedAt` and `expiresAt`.
- A requested AuraFace branch and Liquid branch, each with a BFF-owned `required`
  flag and a closed model-specific `plan` selecting exact model/profile identities.
- For Liquid, the exact prompt digest, response profile, language and generation
  settings. The BFF selects an admitted profile; clients MUST reject unsupported
  profiles rather than improvise a prompt, substitute weights or fall back silently.

All `context` fields are frozen in server state: request, operation, attempt,
challenge, application, installation, session, generation, policy ID/version and
the reference/selfie evidence IDs and exact original encoded-byte SHA-256 hashes.
`operationId` may originate as a client idempotency identifier; it acquires no
authority until admitted and bound by the BFF. `generation` is an opaque string,
consistent with the existing sealed-operation contract, never an inferred counter.
Challenge bytes are server-generated, unpredictable and base64url encoded; the
schema's 32-character minimum is an encoding bound, not a substitute for a secure
generator. Example values are synthetic and MUST NOT become production defaults.

`issuedAt` and `expiresAt` are BFF UTC Unix seconds. The server MUST enforce
`issuedAt < expiresAt`, the configured maximum lifetime, current server time and
withdrawal/supersession. Clients cannot extend a deadline with their clock.
The proposal leaves the concrete lifetime and evaluated acceptance policy to the
adopting BFF; no arbitrary recognition threshold is established here.

## Independent model reports

Each report echoes the full context and contains its own execution metadata and
one status: `completed`, `failed` or `unavailable`. A completed report has an
`observation` and no `failure`; the other statuses have a typed failure and no
observation. Missing data is never a zero score, a mismatch, a pass or an invented
explanation. Missing or inconclusive Liquid observations remain explicit inside a completed report; they are not runtime failures.

Both branches MUST consume the exact original pair selected by the request. Each
model applies its own named preprocessing; their derived pixels need not match.
The BFF may pass the admitted Aura result and its meaning to Liquid under the
[versioned prompt contract](PROMPT-CONTRACT.md). That output is score-informed
interpretation, not independent corroboration. No averaging into a synthetic
probability is permitted.

Execution identity records weight digest, profile, runtime name/version, OS family
and version, and elapsed monotonic operation milliseconds. On completion, artifact
identity must describe the artifact actually verified and consumed. On an early
failure/unavailable report it identifies the requested artifact and MUST NOT be
interpreted as proof of loading. Build/runtime metadata must remain truthful even
if inference never starts; unsupported metadata is an adapter integration gap,
not permission to invent a version. The one-hour duration bound is a wire-resource
ceiling, not a latency target or server freshness measure. First-use verification
and model loading count toward operation duration; device wall-clock timestamps
are not used to calculate it. Current SDK/host timing differences are recorded in
the model-specific mapping and require a consistent adapter boundary.

## Validation, replay and recovery

The future BFF adapter MUST perform these checks before admitting a report:

1. Bound transport/content size; decode UTF-8 JSON strictly, rejecting duplicate
   keys at every level, nonfinite numbers, invalid Unicode and unknown versions,
   properties or enumerations. JSON Schema validates decoded shape; it does not
   detect discarded duplicate keys or authorize a request.
2. Validate the appropriate closed model schema using locally registered schemas,
   without fetching client-selected references. Enforce the Liquid raw-generation
   and decoded-text bounds independently of overall transport size.
3. Authenticate the installation/application and the selected platform-proof
   mechanism, verify exact request/result binding through the existing operation
   and receipt adapters, and check audience/purpose and key lifecycle. These DTOs
   do not define a new signature canonicalization or bypass proof verification.
4. Compare every echoed context, model, artifact, preprocessing, prompt, runtime
   and policy identity against server-stored admitted state. Resolve original and
   derived evidence lineage through the authoritative receipts available for the
   selected route. Client-generated aligned digests remain reported observations
   unless the selected verification mechanism independently establishes them.
5. In one transactional state transition, enforce server expiry, current generation,
   cancellation and idempotency. Persist each branch result under `(requestId,
   model)` with its exact bound result digest. Exact authenticated retries return
   the existing receipt; changed payloads for that slot are conflicts, not updates.
   A stale request cannot be reopened by a late successful model callback.

The two branches share a comparison request but have independent result slots.
Proof-key sequencing and challenge consumption MUST use the existing coordinator:
one logical request challenge cannot be consumed twice independently merely
because two reports arrive. The adopting adapter must bind each submission to
its model slot and payload under that coordinator, or submit a single sealed
combined result. It MUST freeze and test its chosen transport mapping before
live use; this proposal does not claim that adapter is implemented.

Results may arrive in either order. The BFF returns accepted branch receipts and
their current state independently. Requiredness is read from its stored plan,
never from a submitted client flag. Nonrequired missing/failed branches remain
explicit in the summary. A superseded/expired/cancelled operation rejects new
publication; readback may return its retained receipts without reviving it.
Server retention and erasure policy MUST cover reports, generated descriptions,
receipts and caches. Cross-request reuse requires a separately authorized evidence
policy; a matching hash alone does not make old observations fresh.

A signature or platform assertion can establish the selected device/request
binding under that mechanism. It does not prove that a model executed correctly,
that the camera saw a live person, or that a passport/licence is authentic.
Assurance qualification must describe these limits and any independent checks.

## Policy and presentation

The BFF owns the evaluated policy and any calibrated AuraFace operating point.
The proposed development mode is observation-only: display the two branch
observations and their limitations without issuing biometric or identity
acceptance. Liquid explanations are display-only untrusted model-generated
content, including its qualified review of a supplied Aura result. They MUST NOT become instructions, executable markup, tool calls,
thresholds, credentials or authorization. Typed Liquid observations remain
experimental and cannot become a mandatory acceptance factor without separate
task evaluation and an explicit policy revision.

The BFF returns typed recovery/outcome reasons and structured arguments. Native
catalogs own authored labels and accessibility wording. The proposed Liquid
report explicitly identifies generated English content; it is not localized
catalog copy. The presenter must show it as model-generated content and retain
its uncertainty. AuraFace provides numerical and processing facts, not a
fabricated natural-language account of which facial features matched.

This envelope does not authorize upload of raw images, embeddings or names.
The prompt contract explicitly permits locally supplied, provenance-bound DOB
and age context; that does not itself authorize external disclosure. Generated descriptions may still be identity-bearing and MUST NOT enter
routine logs/telemetry. Any additional disclosure requires an explicit operation,
recipient and retention agreement under BFF-04.

## Compatibility and remaining delivery

These are new adapter contracts; the existing portable SDK APIs remain independent
of them. Any change to preprocessing, prompt bytes, sampling, schema or accepted
model identity needs a new immutable profile and explicit compatibility review.
Stored observations retain their original model/profile/policy identity. The
current Liquid pair-JSON v1 cannot be relabelled as the proposed interpretation profile or have
explanations synthesized from its aggregate quality flags.

Before live BFF adoption: implement adapter/DTO mapping and proof coordination;
execute common positive/negative shape and stateful binding/replay/expiry vectors;
test both arrival orders, exact retries, changed retries, response loss, cancellation,
late completion and partial results; evaluate the new prompt on frozen inputs;
and verify UI/accessibility and physical flows against that exact revision.
Contract review or synthetic schema validation establishes none of these live
claims. Future optical-document medium assessment is a separate Liquid profile,
as described in its contract, and is not part of this face comparison operation.
