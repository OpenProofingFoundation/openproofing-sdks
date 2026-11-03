# Unified Engineering Specification: Edge-Native Biometric and Document Verification

**Document ID:** SPEC-IDBIO-200  
**Revision:** 3.1  
**Date:** 2026-10-16  
**Status:** Engineering design draft with source-backed implementation inventory. This is not a release approval, certification or measured security-performance report.  
**Scope:** Kenshiki Identity SDK, complementary ID Cadastral analysis, and the session-bound issuer/phone/verifier integrations needed for the declared credential path.

This revision corrects the [v3.0 working draft](history/SPEC-IDBIO-200-v3.0.md) using three parallel domain reviews and integration review. See [revision-audit.md](revision-audit.md) for issue disposition and executed document checks. The production SDK and existing server contracts are unchanged by this document.

Sections 1–8 contain the architecture, responsibilities, technical contracts and acceptance requirements. [Appendix A](#appendix-a-versioned-evidence-contract-and-detached-platform-proof) contains the candidate wire protocol; [Appendix B](#appendix-b-implementation-and-migration-plan) contains implementation and migration planning. The built-versus-planned inventory remains in section 1.2.

## 1. Architecture, built capabilities and planned work

### 1.1 Intended outcome and assurance boundary

The delivery objective is to remove both Regula and InsightFace from the released dependency graph and replace them with separately releasable, open-source face and document SDKs, each supporting iOS and Android. The replacement retains and extends the existing capture, Cadastral, issuer-record, phone-subject and custody controls. Section 2.1 defines the SDK boundaries, section 8.4 defines vendor-removal acceptance, and [Appendix B](#appendix-b-implementation-and-migration-plan) supplies the implementation and migration plan; writing a wrapper around either vendor does not satisfy the objective. Cadastral spatial analysis and the proposed learned models are complementary. The decision concerns a complete, bound verification attempt; it does not require any one component to prove the entire identity claim independently.

The intended chain is: source-linked document capture → field/portrait derivation and spatial/material observations → issuer-record or cryptographic credential verification → admitted present-human face comparison → phone possession and available subscriber-to-document comparison → authenticated, fresh server decision. Processing can overlap, but the final decision MUST bind the exact inputs/results and applicable policy. Issuer lookup, face matching and phone evidence have different claims and failure modes; correlated observations MUST NOT be multiplied into a confidence score without supporting evaluation.

Regula and InsightFace have separate implementation and cutover tracks toward the same required end state: both removed. Existing controls remain applicable until a versioned replacement assumes their responsibilities. Separate cutovers allow each track to finish with evidence; permanent vendor fallback is not the completed plan. Public repository creation, publication and production promotion are implementation milestones, not actions performed by this document revision.

### 1.2 How to read implementation status

The matrix below answers **what is already built versus what is planned**. “Built” means source implementation was located and inspected in this checkout; it does not mean shipped, currently installed or empirically validated. Each release evidence record MUST separately identify source revision/dirty state, executable artifact, runtime test, adopter integration, installation and physical/independent evaluation. A historical test note is attributed as historical and MUST NOT be reported as a new test run.

| Capability | Already built / current source | Planned change | Evidence boundary on 2026-10-16 |
| --- | --- | --- | --- |
| Native document acquisition and custody | [Frame recording](../../Sources/IdentityEvidenceApple/DocumentJourneyRecordingFrames.swift), [temporal capture](../../Sources/IdentityEvidenceApple/AVFoundationTemporalCapture.swift), [motion collector](../../Sources/IdentityEvidenceApple/DocumentTemporalMotionCollector.swift) | Add declared live-analysis cadence and replay contracts for proposed detectors | Source inspected; no fresh iOS build, installation or physical trial in this revision |
| Sequential tilt guidance | [Perspective measurements](../../Sources/IdentityEvidenceApple/DocumentPerspectiveMeasurement.swift), [tilt controller](../../Sources/IdentityEvidenceApple/DocumentTiltController.swift) | Reuse guidance; add independently evaluated relative-pose/physical decisions where required | Built 2D projected-shape logic; not calibrated physical degrees |
| Card pose and specular measurements | [Pose math](../../Sources/IdentityEvidenceApple/DocumentCardPoseMath.swift), [sweep measurements](../../Sources/IdentityEvidenceApple/DocumentSpecularSweepFrames.swift), [curve features](../../Sources/IdentityEvidenceApple/DocumentSpecularSweep.swift) | Integrate approved calibrated profiles and evaluate attack/genuine behavior | Built measurement code; no authenticity performance or deployed calibration established here |
| Sensor calibration and liveness policy | [Calibration contract](../../Sources/IdentityEvidenceApple/DocumentLivenessSensorCalibration.swift), [capture policy](../../Sources/IdentityEvidenceApple/DocumentLivenessCapturePolicy.swift) | Obtain measured device/camera/light calibrations and approved thresholds | Host-supplied contracts exist; SDK supplies no universal calibration lookup |
| ID Cadastral spatial pipeline | [Orchestration](../../Tools/Cadastral/prepare.py), [ingest](../../Tools/Cadastral/ingest.py), [regions](../../Tools/RegionSegmentation/experiment.py), [topology](../../Tools/CardTopology/audit.py), [material metrics](../../Tools/AppleMaterials/metrics.py) | Preserve native evidence; implement/evaluate useful mobile operations and anomaly decisions | Built Python host analysis; mobile parity and automated fraud detection not demonstrated |
| Temporal host inspection | [Temporal analysis](../../Tools/TemporalEvidence/analyze.py), [review annotations](../../Tools/TemporalEvidence/review.py) | Add evaluated automated handling/photometric decisions | Built retained-frame inspection; visual annotations are not automatic PAD |
| Selfie depth/expression admission | [Depth policy](../../Sources/CaptureSelfie/SelfieDepthPolicy.swift), [admission policy](../../Sources/CaptureSelfie/SelfieAdmissionPolicy.swift) | Preserve or explicitly replace with evaluated device-specific alternatives | Built engineering controls; no certified/calibrated PAD result claimed |
| Face inference, route policy and lineage | [Current face engine](../../ThirdParty/FaceMatching/Sources/FaceMatching/FaceMatch.swift), [route policy](../../Packages/IdentityEvidenceFaceMatching/Sources/IdentityEvidenceFaceMatching/FaceComparisonRoute.swift), [submission evidence](../../Packages/IdentityEvidenceFaceMatching/Sources/IdentityEvidenceFaceMatching/FaceComparisonSubmissionEvidence.swift) | Train/license and qualify replacement weights, conversion and thresholds | Built comparator and InsightFace-derived model path; historical provenance/tests do not establish replacement accuracy |
| AAMVA operation and capture binding | [Barcode client/payload](../../Packages/IdentityGateway/Sources/IdentityGateway/PulsePersonaBarcode.swift) | Replace observation supplier while retaining field/capture/operation binding; add composite receipt adapter if selected | Built request/reply checks; live service availability and jurisdiction coverage not revalidated |
| Document-bound phone subject comparison | [Checked-subject route](../../../pulse-worker/src/ssaSmsRoutes.ts), [identity comparison](../../../camara-api/src/routers/identity.py), [phone gate](../../../pulse-worker/src/enrollmentPhoneGate.ts) | Publish path-specific coverage/profile and composite receipt bindings | Built source behavior; unavailable/single-provider handling remains explicit; no new live-provider evidence |
| Face request and evidence attestation | [Face client](../../Packages/IdentityGateway/Sources/IdentityGateway/PulseFaceAttestClient.swift), [platform binding](../../Sources/KenshikiIdentity/AppleAppAttestProvider.swift), [server route](../../../pulse-worker/src/nativeFaceAttestRoutes.ts) | Candidate composite payload and adapter in appendix A | Existing contracts built; new schema/protocol is documentation and offline fixtures, not a deployed API |
| Passport cryptographic adapter | [Observation mapper](../../Packages/IdentityEvidencePassport/Sources/IdentityEvidencePassport/PassportObservationMapper.swift), [authenticated DG2 portrait](../../Packages/IdentityEvidencePassport/Sources/IdentityEvidencePassport/PassportAuthenticatedPortrait.swift) | Reuse selected protocol results and trust governance; qualify exact release path | Built adapter; no NFC/accepted server receipt revalidated in this revision |
| SCRFD-Doc, custom AdaFace replacement, document centroids, U-Net and MobileViT-CDCN | No release artifact or evaluation receipt for these proposed replacements established in this review | Implement/train/license, pin manifests, qualify devices and measure operating points | Planned model artifacts; architecture names and asset budgets are not delivered weights |
| Active display photometry, tremor and color OVD classification | Acquisition/specular observations exist as above; proposed classifiers not established | Freeze methods, timing/pose contracts, calibrations and attack evaluation | Planned defenses; no immunity or universal latency guarantee |
| mDL reader | No complete reader established by the scoped source search | Select local/Wallet profile; implement trust, transport, element and device authentication | Planned path; passport code is not mDL support |
| NIST Linux submission | No conforming replacement library or official result established | Build and validate actual Track A artifact and submit under current requirements | Planned; incomplete v3.0 scaffold is retired |

The [face-method note](../methods/face-matching.md) and [model provenance](../../ThirdParty/FaceMatching/Provenance/pulse-face-embedder-provenance.md) describe historical software/parity receipts and their limits. They were not rerun here. Source anchors describe the working tree, which contains unrelated edits; the revision audit pins relevant files. No complete catalogue of all capabilities in the repository is claimed.

### 1.3 Normative conventions and accountable ownership

MUST, MUST NOT, SHOULD and MAY describe requirements on a future implementation claiming conformance to this revision. They do not assert that the requirement is already implemented. Every claimed capability MUST reference its matrix status, artifact and execution evidence. Each required release gate names an accountable role; a release record MUST identify the responsible person and independent reviewer. An unresolved critical parameter or missing receipt leaves that path's release gate open.

Standards are used only for their named interfaces and verification procedures. ISO/IEC 30107-3 applies to the selected PAD evaluation protocol; ISO/IEC 7810 supplies nominal document geometry; ICAO 9303 governs the selected eMRTD path; ISO/IEC 18013-5 and selected platform profiles govern mDL; AAMVA/CDS governs supported barcode/data rules. NIST FRTE evaluates its submitted face artifact. Applicable editions, amendments, platform contracts and coverage MUST be pinned before a conformance claim. Merely listing a standard is not compliance, certification or an identity-assurance-level determination.

### 1.4 Data processing and provenance invariants

| Data class | Intended handling and required boundary |
| --- | --- |
| Camera originals, portrait crops, depth and embeddings | Local inference is the default design. Define volatile processing and any explicitly authorized encrypted custody/diagnostic mode separately, with bounded lifetime, purpose, access and deletion. Existing local retention MUST NOT be described as already volatile-only. |
| Licence identity fields | Minimum necessary fields may be disclosed to the configured issuer-record service under its approved purpose and retention policy. Barcode parsing and lookup are separate operations. |
| Phone number and subscriber-comparison fields | Disclose only to the selected phone/identity adapters under their approved purpose and coverage. Possession, subscriber agreement, SIM swap and risk remain distinct observations. |
| Passport/mDL protocol material | Minimize by selected reader/verifier profile. A server-terminal NFC protocol or Wallet presentment may require server processing; declare the exact exchanged fields, including any portrait disclosure. |
| Categorical outcomes, hashes and receipt references | Candidate appendix-A envelope permits only declared results and lineage. Treat these as sensitive derived metadata, not anonymous or zero-knowledge evidence. Scores/norms/raw biometrics are absent from that envelope. |
| Model/data provenance | Pin code/data/weights and synthetic-generation dependencies, actual permission/redistribution scope, training/calibration/test separation and approval evidence. Architecture names, random initialization or consent labels alone do not establish rights or legal compliance. |

The document owner MUST maintain the processing inventory, recipients, legal/consent basis, retention, incident/recovery behavior and actual platform-copy limitations before release. Clean-up claims cover observed application-owned operations only. No statement here certifies BIPA, CUBI, GDPR or any other legal compliance; actual obligations and agreements require the responsible legal/procurement review.

### 1.5 Attack and failure model

The evaluation plan MUST state the attacker's access to originals, valid issuer data, portrait editing, physical substrates/overlays, displays, camera buffers, timestamps, app process, OS and signing/challenge interfaces. Ordinary physical presentations, software injection and a compromised trusted app/OS are separate threat classes. Platform attestation is one control, not a universal solution to all three.

Required joint scenarios include issuer-valid data with substituted portrait and consistent barcode; live attacker using their own verified number; photocopy/display/overlaminated reproduction; adaptive photometric replay; cross-attempt/capture or receipt substitution; stale or reordered requests; corrupted models/reports; and service outage/coverage loss. The phone path must distinguish possession-only from actual subscriber agreement. Genuine wear, supported revisions, stable/mounted phones and accessibility conditions belong in the genuine-user population. Test both the applicable combined predicate and missing-evidence recovery, with explicit residual risks.

## 2. Subsystems, evidence boundaries and implementation status

The tracks share suitable operators and evidence conventions. They do not share a demonstrated physical detector or one mutually comparable face/document embedding space. Track A processes submitted static face images; its results do not evaluate production capture, document authentication, presentation attacks or injection defenses. Track B combines local measurements, model outputs and the session-bound external checks in section 6.

| Stage | Track A: FRTE 1:1 submission | Track B: live face | Track B: optical document |
| --- | --- | --- | --- |
| Acquisition | Harness-supplied static images | Captured image, expression and available paired depth; proposed active photometry and motion analysis | Original image, source-linked geometry, temporal frames and phone motion; calibrated specular measurements where available |
| Alignment | Model-specific face detector and similarity transform | Model-specific detector and similarity transform | Observed perimeter plus separate fitted card plane and model-specific rectification |
| PAD and integrity | Outside this track | Existing depth/expression admission; proposed evaluated photometric and learned PAD | Existing measurement/rehost/forensic observations; proposed evaluated local anomaly, material and OVD detectors |
| Embedding | Versioned face artifact | Versioned face artifact, with explicit parity evidence if different from Track A | Separate jurisdiction/revision artifact plus unmasked Cadastral evidence; portrait enters face branch |
| Output | Harness status, template and similarity | Bound face/admission results | Bound capture, derivation, document observations and external check references |

**Current status.** Cadastral host orchestration is implemented in [prepare.py](../../Tools/Cadastral/prepare.py); source-hash admission is implemented in [ingest.py](../../Tools/Cadastral/ingest.py). These are host tools, not proof of deployed on-device execution. Native temporal recording, 2D tilt guidance, planar-pose/specular measurements and selfie depth admission have source implementations. The proposed SCRFD-Doc, document embedder, restoration network, shared MobileViT-CDCN, photometric timing classifier and color OVD classifier are proposed artifacts unless an artifact-specific release record establishes otherwise. This specification supplies no new physical-device, PAD or biometric performance result.

All capture-derived assertions MUST distinguish an observation, an inference, its policy disposition and its uncertainty or unavailable status. `MEASURED` is not synonymous with `PASS`. Reprojection consistency, a material score or an embedding similarity is not independently an issuer-authentication result. Final acceptance belongs to the combined policy, not to one physical gate.

### 2.1 SDK responsibilities and dependency contracts

The required architecture has separate open-source face and document SDKs, each supporting iOS and Android. Each capability has a versioned public API, evidence/coordinate/model contracts, conformance fixtures and native platform adapters. Optional UI remains separate from headless processing. Matching platform APIs do not imply equivalent acquisition, acceleration, calibration or security evidence. The current implementation status remains as recorded in section 1.2; proposed repository extraction and naming are in [Appendix B.1](#b1-repository-extraction-and-release-layout).

| Required component | Responsibility and public products | Excluded from its mandatory dependencies |
| --- | --- | --- |
| Face SDK | Headless face detection/alignment, embedding, comparison, quality/admission and declared PAD; optional selfie capture/UI; iOS Swift package/framework and Android library with the same conceptual contracts. A Linux FRTE adapter can consume its selected face core/artifact separately. | Regula, InsightFace-provided runtime/model artifacts, document SDK, whole identity SDK, mandatory AAMVA/CAMARA calls or product enrollment policy |
| Document SDK | Document capture, source/derivative geometry and custody interfaces, Cadastral spatial/material analysis, OCR/barcode parsing, primary portrait extraction and declared document checks; iOS and Android libraries with optional UI. Chip/mDL modules are separately scoped additions within this repository when implemented. | Regula binaries/database/licence resources, face-match SDK for basic capture/portrait export, whole identity SDK, mandatory paid issuer/phone services or product enrollment policy |
| Existing identity SDK and service adapters | Compose the independently released face/document packages with AAMVA, CAMARA, passport/mDL verification where selected, attempt binding, attestation and product/server acceptance policy | Must not reintroduce retired vendors through an adapter, reference app, packaging script or transitive dependency |

The document SDK outputs a source-bound portrait artifact/reference; the face SDK accepts that generic reference and an admitted selfie. Neither public interface exposes Regula types or InsightFace-specific model-pack identities. Shared evidence conventions use minimal versioned contracts and common test vectors. Shared foundations MUST preserve an acyclic dependency graph and MUST NOT require the product-level identity SDK for generic hashing, storage or clock injection. A new foundation package is an implementation choice, not an additional required SDK. Optional React Native wrappers MUST consume public native APIs.

A public SDK's independent sample MUST build and run its declared supported path without a Kenshiki backend account or the other SDK. Backend-assisted checks remain explicit optional adapters in the composed identity product. Native iOS and Android releases require separate artifacts and evidence; an iOS implementation cannot be labelled cross-platform merely because the Android interface is specified.

## 3. Capture evidence and proposed physical defenses

### 3.1 Trust and acquisition contract

Application capture evidence, platform attestation and sensor authenticity are different trust boundaries. An App Attest assertion binds application evidence under the platform protocol; it does not provide a hardware signature from the camera on each frame. No claim of hardware-attested optical exposure, universal anti-injection detection, or immunity to OIS, EIS or vehicle motion is made.

For each evaluated device/camera configuration, the capture contract MUST specify:

1. Pixel format, dimensions, orientation, mirroring, color attachments, camera/lens identity, lens distortion treatment, stabilization mode and camera switching behavior.
2. Frame timestamp source, clock domain and epoch; motion timestamp source; conversion procedure; observed frame intervals; timestamp discontinuities and missing samples. Clock synchronization uncertainty MUST be measured for timing-based decisions.
3. Available exposure, ISO, white-balance, focus and intrinsics metadata, its observation time and freshness. Device-state readbacks MUST NOT be relabeled as per-frame sensor exposure telemetry.
4. Bounded live analysis cadence, buffering, backpressure, thermal behavior, frame admission and required coverage. Dropped frames and analysis omissions MUST be explicit.
5. Attempt/capture identity and derivation lineage, analysis/model/calibration/policy versions, and the exact acquisition segment consumed by each result. A lens, geometry or clock discontinuity MUST terminate or reacquire the applicable baseline; it MUST NOT be bridged silently.
6. Application-owned data lifetimes, diagnostic opt-in, local evidence retention limits and erasure behavior, consistent with section 1.4. Source preservation means maintaining fidelity and lineage during the authorized lifecycle; it does not authorize indefinite production retention.

[AVFoundationTemporalCapture.swift](../../Sources/IdentityEvidenceApple/AVFoundationTemporalCapture.swift), [DocumentJourneyRecordingFrames.swift](../../Sources/IdentityEvidenceApple/DocumentJourneyRecordingFrames.swift) and [DocumentTemporalMotionCollector.swift](../../Sources/IdentityEvidenceApple/DocumentTemporalMotionCollector.swift) provide parts of that acquisition foundation. Apple's [presentation timestamp contract](https://developer.apple.com/documentation/CoreMedia/CMSampleBuffer/presentationTimeStamp) describes sample presentation time. The display-link [timestamp](https://developer.apple.com/documentation/quartzcore/cadisplaylink/timestamp) and [targetTimestamp](https://developer.apple.com/documentation/quartzcore/cadisplaylink/targettimestamp) are scheduling/display timing interfaces, not direct measurements of illumination reaching the subject or camera.

### 3.2 Live analysis and retained evidence are separate paths

[DocumentJourneyPacing.swift](../../Sources/IdentityEvidenceApple/DocumentJourneyPacing.swift) paces durable journey frame offers at 0.5 seconds; the in-memory ring is unpaced. The paced export MUST NOT be used to reconstruct high-frequency photometric or tremor evidence. A proposed high-cadence algorithm MUST declare its live input path and retain sufficient bounded replay evidence, when authorized, to reproduce its numerical result and inspect coverage. This requirement does not authorize unbounded native-frame recording or removal of journey pacing.

The existing host temporal method in [analyze.py](../../Tools/TemporalEvidence/analyze.py) measures unregistered absolute luma difference over retained frames. It MUST NOT be described as optical flow, depth reconstruction or automatic physical-handling authentication. Its motion-join bound supports that analysis workflow; it is not a measured photometric synchronization guarantee.

### 3.3 Face acquisition: existing admission and proposed active photometry

Current [SelfieDepthPolicy.swift](../../Sources/CaptureSelfie/SelfieDepthPolicy.swift) requires valid, fresh depth and combines depth with expression admission. Its engineering thresholds are not population-calibrated PAD results. The replacement MUST preserve required admission/lineage controls until an evaluated replacement and explicit policy migration supersede them. Unsupported depth on a device requires a declared evaluated alternate path or an unsupported outcome.

**Proposed photometric branch.** A server-attempt-bound, unpredictable challenge MAY drive a bounded display color sequence. The design MUST specify sequence generation, when challenges become visible to an attacker, emitted display behavior, region tracking, exposure integration, rolling shutter, ambient illumination, display scanout, auto-exposure/white-balance interactions, clipping and synchronization uncertainty. Evaluation MUST measure signal response over skin tones, glasses, display brightness, ambient lighting and device configurations.

A feature such as response lag or chromatic transfer MUST be reported with its method, units, valid range, coverage and uncertainty. An empirically selected timing threshold belongs to the versioned calibration/policy. The draft's 400 ms window and single-frame lag threshold are experimental candidates, not release defaults. At 30 fps, one nominal interval is approximately 33.3 ms and two are approximately 66.7 ms; elapsed times MUST be computed from actual timestamps.

No universal minimum deepfake latency or universal dermal red/blue ratio is assumed. A coherent prerecorded response, adaptive display replay, low-latency synthesis and an attacker able to alter application buffers/timestamps are distinct attack cases. Evaluation MUST state the attacker control actually tested. Correlation alone does not establish sensor origin or rule out all injection paths.

### 3.4 Face motion, tremor and optional ambient observations

**Proposed motion branch.** The analysis MAY compare tracked face/background motion with phone motion. It MUST separate rotational image motion, translation, independently moving objects, stabilization and tracking error. Pure camera rotation induces `p' ~ K R K^-1 p`, which is independent of scene depth; gyro correlation alone therefore cannot establish 3D facial relief. This restriction follows projective geometry; see the primary [OpenCV homography derivation](https://docs.opencv.org/4.x/d9/dab/tutorial_homography.html).

The proposed 8–12 Hz band and 400 ms observation window remain hypotheses. At 30 fps, that window supplies about 12 frames and only 3.2–4.8 cycles at the proposed frequencies. A candidate implementation MUST specify actual sampling rates, anti-aliasing, filter initialization and delay, phase estimation, confidence, required cycles and invalid-data handling before any threshold is selected. It MUST be tested on held/mounted/stabilized phones, deliberate stillness, accessibility use cases and moving environments. Absence of tremor is not, by itself, evidence of fraud.

Barometer and magnetometer observations MAY provide context. Their absence, low variance or unusual variance MUST NOT be converted to fraud by an unvalidated universal rule. Any use in acceptance requires device/environment coverage and attack evaluation. These sensors do not independently prove camera authenticity.

### 3.5 Document-relative movement and material observations

Document photometric response depends on the surface, lighting and camera geometry. Phone gyro integration estimates phone rotation; it is not the document's orientation relative to the camera. Tests MUST include card-only motion, phone-only motion and co-motion with nearly constant relative pose.

The existing [DocumentPerspectiveMeasurement.swift](../../Sources/IdentityEvidenceApple/DocumentPerspectiveMeasurement.swift) computes opposite-edge log ratios in delivered image pixels. [DocumentTiltController.swift](../../Sources/IdentityEvidenceApple/DocumentTiltController.swift) supplies association, continuity, baseline and dwell logic. These signals guide one relative movement at a time; they are not calibrated angular measurements. A replacement MUST preserve sequential guidance and explicitly handle reacquisition instead of requiring simultaneous ambiguous phone/card movements.

A separate implemented measurement route in [DocumentCardPoseMath.swift](../../Sources/IdentityEvidenceApple/DocumentCardPoseMath.swift) and [DocumentSpecularSweepFrames.swift](../../Sources/IdentityEvidenceApple/DocumentSpecularSweepFrames.swift) estimates planar pose from a nominal card model and camera intrinsics and measures predicted/observed glare behavior. Its [capture policy](../../Sources/IdentityEvidenceApple/DocumentLivenessCapturePolicy.swift) and [sensor calibration](../../Sources/IdentityEvidenceApple/DocumentLivenessSensorCalibration.swift) are host supplied and attributed. The SDK supplies no universal sensor calibration; unavailable calibration produces an unsupported result. [DocumentSpecularSweep.swift](../../Sources/IdentityEvidenceApple/DocumentSpecularSweep.swift) reports curve/alignment measurements and does not issue a counterfeit verdict. Distances inferred from an assumed card size remain conditional on that size and pose model.

**Proposed OVD branch.** Color/specular trajectories MAY augment those measurements. The branch MUST identify supported jurisdiction/revision/security-feature families, regions, relative-pose estimator, illumination assumptions, camera color processing, registration, saturation masks, coverage and uncertainty. A calibrated specular response and a diffractive response MUST remain distinct observations. A 5–12 degree sweep over 500 ms is an initial experimental candidate, not an established universal acquisition requirement.

Neither localized chromatic change nor a specular peak proves issuer origin. Genuine documents can be worn, obscured or lack the assumed feature; reproduction attacks may use reflective laminates, holographic overlays or high-resolution displays. Moiré absence/presence and flat/directional reflection MUST NOT be treated as universal genuine/counterfeit rules. These are testable candidate features within the joint policy.

## 4. Alignment, Cadastral evidence and learned material analysis

### 4.1 Facial alignment is model-specific

The proposed detector returns face boxes and five landmarks. A similarity transform maps those landmarks to the selected model's canonical coordinates and produces a model-specific tensor. This is 2D alignment, not 3D facial orthorectification or a physical measurement of facial geometry.

For a model trained to the stated 112 × 112 reference, the proposed coordinates are `[(38.2946,51.6963),(73.5318,51.5014),(56.0252,71.7366),(41.5493,92.3655),(70.7299,92.2041)]`. Detector weights, landmark ordering, handedness, pixel-center convention, interpolation, border fill, color ordering and normalization MUST be pinned together. The coordinates MUST NOT be reused with incompatible trained preprocessing merely because the output dimensions match.

Multi-face handling MUST be defined separately for production and the FRTE API role. Area/centrality ranking is a candidate heuristic, not an established subject-binding rule. The production policy MUST specify rejection/retry versus selection when multiple faces are present and preserve the selected subject's tracking/lineage; it MUST NOT silently switch subjects. The FRTE implementation MUST follow its pinned API requirements.

### 4.2 Document rectification is a nominal coordinate construction

A detector or observed perimeter supplies source-image geometry with stable corner roles. A nondegenerate homography maps a modeled planar document to an analysis grid. Mapping four input corners to a rectangle imposes that rectangle; it does not independently verify aspect, dimensions, authenticity or boundary accuracy. Known intrinsics permit pose estimation under model assumptions but do not independently establish absolute document size from a monocular image. A scaled reproduction can preserve aspect.

Use the shared document geometry contract for nominal dimensions. For ID-1, the model plane is 85.60 × 53.98 nominal mm. An 856 × 540 **model input grid** is permitted if the model manifest defines its pixel-center/edge mapping and resampling. It MUST NOT be labeled exact isotropic 10 px/mm: the nominal height times 10 is 539.8. Source resolution, observed sampling and nominal plane coordinates MUST remain distinguishable. ID-3/TD3 and TD1/other documents require their own geometry/class configuration; one passport raster MUST NOT be assumed appropriate for all e-IDs.

Rectification MUST retain original coordinates, transforms and inverses, coordinate units, output extent, interpolation and valid-data masks. Native perimeter irregularities MUST remain available separately from fitted edges/corners. Fit residuals and corner reprojection errors MUST be reported in source pixels with their fit support. Reusing fitted corners for error calculation tests internal consistency, not independent metrological accuracy. Physical accuracy claims require independent reference observations and uncertainty propagation including detector, optics, distortion, pose and reference error.

The existing [boundary rectifier](../../Tools/CardRectification/rectify.py), [nominal-coordinate decision](../../References/decisions/0039-nominal-id1-coordinate-foundation.md) and [GeoTIFF decision](../../References/decisions/0051-host-card-geotiff.md) separate observed geometry, nominal registration and durable raster packaging. Preserve those distinctions.

### 4.3 Cadastral spatial evidence remains a first-class branch

The governing [ID Cadastral contract](../../References/contracts/id-cadastral.md) treats the entire capture as a spatial scene. Pixels are located observations; feature roles are derived from geometry, appearance, texture, boundaries, topology, adjacency and context. OCR is an annotation branch, not a prerequisite for structural analysis. The native observed perimeter, including wear/damage, is evidence; an ideal rectangle is a comparison model.

For optical document paths that consume Cadastral evidence, the replacement MUST preserve these linked branches during the authorized processing lifecycle:

- Original full-scene image and integrity/provenance metadata.
- Observed perimeter and native source detail, fitted plane and linked card/GIS coordinates.
- Native luminance/chroma/texture regions, connectivity, adjacency, edge topology and local relationships across portrait, text, substrate, perimeter and surrounding scene.
- Model-specific masked/resized document classification input and its exact mask, derived from the same original.
- Unmasked local anomaly/material evidence and portrait derivations, linked back to the same capture.

The native baseline MUST first process every source pixel under the Cadastral contract. A production optimization requires an explicit equivalence/evidence record; reduced model inputs MUST NOT silently replace the full-scene evidence contract. A normalized grid does not restore lost detail. Every retained metric MUST record processing dimensions and transforms.

[Region segmentation](../../Tools/RegionSegmentation/experiment.py), [adjacency](../../Tools/RegionSegmentation/adjacency.py), [topology](../../Tools/CardTopology/audit.py) and [material metrics](../../Tools/AppleMaterials/metrics.py) implement descriptive tools. Region memberships, channel names and score separation MUST NOT be relabeled as confirmed substrate chemistry or trained authenticity probabilities. Automatic portrait-substitution/anomaly verdicts require their own evaluated implementation. The document embedding can add jurisdiction/revision evidence while unmasked local evidence assesses a portrait boundary; neither branch replaces the other.

### 4.4 Proposed portrait restoration and material PAD

A proposed restoration network MAY create a second portrait derivative. It MUST preserve the original portrait route, its masks/transforms and source lineage. Restoration can change identity-bearing pixels; no U-Net architecture or footprint guarantees identity preservation. Evaluation MUST measure genuine/impostor score shifts, attack behavior, subgroup performance and threshold decisions for original versus restored routes. Any selection or aggregation rule belongs to a frozen calibration/policy; selecting whichever route produces a match requires evaluation of that exact rule.

A proposed MobileViT-CDCN or other learned material/PAD model MUST pin training provenance, weights, modality/domain, preprocessing, conversion, runtime and output semantics. A shared architecture does not establish shared face/document calibration. Neither a model's architecture nor its numeric output establishes a probability or certification. Proposed weight sizes are budgets until compiled artifacts are measured. Learned outputs complement Cadastral observations and session binding in the combined evaluation.

### 4.5 Capture-specific release evidence and unresolved decisions

No default calibrated thresholds are introduced here. Each required physical check MUST have a versioned policy selecting supported devices/credentials, method and calibration identifiers, required coverage, thresholds, uncertainty limits, retry/unsupported behavior and a named accountable owner. A required unavailable, unsupported or inconclusive check MUST NOT silently become a pass. An alternate path requires a separately evaluated policy.

| Decision / owner role | Evidence required before use in acceptance |
| --- | --- |
| Capture engineering: cadence, bounded replay and clock conversion | On-device acquisition report with frame/motion/display timing, gaps, exposure uncertainty, thermal/load behavior and reproducible fixtures |
| Capture engineering and metrology: document pose/calibration | Attributed camera/light calibration for each supported configuration; independent pose/boundary references and uncertainty; card-only/phone-only/co-motion tests |
| PAD research and security: active photometry/motion/OVD | Frozen methods and attacker-control matrix; held-out physical/injection attacks, genuine-user failure/retry rates, confidence intervals and device/environment/accessibility strata |
| Cadastral engineering: mobile integration and optimization | Source-fidelity/coordinate/topology preservation record; explicit host-to-mobile parity or justified deviations; no assumed native-runtime coverage from Python tests |
| Biometric research: portrait restoration route | Original/restored lineage and evaluated decision parity/score changes under the actual aggregation rule |
| Product/security policy owner: unsupported and recovery behavior | Explicit credential/device matrix and tested sequential guidance; alternate paths and residual risks approved before vendor removal |

Acceptance testing MUST include genuine wear, glare, weak lighting, stable/mounted use, lenses/stabilization, issuer revisions and unsupported designs; attacks MUST include portrait substitution with valid data, overlamination, printed/display reproductions and replay/injection under explicit control assumptions. Joint acceptance and genuine-user rejection/retry MUST be measured for the complete applicable flow, including AAMVA, document-bound phone checks, face comparison and custody. Component tests diagnose failures; they MUST NOT be multiplied as independent probabilities without supporting evidence.

## 5. Layer 3: face and document embedding contracts

Face recognition and document classification may both use 512-dimensional unit vectors. They remain separately trained spaces with separate inputs, weights, class inventories, calibration and decisions. A face vector must never be compared with a document centroid. The document branch complements the unmasked Cadastral evidence graph, issuer-record response, face comparison and phone-to-document subject comparison; no component must independently establish the complete identity claim.

### 5.1 Artifact identity and training contract

AdaFace is a candidate quality-adaptive training loss, not a pretrained model, a release artifact or an accuracy guarantee. For raw face features `v`, use `q = ||v||₂` and `x = v/q` only after rejecting nonfinite features and a norm below the model manifest's numerical floor. `q` is a model-dependent learned quality proxy, not physical metrology or an identity probability. Its inference range is not universally `[0,100]`.

For AdaFace training, the proposed starting parameters remain `s = 64`, `m = 0.40`, `h = 0.333`, and `d = 512`. Define `z = clip(h(q_safe − μ)/(σ + ε), −1, 1)`, `g_angle = −mz` and `g_add = m(z + 1)`. The training recipe must pin norm clipping, stop-gradient behavior, running-statistic initialization/update, epsilon, angular clipping, augmentation and training code revision. These are training parameters; the deployed comparator uses the extracted vectors and its calibrated policy. The author's [head implementation](https://github.com/mk-minchul/AdaFace/blob/master/head.py) is a reference, not an incorporated licence grant or a reproducibility receipt for this SDK.

Each detector, embedder, PAD and portrait-restoration artifact must have a content-addressed manifest containing:

- weights and model-graph digests; architecture and training code/configuration revision; checkpoint selection and random-seed records;
- training-data inventory and access-controlled provenance; subject-disjoint training/calibration/test splits; generator and upstream asset/weight provenance for synthetic data;
- authorized use and distribution evidence for code, data and weights, including SDK redistribution, named adopter/use scope, territories, duration and any contractual indemnity;
- input colour order, range, layout, dimensions, landmark order/template, crop/warp/interpolation, image-orientation and alpha conventions; output shape, precision and normalization;
- conversion toolchain, target platform/runtime/compute-unit policy, source/deployed numerical comparisons and threshold-decision comparisons;
- policy and calibration identifiers, authorized portrait routes, unsupported-input behavior and release evidence links.

Random initialization or procedural rendering alone does not establish lawful data provenance. A consent or indemnity label does not establish compliance with all biometric or data-protection obligations. The designated legal/procurement owner must approve the actual evidence and contractual scope before shipment. This specification does not certify legal compliance. The proposed 50,000-subject training corpus is a planning assumption; sample count alone is not an acceptance criterion.

The existing [Pulse embedder provenance](../../ThirdParty/FaceMatching/Provenance/pulse-face-embedder-provenance.md) contains an owner-held InsightFace licence note that supersedes its earlier research-only warning for Pulse. No licence agreement was inspected in this review. Confirm the actual SDK/adopter scope rather than describing the existing Pulse deployment as necessarily unlicensed. This note does not clear other weights or applications.

### 5.2 Face inputs, restoration and scoring

The proposed custom-trained mobile face input remains a five-landmark-aligned `112 × 112 × 3` RGB tensor with `(pixel − 127.5)/128`. Its endpoints are approximately `±0.9961`; this is a specific preprocessing contract, not exactly `[-1,1]`. The proposed 30% low-resolution and 15% luminance-replication training augmentations are starting settings and must specify sampling, overlap, luminance conversion and interocular-distance measurement in the frozen recipe.

The upstream AdaFace released-checkpoint [inference path](https://github.com/mk-minchul/AdaFace/blob/master/inference.py) instead reverses RGB to BGR and uses normalization equivalent to `(pixel − 127.5)/127.5`. Neither that path nor the current SDK's baked Core ML preprocessing can be interchanged with the proposed custom-trained input without artifact-specific parity evidence. Preprocessing must occur exactly once.

For admitted probe/reference vectors, compute `S_face = clamp(x_probe · x_ref, −1, 1)`. Nonfinite inputs, invalid norms and incompatible model identities return an explicit error/unavailable result, never an ordinary low match score. The cosine is dimensionless; `acos(S_face)` is the corresponding angular distance if needed. Calibration must cover the actual selfie-to-printed-portrait and selfie-to-authenticated-chip/mDL-portrait domains, devices, demographic strata, ageing, lighting, occlusion and supported crop routes. Freeze thresholds before the independent test. Report false match/non-match, failure-to-acquire/extract and review/unavailable outcomes with denominators and uncertainty.

No fixed cosine, including `0.38`, establishes `FMR = 10⁻⁶`. A monotonic display mapping onto `0–1000` preserves ordering only; its version and any decision boundary must refer to a measured calibration artifact. Do not call it NIST-calibrated without a report supporting that exact artifact and claim. A MobileFaceNet/pruned/FP16 mobile model does not inherit IResNet-50 Linux evaluation results.

Portrait restoration is an optional, separately versioned derivative. Retain the original portrait reference and its binding to front capture or authenticated issuer data. Evaluate original and restored routes using genuine and impostor pairs, identity-bearing detail, printed security overlays and attacker-selected inputs. A restored route must not silently rescue a failed original comparison or compete by maximum score unless that exact routing policy is calibrated and tested. Preserve source hash, crop transform, restoration digest and derivative hash. Failure, unavailable restoration and route disagreement must have explicit policy outcomes. A 2.1 MB U-Net target is not evidence of identity preservation.

Preserve the existing [route-constrained comparison](../../Packages/IdentityEvidenceFaceMatching/Sources/IdentityEvidenceFaceMatching/FaceComparisonRoute.swift), [submission lineage](../../Packages/IdentityEvidenceFaceMatching/Sources/IdentityEvidenceFaceMatching/FaceComparisonSubmissionEvidence.swift) and [fresh depth admission](../../Sources/CaptureSelfie/SelfieDepthPolicy.swift) until evaluated replacements explicitly supersede them. Changed weights, routes, restoration, thresholds or admission rules require a new compatible policy/implementation identity; previous stored verdicts cannot silently acquire new semantics.

### 5.3 Document centroids and local anomaly evidence

The proposed classifier consumes a nominal rectified `856 × 540` raster and a revision-specific mask. The native source, observed boundary irregularities, portrait/text boundaries, surrounding scene, regions, adjacency, topology, material observations and temporal lineage remain available to the linked unmasked Cadastral branch. Record mask version and coordinates, rectification transform, original/derivative hashes, model digest and Cadastral evidence reference. Masking variable data for classification must not remove it from the alteration-evidence branch.

A signed coverage inventory must enumerate supported country, issuer, credential type, revision/security-feature variant, validity interval, centroid digest and policy. The issuer's IIN narrows issuer candidates; it does not uniquely identify a revision. Use a validated revision-selection rule and open-set rejection. Unsupported or ambiguous revisions return `UNSUPPORTED` or `REVIEW` under policy, never automatic acceptance by the nearest known centroid. Canadian coverage needs its own enumerated inventory; a proposed 150 US-centroid budget does not establish it.

For compatible document embedding `d` and supported centroid `w_c`, `S_doc = d · w_c` is a classification/conformance observation. Its threshold and ambiguity margins are fitted on independent genuine and alteration examples by revision. The classifier does not guarantee rejection of every altered background, font or substituted portrait. Specify evaluated attack classes and residual limitations. Local alteration evidence, including portrait-boundary anomalies hidden by the classifier's mask, must reach the final policy through the linked Cadastral result. Host Cadastral tools are existing analysis infrastructure; automated on-device alteration decisions remain work to implement and evaluate.

At `C = 150`, FP32 centroid storage is exactly `150 × 512 × 4 = 307,200 bytes` (307.2 decimal KB, 300 KiB), before manifests and signatures. A compact centroid store still represents a reference inventory; its size is not evidence of document authenticity or coverage.


## 6. Credential verification and external subject checks

This section specifies integration requirements, not a claim that all paths are implemented. The optical ID-1 path, the existing passport adapter, and a future mDL adapter have different evidence and coverage. A supported-path registry MUST identify country, issuer, revision, required protocols, trust material, algorithms, application/platform version, and applicable acceptance policy. Unsupported paths MUST return `unsupported`; they MUST NOT inherit the assurance of another path.

### 6.1 Physical ID-1 driver licences

1. Decode the original back PDF417 bytes using a versioned AAMVA/CDS parser. Validate encoding, issuer identification, revision-dependent field rules and dates. Retain parser version and exact consumed-byte digest. Barcode syntax is not issuer authentication.
2. Compare front observations with barcode fields using a versioned field-normalization contract. Define name/transliteration, separators, date formats, document-number rules, confidence, missing fields and OCR ambiguity separately. A low-confidence unreadable field is `inconclusive`, not automatically a mismatch or a pass. Exact normalized equality can be required where the supported profile permits it; a Levenshtein distance alone is not a universal identity rule.
3. Preserve both captures and their identifiers/hashes, original portrait lineage, unmasked Cadastral evidence, classifier/revision selection, local alteration observations and acquisition/PAD report. Restoration is a derived branch; retain its source digest and approved transform/model manifest. The comparison policy determines whether the original portrait is required alongside restoration.
4. Submit the necessary document fields to the configured AAMVA access service through the existing checked-document operation. Authenticate and retain the server response, request binding, coverage, individual field results, supplier identity, times and correlation ID. Distinguish no-record, mismatch, unavailable, unsupported issuer and verified fields. AAMVA checking establishes the returned record comparisons; it does not by itself authenticate the photographed portrait or substrate.
5. Bind the phone verification run to that checked document's subject under the same installation and operation. Preserve number-possession outcome, compared subscriber attributes, provider-specific coverage, contradiction/risk/SIM-swap outcomes and unavailable/not-compared states. A network/possession success and a subscriber identity comparison are separate observations.

Existing integration anchors are [PulsePersonaBarcode](../../Packages/IdentityGateway/Sources/IdentityGateway/PulsePersonaBarcode.swift), [SMS checked-subject binding](../../../pulse-worker/src/ssaSmsRoutes.ts), [provider identity reduction](../../../camara-api/src/routers/identity.py), and [enrollment phone policy](../../../pulse-worker/src/enrollmentPhoneGate.ts). These are source findings, not current service-availability receipts. Canadian and US coverage MUST be enumerated separately; the title or a jurisdiction centroid count does not establish either.

### 6.2 ICAO 9303 passports and compatible eMRTDs

Use the selected reader protocol's complete implementation for BAC/PACE and secure messaging; do not derive a new key algorithm from abbreviated pseudocode. MRZ check digits detect transcription errors and are not issuer authentication. Document format and supported access/cryptographic algorithms belong in the path registry.

Passive authentication verifies signed data integrity and issuer trust; chip anti-cloning mechanisms are separate. The validation report MUST identify the document signer and validated trust path, trust-bundle version/digest, algorithm identifiers, consumed EF.SOD digest, DG1 and DG2 digests and per-group verification results. Use the digest algorithm selected by EF.SOD; do not assume SHA-256 for every document. Trust management MUST define authenticated acquisition, validity/revocation handling, update cadence, stale-bundle behavior and unsupported-algorithm policy. ICAO distinguishes these checks in its [validation roadmap](https://www.icao.int/icao-pkd/epassport-validation-roadmap-tool-system-requirements).

Record BAC, PACE, AA and CA independently as `succeeded`, `failed`, `unsupported` or `notPerformed`. Never collapse absent AA/CA into successful chip authenticity. A profile claiming anti-cloning evidence MUST require successful AA or CA under its supported reader profile; otherwise it MUST state the lower assurance or route to an independently approved alternative. Failed protocol results MUST NOT be erased by fallback. The current [mapper](../../Packages/IdentityEvidencePassport/Sources/IdentityEvidencePassport/PassportObservationMapper.swift) and [chip authenticity policy](../../Packages/IdentityEvidencePassport/Sources/IdentityEvidencePassport/PassportReadObservation.swift) govern the existing adapter; this document does not silently tighten or loosen them.

Admit the reference portrait only after recomputing and verifying the complete DG2 group's SOD-selected digest and tracing the extracted portrait bytes to that group. Bind chip transcript/report, portrait extraction, live selfie, face comparison and server attempt. A trusted server credential receipt MUST validate the submitted cryptographic evidence through the selected credential adapter and record that binding. Hashing an unverifiable local report is insufficient. Do not claim an AAMVA lookup for this path unless a separately documented service actually performs it.

### 6.3 Mobile driving licences

A reader profile MUST be selected before implementation: local ISO/IEC 18013-5 engagement and an in-app Wallet presentment are not interchangeable. State transport/engagement, session transcript construction, requested namespaces/elements, device authentication mechanism, trusted IACA acquisition/update policy, validity and revocation policy, and algorithm allowlist.

Verify the document signer's certificate against a trusted IACA, the issuer authentication signature/MSO, MSO validity and every consumed issuer-signed item digest, including the portrait. Verify device authentication with the MSO-bound device key and the exact session transcript. Apple's [Wallet procedure](https://developer.apple.com/documentation/passkit/verifying-wallet-identity-requests) uses server-decrypted HPKE with a specific Apple handover transcript and ECDSA device authentication; it is not a generic NFC/BLE recipe. Use that profile only where explicitly selected.

Bind the accepted portrait bytes, credential validation receipt, challenge, requesting application, session and selfie. Preserve document and element errors; unsupported algorithms, absent portraits, expired credentials or failed issuer/device authentication cannot become success. No complete mDL reader was established by this review: the path remains proposed until implementation, trust governance, entitlement/transport evidence and interoperability/negative tests are recorded. If the selected Wallet path reveals portrait/identity elements to the verifier server, disclose that explicitly; it cannot inherit a universal local-only processing claim.

### 6.4 Availability, recovery and server policy

`pass`, `fail`, `inconclusive`, `unavailable`, `unsupported`, and `not_performed` have different meanings. Positive coverage MUST enumerate what was actually checked. Missing evidence cannot be represented by a zero score or a successful bit.

The initial policy registry MUST distinguish:

- **Current checked-in phone-policy profile:** preserves the checked-in phone gate's treatment of single-provider, unavailable and not-compared results. Contradiction, highest-tier carrier risk and reported recent SIM swap pause dependent checks. This source behavior is not a declaration that the full replacement's assurance requirements are met.
- **Combined replacement release profile:** requires the enumerated evidence for a declared credential path. If issuer confirmation or subscriber agreement is part of that profile's assurance claim, absent required coverage yields pending/retry or an approved alternative with a separately named assurance result. The profile MUST NOT report full combined assurance while missing a required service.

Profiles MUST be immutable and digest-pinned. No profile is deployable until a named owner approves its complete predicate, supported populations, service coverage, failure/retry limits and measured genuine-user impact. A user MUST be able to resume an interrupted check without accepting stale attempts or combining captures from different generations. Recovery preserves genuine contradictions and records why an earlier attempt was superseded. Outages are service failures, not biometric mismatches.


## 7. Track A: NIST FRTE 1:1 implementation requirements

This section replaces the earlier incomplete C++ scaffold. No conforming `.so`, implemented extractor, fork-safety result or NIST submission is delivered by this specification. The Track A owner must pin the actual NIST API/header, validation package and environment at submission time and implement every required interface, including required unimplemented-function behavior. See the official [API](https://pages.nist.gov/frvt/api/FRVT_ongoing_11_api.pdf) for template-role, multiple-image, eye-coordinate and return-code requirements. Do not silently ignore all but `faces[0]`.

Use a versioned template encoding with explicit length, byte order, artifact compatibility, finite-value/norm checks and failed-extraction representation. A zero-filled placeholder is not a successful extracted face. Avoid unaligned `reinterpret_cast<float*>` decoding of arbitrary byte vectors. Implement failed-template comparison and valid-score/error behavior exactly as required by the pinned API. The official [header](https://github.com/usnistgov/frvt/blob/master/11/src/include/frvt11.h) also describes initialization before process forking; actual post-fork execution must be exercised rather than inferred from environment variables.

The Track A design requires one inference thread per process and an explicit runtime/thread-pool policy covering initialization and child execution. The validation record must include reproducible post-fork extraction and comparison, observed thread counts, dependency inventory, CPU instruction support, deterministic outputs within the declared tolerance, failures/timeouts and memory use. Do not require AVX-512 without confirming the submitted environment and providing appropriate compatibility behavior. A local 36-process stress run may be an internal scenario; it is not a universal NIST-defined concurrency requirement.

The internal proposed target is template generation P99 ≤150 ms on one Xeon Gold 6254 core at 3.10 GHz, with workload, image dimensions and measurement conditions recorded. The API retrieved on 2026-10-16 lists median per-image extraction limits of 2,000 ms and matching of 0.1 ms; the NIST status page separately announces execution updates effective 2026-11-30. Submission-time published requirements govern; internal P99 and external median requirements are different checks.

NIST participation requires the agreement, required validation package, and submission/encryption process. Passing local validation is distinct from submission, NIST execution and published results. FRTE face-verification results do not certify document authentication, PAD, capture sensor provenance or the combined identity workflow. Recheck the [official FRTE page](https://pages.nist.gov/frvt/html/frvt11.html) before submission and cite any eventual report with the exact submitted algorithm identifier and date.

## 8. Footprint, evaluation and vendor-removal gates

### 8.1 Proposed mobile asset budget

These are design budgets, not measured shipping sizes. Use decimal MB consistently; record actual uncompressed and distribution sizes for each supported platform separately.

| Candidate asset | Proposed budget |
| --- | ---: |
| SCRFD-500M face detector | 0.8 MB |
| SCRFD-Doc document/portrait detector | 0.6 MB |
| Optional portrait-restoration model | 2.1 MB |
| MobileViT-CDCN face/document PAD candidate | 3.2 MB |
| Document embedder plus approximately 150 centroids | 4.1 MB |
| Mobile face embedder, architecture pending selection | 4.5–22.0 MB |
| Sum of listed candidate assets | 15.3–32.8 MB |

The asset sum excludes inference/runtime libraries, compiled-model expansion, platform slices, manifests, jurisdiction layouts, Cadastral execution dependencies, diagnostics and application integration. Measure incremental installed SDK size, downloaded size, peak working memory, cold/warm latency, sustained thermal behavior, energy and retained capture storage on named devices. No 200 MB+ vendor comparison is asserted without an equivalent measured application configuration and attribution.

### 8.2 Evaluation evidence and target approval

All numeric targets below are provisional design targets. No row currently has an execution receipt in this specification. Before a vendor-removal decision, each owner must publish the frozen protocol, exact artifact/policy IDs, test-set provenance and exclusion rules, sample sizes, point estimates and confidence intervals, failures, threshold-selection split and the signed decision. Any missing critical target or denominator leaves the affected release gate open. Results must separate source, unit/runtime validation, device installation, physical performance and independent evaluation.

| Gate / accountable role | Proposed target or required measurement | Evidence required to close |
| --- | --- | --- |
| Face local benchmark / biometric evaluation owner | IJB-C TAR ≥0.930 at false-match operating point 10⁻⁶; ≥0.965 remains a stretch target, not a promised rank | Frozen benchmark protocol, weights/data rights, subject-disjoint calibration, official splits and aggregation, nonmated/mated counts, uncertainty and failures. IJB-C is a proxy, not a NIST result. |
| Deployment-domain face performance / biometric evaluation owner | Select and approve FMR/FNMR, acquisition failure and review limits per supported portrait/capture route before test | Printed/chip/mDL portrait versus supported live-selfie devices and demographic/quality strata; original/restored route analysis; deployed precision and policy tested. Rare-event claims require adequate evidence; zero errors on a small set cannot establish 10⁻⁶. |
| Track A implementation / NIST owner | Internal P99 extraction ≤150 ms; comply with submission-time API | Build/runtime provenance, pinned official harness output, one-core thread/fork evidence and exact tested library; publication is separately recorded. |
| Numerical/input parity / mobile and NIST owners | Set model-specific tensor/vector/score tolerances and permitted boundary-decision discrepancies before test | Same decoded inputs across source/Linux/Core ML artifacts, orientation and channel fixtures, supported 8/24-bit formats, valid grayscale handling, malformed/nonfinite inputs and threshold-adjacent cases. Grayscale and colour are not assumed to yield identical identity scores. |
| Geometry / capture-metrology owner | Proposed ≤0.25 mm equivalent independent boundary error under evaluated 0–40° poses | Independent measured reference, source-pixel residuals, scale uncertainty and camera/pose conditions. A nominal fitted rectangle cannot validate its own physical dimensions. |
| Document attacks / document evaluation owner | Proposed ≥99.2% rejection for the declared print/replay/font-edit inventory | Freeze issuer/revision coverage, genuine rejection/review limits and sample plan; report per-attack and per-revision rates with confidence intervals. Include portrait substitution using issuer-valid data and consistent barcode, high-quality reproductions, OVD overlays and unsupported revisions. Evaluate joint policy with Cadastral evidence, AAMVA and phone subject binding. |
| PAD / attack evaluation owner | Proposed APCER ≤1% per defined presentation-attack instrument species; jointly approve BPCER and nonresponse limits | Document the ISO/IEC 30107-3 edition, protocol, instruments, devices, conditions and independent report when available. Report face/document results separately. “Level 1–3” has no defined meaning here until a named scheme is selected. Test digital injection separately with attacker privileges and session/challenge controls stated; do not label injection testing alone ISO PAD compliance. |
| Whole-flow identity / security and product owners | Approve maximum attack acceptance, genuine rejection/review, completion/latency and unavailable-provider limits before blind test | Joint attempts binding the applicable source evidence: original front/back and issuer response for optical ID-1, authenticated credential receipt for chip/mDL, plus portrait, admitted human, phone-to-document subject comparison, capture provenance, challenge and server decision. Test correlated bypasses, valid-data portrait substitution, injection/replay, provider contradiction/unavailability and retries. Do not multiply component error rates as though independent. |
| Footprint / SDK release owner | Candidate asset budget 15.3–32.8 MB; device budgets selected before test | Shipping artifact inventory and named-device performance receipts, separately for every adopting app/build. |
| Provenance / legal-procurement and model owners | Complete approved rights/provenance manifests for all shipped models/data dependencies | Actual agreement/scope review and asset digests, including detectors, synthetic generators, restoration and PAD. No inference from architecture name or a code licence. |

### 8.3 Existing vendor responsibilities and replacement disposition

The following is an inventory of the configured adapter, not evidence that every requested vendor check executed or worked at a measured operating point. Before Regula removal, the release record MUST expand it into a per-check keep/replace/not-applicable/retire matrix, with coverage, responsible implementation, outcome semantics and evaluation evidence. A centroid alone does not supply the responsibilities below. The replacement may combine Cadastral, models, issuer/phone services and other SDK operations; one-for-one replication of vendor internals is not required.

| Existing responsibility / source | Proposed disposition and remaining gate |
| --- | --- |
| OCR, document classification and field observations: [observations](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaDocumentObservations.swift), [printed fields](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaPrintedFields.swift) retain allowlisted fields, original/alternative values, source/page/locale/probability, validity and cross-source findings | Define the OCR field/locale/date inventory, uncertainty, alternatives and reconciliation. The planned OCR/classifier covers only declared cases; jurisdiction similarity supplies neither text extraction nor field validity. |
| Prepared-card versus full-scene analysis: [reader](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaDocumentReader.swift) recognizes prepared document then full photo under separate retained reports of one original; prepared supplies fields/classification and full photo supplies authenticity | Preserve distinct branch inputs and report lineage. A missing/failed full-scene analysis cannot be replaced silently by prepared-card authenticity. The new engine need not duplicate vendor calls but must preserve explicit failure semantics. |
| Primary portrait extraction: [mapping](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaInspectionMapping.swift), [portrait contract](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaPortrait.swift) select the primary page portrait and validate bytes, dimensions, hash and provenance | Define primary selection, output encoding, ambiguity/absence/budget/error behavior for SCRFD-Doc or another extractor. Restoration stays a linked optional route, not a substitute for original extraction provenance. |
| Portrait-region geometry and retained reference: [geometry](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaPortraitGeometry.swift), [mapping](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaPortraitMapping.swift), [resolver](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaPortraitResolver.swift) bind same-result/page region/raster and reject ambiguous or mismatched custody | Specify new source-coordinate transforms and exact report/reference admission. Existing vendor rectangles are not assumed already registered to original pixels. |
| Secondary/ghost-portrait comparison findings: [secondary findings](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaSecondaryPortraitFindings.swift), [current contract](../../Packages/IdentityEvidenceRegula/CONTRACT.md) retain distinct findings without rewriting vendor failures | No complete proposed secondary/ghost method is defined yet. Implement/evaluate it or explicitly retire the named check under the reviewed coverage policy. Primary face matching and masked classification do not establish equivalence. Separate ghost-image extraction is not claimed as an existing capability. |
| Authenticity categories and unknown findings: [inspection setup](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaInspectionSetup.swift), [finding mapping](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaAuthenticityFindings.swift) request selected image/OCR/MRZ/barcode/photo/security/liveness checks and retain types, statuses, diagnoses and geometry | Enumerate selected replacements and unknown/not-performed handling; configuration flags do not prove a check ran. Do not fabricate Regula codes for new engines or map every unavailable result to a similarity pass. |
| Document liveness observations: [liveness projection](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaDocumentLiveness.swift) distinguishes depth, screen/electronic-device, OVI/laser-image, barcode-background, copy, dynamic-print and geometry categories, preserving failure/disabled/unreported/unknown states | Declare which Cadastral/specular/PAD operations supply each retained claim and which vendor categories are unsupported or retired. Measure actual attack/genuine rates; an architecture name supplies no equivalence. |
| Export compatibility and decision ownership: [observation export](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaObservationExport.swift) supports strict default v2 and opt-in v3 metadata/regions; the reader records authenticity/liveness failures without itself refusing the reading | Preserve current observe-versus-refuse ownership until a separately versioned policy changes it. Define a new observation adapter/server negotiation rather than silently activating new phone-side rejection or forging vendor observations. |
| Model/resource integrity and operation recovery: [configuration](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaAnalysisConfiguration.swift), [execution gate](../../Packages/IdentityEvidenceRegula/Sources/IdentityEvidenceRegula/RegulaExecutionGate.swift) enforce resource/config identity, leasing and bounded failure/cancellation handling | Vendor lifecycle mechanics may disappear, but replacement artifact integrity, bounded execution, cancellation, recoverability and report-before-export custody require explicit contracts and tests. |

In this configured reader, Regula's face API, backend/online recognition, multipage and double-page spread are disabled by the inspection setup. They are not claimed existing responsibilities to replace for this path. Passport NFC and proposed mDL are separately owned paths. InsightFace replacement scope includes the actual detector/embedding artifacts and preprocessing licences/contracts, while route policy, admission, comparison and custody can be retained. Record each adopting application's exact dependency scope.

### 8.4 Vendor-removal acceptance criteria

Removal of both Regula and InsightFace is the required outcome. Their cutovers are separate engineering/release milestones, not a decision to leave either vendor permanently embedded. For each removal, document which existing responsibilities the combined replacement assumes, any unsupported coverage and the explicit fallback policy. Run a blinded, representative comparison of complete attempt outcomes at predeclared thresholds, together with component diagnostics to explain failure modes. Benchmarking existing and replacement engines must use lawfully available inputs and a defined data-handling protocol.

Close shared custody/protocol, model-specific accuracy, joint attack, genuine-user performance, integration and provenance gates before promotion. Acceptance MUST identify the exact independently released SDK packages, source/artifact provenance, each adopting application's integrated artifact, installation and physical acceptance evidence. A document approval or green unit test does not establish installed-device or physical acceptance. Unmet critical gates block promotion of that path; they do not establish that the architectural direction is invalid. Implementation and cutover sequencing are in [Appendix B](#appendix-b-implementation-and-migration-plan).

The required final state is two independently released capability SDKs with iOS and Android support for their declared scope; no shipped runtime, transitive package, model loader, bundled asset or default network download requires Regula or InsightFace; identity composition and adopting releases consume the replacement packages; applicable quality, security and rights gates have evidence; and public source/package installation is reproducible. Disabling a still-shipped vendor through a feature flag does not satisfy removal. Historical reports retain their original identities through bounded readers that do not load retired engines; old comparisons MUST NOT be reinterpreted as replacement-model evidence.

## Appendix A. Versioned evidence contract and detached platform proof

### A.1 Scope and compatibility

The candidate `SPEC-IDBIO-200-v3.1` contract is a proposed iOS integration profile. It is not a current exported SDK API or an instruction to migrate existing adopters. The existing [face client](../../Packages/IdentityGateway/Sources/IdentityGateway/PulseFaceAttestClient.swift), [App Attest representation](../../Packages/IdentityGateway/Sources/IdentityGateway/PulseAppAttestAssertion.swift), [evidence-signing payload](../../Sources/KenshikiIdentity/EvidenceSigningPayload.swift) and [evidence-to-platform binding](../../Sources/KenshikiIdentity/AppleAppAttestProvider.swift) retain their current byte contracts. A deployed change requires versioned SDK/server negotiation, cross-language vectors, adopter validation and a retirement plan for old contracts. No new Android/StrongBox equivalence is asserted; Android needs its own reviewed platform proof and server profile before deployment.

App Attest authenticates an application request using a registered platform key. It does not provide an arbitrary COSE signing API and does not attest the truth of model outputs or hardware-sign camera exposure. Local evidence signing and platform attestation remain separate controls. If application COSE is introduced later, its independent key registration/binding and RFC 9052 `Sig_structure` MUST be specified; an Apple certificate MUST NOT be relabelled as attestation of an unrelated evidence key. [Apple validation](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server), [COSE signing construction](https://www.rfc-editor.org/rfc/rfc9052.html#section-4.4).

### A.2 Exact signed bytes and envelope

The new candidate uses an unsigned JSON payload transported as an exact UTF-8 string and a detached native App Attest object. The payload MUST NOT contain its own proof or any hash of a containing signature, avoiding recursive signing. The candidate envelope has precisely:

```text
{
  payloadJson: <exact UTF-8 JSON text>,
  challenge: <canonical unpadded base64url of 32 server-random bytes>,
  appAttestAssertion: {
    keyId: <platform key identifier>,
    assertionObject: <canonical unpadded base64url of native assertion bytes>,
    clientDataHash: <canonical unpadded base64url of the 32-byte hash below>
  }
}
```

For this candidate only:

```text
clientData = UTF8("kenshiki:edge-verification:v3.1")
             || 0x00 || UTF8(envelope.challenge)
             || 0x00 || UTF8(envelope.payloadJson)
clientDataHash = SHA256(clientData)
```

The server independently recomputes the hash from received bytes and verifies the platform proof against the registered key. It MUST NOT parse and reserialize before computing this hash. `keyId` uses the platform's opaque key identifier representation; the other encoded binary fields above use canonical base64url. A candidate UTF-8 payload has no BOM, duplicate keys, invalid Unicode or non-finite numeric values. Unknown fields, versions and unsupported profile IDs are rejected. All integers are limited to the exactly representable JSON range, and generation/revision MUST be positive safe integers. The envelope MUST be bounded to 65,536 UTF-8 bytes, `payloadJson` to 32,768 UTF-8 bytes and parsed payload nesting to 16 levels before expensive verification. Schema character limits do not replace byte limits. Size/depth limits are enforced before processing. If canonical JSON is later required, specify and test a particular scheme; sorted Swift dictionary keys alone MUST NOT be described as [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785.html) compliance.

Existing native face v2 instead hashes its own domain, separator, challenge and exact payload JSON and uses its existing encoding rules. Existing evidence App Attest separately binds payload digest and signing-key hash. These constructions are preserved rather than treated as byte-compatible with this candidate.

### A.3 Payload fields and lineage invariants

The standalone [payload schema](contracts/payload.schema.json) and [iOS envelope schema](contracts/ios-envelope.schema.json) define shapes. The [synthetic example](fixtures/ios-id1-complete.example.json) and [offline checker](validate_spec.py) exercise syntax, byte hashing and selected policy predicates. They contain no real App Attest proof and cannot authorize enrollment. The following are required semantic bindings; schema validity alone cannot establish them.

| Payload group | Required content and binding |
| --- | --- |
| `schemaVersion`, `policyProfile` | Exact candidate version and immutable server-approved policy identifier. |
| `session` | `sessionId`, `generation`, `revision`, `attemptId`, `attemptChallenge`, `installationId`, `documentCheckId`, `documentOperationId`, `phoneRun`. All match server-issued state, including attempt freshness and authenticated installation. Attempt challenge is distinct from the single-use platform proof challenge. |
| `capture` | Front/back capture IDs and SHA-256 of original bytes for optical ID-1; null only where the credential path does not consume optical images. Selfie capture ID and digest of the exact admitted image consumed by comparison are mandatory; its camera-source derivation remains in the linked manifest. Portrait has its consumed-byte `sha256`, `sourceSha256`, and `derivationSha256`. |
| `artifacts` | `modelManifestSha256`, `calibrationSha256`, `policySha256`; resolve to immutable approved artifacts with complete preprocessing/precision/transform and threshold contracts. |
| `evidence` | `cadastralReportSha256`, `custodyRootSha256`, `admissionReceiptSha256`; resolve to available authenticated reports and lineage. Presence of a digest alone proves no physical claim. For a path without optical document Cadastral analysis, `cadastralReportSha256` is null and the path policy explicitly records nonapplicability; it is never a successful optical check. |
| `credential` | `path` is `physical_id1`, `icao9303` or `mdl18013_5`; `reportSha256` identifies the complete path-specific report. |
| `services` | `issuerReceiptId` for the optical issuer check, `credentialReceiptId` for chip/mDL verification, and `phoneReceiptId`. Nonapplicable issuer/credential receipt is null by path, not a fabricated success. |
| `outcomes` | `face` is `pass`, `manual_review`, `fail` or `unavailable`. `document` and `physical` are `pass`, `fail`, `inconclusive`, `unavailable`, `unsupported` or `not_performed`. These are signed application observations; the server decides acceptance. Here `physical` means optical document material/handling checks only. It never waives live-selfie admission or the face PAD requirements, including on chip/mDL paths. |
| `issuedAt` | UTC epoch milliseconds as a safe JSON integer; server expiry uses trusted server state, not the device time alone. |

Every derived object MUST trace to its original bytes by a versioned derivation manifest, including input/output hashes, crop/coordinate transforms, restoration and actual model digests. For optical ID-1, portrait `sourceSha256` equals the bound front source digest. For chip/mDL it equals the authenticated credential source identified by the server credential receipt. The consumed portrait digest MUST match face-comparison reference lineage. The admission receipt MUST name the consumed selfie. An original-capture digest MUST NOT be replaced by the digest of a resized/model raster.

A service receipt is a server-authenticated record, not a client's claim. The verifier MUST resolve it within the authenticated installation and exact session/attempt generation, document operation/check and phone run; re-use rules must be explicit and freshness bounded. Its checked capture/credential hashes and subject binding MUST match this payload. Receipts record request/response correlation, coverage, status, provider/adapter version, trusted observation/expiry times and policy identity. Current result stores may need a versioned receipt adapter to supply this composite binding; its existence is not claimed here. A new client-supplied receipt ID cannot add provenance to old records automatically.

Raw frames, portrait bytes, embeddings, face norms and similarity scores are absent from this decision envelope. Categorical results and digests remain sensitive derived data. Reports referenced by digest require access control and retention limits; this appendix does not authorize their unrestricted upload.

### A.4 Verifier sequence and concurrency

1. Authenticate installation and accepted app/environment; validate bounded envelope and payload syntax without mutating state. Before a fresh-operation replay check, a currently authorized identical result-readback MAY resolve a previously verified request by installation, operation and exact payload/proof digest. Return only the original stored result within its retention/access rules; do not refresh its validity or execute a new action. A changed request or unauthorized readback is refused.
2. Locate a registered App Attest key and an unexpired server challenge with the candidate purpose, installation, attempt and policy scope. Recompute candidate client data; reject mismatched hash or proof.
3. Apply the maintained Apple registration/assertion procedure: certificate trust/key identity and app/environment checks at registration; signature, app identity, challenge and assertion counter checks for requests. Persist replay state atomically. [Apple server validation](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server).
4. Verify exact attempt, capture, portrait, admission, model/calibration/policy, custody and service-receipt relationships from A.3. The digest must resolve to the authorized object actually consumed; reject missing, stale, superseded or contradictory bindings.
5. Evaluate the server-approved credential-path predicate over authenticated evidence and actual coverage. A full telemetry mask, shape-valid JSON or client `pass` alone MUST NOT trigger acceptance. Return a server decision receipt identifying payload digest, proof key identity/counter, policy digest, resolved input receipt IDs, decision, reasons and server time.

The candidate MUST bind challenge consumption and operation/result recording through an explicitly specified transaction or recoverable state machine. An identical previously authenticated readback follows step 1 rather than being processed as a fresh assertion with a consumed challenge or stale counter; it returns only the retained original result and performs no new action. An altered request under the same consumed challenge is refused. No available stored result means a fresh challenge/assertion and idempotent operation recovery are required. Existing routes may consume challenges before later processing fails; the migration design must define a fresh-challenge retry and operation idempotency rather than claiming an atomic guarantee already exists.

App Attest counters are per key, shared across operations. The candidate client MUST coordinate assertion generation/submission across routes using a key so a strict increasing server counter does not mistake legitimate reordering for fraud. If ordering is lost, request a fresh challenge/assertion for the still-valid operation; record the first refusal as a replay/order error, not a biometric mismatch. Supporting out-of-order admission is a separate reviewed replay design. Test simultaneous operations, retry after response loss and interruption after challenge consumption.

### A.5 Claim commitments, disclosure and buffer lifecycle

Do not call a nonce-plus-hash a zero-knowledge proof. If claim commitments are used, define their concrete purpose and disclosure recipients. A candidate typed construction is:

```text
claimsDigest = SHA256(
  UTF8("kenshiki:claims:v1") || 0x00 ||
  deterministic-CBOR([audience, sessionId, attemptId, salt32,
                     sorted [[namespace, fieldName, typeTag, typedValue], ...]])
)
```

`deterministic-CBOR` means RFC 8949 core deterministic encoding; only explicitly allowed strings, byte strings, signed integers, booleans and null are permitted; no floats, tags or duplicate namespace/name pairs. Sort the field pairs lexicographically by UTF-8 namespace then UTF-8 field name. `typeTag` MUST match the encoded type. Field-specific normalization is versioned before encoding. `salt32` is 32 CSPRNG bytes and kept with the authorized opening; publishing it permits guessing predictable claims. The opening and salt MUST NOT appear in the generic decision envelope. This is a salted commitment with limited hiding assumptions, not selective-disclosure credential verification or a zero-knowledge protocol. Do not reuse session commitments as public identity identifiers. This optional construction requires its own schema, byte vectors and privacy review before use; the current candidate assertion schema does not implement it. [CBOR deterministic encoding](https://www.rfc-editor.org/rfc/rfc8949.html#section-4.2.1).

Local biometric processing and necessary external identity disclosure MUST be specified separately. AAMVA and subscriber matching require defined identity fields to leave the device/backend boundary; record recipient, purpose, consent/legal basis, retention and minimization. The selected mDL profile may also require server processing. The envelope's lack of images does not imply zero PII egress for the whole flow. Current face submission deliberately restricts egress to categorical results and lineage; adding scores is a separate approved contract change.

The device lifecycle is: capture → derive/compare → finalize permitted lineage/results → release transient image/embedding buffers as far as the API permits → record the observed cleanup state → construct payload → obtain proof → submit. The cleanup record describes specific owned buffers, mechanism, completion time and failures; it MUST NOT claim erasure of all framework/NPU copies. Retries retain permitted categorical bytes/proof metadata rather than silently retaining biometric inputs. Custody/diagnostic retention is a separate explicit policy with user authorization, bounded storage and expiry. Do not sign a claim that a future cleanup has already completed.

### A.6 Due-diligence gates and accountable roles

Role names below are required responsibilities, not assignments to an unidentified person. The release record MUST name the responsible person and reviewer before a gate closes.

| Gate | Accountable role | Required evidence |
| --- | --- | --- |
| Candidate protocol adoption | SDK and verifier maintainers | Exact schema, bounded parsers, byte/hash vectors, cross-language verification, compatibility/rollback tests, no recursive signing. |
| Platform registration/proof | Security verifier owner | Current Apple procedure pinned and negative vectors: wrong app/environment/key, malformed proof, altered bytes, expired/consumed challenge, stale/reordered counter, concurrent routes. Actual device registration and accepted server receipt, separate from unit tests. |
| External checks | Identity integrations owner | Server-authenticated issuer/credential/phone receipt adapter, complete subject/capture/attempt binding, provider coverage and unavailable/contradiction recovery tests. Live approved test receipts separate from fixtures. |
| Credential coverage | Credential security owner | Trust acquisition/update evidence, supported algorithm/document registry, passive-authentication and anti-cloning distinctions, stale/revoked/unsupported fixtures; mDL interoperability evidence before claiming support. |
| Privacy/lifecycle | Product privacy and SDK owners | Data-flow inventory, permitted fields and recipients, retention/recovery behavior, observed buffer release limits; commitment vectors if the optional commitment is adopted. |
| Policy acceptance | Product assurance owner | Named immutable predicates and coverage requirements; missing-service paths, substitution/injection attacks and genuine-user completion measured for each released profile. |

Open decisions are the named path registry and service coverage, selected mDL profile, required anti-cloning level, privacy-approved retention and exact acceptance predicates. The document supplies the contract structure and failure semantics; an unapproved or unmeasured profile remains non-releaseable. This revision itself supplies no platform certification, provider activation, deployed verifier compatibility or biometric/security effectiveness result.

## Appendix B. Implementation and Migration Plan

**Status:** Planned extraction, replacement and release work. The current source remains in the identity SDK checkout; no new repositories, Android implementation or public releases were created by this specification revision. Repository names below are proposed names, not existing release locations.

Sections 1–8 define the required system, technical decisions and acceptance evidence. Appendix A defines the candidate protocol. This appendix defines how to implement, extract, sequence, assign, cut over and publish that system. Its planning location does not make the required two-SDK outcome, vendor removal, provenance or acceptance requirements optional. Unresolved model/preprocessing choices, thresholds, supported profiles and required operating points remain visible in the main specification.

### B.1 Repository extraction and release layout

Implement the [SDK responsibility and dependency contracts in section 2.1](#21-sdk-responsibilities-and-dependency-contracts) using two capability repositories, each owning both platform packages and one conceptual specification. Keep shared algorithm implementations within the relevant capability repository where appropriate. Create a separate foundation package only when concrete shared dependencies justify it; do not introduce platform forks with competing contracts.

| Proposed repository | Planned release layout |
| --- | --- |
| `kenshiki-face-sdk` | iOS Swift package/framework, Android library, native adapters, optional UI, shared conformance fixtures and reproducible model/build recipes. An optional Linux FRTE adapter remains separately qualified. |
| `kenshiki-document-sdk` | iOS and Android libraries, native capture/analysis adapters, optional UI, shared evidence/geometry fixtures and reproducible asset/build recipes. Chip/mDL additions follow their declared scope and qualification. |
| Existing identity SDK and service adapters | Integrate pinned public face/document releases with issuer/phone services, attestation and server policy while preserving the product boundary in section 2.1. |

Repository creation, source extraction, independent package validation and public publication are separately recorded milestones. The current code inventory in section 1.2 does not establish that any of these extraction or Android release tasks have executed.

### B.2 Work packages, dependencies and completion evidence

All rows below are **planned** until their named artifacts and execution receipts exist. Owner roles must be assigned to people in the implementation record. Work may proceed in parallel where dependencies permit; a blocked qualification task triggers remediation rather than silently retaining a vendor as the final architecture.

| ID / accountable role | Concrete work and dependency | Required completion evidence |
| --- | --- | --- |
| REMOVE-01 / SDK architecture owner | Freeze minimum release paths and the responsibility inventory in 8.3. Identify every direct/transitive vendor import, type, binary, model, resource, build fetch and exported contract in SDKs, runtimes and adopters. | Source-linked dependency/resource inventory and path coverage; each responsibility assigned to replacement or explicitly retired with its assurance impact. No hidden unowned Regula check or InsightFace detector remains. |
| REMOVE-02 / SDK maintainers | Establish the two public capability boundaries and planned repository/release layout. Extract generic document/portrait and face inference interfaces; separate product adapters. Depends on REMOVE-01. | Standalone iOS/Android package definitions and sample contracts; no vendor/product types in public API; dependency direction checks; extraction provenance and licence notices. Repository creation/publication are recorded separately from design. |
| REMOVE-03 / model and data owners | Obtain/train reproducible replacement detector, embedder and required document/PAD artifacts with redistribution-compatible rights. Assess AXON candidates under [B.4](#b4-axonkaggle-acquisition-and-model-distribution-workstream). Optional restoration and other research models enter only if the minimum path requires them. | Content-addressed manifests, code/data/weight rights, frozen training/calibration/test partitions, supported devices/revisions, conversion and quality/threshold evidence. No renamed or converted InsightFace checkpoint masquerades as a new model. |
| REMOVE-04 / face SDK owner | Replace the InsightFace-derived inference path on iOS and implement Android using the selected artifacts. Preserve or explicitly replace aligned routes, invalid-vector admission, selfie/depth/PAD rules and reference/selfie lineage. Depends on REMOVE-02/03. | Independent face packages and native sample builds; numerical and decision tests; model-loader failure/recovery; deployment-domain and device evidence. Old embeddings, thresholds and stored verdicts retain their original model/policy identity and are not reinterpreted. |
| REMOVE-05 / document SDK owner | Replace Regula's actual configured responsibilities using document capture, Cadastral, OCR/field comparison, primary/secondary portrait policy, classifier and selected material/PAD operations. Implement the minimum scope on both platforms. Depends on REMOVE-02/03. | Independent document packages; exact original/derivative/portrait geometry and custody; supported coverage, unsupported/error handling, secondary/ghost disposition and calibrated local decisions. Fields and authenticity branches preserve their distinct source provenance. |
| REMOVE-06 / identity/verifier owners | Replace Regula-specific reader/portrait and observation wire adapters; connect public document output to public face input and existing AAMVA/phone/attempt flow. Retain current wire contracts through adapters or implement a negotiated successor. Depends on REMOVE-04/05. | Client/server contract vectors, report/receipt lineage, old-record readback and recovery, version negotiation, no forged vendor check codes, no unannounced policy changes, same-session combined-flow evidence. |
| REMOVE-07 / evaluation owner | Blindly evaluate the replacement's minimum supported whole flow against approved bounds and representative attacks/genuine users; use current vendors as diagnostic comparators, not ground truth. Depends on selected artifacts and integrated path. | Section 8 operating-point and uncertainty records, failure analysis and closed critical gaps. Additional color OVD/tremor/restoration/mDL or NIST work is not automatically a removal prerequisite unless the minimum release scope or an advertised claim depends on it. |
| REMOVE-08 / release/build owners | Cut over each vendor track, then remove its shipped imports, package references, binaries, weights, licence/database fetches, resource loaders, runtime branches and packaging dependencies. Depends on qualification for that track. | Clean-checkout native builds and packaged-artifact/SBOM scans proving no direct/transitive vendor runtime or model payload, no startup download, no hidden vendor fallback. Source search alone is insufficient. |
| REMOVE-09 / adopting-app owners | Rebuild every adopting app against pinned independent SDK releases; test install, resume/retry and physical journey on each supported platform. Depends on REMOVE-06/08. | SDK/source/build provenance, separate iOS/Android integration receipts and actual installed physical results for each adopter. Existing TestFlight/app artifacts do not update themselves. |
| REMOVE-10 / open-source maintainers | Publish source, reproducible build/model recipes, allowed assets/manifests, notices, security reporting and release artifacts; exercise external clean-room installation. Depends on rights clearance and qualified release artifacts. | Public release tags and checksums, source-to-package trace, model distribution terms, independent package/sample install and measured platform support. Contracts, raw biometric data and vendor resources are not published merely because code is open-source. |

### B.3 Concrete removal surfaces, cutover and adopter migration

The initial inventory MUST include at least these current anchors and all consumers discovered from them:

- **Regula dependency and runtime:** [package manifest](../../Packages/IdentityEvidenceRegula/Package.swift), its resolved dependencies, [runtime project](../../Distribution/IdentityCaptureRuntime/project.yml), [Regula runtime](../../Distribution/IdentityCaptureRuntime/Sources/RegulaDocumentRuntime.swift), [configuration](../../Distribution/IdentityCaptureRuntime/Sources/RegulaDocumentConfiguration.swift), [document-to-face coupling](../../Distribution/IdentityCaptureRuntime/Sources/DocumentFaceRuntime.swift), Regula-specific gateway payloads and observation/presentation modules.
- **Regula distribution/resources:** [vendor framework inventory](../../scripts/vendor-frameworks.json), [packaging](../../Distribution/package-react-native.py), [contract check](../../scripts/check_regula_contract.py), resource/licence/database provisioning and host scripts. Remove runtime fetch/copy paths as well as linked frameworks; retire corresponding distribution metadata accurately.
- **InsightFace inference/resources:** [face package dependency](../../Packages/IdentityEvidenceFaceMatching/Package.swift), [imported inference package](../../ThirdParty/FaceMatching/Package.swift), [model resources](../../ThirdParty/PulseFaceMatching/Models), loader defaults, conversion/download scripts and every bundled/cached model provisioning path. The replacement covers the detector as well as the embedder; retaining a SCRFD architecture with new, properly licensed weights is distinct from retaining InsightFace-distributed weights.
- **Public contracts and adopters:** neutral document/portrait interfaces replace Regula-owned references; new model identity accompanies face outputs. Update bridge/runtime/package scripts and reference/adopting apps. Preserve historical records and lawful attribution; neither renaming a module nor deleting old audit text constitutes dependency removal.

Reusable owned comparison/custody code may remain after its vendor dependencies are removed. Imported code that is retained requires its actual licence/provenance and an explicit home; do not claim clean-room authorship for copied code. Historical vendor reports remain readable under their original versions through bounded legacy readers that do not load retired engines. Expired old comparisons cannot be promoted to replacement-model evidence. Training/evaluation archives stay outside public release assets under their authorized retention policy.

Retain release provenance, reversible pre-cutover feature selection and operational monitoring with explicit rollback triggers. Rebuild every adopting app against the selected packages; a shared SDK source edit does not update an installed app or existing TestFlight artifact. Record integration, installation and physical acceptance separately, against the core requirements in [section 8.4](#84-vendor-removal-acceptance-criteria).

Temporary side-by-side evaluation is bounded. Rollback uses a separately pinned earlier application/release or an explicit safe recovery path, not an undisclosed dependency in final packages. Open-source publication is a distinct recorded milestone, not implied by successful local extraction.

### B.4 AXON/Kaggle acquisition and model-distribution workstream

The owner identified [Axon Labs (`axondata`)](https://www.kaggle.com/axondata/datasets) as a candidate source. On 2026-10-16 the public Kaggle listing/API was inspected; [axon-candidates.json](axon-candidates.json) records selected dataset references, advertised versions and licence metadata. No biometric payload or executable notebook was downloaded or run in this document work. These are dataset listings, not established SDK source repositories or approved replacement weights.

Prioritize the selfie/official-ID pairing dataset for the face-reference domain and live/print/replay/mask collections for declared PAD attack coverage. These collections do not supply Cadastral licence-front/back ground truth, per-frame camera/IMU/display synchronization, issuer validity or a mobile inference model unless the actual selected files establish those properties. A dataset title containing “NIST” or “iBeta” is not evidence of NIST origin, official evaluation or certification.

The selected listings currently declare **CC BY-NC 4.0**. Record that restriction explicitly: it is not a commercial training/distribution clearance or a permissive SDK code licence. Obtain the actual scope needed for commercial development/use, trained-model release and downstream adopters; do not assume publishing code for free resolves the restriction. Code/notebook, data and model-weight permissions are separate. See the [Creative Commons terms](https://creativecommons.org/licenses/by-nc/4.0/). Underlying collection provenance, participant permissions, identity pairing, attack labels and any original-source rights still require evidence.

For each selected asset, the acquisition record MUST contain exact Kaggle reference/version, metadata snapshot, licence/permission evidence, downloaded file inventory and hashes, actual sample/identity/attack counts, label/quality audit, duplicate/overlap analysis, intended use and retention. Assign subject-disjoint training/calibration/test splits and record overlap with external benchmarks before use. Samples/weights are admitted to commercial training or public distribution only after their actual permissions and intended use are cleared; assessment of availability alone does not close REMOVE-03. Publish reproducible acquisition references and permitted synthetic/public fixtures, not raw biometric collections in the SDK Git history. If an asset's rights or quality are unsuitable, record the rejection and select another source rather than blocking the whole vendor-removal program indefinitely.
