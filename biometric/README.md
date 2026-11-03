# Kenshiki Biometric SDK

Independent Swift, Kotlin and C++ portrait/embedding mechanisms, with optional
iOS capture and Apple inference products. Document, issuer/phone services and
product acceptance remain outside this package.

## Products and boundaries

| Product | Implemented behavior |
| --- | --- |
| `BiometricSDK` | Owned portrait pixels, exact-byte hashing, complete request bindings, embedding admission, normalization, cosine/angular math and operation fences |
| `BiometricCapture` | iOS TrueDepth acquisition/admission, owned color/depth snapshots and bounded oriented-PNG-to-RGB conversion |
| `BiometricQuality` (separate `quality-apple` package) | Optional local OFIQ 1.0.3/OpenCV 4.5.5 assessor, exact profile/raster bindings and all component status facts; shared Apple ORT 1.22.0 |
| `BiometricCapturePreview` | Optional native preview, separate from the headless library |
| `BiometricInference` | Source-hashed ImageIO decoding, owned matcher preparation, C++ frame selection/five-point alignment and AuraFace/ONNX Runtime CPU inference on macOS/iOS |
| Optional C++ `kenshiki_auraface` | Verified owned model bytes, aligned RGB112 preprocessing and manifest-bound embeddings; see [C++ build/API](cpp/README.md) |
| Android `biometric-sdk` | Portable Kotlin contracts, numerical primitives and lifecycle fences; live capture and inference remain unimplemented |

The iOS reference app composes the original passport portrait and reviewed selfie
through the [Apple alignment route](../contracts/apple-face-alignment-v1.md).
The output is a cosine observation, without a calibrated match threshold or an
identity verdict. The SDK has no mandatory document, passport or paid-backend
dependency. Shared custody/key mechanisms belong in `foundation/`; complete
producer/selection/derivation verification and product proof adapters remain
separately qualified work.

The optional [frame selection contract](../contracts/face-frame-selection-v1.md)
defines source-bound candidates, complete exclusions and deterministic first/native
quality-score policies. The Swift interface calls one dependency-free C++ core.
Matcher preflight retains private owned pixels/geometry for selected comparison,
without loading an embedding model. The reference phone workflow opts into a
bounded acquisition window with per-candidate admission/depth/motion receipts,
local serialized quality assessment and exact selected-owner comparison. The
single-frame capture default is preserved for other adopters. The mechanism does
not establish an improved ranking policy or calibrated recognition threshold.
The separate optional quality package uses a framework source-built from pinned public dependencies;
its external, exact-hash model profile is provisioned separately. Both native
execution and representative-device resource acceptance require fresh receipts.

The experimental Liquid assessment product, runtime, model provisioning and MLX
package dependencies were removed on 22 October 2026 after the external Mac
evaluation failed to demonstrate reliable capture interpretation. This does not
qualify or invalidate AuraFace. Previously stored visual records remain readable
through passive compatibility types owned by the reference app; the SDK does
not export or execute a visual-language model. Historical experimental contracts
remain available for interpreting old evidence.

AuraFace-v1 is the selected development embedding baseline. Its [artifact record](docs/auraface-baseline.json),
[aligned-input contract](../contracts/auraface-aligned-input-v1.md) and
[model qualification policy](../governance/model-selection.md) pin its role and
limits. Detector/PAD artifacts, calibrated recognition, training provenance,
public weight rights and the actual FRTE algorithm adapter are separate gates.
The public baseline inventory contains no training checkpoint or training code;
no fine-tuning or recognition benchmark is established by the synthetic probes.
Weights and real biometric media stay outside Git. Apple runtime attribution is
in [the ONNX Runtime notice](third-party/onnxruntime/NOTICE.md).

## Foundational motion evidence

The [motion API and workflow guide](../foundation/motion/README.md) documents the
shared `KenshikiMotion` collector, sensor fields, existing summary features and
selfie frame bindings. It distinguishes the summary retained in a selfie receipt
from the raw windows independently journaled by the composed passport-to-selfie
workflow, and records the current cross-capability integration gaps.

## Build and validation

From the monorepo root, install tooling as described in [the repository guide](../README.md), then run:

```sh
bash scripts/python.sh scripts/check.py --sdk biometric --platform all
bash scripts/python.sh scripts/capture_check.py
bash scripts/python.sh scripts/presentation_check.py --platform ios-ui
```

Individual native lanes are `guards`, `macos`, `ios-device`, `ios-simulator` and
`android`; `nist` selects the optional C++/Linux tooling. Apple deployment floors
and pinned runtime dependencies are in `Package.swift`; Android tooling is pinned
in its Gradle project. Package coordinates and public releases are not configured.

The common contract executes 200 portrait and 30 numerical vectors in Swift,
Kotlin and C++20. Native suites also cover resource bounds, source substitution,
stale/cancelled/replaced operations, reentrancy and invalid scores. C++ tests use
fatal ASan/UBSan and independent mutations; generated ONNX graphs exercise the
actual runtime without learned weights. See [QA obligations](docs/qa.md),
[capture contract/provenance](docs/capture-extraction.md),
[extraction ledger](docs/extraction-ledger.md) and [NIST boundary](nist/README.md).

Dated machine-readable evidence remains in [portrait primitives](docs/primitives-validation.json),
[capture](docs/capture-validation.json), [C++ inference](docs/auraface-inference-validation.json)
and [aligned-input parity](docs/auraface-parity-experiment.json). The parity experiment
uses generated aligned inputs and development numerical tolerances, not identity
operating points; Linux emulation is not NIST performance qualification. Historical
scaffold receipts remain in `docs/qa-validation.json`. Fresh receipts and required
executed-test inventories are emitted by the native runners. Current delivery and
hosted blockers are recorded once in [HANDOFF.md](../HANDOFF.md).

The [external face workbench](tools/face_lab/README.md) owns private corpus/sample
experiments and ML environments. Its source [reuse inventory](docs/reuse-inventory.md)
is historical provenance, not a claim that its old model weights were adopted.
[APP-ARCH-001](../governance/architecture/APP-ARCH-001.md) governs integration;
[SPEC-IDBIO-200](../governance/references/edge-verification/SPEC-IDBIO-200.md)
is the frozen verification reference. `docs/design-provenance.json` retains the
original specification hash. Code, model and data permissions require separate
review before publication.
