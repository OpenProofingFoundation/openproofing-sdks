# AuraFace BFF observation contract v1

**Status: PROPOSED.** This specifies a BFF wire adapter and display data. It does
not implement a BFF, change the SDK, authorize a threshold, or qualify the model.
The [shared comparison contract](face-comparison-bff-v1.md) owns authenticated
request issuance, freshness, attempt generations, admission evidence, retries and
server decisions. The [schema](schemas/auraface-bff-observation-v1.schema.json)
defines this branch's closed JSON payload and its request-plan definition.

## Meaning and exact profile

AuraFace returns a dimensionless **cosine similarity in [-1, 1]** between two
512-dimensional face embeddings. Higher means greater similarity in this embedding
space; it is not a percentage, confidence, probability, PAD result, document
authenticity finding, explanation of facial features, or identity acceptance.
There is no calibrated match threshold in this contract. A failure has no score.
AuraFace is the embedding-recognition branch. Liquid may contribute separately
typed image-quality triage or visible-feature observations; it is not a second
recognition engine. An explicitly selected BFF prompt profile may give Liquid
the admitted AuraFace result and its metric meaning so it can contextualize the
visual observations. That interpretation does not independently validate the
score or change AuraFace's evaluated operating point.

The proposed BFF profile ID is
`auraface-v1-apple-vision3-rgb112-ort122-cpu-v1`. It binds these existing inputs:

| Component | Frozen identity |
| --- | --- |
| Weights | `fal/AuraFace-v1`, revision `af6d057c9b0ec4071d4c49c80e3539258798b609`, `glintr100.onnx`, 260694151 bytes |
| Weights SHA-256 | `a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60` |
| Combined artifact manifest SHA-256 | `9db36f239a89adfa6794f616f7face61f5ba1b0ca0c7f26b93a6204001856347` |
| Aligned-input preprocessing manifest SHA-256 | `70da7b12bc90fda352222d941cc51e97288305de9522320fde8633b22a38e1d9` |
| Alignment route | `apple-vision-revision3-five-point-cpp-bilinear-v1` |
| Runtime | ONNX Runtime 1.22.0, CPUExecutionProvider, sequential, one intra/inter-op thread |

The [artifact manifest](auraface-artifact-v1.json),
[aligned-input profile](auraface-aligned-input-v1.md) and
[Apple alignment route](apple-face-alignment-v1.md) remain normative for numerical
execution. Apple Vision request revision 3 does not pin Apple's internal weights
across OS releases, so the execution report records the actual OS version.
Completed reports for this route require runtime platform `ios` or `macos`;
platform names identify OS families and do not establish physical-device
qualification or distinguish an iOS simulator. The BFF's approved runtime/build
registry must enforce its deployment scope separately.
The proposed profile ID is a new wire identity; it is not an existing SDK output.

## Calibration and NIST boundary

The current AuraFace profile is a development baseline, not a calibrated product
matcher or a qualified FRTE submission. Synthetic tensor/embedding parity,
successful NFC extraction, a plausible score on a live pair and passing schema
fixtures establish no recognition operating point.

Before the BFF applies an acceptance threshold, its policy must reference a
retained evaluation for the exact artifact, preprocessing, alignment route and
intended population/capture conditions. The evaluation must use authorized real
genuine/impostor comparison pairs with independently established subject labels,
document its partitioning and prevent calibration/evaluation subject leakage.
It must record a DET/error tradeoff, false-match and false-nonmatch measurements,
sample counts, uncertainty and relevant capture/quality breakdowns at the chosen
operating point. The BFF owns the evaluated threshold and versioned policy, never
the SDK, Liquid output, UI or a hard-coded sample-app cutoff. An operating point
for another model, route or corpus cannot be silently inherited by this profile.

The [NIST adapter track](../biometric/nist/README.md) separately records the
unimplemented recognition adapter and qualification obligations. Existing official
driver/null-reference mechanics and synthetic inference parity are not a real
AuraFace FRTE validation, submission, NIST execution or published performance
result. Those stages require their own evidence and must remain distinct from
local calibration and BFF integration. No NIST performance claim is authorized
by this contract.

## BFF plan and submission

The server stores a branch plan matching schema `$defs/plan`, together with the
shared request context and expiry. The plan fixes the model, complete profile,
weight digest, manifests and alignment route. The client cannot select a different
route, restored portrait, model, normalization or threshold under the same plan.
Changing any of those requires a newly approved profile and a new BFF-issued plan.

The branch response echoes the frozen shared context. `context.reference.sha256`
and `context.selfie.sha256` identify the exact encoded bytes consumed by the SDK.
`observation.referenceAlignedSHA256` and `selfieAlignedSHA256` identify the exact
37632-byte, orientation-1, packed RGB8 112x112 derivatives consumed by inference.
They are not encoded-image or tensor digests. Any change of source bytes requires
a new request/attempt binding; no substitution based on a similar image is valid.
The authenticated BFF resolves passport DG2 authentication and selfie admission
through the separately stored evidence records. A digest alone proves neither.

`execution.artifactSHA256` means the expected weight bytes for this fixed profile,
not the combined manifest hash. Successful reports must carry the profile's exact
weight digest and profile ID. The observation separately retains the combined
manifest and preprocessing digests and route. For failures/unavailability, execution
identifies the attempted profile; the branch status explicitly does not claim that
the weights loaded or inference ran. Shared duration is elapsed monotonic time for
the branch attempt, including lazy loading, preparation and both embeddings, and
does not claim to be kernel-only time. Runtime metadata is reported environment
metadata, not attested proof that a particular inference executed.

Schema validation is necessary but insufficient. The BFF must compare every
context binding and profile field to its stored plan, verify freshness and source
admission under the shared contract, and reject superseded or replayed attempts.
Client-supplied hashes, runtime names and signed reports cannot independently
establish computation correctness. Raw images, embeddings, landmark coordinates
and transform matrices are excluded from this payload; their disclosure needs a
separate authorized contract.

An optional downstream Liquid input must reference the admitted AuraFace report
by result digest and bind the same request, attempt, generation and exact image
pair. It may contain the finite cosine, fixed metric name/range and approved
model/profile lineage; any supplied decision or threshold meaning must come from
the separately evaluated BFF policy. Failed, unavailable or absent scores remain
explicit states, never zero-valued comparisons. A valid echoed score is still
client-reported inference unless independently verified by the selected backend
mechanism. Feeding that observation to Liquid creates a dependent interpretation
branch: agreement between the two outputs cannot be counted as independent
corroboration. This optional flow changes orchestration and prompt inputs; it is
not implemented by the current parallel two-image API.

## Results and failures

`completed` carries exactly one observation: `cosineSimilarity`, both aligned
digests, artifact/preprocessing digests, route, and fixed embedding/input metadata.
JSON numbers must be finite; NaN and infinity are not JSON. Values outside [-1, 1]
are invalid and must not be clamped or converted into an ordinary result.
There are no `confidence`, `match`, `accepted`, threshold or explanation fields.

`failed` and `unavailable` carry a shared typed failure and no observation. The
adapter must preserve the technical cause without exposing runtime exception
prose, file paths, images or embeddings:

| Native cause | Wire code | Status |
| --- | --- | --- |
| `invalidImage` | `invalid_image` | `failed` |
| `resourceLimit` | `resource_limit` | `failed` |
| `sourceMismatch` | `source_mismatch` | `failed` |
| `faceMissing` | `face_missing` | `failed` |
| `multipleFaces` | `multiple_faces` | `failed` |
| `landmarksUnavailable` | `landmarks_unavailable` | `failed` |
| `modelUnavailable` | `model_unavailable` | `unavailable` |
| `alignmentFailed` | `alignment_failed` | `failed` |
| `inferenceFailed` or unclassified embedding/native failure | `inference_failed` | `failed` |
| Unsupported host/runtime, detected by the adapter | `runtime_unavailable` | `unavailable` |
| `CancellationError`, observed by the adapter | `cancelled` at the actual interrupted stage | `failed` |

The SDK currently collapses several model-load problems into `modelUnavailable`
and native errors into alignment/inference failures. An adapter must not claim a
more precise cause without evidence. `cancelled` is a terminal technical report,
not permission to revive a superseded attempt. Shared cancellation/expiry rules
govern abandoned attempts; they cannot publish a late success. One branch failing does
not rewrite the other branch, and an outage is never a biometric mismatch.

## Useful UI detail and current implementation gap

The presenter can show the raw cosine, its dimensionless range, model/profile,
512 embedding dimensions, two 112x112 aligned inputs, alignment route and elapsed
time. Lineage hashes can support an expandable technical detail view. Fixed input
metadata describes the selected profile; it is not a measured quality rating.
Localized presenter text must explain that the score is an observation and that
no evaluated decision threshold is supplied. No fabricated facial narrative,
face-quality score, demographic inference or liveness verdict may be derived
from this branch. Product decisions and their evaluated policy identity are
separate BFF outputs.

The current public
[`FaceSimilarityObservation`](../biometric/ios/Sources/BiometricInference/AuraFaceComparison.swift)
already returns source/derivative hashes, combined artifact-manifest hash,
alignment route and cosine. It does not return runtime metadata, timing, a BFF
request/challenge, preprocessing hash or this new profile ID. Those require a
reviewed adapter: obtain timing from a monotonic clock around the branch, derive
fixed metadata from the approved profile, and retain actual runtime/OS provenance.
The SDK keeps raw embeddings internal to this comparison API. The current app
reduces the Aura result to a score; this proposal does not claim the richer wire
payload or UI is implemented.

The [completed](examples/auraface-bff-completed.json),
[failed](examples/auraface-bff-failed.json) and
[unavailable](examples/auraface-bff-unavailable.json) examples contain synthetic
identifiers, digests and illustrative numbers. They are schema fixtures, not
device receipts, measured accuracy or a recommended threshold.
