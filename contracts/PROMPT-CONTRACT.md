# Liquid prompt contract

**Engineering contract under native validation; not production qualified.**

The [profile manifest](profiles/liquid-evidence-review-v2.json) binds one coherent
bundle: [task instructions](profiles/liquid-face-interpretation-v2.prompt.txt),
[input schema](schemas/liquid-prompt-input-v2.schema.json),
[model response schema](schemas/liquid-prompt-output-v2.schema.json), three
[balanced examples](examples/liquid-prompt-examples-v2.json), the model artifact
and generation settings. These are supplied to the model as actual message
content. A separately pinned structural subset configures native constrained
decoding; the full response schema and semantic checks validate the result.

## Inputs and output

The input contains the original NFC portrait and whole supplied selfie, the
BFF-admitted Aura score and its meaning, DOB-derived expected age and available
capture context. Optional ordered selfie frames and aligned motion/depth summaries
have explicit availability and source bindings. The native input schema omits
BFF request/challenge identities, which a local camera flow cannot manufacture.
It carries the two still images plus available numeric capture measurements:
TrueDepth sample count and plane residual in metres, depth map dimensions and
timing, blink coefficients and timing, tracking duration/count, and quality data.
The measurement block binds the exact selfie hash and ARKit session clock.
Missing values remain explicit; a still depth measurement is not a frame sequence.
The native review adapter passes the bound Aura result when available. DOB context
remains unavailable until a reviewed birth-century resolver supplies it.

The response has six sections: `reference`, `selfie`, `auraReview`, `ageReview`,
`captureReview`, and `summary`. It supplies apparent-age ranges, useful visual
observations, qualified agreement/tension with the supplied Aura result, and
named scene/presentation/manipulation indicators with an evidence basis. It has
no overall identity or live/spoof verdict. The BFF owns calibrated decisions;
model narrative is bounded inert operator/audit content.

DOB century resolution and expected-age arithmetic belong to the BFF. A passport
issue date does not establish when its portrait was photographed. Unknown portrait
dates, unavailable scores, missing sensors and unobservable cues stay explicit.
The contextual review of an Aura result is dependent evidence, not independent
corroboration of that score.

## Assembly and integrity

`tools/prompt_contract.py` is an offline contract assembler/validator. It creates
a system message containing the task and full output schema, three alternating
user/assistant example pairs, then the current user message with ordered image
references and substantive context. Hypothetical example descriptions are clearly
marked as demonstrations; they never replace the current images. Bookkeeping
hashes are kept outside model text, while the full input and exact message content
each receive a SHA-256 digest. The result also binds the profile digest.

Input digests describe the exact serialization produced by this assembler. They
are adapter-level content identities, not replacements for the existing sealed
operation signature or receipt encodings. Runtime token limits, real image-byte
verification, schema-guided generation and server proof verification still need
their own integration. The offline assembler does not run inference, upload media
or claim to verify capture provenance. The native adapter validates the capture
receipt before mapping its measurements and checks source/timing bindings again.

The initial generation profile is greedy with a 2048-new-token / 16384-output-byte
ceiling. Input text has a 131072-byte ceiling and an 8192-token ceiling requiring
the actual tokenizer at integration time. These are provisional engineering bounds,
not measured latency/accuracy claims. Parameter, prompt, schema, example and
preprocessing changes require a new reviewed profile identity/digest.

## Validate and inspect

Use an isolated Python environment with the pinned `tools/requirements.txt`:

```sh
python -m pip install -r contracts/tools/requirements.txt
python contracts/tools/prompt_contract.py
python -m unittest discover -s contracts/tools -p 'test_*.py'
python contracts/tools/prompt_contract.py --input request.json --output packet.json
```

Validation covers schema shape and semantic bindings: image order, foreign Aura
sources, age arithmetic, range ordering, duplicate indicators, missing modalities
and temporal claims made from still inputs. Grammar/schema validity does not prove
observational accuracy. That requires testing the assembled packet, actual images,
model and decoder on the target device. The separate
[PAD capture contract](liquid-pad-observation-v1.md) retains the requirements for
temporal evidence and calibrated fusion.

## CoreMotion reuse

The native capture adapter consumes the shared `KenshikiMotion` package extracted
from `pulse-ios`. Its `PulseCeremonyMotionSummary` field names, units, calculations
and raw-window fingerprint remain the source format. The selfie adapter adds the
exact image/frame binding, CoreMotion window timestamps and an explicit host-uptime
proximity check. This is a bounded device-motion window beside one selfie, not a
sequence of face images. Temporal visual cues still require actual image frames.

The initial window retains at most five seconds / 300 samples at a requested
50 Hz. Collection follows the active, consented camera session and stops on
withdrawal, backgrounding, failure or capture. Only the summary travels onward;
the raw in-memory window is erased when the session retires. Motion plausibility
and its fingerprint do not authenticate hardware or prove that an image is live.

Motion acquisition also requires the explicit product Motion & Fitness grant,
using the existing Pulse request pattern. Permission state is visible alongside
the measurements. Denied, restricted and unavailable access produces no motion
measurements; no zero-valued trace is substituted.

The native review profile temporarily lowers the process-wide MLX reusable-buffer
cache budget to 128 MiB, retaining an existing lower host limit. It clears unused
buffers between prefill chunks and every 32 output deltas, synchronizes pending GPU
work before restoring the prior limit, and does not change the model, prompt,
examples, output schema or generation ceilings. Hosts sharing MLX in the same
process should account for this temporary cache-recycling effect.
