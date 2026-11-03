> Historical v3.0 review. See [the revised specification](SPEC-IDBIO-200.md) and [revision audit](revision-audit.md) for corrections and disposition, including additional existing specular-sweep source found by the swarm.

# SPEC-IDBIO-200 v3.0: implementation and engineering review

Review date: 2026-10-16. SDK HEAD: `4b407a7bc5eb14a2f5913a77cd919fcde4c11290`.
The checkout contains substantial existing uncommitted work. This review describes the
files read, including working-tree changes; it is not a review of HEAD alone. Exact hashes
of the principal local sources are in [review-checks.json](review-checks.json).
The specification hash reviewed is `b4be275b691756dfc1a5e2e15330fdd0f4c4f3243be27874849bb49091e4d630`.
This includes the earlier provisional section 1.2 and privacy edit. No additional spec
edits were made during this review.

## Decision

The combined architecture is a credible vendor-replacement direction. Existing Cadastral
analysis and the proposed models are complementary. AAMVA issuer-record checks, carrier
subject comparisons, face matching, capture evidence and server-side attempt binding
must be assessed together. Neither the code nor this review establishes that Regula or
InsightFace must remain permanently.

The draft is not yet an implementable replacement contract. Its main problems are specific:
it substitutes phone attitude for document-relative pose, describes software timestamps as
hardware-attested exposure evidence, conflates App Attest with arbitrary COSE signing,
and omits existing subject/capture bindings from its normative wire payload. Several
performance and rejection claims are hypotheses presented as guarantees.

## What already exists and should be preserved

| Path traced | Current implementation | Consequence for the proposal |
| --- | --- | --- |
| Spatial orchestration | [Cadastral prepare](../../Tools/Cadastral/prepare.py), `plan` / `assemble`, runs rectification, edges, topology, measurements, perimeter assembly, region analysis and optional material separation. [Ingest](../../Tools/Cadastral/ingest.py) checks selected capture identity and original/derivative hashes. | Reuse the evidence graph and explicit dependencies. These are host tools, not already-shipped phone inference. |
| Observed geometry | [Boundary rectification](../../Tools/CardRectification/rectify.py), `fit_boundary` / `derive_transform`, retains boundary samples, robust-fit residuals, transforms and a nominal card plane. | Keep observed irregularities separate from the fitted plane and model input raster. |
| Full-scene structure | [Region experiment](../../Tools/RegionSegmentation/experiment.py) measures native luminance/chroma/texture; [adjacency](../../Tools/RegionSegmentation/adjacency.py) accounts for every four-connected interface; [topology](../../Tools/CardTopology/audit.py) nodes edges and polygonizes enclosed regions. | Local portrait-boundary and surrounding-scene evidence need not be compressed into a jurisdiction embedding. These measurements do not yet constitute a trained alteration verdict. |
| Material observations | [Metrics](../../Tools/AppleMaterials/metrics.py), `measure`, uses all 46 score channels, selects dominant inside/outside patterns and retains both winner membership and continuous score difference. | Useful observations; regional separation on a sample is not a calibrated genuine/counterfeit probability. |
| Native capture sequence | [Frame recording](../../Sources/IdentityEvidenceApple/DocumentJourneyRecordingFrames.swift), [temporal capture](../../Sources/IdentityEvidenceApple/AVFoundationTemporalCapture.swift), and [motion collector](../../Sources/IdentityEvidenceApple/DocumentTemporalMotionCollector.swift) bind timestamps, geometry, camera-state readbacks and motion. | Existing acquisition/custody foundation; preserve gaps, clock epochs and optics transitions. |
| Tilt guidance | [Perspective measurement](../../Sources/IdentityEvidenceApple/DocumentPerspectiveMeasurement.swift) measures opposite-edge log ratios. [Controller](../../Sources/IdentityEvidenceApple/DocumentTiltController.swift) checks association, continuity, baseline and dwell. | This is projected-shape guidance, not calibrated 3D card orientation. |
| Temporal interpretation | [Analysis](../../Tools/TemporalEvidence/analyze.py), [measurement](../../Tools/TemporalEvidence/measure.py), and [review](../../Tools/TemporalEvidence/review.py) verify consumed bytes, join bracketed motion, report gaps and retain attributed review annotations. | Current luma change is unregistered image difference, not optical flow. Handling findings are reviewed annotations, not an automatic PAD verdict. |
| AAMVA submission | [Barcode payload/client](../../Packages/IdentityGateway/Sources/IdentityGateway/PulsePersonaBarcode.swift) binds operation ID, front/back capture IDs and hashes, barcode and front observations into the request; reply admission requires the request echoed by the plan to match. | Preserve those bindings when replacing Regula-produced observations. Issuer lookup is already an explicit remote exchange. |
| Phone-to-document subject | [SMS route](../../../pulse-worker/src/ssaSmsRoutes.ts) requires the submitted subject digest to match the server's checked-document operation under the installation. [Identity reduction](../../../camara-api/src/routers/identity.py), `_verdict`, requires family name plus address or DOB for a provider's agreement. | My earlier example of simply verifying an unrelated phone omitted this implemented subject comparison. |
| Phone result policy | [Enrollment phone gate](../../../pulse-worker/src/enrollmentPhoneGate.ts) pauses new dependent checks for contradiction, highest-tier Twilio risk or reported recent SIM swap. Single-provider, unavailable and not-compared outcomes do not themselves pause this gate. The current identity router explicitly does not request Vonage subscriber matching. | Record actual coverage and outcome. Two provider records do not mean two independent subscriber matches. This is source behavior, not a live-provider verification performed for this review. |
| Face admission and submission | [Depth policy](../../Sources/CaptureSelfie/SelfieDepthPolicy.swift) combines fresh unfiltered depth with expression admission. [Submission evidence](../../Packages/IdentityEvidenceFaceMatching/Sources/IdentityEvidenceFaceMatching/FaceComparisonSubmissionEvidence.swift) validates retained lineage. [Face client](../../Packages/IdentityGateway/Sources/IdentityGateway/PulseFaceAttestClient.swift) binds document operation, capture, selfie, phone run and server challenge. [Server route](../../../pulse-worker/src/nativeFaceAttestRoutes.ts) validates the assertion, consumes the challenge and checks document association. | Changing the embedder need not replace the entire admission/custody/attempt protocol. Retain these controls unless explicitly superseded with evaluated equivalents. |

## Findings and required corrections

### R1. Phone rotation is not the card's relative tilt — sections 3.2 and 4.2

Integrating the phone gyroscope gives phone rotation in its reference frame. A user can
tilt the card while holding the phone still, or move both together while keeping their
relative orientation constant. The observed diffraction depends on card/light/camera
geometry, not phone rotation alone. The existing controller deliberately uses projected
card shape and does not equate that signal with physical degrees.

Specify a relative-pose observation from tracked card geometry, calibrated camera data
where available, phone motion and uncertainty. Preserve separate phone and object movement.
Use the current one-step relative movement flow as the starting point. The proposed
5–12 degree sweep and 500 ms window remain evaluation parameters until measured.

### R2. The photometric and tremor gates need an acquisition contract — sections 3.1 and A.1.1

The recorder uses `CMSampleBufferGetPresentationTimeStamp`, a presentation timestamp;
camera exposure duration and ISO are periodic device-state readbacks. These are not
per-frame hardware-signed exposure measurements. Apple documents the presentation timestamp
and display-link timestamp with different meanings. A display-link callback is not a
measurement of photons arriving at skin. The draft needs common-clock conversion,
exposure intervals, display scheduling/scanout, rolling-shutter treatment, auto-exposure
and white-balance behavior, dropped-frame handling and measured timing uncertainty.
See Apple's [sample timestamp](https://developer.apple.com/documentation/coremedia/cmsamplebuffergetpresentationtimestamp(_:))
and [display timestamp](https://developer.apple.com/documentation/quartzcore/cadisplaylink/timestamp) contracts.

The blanket minimum synthesis latency is unsupported. At 30 fps two frames are 66.7 ms,
not 33 ms. Timing evidence can be useful, but the attack model must identify whether an
attacker controls pixels, timestamps, the app process or the challenge response. App
attestation does not turn a camera buffer into a sensor-signed observation.

Gyroscope correlation also does not by itself establish depth. For pure camera rotation,
the projective mapping is `p' ~ K R K^-1 p`, independent of scene depth. Translation and
object motion require separate treatment. Our numerical check confirms identical
normalized projections for points at two depths on the same ray under rotation. This is
a counterexample to a universal depth inference, not a test of the proposed PAD accuracy.

At 30 fps a 400 ms window has about 12 frames and only 3.2–4.8 cycles at 8–12 Hz. Specify
filter initialization/delay, actual sampling rates, phase estimation and availability
rules. OIS/vehicle immunity and a universal tremor requirement have not been established.
Evaluate mounted/stable phones and accessibility use cases rather than treating absent
tremor as evidence of fraud.

### R3. Existing retained recordings do not supply the proposed temporal bandwidth

[Journey pacing](../../Sources/IdentityEvidenceApple/DocumentJourneyPacing.swift) offers a
durable journey frame every 0.5 seconds. The in-memory ring is unpaced, but temporal
retention is opt-in and bounded. A two-fps journey export cannot reconstruct an 8–12 Hz
signal or a fifteen-frame sweep in 500 ms. This is an integration requirement, not a
fundamental limit on running the proposed algorithm live.

Define a bounded live analysis branch at the required cadence, its exact inputs and its
retained diagnostic evidence. Do not silently remove the pacing that prevents excessive
capture storage. The temporal host reader's 25 ms motion join is a display/analysis bound,
not demonstrated photometric precision.

### R4. Nominal rectification is not independent physical metrology — section 4.2

Mapping four selected corners to an ID-1 rectangle imposes the target shape. Reprojection
error on those same fitted corners cannot independently validate the boundary or physical
dimensions. Camera intrinsics constrain calibrated geometry; they do not alone resolve
absolute object size from one monocular view. A reduced-size reproduction can have the
same aspect ratio.

Keep source-pixel errors, independent boundary/pose reference measurements, lens calibration
and propagated uncertainty distinct from nominal millimetres. The Cadastral contract and
GeoTIFF exporter already make that distinction. `856 × 540` is also a rounded grid:
`53.98 × 10 = 539.8`, so the stated exact ten pixels/mm in both axes needs a coordinate
convention. This rounding issue is minor compared with the independent-measurement gap.

### R5. Embedding similarity is one observation; revision and anomaly behavior need definition — section 5.2

There is no objection to using centroids alongside Cadastral evidence. The unsupported
sentence is the universal claim that every listed alteration must fall outside the
acceptance cone. Define evaluated alteration classes, revision selection, unsupported
documents and open-set rejection. IIN identifies the issuer; it does not alone select
the correct revision among that issuer's multiple centroids.

Keep the masked classification branch and unmasked local anomaly branch linked to the
same original. State how portrait-boundary evidence reaches the final policy. Define
Canadian coverage separately: the approximately 150 US jurisdiction/revision centroids
do not specify the full US/Canadian path advertised in section 6.1.

The 307,200-byte FP32 centroid arithmetic is correct. It is only the centroid storage,
not proof of training coverage, a complete document inventory or an authentication rate.

### R6. Face replacement needs a model-specific contract — sections 4.2, 5 and 7

AdaFace is a training loss, not a ready trained model or guaranteed operating point. The
draft's margin signs and scale agree with the author's formulation, but running-statistic
updates, numerical epsilon and model provenance remain unspecified. The author's
[head implementation](https://github.com/mk-minchul/AdaFace/blob/master/head.py) is the
reference for those details. Feature norm is a learned quality proxy, not an absolute
metrological unit or a universal `0–100` output range.

The proposed RGB `/128` contract is valid if training and conversion explicitly use it.
It is not interchangeable with the author's released-checkpoint
[inference preprocessing](https://github.com/mk-minchul/AdaFace/blob/master/inference.py),
which reverses RGB to BGR and normalizes by 127.5. The current SDK embedder also has its
own baked preprocessing. Pin weights, alignment, channels, scaling, conversion, precision
and output format together; test numerical and decision parity for each deployed artifact.

A monotonic mapping of cosine 0.38 to score 500 preserves ranking; it cannot establish
FMR 10^-6. Calibrate actual weights against the relevant printed/chip portrait and selfie
domains, then version the thresholds with the model. If NIST uses IResNet and mobile uses
MobileFaceNet or a pruned network, they are different evaluated artifacts until equivalence
is demonstrated. Sharing 512 dimensions or a loss does not make face and document vectors
mutually comparable.

The portrait U-Net also needs identity-preservation evaluation, an original-image route,
and lineage for both. Architecture and a 2.1 MB target do not guarantee removal of an
overlay without changing identity-bearing detail.

Importantly, the current [embedder provenance](../../ThirdParty/FaceMatching/Provenance/pulse-face-embedder-provenance.md)
ends with an owner-held InsightFace licence note that supersedes its earlier research-only
caveat for Pulse. Do not claim this checkout is necessarily unlicensed. Confirm the actual
agreement's SDK/adopter scope separately; no contract was inspected in this review.
New provenance requirements must cover the detector, restoration and PAD weights too.

### R7. The proposed App Attest/COSE protocol is not the platform's protocol — appendix A

The SDK already separates evidence signing from App Attest registration/assertion and
binds the server challenge, payload hash and evidence-signing key. Apple assertions carry
authenticator data and a signature over the platform-defined construction. They are not
arbitrary ES256 COSE signatures issued through a general signing interface. An Apple
attestation certificate cannot simply attest an unrelated Secure Enclave COSE key.
See Apple's [server validation procedure](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server).

Choose an explicit application envelope containing the unsigned payload and detached proof,
or retain the existing receipts with a versioned payload. If an application COSE signature
is added, specify its separate key binding and the COSE `Sig_structure`, not just a
signature over payload CBOR. [RFC 9052 section 4.4](https://www.rfc-editor.org/rfc/rfc9052.html#section-4.4)
defines the signing construction. State verifier behavior for registration, challenge
consumption, replay, environment, key identity and concurrent requests.

As written, `AssertionPayload` requires `enclaveSignature.coseSign1PayloadB64` while that
COSE message contains `AssertionPayload`. No exclusion or detached construction breaks
the self-reference. The appendix needs a byte-level signing definition and test vectors.
Platform attestation, application inference and physical sensor provenance remain distinct.

### R8. The appendix does not yet encode the combined acceptance policy

The mandatory payload lacks the existing front/back capture identifiers and hashes,
portrait derivation, AAMVA response binding, phone subject/result binding, model digest,
calibration/policy identity and Cadastral evidence reference. A single session ID and
custody-chain hash do not specify these links or how the server verifies them.

The reproduced Draft-07 example is structurally valid with the full physical-flow bitmask,
`decision = NON_MATCH` and `cryptographicSignatureValid = false`. A negative-result payload
is legitimate; the defect is treating schema validity or a full mask as sufficient for
acceptance without a separate explicit policy. There is no face-match bit. Bit 8 also
combines OCR/barcode agreement with cryptographic verification under one name despite
their different meanings. Define decision predicates and status semantics per path.

The claimed AJV-ready JSON is currently Markdown-escaped text, has an unregistered dialect
identifier `json-schema-draft-07`, and is not a checked standalone schema. Use the standard
Draft-07 dialect URI and generated fixtures when formalizing it. The bit-depth parity
acceptance row is visibly truncated (`max` with no protocol). Code blocks need fences.
These are document defects, not production runtime defects demonstrated by this review.

The scrub bit is also temporally inconsistent with the original requirement to scrub
after signing while signing a claim that it has already happened. Define the actual order
and the buffers covered. A boolean cannot prove clearing of framework/NPU copies.
The claim-commitment construction needs an unambiguous typed encoding and domain; a public
nonce and hash do not establish a zero-knowledge protocol or guarantee hiding of predictable
identity fields. The assertion itself includes scores, norms and jurisdiction metadata,
so specify permitted derived-data disclosure rather than claiming no information egress.

### R9. Passport and mDL paths should build on explicit protocol results — section 6

The existing passport mapper distinguishes passive-authentication trust failure, data
integrity failure and individual chip protocol results. DG2 admission recomputes the digest
using the SOD-selected algorithm, supporting more than SHA-256. The draft's abbreviated
BAC/PACE key derivation and universal SHA-256 wording should defer to the actual selected
protocol and document algorithms. Declare trust-anchor updates, revocation and unsupported
algorithm policy.

AA/CA support varies. Preserve succeeded, failed, unsupported and not-performed states;
declare which credential paths require successful anti-cloning evidence. Do not convert
passive authentication into a chip-possession claim. This distinction follows the
[ICAO validation roadmap](https://www.icao.int/icao-pkd/epassport-validation-roadmap-tool-system-requirements).

For mDL, specify document-signer certificate validation to a trusted IACA, MSO validity,
issuer-signed item digests including the portrait, device-key binding and session-transcript
authentication. IACA is the trust anchor, not a shortcut for every issuer signature. State
the selected engagement/platform profile and supported device-authentication mechanisms.
Apple's [Wallet verification procedure](https://developer.apple.com/documentation/passkit/verifying-wallet-identity-requests)
describes request transcript and element-digest validation. No complete mDL reader was
located in the Sources/Packages paths searched; do not infer one from passport support.

For optical front/back comparison, define field normalization, OCR confidence and unreadable
outcomes. Exact normalized equality may be a policy, but perfect OCR recovery is not a
guarantee. Keep AAMVA service verification distinct from local PDF417 syntax/parity.

### R10. NIST section and release matrix require artifact-specific gates — sections 7–8

The current NIST general specification calls for Ubuntu 24.04.3 and g++ 13.3.0/C++20
link compatibility; timing is on Gold 6140, with other hosts listed. The draft fixes
22.04, C++17 and Gold 6254. Pin the actual submission documents/harness revision and
build against them. Single-thread options alone are not a fork-safety receipt.
[NIST general requirements](https://pages.nist.gov/frvt/api/FRVT_common.pdf).

The current 1:1 timing limits are median 2,000 ms/image extraction and 0.1 ms matching;
the proposed P99 150 ms is an internal target. The sample only uses `faces[0]`, leaves
eyes empty, allocates an all-zero template and returns success with inference in comments.
It also lacks a versioned template/error encoding, exact-length/finite/norm checks and
safe float decoding. NIST requires multiple-image handling and explicit failed-template
matching behavior; this is a scaffold, not a normative completed extractor.
[NIST API](https://pages.nist.gov/frvt/api/FRVT_ongoing_11_api.pdf),
[official header](https://github.com/usnistgov/frvt/blob/master/11/src/include/frvt11.h).

The listed 15.3–32.8 MB model subtotal adds correctly, but excludes runtime libraries,
OCR/barcode/NFC code, trust material, conversion/compiled assets and peak RAM. Measure
installed size and latency on named devices; do not label a model-weight subtotal as the
total SDK binary footprint.

Define false acceptance AND genuine-user rejection, failures to acquire, time to complete,
coverage, device/lighting populations, supported document revisions, attack strata and
confidence intervals. Face PAD, document alteration/reproduction and digital injection
need distinct denominators. Whole-flow tests must exercise correlation and missing-service
paths. A 99.2% rejection target without the genuine rejection rate and tested attack
distribution is not a useful release gate. A “Top-50” target cannot be inferred from an
IJB-C score alone. NIST matching evaluation remains separate from PAD and end-to-end proofing.

## Concrete revision sequence

1. Retain the combined architecture and map its evidence graph into the existing capture,
   document, face and phone contracts. Make AAMVA/CAMARA outcomes and recovery explicit.
2. Rewrite sections 3–4 as measurable acquisition/relative-geometry requirements. Separate
   implemented observations, proposed algorithms, provisional thresholds and measured results.
3. Define model artifact/provenance/preprocessing contracts and preserve Cadastral's unmasked
   spatial branch. Scope document revisions, phone platforms and credential paths explicitly.
4. Replace appendix A with an unsigned payload plus platform-appropriate detached proof,
   exact session/evidence bindings, verifier policy and machine-readable test vectors.
5. Repair the NIST scaffold and release matrix. Evaluate vendor removal independently for
   each capability, then validate the combined operating point and physical capture flow.

This sequence does not require discarding the proposed models, the current spatial code,
or the existing external checks. It makes their integration reviewable and testable.

## Verification performed and remaining limits

Read the draft end to end and traced the source paths above, including the actual phone
subject policy and server face route. Consulted primary Apple, NIST, AdaFace, ICAO and COSE
references. Ran [review_checks.py](review_checks.py): schema counterexample, pure-rotation
depth counterexample, bitmask/arithmetic checks and source hashes. The script uses existing
local NumPy/jsonschema and reads the spec; it does not modify it.

No SDK source changes, full builds, model training, biometric benchmark, provider calls,
device installation, physical attack trial, commit or deployment were performed. No raw
capture/PII datasets were opened or copied into this review. These results establish draft
and integration findings, not achieved fraud rejection, calibrated confidence or a live
service-state audit. The prior provisional spec edits remain unchanged for the next iteration.
