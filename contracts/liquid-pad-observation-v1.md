# Liquid selfie PAD observations: proposed separate task

**Status: DESIGN STUB; input contract unresolved.** This is a separate future
selfie presentation-attack/manipulation investigation task, not part of the
[pair-interpretation profile](liquid-bff-observation-v1.md). It defines no active
model profile, frozen prompt, executable wire schema, accepted sampling recipe,
fusion weights, trained detector or deployment authorization.

The current implementation receives two still images after selfie acceptance:
an NFC-derived reference portrait and a selfie. It does not run continuously
during capture and supplies no ordered capture sequence, timing, IMU or depth
stream to the vision model. Do not represent that call as this proposed task.

## Intended observations

The model may inspect the complete supplied selfie frame, including physical
environment outside the face, for visible presentation or manipulation cues.
A dedicated capture sequence may additionally expose temporal cues. Investigation
is useful even when no definitive conclusion is possible: the result reports
observations, visible basis and unavailable evidence, not `live`/`spoof`, an
identity match, authenticity or a calibrated probability.

Proposed named static indicators include `screen_texture`, `paper_texture`,
`moire`, `visible_bezel`, `printed_edges`, `face_scene_inconsistency` and
`possible_manipulation_artifacts`. The future sequence profile may add
`highlight_motion`, `parallax` and `replay_dynamics` only when its inputs support
the corresponding observation. A still-image report must not infer motion or
timing from imagined frames.

Each observed indicator should have `present`, `absent` or `not_observable`
status, bounded plain-English visible basis and exact frame/interval references.
The final enum/schema is not frozen until the input contract is defined.
`absent` means no named cue was visible in the supplied evidence, not that an
attack is absent. `not_observable` identifies missing visibility or modality;
unreported cues do not silently become absent. A moire pattern, suspicious edge,
texture or scene inconsistency can have benign causes. General VLM capability
does not establish a qualified deepfake/manipulation or presentation detector.

## Input contract that must be settled first

- Define whether an attempt supplies one still, an ordered still sequence or
  video; define the exact frame selection and whether the whole captured frame
  is retained. A face-only crop can remove attack/environment clues.
- Bind every frame to the capture attempt, source hash, order and orientation;
  record authenticated producer/custody evidence independently of model output.
- Specify frame timestamps, clock domain, intervals, tolerated gaps and
  synchronization. A claimed temporal cue needs enough actual samples to
  support it; suitable duration and sampling cadence remain to be evaluated.
- Bound frame count, dimensions, total encoded bytes, decode cost and model
  image-token/context usage on the target device. These limits are undecided;
  no arbitrary current-pair bounds establish sequence feasibility.
- Define any challenge and available physical sensor inputs. The model cannot
  claim IMU, TrueDepth or other signals that were not supplied. Bind separate
  sensor observations to the same attempt with their own calibration, timing,
  modality support and unavailable states.
- Define cancellation, stale-frame exclusion, retake, resource lifetime and
  camera permissions; distinguish capture-time processing from a later review.

The existing face-pair context schema is not reused as if it already specified
this sequence. A separate input/evidence contract must preserve the actual
capture and temporal relationships before a PAD prompt/profile can be frozen.

## Policy, display and validation

The BFF owns fusion with any independent embedding, IMU, TrueDepth, challenge or
other PAD leg. It owns evaluated weights/thresholds, required observations,
unsupported-device behavior, capture guidance and final outcomes. The VLM does
not set those weights, receive the desired answer or replace a missing physical
sensor leg with narrative. This stub defines no operating point or fallback.

Bounded model prose may inform an operator/audit report when explicitly labeled
as model-generated and rendered as inert escaped text. It is not a command,
policy rule, prompt, executable tool argument or decision authority. Fixed typed
fields, constrained generation and strict validation remain required; they
bound format but cannot prove an observation truthful or immunize image input
against adversarial instructions.

Validation must cover genuine users, physical prints, display replay, relevant
manipulation/deepfake cases and benign confounders under the final capture
protocol. Keep subject/session/device separation, independent labels and exact
input/model/runtime/profile provenance. Evaluate missing cues, unsupported
modalities, attack errors, genuine-user errors, grounding, resource use and
failure behavior. Dataset access or a successful model call is not qualification.
No training or collection is authorized by this stub.

Model-inferred apparent provenance is separate from verified source provenance.
Pixels may suggest a screen, print or recapture; they cannot establish the
authenticated camera producer, NFC origin, capture time, device sensor readings
or evidence custody. The BFF resolves those through their actual verified
receipts. Asking a model for provenance does not create an attestation.
