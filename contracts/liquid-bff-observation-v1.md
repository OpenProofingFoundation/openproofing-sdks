# Liquid BFF image-pair interpretation v1

**Status: PROPOSED; contract and synthetic examples only.** The current proposal
implements neither a BFF nor a native runtime change.
The wire schema remains version `1`; its proposed profile is
`lfm25-vl16b-affine4-g64-mlx-pair-interpretation-v2`.

## One job: interpret the supplied images

Liquid investigates how the images, supplied measurements and contextual facts
fit together. Its report supplies the BFF's slower interpretation loop with
capture-quality issues, facial observations, age estimates and discrepancies,
qualitative cross-checks of AuraFace, and visible scene/presentation/manipulation
indicators. Grounded English accompanies typed facts for operator/audit review.
Recognition remains the embedding branch plus evaluated server policy; Liquid
does not set a new recognition threshold or manufacture a calibrated confidence.
The report informs the BFF's final decision rather than replacing it.

The model may inspect the **whole provided selfie frame**, including environment
outside the face. Cropping it to an aligned face would discard useful scene and
presentation evidence. “Whole provided” does not recover portions absent from
capture or imply an uncropped camera sensor frame. NFC-derived reference pixels
and a selfie still do not supply a capture sequence, motion, IMU or depth stream.

The current [SDK v1 contract](../biometric/contracts/visual-face-assessment-v1.md)
and [source](../biometric/ios/Sources/BiometricVisualAssessment/VisualFaceAssessment.swift)
return a consistency label and aggregate quality flags under a different prompt,
with 128 new tokens and a 2048-byte output ceiling. They cannot satisfy this
interpretation contract. Do not relabel a v1 result, fabricate its explanation,
or derive per-image observations from its aggregate flags. A reviewed report
adapter and separately selected profile are required. Neutral SDK APIs,
installed behavior and historical receipts remain unchanged by these documents.

The [shared pair contract](face-comparison-bff-v1.md) owns request issuance,
attempt/evidence binding, freshness, transport admission and server decisions.
[Dedicated selfie PAD](liquid-pad-observation-v1.md) is a separate proposed task
with an unresolved capture-input contract; it is not activated by this profile.

## Frozen proposed profile and inputs

| Item | Value |
| --- | --- |
| Profile | `lfm25-vl16b-affine4-g64-mlx-pair-interpretation-v2` |
| Weight SHA-256 | `bf86cc6b16e4f6a870336d5e0ebad0c5cf1d63214efef8efeb8b9655174b3913` |
| Prompt | [Exact UTF-8 bytes, including final LF](profiles/liquid-face-interpretation-v2.prompt.txt) |
| Prompt SHA-256 | `d430c1e210df56628384d00598c83f66bcc8d3ef986b559e848a95a9d58a158d` |
| Runtime | `mlx-swift-lm`, version/revision `bb0d5b048f02e14dbf8f2d7bb1a20911a295470a` |
| Report language | `en`; bounded generated English encoded as valid UTF-8 |
| Output engineering ceilings | At most `2048` new tokens and `16384` raw UTF-8 bytes |

The [artifact manifest](../governance/reference-visual-model.json) remains pinned
at SHA-256 `fc976071d9be3480281b07fdace453a18ca919c4360d81f7e35c7b27089f5606`.
It intentionally retains its original SDK v1 profile identity; this new BFF plan
pins the interpretation profile separately. The checkpoint, 4-bit/group-64
conversion, tokenizer, processor and chat-template bytes remain unchanged.
The immutable BFF bundle binds the instruction prompt, expected input schema,
raw output schema, balanced examples, generation configuration, preprocessing
and artifact manifest by exact file hashes. It also retains approved
adapter/build and transitive runtime provenance; a client-supplied weight hash
alone does not establish execution correctness. Altering any bundle member
requires a newly approved bundle identity. See [model selection](../governance/model-selection.md).

The exact original encoded reference portrait and admitted selfie bytes are the
same source pair submitted to AuraFace. Source digests are checked before decode.
Liquid uses its existing image route, not AuraFace's aligned RGB112 derivatives:
complete single-frame upright images; at most 33,554,432 encoded bytes per image,
4096 pixels on either axis and 8,388,608 pixels total; bounded thumbnail decode;
aspect-fit into neutral-gray 512-square sRGB tiles; pinned processor normalization
and patch extraction. Preserve all of the supplied selfie frame within that
route. No new face crop, generated restoration, input substitution or training
is proposed. Tokenization/processor route changes require another profile.

The reference is first, selfie second. At the pinned revision,
[LFM2VL.prepare](https://github.com/ml-explore/mlx-swift-lm/blob/bb0d5b048f02e14dbf8f2d7bb1a20911a295470a/Libraries/MLXVLM/Models/LFM2VL.swift)
uses the Qwen2VL message generator after special-token-label screening.
[Chat.contentParts](https://github.com/ml-explore/mlx-swift-lm/blob/bb0d5b048f02e14dbf8f2d7bb1a20911a295470a/Libraries/MLXLMCommon/Chat.swift)
emits each valid label as text immediately before its image.
[UserInput.Image](https://github.com/ml-explore/mlx-swift-lm/blob/bb0d5b048f02e14dbf8f2d7bb1a20911a295470a/Libraries/MLXLMCommon/UserInput.swift)
formats the supplied plain label as `[Media-1]` or `[Media-2]`; these are host text,
not intrinsic model tokens. The label must not contain `<`, `>`, `|`, `[` or `]`
or collide with screened special tokens. The pinned
[chat template](https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B/blob/919fde3d022e3f90a4716006f993938ee8c2eb97/chat_template.jinja)
preserves text/image order, producing the message-content prefix
`[Media-1]<image>[Media-2]<image>` before the task text. This source trace establishes
how labels reach the template, not model accuracy. Activation still requires a
synthetic role/order probe of actual prepared input and image binding; changing
the template, labels or ordering changes the profile.

The native invocation currently starts **after selfie acceptance**, alongside
AuraFace. It does not continuously examine the camera preview and currently
does not receive the richer context defined here. This proposal permits
AuraFace's exact cosine plus its supplied interpretation, DOB, capture date,
expected age and portrait-date context. Sequence, CoreMotion and TrueDepth
availability is explicit; the current pair-only path has no such evidence.

## Supplied facts, observations and cross-checks

The BFF supplies and authenticates contextual facts; the model reports what
the images make observable and how that relates to those facts. Inputs preserve
source and availability instead of presenting missing information as a zero,
false, empty measurement or guessed fact.

- AuraFace's score and supplied interpretation must belong to the exact same
  source pair. Carry their method/profile and interpretation-policy lineage.
  Liquid may explain visual agreement, meaningful tension or insufficient
  evidence; it must not invent an operating point from a bare number.
- DOB and capture date support the BFF's expected age of the **claimed holder**.
  They do not establish who appears in the selfie. Keep that expected age
  separate from model-estimated apparent age ranges and their limitations.
- A reliable portrait capture date can contextualize an older reference. An
  issuance date is not a portrait capture date. Unknown photo age stays unknown;
  an older-looking or younger-looking portrait alone is not a resolved conflict.
- Apparent-age ranges are qualitative estimates, not calibrated measurements.
  The model may report discrepancies with expected age and explain alternative
  causes or insufficient visibility. No automatic age-based identity rule is
  introduced by this contract.
- Any supplied sequence, motion or depth evidence needs its own attempt/source,
  timing and modality provenance. Missing modalities are explicitly unavailable.
  A single selfie cannot provide parallax, highlight motion or replay dynamics.

The invocation freezes its context before generation. If AuraFace has not
completed, its input must be explicitly unavailable; a later score cannot be
silently inserted into an in-flight report. A new context requires a newly bound
attempt/report. Supplied policy interpretation is context for a qualitative
cross-check, not permission for the model to decide identity acceptance.

## Prompt, decoder and generation controls

The prompt states an investigative goal and ordered work: inspect each input,
describe quality and features, cross-check AuraFace, reason about age context,
and ground scene indicators in supplied evidence. The feature checklist includes
eye spacing/shape, nose bridge/tip, mouth width, jawline, ears, hairline and visible
marks. These are qualitative observations, not geometric measurements or
population-norm scores.

The **expected output schema and balanced few-shot examples must actually reach
the model as separate message content**. A phrase in the instruction referring
to an absent schema is insufficient. The reviewed adapter builds messages from
the immutable bundle and then the current source-bound context/images; it does
not merely keep schemas/examples on disk for post-hoc validation. Guided decoding
and strict output validation additionally enforce the contract.

[The balanced examples](examples/liquid-prompt-examples-v2.json) cover usable
evidence, a meaningful measurement/visual conflict and insufficient evidence.
Their image descriptions are explicitly synthetic teaching material, not actual
input images or authoritative current observations. All examples use the same
schema. None is a fallback answer or a preferred default, and example prose must
not be copied as a statement about the current images. Examples with actual
photographs require separately authorized external fixtures; no real biometric
media is included in this repository.

The [pinned Liquid vision cookbook](https://github.com/Liquid4All/cookbook/blob/744c5b628a27adb4f219ff4a1d11e3d70259b369/guides/lfm25_vl_image_understanding.ipynb)
informs explicit image references, bounded tasks, processor/chat-template use and
structured output. This is our proposed task design, not a publisher-validated
face/PAD recipe. The [publisher model card](https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B#model-details)
lists general text settings temperature `0.1`, `min_p=0.15`, repetition penalty
`1.05` (checked 20 October 2026); those are not task-specific accuracy evidence.

This profile keeps a greedy engineering baseline and freezes all choices in the
BFF-issued plan, rather than inheriting mutable runtime defaults:

| Parameter | Frozen proposed value |
| --- | --- |
| `temperature` | `0` |
| `topP` / `topK` / `minP` | `1` / `0` / `0` |
| `repetitionPenalty` / `repetitionContextSize` | `null` / `20` |
| `presencePenalty` / `presenceContextSize` | `null` / `20` |
| `frequencyPenalty` / `frequencyContextSize` | `null` / `20` |
| `seed` | `null` |
| `maxNewTokens` / `maxOutputBytes` | `2048` / `16384` |

The [pinned MLX implementation](https://github.com/ml-explore/mlx-swift-lm/blob/bb0d5b048f02e14dbf8f2d7bb1a20911a295470a/Libraries/MLXLMCommon/Evaluate.swift)
uses argmax at temperature zero; sampling filters and RNG are bypassed. Penalties
remain separate logit processors and can change that path if enabled.
The proposed guided loop instead uses greedy sampling by construction; it does
not accept these generic sampler knobs. Their disabled/null values document the
selected behavior, not fictitious parameters passed to that API. A future
adapter must pin its actual guided-loop configuration, raw-schema digest and
termination behavior before activation.
Neither greedy decoding nor the publisher preset has demonstrated best task
performance. The expanded output ceilings are provisional engineering bounds,
not hyperparameter tuning, fine-tuning, measured feasibility, latency or memory
claims. All prompt/schema/parameter changes need a new immutable profile and
BFF plan. No silent sampling changes, automatic repair generations or retry
randomization are authorized.

**Constrained decoding is an activation requirement, not an implemented feature.**
The pinned dependency contains optional `MLXGuidedGeneration` backed by vendored
xgrammar. Its [GrammarConstraint](https://github.com/ml-explore/mlx-swift-lm/blob/bb0d5b048f02e14dbf8f2d7bb1a20911a295470a/Libraries/MLXGuidedGeneration/XGrammarBridge.swift)
accepts JSON Schema, and [GuidedGenerationLoop.run](https://github.com/ml-explore/mlx-swift-lm/blob/bb0d5b048f02e14dbf8f2d7bb1a20911a295470a/Libraries/MLXGuidedGeneration/GuidedGenerationLoop.swift)
accepts prepared `LMInput` and `ModelContext`, invokes the model's preparation
path and generates greedily. The current app does not link that product, call
that loop or supply guided `GenerationComponents` to its current `TokenIterator`.
Post-generation regex/JSON parsing is not constrained decoding. Before this profile can execute,
a reviewed adapter must compile the approved raw-observation schema, wire an
actual guided generation path, add its dependency/licence/source/guard coverage,
prove compatible runtime/Metal/device execution and document the exact supported
JSON Schema subset. Grammar support
for shape/keys/enums does not establish support for every string bound or schema
keyword; the strict validator remains mandatory for the complete contract.

Formatting, key order, enum/type/length/character restrictions belong to the
approved decoder configuration and validator, not a long prompt-policy list.
Do not claim the optional dependency alone makes this contract executable.

## Observation shape and meaning

The executable [prompt input schema](schemas/liquid-prompt-input-v2.schema.json)
defines bound image descriptors and available/unavailable Aura, age and capture
context. Actual image bytes remain separate image message parts. An image
description in a synthetic example is not a substitute for current input pixels.
The general input envelope can describe a still or sequence and explicit
motion/depth observations; that shape does not activate an unqualified sequence
or sensor path in the current two-still-image adapter. Its actual supported
modalities and preprocessing remain pinned by the selected profile.

The closed [BFF wire schema](schemas/liquid-bff-observation-v1.schema.json) uses the
[common context/execution/failure schema](schemas/face-comparison-bff-common-v1.schema.json).
Its `$defs/plan` pins the BFF-selected artifact/profile/prompt, language and
parameters. The BFF stores the exact plan; the client cannot supply a different
prompt, model, budget or source pair. `operationId` is an opaque echo, not authority.

`completed` carries exactly one observation; `failed` and `unavailable` carry a
typed failure and no observation. `execution` binds the expected profile, prompt,
weights, actual adapter/runtime/OS provenance and elapsed monotonic milliseconds.
It also binds `inputSHA256`, `promptContractSHA256` and `responseSchemaSHA256`.
The wire observation is `{language: "en", report: <validated raw output>}`; the
adapter supplies language and never asks the model to generate provenance.
On unsuccessful branches those identities describe the attempted plan, not proof
that verification or inference ran. Duration includes admitted preparation,
cold verification/loading and inference, excluding time waiting for a preceding
serialized operation. Zero is permitted for early failures.

| Field | Meaning and bounds |
| --- | --- |
| `reference.qualityIssues` / `selfie.qualityIssues` | Up to four unique typed image-quality observations |
| `reference.observations` / `selfie.observations` | Up to three grounded observations per image; 1–240 characters each |
| `reference.apparentAge` / `selfie.apparentAge` | Integer `[minimum, maximum]` age range in years or `null`, with a visible basis and up to two limitations |
| `auraReview` | `supports`, `tension` or `not_assessable`, with up to three evidence statements and two limitations |
| `ageReview` | `plausible`, `raises_question` or `not_assessable`, with up to three evidence statements and two limitations |
| `captureReview.indicators` | Up to six unique named static/temporal/sensor cues, each with status, evidence and source image IDs |
| `captureReview.observations` / `captureReview.limitations` | Up to three observations and two limitations |
| `summary` | Grounded operator summary, 1–400 characters |

All other generated prose is 1–240 characters. Apparent-age range endpoints are
integers from 0 to 130, with minimum no greater than maximum. Those bounds are
representation limits, not supported-age accuracy claims. `null` explicitly
means the image does not support a useful estimate; its basis explains why.

`auraReview.relationship` is a qualitative visual cross-check, not a new score
or a conversion of cosine into a probability. `ageReview.relationship` describes
how the supplied age context and appearance relate, not an age-verification or
identity verdict. Evidence and limitations must explain these short labels;
no label independently authorizes product acceptance.

Quality codes: `blur`, `underexposure`, `overexposure`, `uneven_lighting`,
`occlusion`, `off_angle`, `low_detail`, `glare`, `partial_face`.

Static indicator codes: `screen_texture`, `moire`, `visible_bezel`, `paper_texture`,
`printed_edges`, `face_scene_inconsistency`, `possible_manipulation_artifacts`.
Each contains `status: present | absent | not_observable` and `evidence`, a
1–240-character English statement grounding the status in the supplied image,
plus exact `sourceImageIds` linking it to supplied evidence.
One indicator code may occur at most once. This is a candidate observation
inventory, not an evaluated deepfake or presentation-attack detector.

Reserved modality-dependent indicators are `motion_parallax`, `highlight_motion`,
`replay_motion`, `camera_motion_consistency` and `depth_consistency`. A claim of
`present` or `absent` needs the appropriate actual sequence or synchronized
motion/depth evidence. Without it, the report may explicitly use `not_observable`
and explain the missing input. Schema membership does not make a sensor or
temporal observation available.

`present` means the model reports visible evidence of that named cue. `absent`
means it reports no visible cue **within the supplied frame**, not proof that an
attack or manipulation is absent. `not_observable` names a limitation: crop,
resolution, occlusion or input type prevents that cue assessment. Empty lists and
omitted indicator codes mean **not reported**, never a passed quality/PAD test.
Moire, texture, compression, scene or facial-detail irregularities have benign
explanations; a model statement alone cannot establish their cause.

Supporting details are not a same-person judgment. Limitations may describe
quality, pose, coverage or missing temporal evidence. The model may investigate
visible scene/presentation/manipulation cues and explain its visible basis;
there is still no aggregate match, live/spoof, authenticity or identity verdict.
A still-image cue cannot claim measured parallax, changing highlight behavior or
replay dynamics without the corresponding sequence. Those require the sequence/sensor branch of the input contract and separate
modality qualification before activation.

The [raw output schema](schemas/liquid-prompt-output-v2.schema.json) defines six
top-level fields: `reference`, `selfie`, `auraReview`, `ageReview`, `captureReview`
and `summary`. This exact schema is both supplied to the model and used for
guided decoding/validation; the BFF wrapper constructs request/execution metadata
outside generation. The prompt bundle hashes its exact input/output schemas and
few-shot examples, rather than leaving a raw schema to an unspecified future
derivation. Language is selected by the profile, not generated binding metadata.

## Validation, failures and authority

Require strict UTF-8, no BOM, one complete object, normal generation termination,
and at most 16384 raw output bytes. Reaching the token cap is failure even if an
object happened to close. Reject unknown/missing/duplicate keys (including
escaped-equivalent keys before ordinary object decoding), wrong types, unknown
enums, repeated issue/indicator codes or notes, extra/trailing content, invalid
Unicode, nonfinite/out-of-range numbers and mismatched source/plan bindings.
Do not repair JSON, coerce types, discard invalid fields or salvage partial text.

Generated text has at least one non-space character, valid UTF-8 and the stated
decoded-character limits. Unicode is allowed; ASCII-only output is not required.
Reject control characters and invalid surrogate/encoding sequences. Bounds apply
after JSON unescaping; do not normalize or truncate invalid text into validity.
Restrict structural whitespace to JSON whitespace. Wire parsing has shared
bounds too. These format rules do not establish truthfulness, helpfulness or
semantic safety.

Semantic validation checks DOB/date arithmetic, chronological consistency,
apparent-age range order, exact image/source bindings, unique indicator names
and whether claimed temporal/motion/depth cues have actual supporting inputs.
The model cannot upgrade unavailable context to an observed fact. A schema-valid
narrative still requires evaluation for grounding and appropriate uncertainty.

Malformed/truncated/bounded-output failures use `failed` / `invalid_output` at
`output_validation`; raw/partial output never becomes an ordinary observation.
`invalid_image`, `resource_limit`, `source_mismatch` use `failed` /
`input_validation`; `model_mismatch` uses `failed` / `artifact_verification`;
`engine` uses `failed` / `inference`; cancellation uses `failed` / `cancelled` at
the actual stage. `model_unavailable` is `unavailable` / `artifact_verification`;
`runtime_unavailable` is `unavailable` / `runtime`. The present SDK serializes
operations; its legacy declared `assessment_in_progress` case is not part of
this new adapter's wire mapping. Never expose exception prose or device paths.

The BFF verifies authenticated caller, challenge freshness/use, source admission,
exact stored request/attempt/session/generation and selected profile before
admission. Cancellation, replacement, expiry and supersession fence late results;
a technical cancellation report cannot revive an abandoned attempt. Cancel and
settle generation workers before resource reuse. Retries/readback follow the
shared contract; new generation work needs a new admitted attempt. Echoed hashes,
model metadata, signatures and platform attestation do not prove inference
correctness. An outage is not a biometric mismatch.

**Model-generated prose is untrusted operator/audit content.** Render as escaped,
bounded inert text with a catalog-owned model-generated label. Do not interpret
it as HTML, Markdown, links, prompts, tool arguments, commands, policy,
authorization or a suggested final verdict. Never parse narrative into decision
logic. UI labels, warnings, accessibility copy and holder-facing recovery remain
catalog-owned; no arbitrary generated prose becomes an enrollment instruction.
The initial English profile is not silently translated or claimed localized.

Image content can influence a model adversarially. Prompt instructions are not an
injection defense. The architecture fixes the allowed schema, prompt, input
slots and output handling, isolates tools/secrets and keeps generated narrative
outside decision/instruction paths. Shape-valid output can still misdescribe an
image or contain misleading instructions. Evaluate image-borne instructions,
malformed output, hallucinated cues and semantic overclaims before activation;
constrained generation alone does not prove semantic safety.

The BFF owns whether evaluated typed quality/cue observations inform recapture,
review or other slow policy. It owns model-branch requirements, recognition/PAD
fusion and unavailable/conflicting-result behavior. Prose is display-only. This
contract specifies no fusion weights or calibrated recognition/PAD threshold.
No raw-image disclosure, embedding upload or new retention/recipient is implied.
Identity-bearing observations, raw output and media must not enter routine logs.

## Separate future capture/PAD and provenance work

The [selfie PAD proposal](liquid-pad-observation-v1.md) requires its own capture
inputs and device/evaluation evidence. Future whole-document work can ask for
apparent `physical_document`, `paper_print`, `digital_display` or `uncertain`
medium with visible basis under a separate profile; face portraits discard
necessary whole-document/scene context. Neither proposal is an active task here.

Model-inferred apparent provenance means visible clues about presentation or
recapture. It is separate from BFF-verified NFC/DG2, capture, custody, hardware,
time, IMU/depth and platform-proof receipts. Pixel interpretation cannot create
those receipts, an authenticity attestation or a definitive liveness claim.

## Examples and activation evidence

[The balanced prompt examples](examples/liquid-prompt-examples-v2.json) include
full schema-valid synthetic inputs and outputs for usable evidence, meaningful
conflict and insufficient evidence. Their dates, measurements, image descriptions
and observations are invented teaching material, not evaluation findings.

[Completed](examples/liquid-bff-completed-v1.json),
[limited visibility](examples/liquid-bff-limited-v1.json) and
[failed](examples/liquid-bff-failed-v1.json) examples contain synthetic identities,
illustrative English and invented timing, not actual model observations or
performance receipts. Before activation, prove input-role/template ordering,
actual transmission of the exact schema/examples/context bundle, guided-decoder
integration, strict parser and source bindings, cancellation, safe presentation,
complete valid-output rates, grounded usefulness, age/cross-check behavior,
injection behavior and cold/warm latency/memory on the actual target device.
No training or sampling experiment is authorized by this proposal.
