# Model roles and selection record

**Status: AuraFace-v1 selected by the owner on 17 October 2026 as the face-embedding development baseline.** The [pinned acquisition and graph/CPU smoke record](../biometric/docs/auraface-baseline.json) identifies the exact `glintr100.onnx`, publisher revision, digests, declared Apache-2.0 licence and observed tensor contract. Weights remain in the external face workbench. This is a baseline selection; the [optional C++ aligned-input adapter](../biometric/cpp/README.md#optional-aligned-input-inference) now implements the fixed [profile](../contracts/auraface-aligned-input-v1.md), with generated-graph runtime tests and actual-weight synthetic reference parity. The earlier external experiment established the preprocessing oracle. Full preprocessing/alignment, mobile integration, fine-tuning, recognition evaluation and public release remain incomplete. The US development/training/data requirements below remain outstanding qualification evidence, not waived or established by this selection.

The first path is to reproduce the original baseline before changing weights or training loss. The pinned graph accepts FP32 NCHW `[batch,3,112,112]`; its declared output is `[1,512]`, and batch-one CPU execution produced finite features with bit-identical repeated output on a synthetic numeric tensor. Batch behavior beyond one, aligned RGB channel semantics and scaling now have synthetic wrapper-parity evidence. Detection, alignment, interpolation, real-image reproduction and mobile parity still require explicit qualification. The publisher describes ResNet100 trained with ArcFace additive angular margin. AdaFace remains an optional later training experiment, not a description of these existing weights.

## Retired vision-language experiment

The owner selected **Liquid AI LFM2.5-VL-1.6B** on 20 October 2026 for the
parallel visual-assessment experiment. Liquid AI is a US company. This selection
authorizes local development with this checkpoint; training-location and
training-data provenance remain qualification evidence under the requirements
below. AuraFace remains the face-embedding baseline.

The original [publisher checkpoint](https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B)
is pinned to revision `919fde3d022e3f90a4716006f993938ee8c2eb97`.
Its `model.safetensors` is 3,193,334,216 bytes with SHA-256
`7fc7458e4382fc6e558cfdda45857fbf9ab5b40a8bf199c9cd073003b14ac26d`.
The publisher describes an LFM2.5-1.2B-Base language backbone and a SigLIP2 NaFlex
400M vision encoder, with multi-image input and configurable image tiling.
The general-purpose VLM's face/document assessment and capture-guidance utility
require task-specific evaluation; model selection establishes no biometric or
document-authenticity accuracy.

The first local mobile candidate is an MLX affine 4-bit, group-size-64 RTN
conversion using `mlx-vlm==0.7.9`, with the vision tower retained as BF16.
Its `model.safetensors` is 1,511,170,678 bytes with SHA-256
`bf86cc6b16e4f6a870336d5e0ebad0c5cf1d63214efef8efeb8b9655174b3913`.
Original and converted artifacts executed the same generated single-image and
paired-image probes on the Mac. Receipts are external under
`experiments/lfm25-vl-20261020/`; these probes establish execution only.
The optional Swift assessment product, Liquid runtime, model provisioning and MLX
dependencies were removed on 22 October 2026. The bounded external Mac evaluation
reported unsupported physical claims and incorrect temporal observations, including
under narrower prompts with reconstructed input tensors. This is an engineering
retirement of the tested integration, not a general model-family benchmark or a
comparison of the Python and Swift runtimes. Historical source-bound records
remain readable through app-only compatibility code. AuraFace remains separate.

Original weights, conversions, isolated runtime and local execution receipts
belong under the external face workbench's `models/lfm2.5-vl-1.6b`,
`runtime/` and `experiments/` directories. Retain publisher revision, original
file hashes, conversion configuration, derived hashes and actual runtime versions.
Evaluate with the existing AuraFace path independently; experimental VLM output
does not change SDK comparison results or authorize identity acceptance.

The [LFM Open License v1.0](https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B/blob/919fde3d022e3f90a4716006f993938ee8c2eb97/LICENSE)
retains redistribution/notice conditions and a commercial-use revenue limitation.
Downstream SDK/weight distribution and applicable commercial permissions remain
separate qualification work. Local execution, conversion parity, SHF integration,
latency/memory and task evaluation must each have their own evidence.

## US development, training and data requirement

The owner explicitly requires all three: **US-developed models, training performed in the US, and US-sourced training data**, in addition to commercial use and public weight publication. This applies to face matching, detector/alignment, face/document PAD, restoration and other learned SDK artifacts. A US publisher, US-hosted download or permissive licence alone does not satisfy the requirement.

Admission evidence must identify the developing organization/team and development provenance; the locations of pretraining, fine-tuning and any teacher/distillation training; and the source/collection geography and permissions of the training corpus. Imported initialization, teachers and synthetic-generator dependencies require their own provenance rather than acquiring US status through conversion or a later US fine-tuning run. Dataset vendor location alone does not establish US collection/source geography. Evaluation-only datasets are tracked separately from training lineage and must retain their own authorized-use scope.

No current third-party checkpoint has been verified to satisfy this complete requirement. MobileFaceNet is withdrawn from the recommended deployment shortlist under the US-origin condition. AuraFace is now the owner-selected development baseline; its published model card does not establish US-only development/training execution or US-sourced training data, so those facts remain unverified. AdaFace and the prior MobileViT-CDCN research candidates are not automatically admitted by their code licences or inclusion in the specification. The primary-paper reference pack remains research grounding, not an approved artifact inventory.

The recommended route is to qualify a US-developed pretrained baseline with weight terms permitting commercial use, modification and public redistribution, then fine-tune and qualify the Kenshiki derivative on approved US infrastructure/data. The baseline qualification must establish the earlier US development, training and data requirements; this priority does not silently relax them. AuraFace is selected for development and remains subject to supplier/provenance and release qualification. Obtain a trainable checkpoint or validate a reconstruction against the released inference artifact before tuning. Exact backbone/loss and corpus selection remain open; FRTE/Linux and mobile parity are continuous qualification constraints. Training an established architecture from random initialization is the fallback if no suitable baseline qualifies, not the default recommendation.

## Public weight release requirement

The owner requires publishing the trained weights alongside the open-source SDKs. Candidate selection must therefore establish public weight redistribution and intended downstream commercial use, as well as reproducible mobile and C++/Linux execution with FRTE kept in scope throughout development. A private-use checkpoint alone cannot close selection.

Record code, initialization/checkpoint, training data, synthetic-generator and any teacher/distillation permissions separately. The training recipe and resulting weights need an explicit proposed release licence and supporting provenance; fine-tuning, random initialization or publishing code alone does not establish those permissions. Research-only or noncommercial assets remain outside the distributable training lineage unless separate permission covers the intended training and weight release. AXON sample availability is not itself that permission.

Release evidence includes exact weight/graph digests, preprocessing and output contracts, code/configuration revisions, training-data provenance and splits, licences/notices, export/runtime parity, model-card limitations and evaluation results. Raw biometric datasets remain outside the SDK repository and are not implicitly included in the weights release. The pinned AuraFace embedding weights are selected for the development baseline; no weights have been fine-tuned.

The governing verification reference is [SPEC-IDBIO-200 revision 3.1](references/edge-verification/SPEC-IDBIO-200.md), especially the subsystem matrix in section 2, material/PAD in section 4.4, embedding contracts in section 5 and evaluation in section 8. Current implementation planning is in [APP-ARCH-001 Appendix A](architecture/APP-ARCH-001.md#appendix-a-adoption-and-implementation-plan). Shared primitives do not imply interchangeable task outputs or a common face/document calibration.

| Specified role | Proposed architecture or mechanism | Selection must establish |
| --- | --- | --- |
| Face and document material/liveness PAD | Shared MobileViT-CDCN candidate, with domain-specific inputs/calibration | Face/document attack and genuine-user performance, preprocessing, domain/modality, temporal/capture/Cadastral integration, actual artifact/runtime footprint |
| Identity embedding and comparison | AuraFace-v1 ResNet100/ArcFace development baseline; AdaFace is a possible later training-loss experiment | Exact checkpoint/provenance, selfie-to-credential operating points, invalid-vector handling, preprocessing and mobile/Linux parity |
| Document classification embedding | Separate jurisdiction/revision artifact and class inventory | Mask/geometry identity, supported revisions, unknown/review outcomes and complementary unmasked Cadastral evidence |
| Detection/alignment and optional restoration | Model-specific detector/geometry; separately scoped restoration | Source lineage, trained preprocessing, actual runtime parity and restoration's identity/decision effects |

The shared material/PAD model must be evaluated for both face and ID liveness. Do not silently substitute a face-only embedding network for that role or assume a shared architecture establishes one shared calibration. A future proposal for one learned backbone with multiple task heads must state its training/input/output contracts and demonstrate the complete role coverage before changing the specified architecture.

The briefly discussed [Idiap EdgeFace XS checkpoint](https://huggingface.co/Idiap/EdgeFace-XS-GAMMA) is only a face-embedding comparison candidate; it has not been adopted or downloaded for SDK use and does not by itself implement the shared MobileViT-CDCN design. Its model card declares CC BY-NC-SA 4.0. The source/code licence, exact checkpoint rights and training-data provenance must be recorded separately. Existing AdaFace/CVLFace source references in the external workbench are not selected deployment weights either.

Before selection, record each candidate's immutable source/checkpoint revision and digest, task-role coverage, input/output/preprocessing contract, measured conversions and device/Linux behavior, data/weight/code provenance, domain-specific evaluation protocol and operating points. Use the owner-authorized AXON samples for initial workflow experiments; do not represent that sample set as evidence for rare-event accuracy or training a general face/PAD model. Keep task-specific findings and whole-flow outcomes separate, as the spec requires.

## Grounding and contract timing

Use the [pinned primary papers and method notes](research/README.md) before implementing a loss, scoring rule, detector, alignment or PAD operator. [Portrait/selfie v1](../contracts/portrait-selfie-v1.md) fixes generic source/geometry/pixel ownership and binding independently of final weights. Qualify candidate architectures, outputs and preprocessing alongside that work; freeze each artifact profile against the actual graph/export. Train or fine-tune after the loss, data/subject-session splits and evaluation protocol are explicit. Model qualification includes Swift/Core ML, Kotlin/Android and C++20/Linux/NIST preprocessing, template and observation parity. Paper references do not establish artifact selection; the owner-selected AuraFace baseline is recorded above.
