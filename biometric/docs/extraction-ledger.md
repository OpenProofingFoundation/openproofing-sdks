# Biometric extraction and provenance ledger

Keep the existing identity-product comparator available while qualifying SDK
mechanisms and replacement artifacts. Historical embeddings and verdicts retain
their original model and policy identity.

| Slice | Source or implementation record | Implemented boundary and remaining work |
| --- | --- | --- |
| Portable portrait and embedding core | Shared portrait/math contracts; `Gates/cpp-sources.json` | Swift/Kotlin/C++ owned pixels, hashing, request bindings, normalization and operation fences; full producer/ordered-derivation verification and template encoding remain separate |
| Native acquisition | Identity SDK `Sources/CaptureSelfie`; `Gates/capture-sources.json` | Optional iOS capture and preview, owned color/depth snapshots and bounded conversion; Android acquisition and product custody adapters remain separate |
| Aligned-input inference | `Gates/cpp-sources.json`, `Gates/onnxruntime-linux-x64.json`, aligned-input contract | Independent C++ AuraFace preprocessing/runtime adapter; selected weights remain external |
| Apple composition | `Gates/inference-sources.json`, `Gates/onnxruntime-apple.json`, Apple alignment contract | ImageIO decoding, Vision revision-3 landmarks, portable alignment and selected-weight CPU inference; no legacy runtime or recognition threshold imported |
| Shared frame selection and prepared ownership | New C++20/C ABI and Swift wrapper, `Gates/cpp-sources.json`, `Gates/inference-sources.json`, frame-selection v1 contract | Optional macOS/iOS deterministic selector and owned matcher preparation; OFIQ mobile assessment, capture-window integration, Android adoption and ranking calibration remain separately qualified |
| Original route and decision policy | Identity SDK `FaceComparisonRoute.swift` and matching submission/custody code; reuse inventory | Preserve historical readers and authorize artifact-specific route/calibration changes explicitly; product BFF acceptance remains outside the SDK |
| Replacement artifacts | Selected AuraFace artifact record and model-role policy | Embedding baseline selected; detector/PAD selection, US provenance, training/export rights and calibrated evaluation remain separate qualification |
| Adopter integration/vendor removal | SPEC-IDBIO-200 Appendix B, REMOVE-04 and REMOVE-06 through REMOVE-09 | The reference app uses SDK composition; other product adopters require their own migration and vendor-removal evidence |
| Linux/NIST | Pinned official `nist/upstream/` inventory and driver/null-reference tooling | C++ primitives/inference and synthetic I/O execute; the actual FRTE recognition adapter, algorithm harness and official qualification remain open |

Before extracting code, record source revision, working-tree hash, dependencies,
ownership/licence and destination. Preserve attributed patches and unrelated
source edits. An owner-held product licence is not redistribution permission for
an SDK or its model weights. No pinned upstream NIST file was changed by these
implementations.

[Capture scope](capture-extraction.md) retains calibration, ownership, PNG/RGB
identities and resource limits. [Source reuse inventory](reuse-inventory.md)
retains the original donor review. The [aligned-input contract](../../contracts/auraface-aligned-input-v1.md)
and [Apple alignment contract](../../contracts/apple-face-alignment-v1.md) own
preprocessing, geometry, numerical admission and artifact identity. [QA](qa.md)
requires behavior, sanitizer/fuzz, parity and lifecycle suites with each extraction.

The [product README](../README.md#build-and-validation) indexes retained dated
machine-readable evidence and fresh validation commands. [The external workbench](../tools/face_lab/README.md)
owns private corpus/sample provenance and experiments; its
[historical status record](face-workbench-status.json) is not current model
qualification. [Model selection](../../governance/model-selection.md) owns artifact
roles and permissions. Source/fixture availability, native execution, physical
acceptance and evaluation remain separate evidence.

## Local phone quality integration, 23 October 2026

The bounded capture window is newly authored around the retained acquisition
mechanism; existing donor source hashes remain unchanged in capture-sources.json,
with destination changes attributed separately. Optional OFIQ assessment is built
from source revision df8fbb5e4bd8de09ae998ff69bc252f6be4367f8 and OpenCV
dad26339a975b49cfb6c7dbe4bd5276c9dcb36e2, with the existing Apple ORT 1.22.0
artifact. The checked-in recipe records original/patched upstream hashes and
serial execution/lifetime repairs. It omits unused encoded-image codecs and the
file-image helper: assessment receives owned RGB bytes through the bounded C ABI.
The profile manifest pins the external model/config/notice bytes. No learned
weights, private camera images or model-bearing signed artifacts belong in Git.
Source build, all-component runtime comparison, physical capture and measured
resource/recognition utility remain separate qualification evidence.
