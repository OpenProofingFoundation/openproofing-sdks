# Mathematical and implementation grounding

Status: relevant method sections inspected against the pinned PDFs below; this is not experimental reproduction. Page references are **PDF page numbers** for the committed versions. The manifest records source identity and the scope of that review. Reported benchmark numbers are intentionally not imported as Kenshiki targets or results.

## 1. Embedding geometry and training objectives

[FaceNet 1503.03832v3, pp. 2–3](papers/1503.03832v3.pdf) learns a unit embedding with triplet constraints. For unit vectors, we derive `||x−y||² = 2−2(x·y)`: squared Euclidean distance and cosine rank pairs identically within the same space. Our inference contract admits finite features before normalization and returns cosine `s` and, where requested, `acos(clamp(s,−1,1))` radians. FP64 accumulation over FP32 features, explicit norm floors and typed failures are Kenshiki numerical choices, not properties certified by the paper. These choices already have native numerical tests in BiometricSDK.

[SphereFace 1704.08063v4, pp. 3–5](papers/1704.08063v4.pdf) introduces a multiplicative angular margin; the globally usable loss needs its piecewise angular construction, not unrestricted `cos(mθ)`. [CosFace 1801.09414v2, pp. 3–4](papers/1801.09414v2.pdf) instead uses normalized class/feature geometry and a target cosine-logit margin. These are training objectives with different boundary behavior. Neither supplies a universal runtime threshold or a guarantee of compatible embeddings across checkpoints.

[ArcFace 1801.07698v4, §3, pp. 4–6](papers/1801.07698v4.pdf) uses target logit `s_train cos(θ_y+m)` and other logits `s_train cos θ_j`, followed by cross-entropy. Angle is arc length on the unit hypersphere, which grounds the angular-margin interpretation. The training scale/margin is not the deployed comparison threshold. This expanded revision also discusses sub-centers; adding that mechanism would be a separately pinned training choice. Our face/document domains and complete artifact identities remain distinct even with identical dimensions. This geometry does not establish physical document angles or material authenticity.

## 2. Quality-dependent margins and uncertainty

[AdaFace 2204.00964v2, §3.2–3.3, PDF pp. 5–6, Eqs. 16–19](papers/2204.00964v2.pdf) defines a clipped, stopped-gradient norm statistic and adaptive margins. With `q=||v||₂`, its standardized statistic is `ẑ=clip(h(q−μ)/σ,−1,1)`, with `g_angle=−m ẑ` and `g_add=m ẑ+m`. The target logit is `s_train[cos(θ_y+g_angle)−g_add]`. Batch/EMA statistics, clipping, epsilon and stop-gradient implementation must be frozen in a training recipe; an implementation's numerical safeguards are not silently part of the paper equation. The deployed pair comparison remains normalized cosine. This supports retaining pre-normalization norm and exact artifact identity; it does not turn norm into a portable probability, calibrated quality scale or liveness check.

[MagFace 2103.06627v4, §3.2, PDF p. 4 and supplement B](papers/2103.06627v4.pdf) combines a magnitude-dependent angular margin with a magnitude regularizer. Its convergence/monotonicity arguments assume bounded magnitude, appropriate increasing/decreasing convex functions and a sufficient regularization coefficient. Those conditional training results do not make arbitrary feature norms quality measurements. A future MagFace experiment must pin the actual margin/regularizer and retain raw-feature norm separately from the unit vector.

[Probabilistic Face Embeddings 1904.09658v4, §4, PDF pp. 4–5, Eqs. 1–3](papers/1904.09658v4.pdf) models a diagonal Gaussian in feature space. Its mutual-likelihood score includes uncertainty-weighted squared mean differences **and** log-variance penalties; it is unbounded and is not cosine or a distance metric. Adopting it would require a new output/score contract and calibration. We do not append an invented variance to the current deterministic embedding contract.

## 3. Detection, alignment and mobile execution

[Kabsch-Umeyama 1902.03138v6, PDF pp. 2–4](papers/1902.03138v6.pdf) reduces the orientation-preserving rigid fit to a trace maximization and an SVD with determinant correction. Using the paper's column-point convention, `M=QPᵀ=VSWᵀ`, `D=diag(1,…,sign(det(VW)))`, and `U=WDVᵀ`. Centering supplies translation. Scale estimation, landmark ordering, raster orientation, degeneracy handling, resampling and border behavior need their own explicit contract; this paper is not a complete face alignment/preprocessing recipe. Required future fixtures include reflection handling, collinear/repeated landmarks, known transforms and inverse reprojection.

[MobileFaceNets 1804.07573v4, PDF pp. 2, 5–6](papers/1804.07573v4.pdf) explains spatially weighted global depthwise aggregation in a compact face backbone. Architecture efficiency, the training loss and the weights are separate choices. Reported phone timing does not establish current Core ML/Android/Linux latency, precision or accuracy. Device/export/parity measurements belong to the selected artifact.

[SCRFD 2105.04714v1, §3, PDF pp. 3–5](papers/2105.04714v1.pdf) studies sample and computation redistribution for efficient detection. That grounds a detector candidate, not the reuse of arbitrary output tensor names, strides or score/NMS gates. Detection decoding and coordinate restoration must be tied to the exact exported graph and common synthetic geometry fixtures.

[MobileViT 2110.02178v2, §3, PDF pp. 4–5](papers/2110.02178v2.pdf) combines local convolution with unfolding, transformer processing and folding that preserves patch/spatial ordering. A mobile backbone paper does not establish a face/PAD head, document-liveness training or current-device latency. A MobileViT-CDCN hybrid remains our specified candidate composition, not a reproduced artifact from either paper.

## 4. Face PAD and document PAD

[CDCN 2003.04092v1, §3.1, PDF p. 3, Eqs. 3–4](papers/2003.04092v1.pdf) gives `y(p)=Σ w(r)x(p+r)−θ x(p)Σw(r)`, algebraically combining intensity and central differences. Its face PAD training also uses depth-related supervision; the contrastive-depth objective is separate from the operator. Kernel support, padding, θ, bias handling and export equivalence require explicit tests. A CDC operator is not physical depth or a live-human proof.

[DeepPixBiS 1907.04047v1, §3, PDF pp. 3–4](papers/1907.04047v1.pdf) uses pixel-level and image-level binary supervision for frame-based face PAD; its output map is aggregated into a score. This is distinct from metric-learning identity embeddings. Transfer to a phone display, printed credential or ID-card material requires task-specific data, attack labels and evaluation.

[Document PAD/MMDT 2404.06663v1, §2, PDF pp. 2–4](papers/2404.06663v1.pdf) separates recapture blur/content and texture traces, then combines RGB and trace modalities. The method explicitly studies document recapture rather than face identity. It supports a separate document attack/domain inventory and cross-content/device evaluation; it does not prove general issuer authenticity or cover every injected/tampered credential. Neither this paper nor the face PAD papers establish shared face/document calibration. Cadastral source geometry/context and issuer/phone checks remain complementary evidence.

## 5. Corpus design and evaluation

[DigiFace-1M 2210.02579v1, §3–4, PDF pp. 3–6](papers/2210.02579v1.pdf) separates rendered identity from appearance/pose/lighting variation and investigates augmentation and synthetic-to-real adaptation. This supports keeping identity/session/derivative relationships and generator provenance in the corpus index. Synthetic image count is not real-world domain coverage; this reference does not authorize dataset or weight use. AXON provider hints must be reconciled before subject/session-disjoint splits are frozen.

[NIST FRTE definitions](https://pages.nist.gov/frvt/html/frvt11.html) distinguish false-match rate on nonmated comparisons from false-nonmatch rate on mated comparisons at a declared threshold. Acquisition/extraction failures and review/unavailable outcomes require their own denominators. [NISTIR 7740](https://www.nist.gov/publications/comparison-confidence-intervals-large-operational-biometric-data-parametric-and-non) is a primary reference for parametric and nonparametric interval methods; only its publication abstract was reviewed locally, so its full interval derivations are not claimed as incorporated.

As an explicit mathematical derivation here: under **independent Bernoulli trials**, zero observed errors has one-sided upper bound `p_U=1−α^(1/n)` at confidence `1−α`, from `(1−p_U)^n=α`. Video frames and reused identities are not automatically independent trials. This bound is an assumption-labelled planning calculation, not our performance result or a substitute for a reviewed dependence-aware evaluation protocol.

## 6. What follows from these references

The portrait/selfie contract preserves original/derived byte identity, explicit coordinate/orientation and preprocessing lineage, model-specific shape/norm semantics and separate PAD/admission observations. Its resource ceilings and fixed-width/buffer rules are explicit engineering choices tested by the reference vectors. Papers do not supply custody, lifecycle, attestation or BFF authority; those follow the governing architecture and actual source implementations.

Freeze generic inputs and typed observations now. In parallel, reproduce candidate preprocessing/model behavior against an explicit training/data recipe and shared Swift/Kotlin/C++ fixtures. Freeze artifact-specific shape/normalization/output only after inspecting the graph and checking export/runtime parity. Train or fine-tune weights after the objective, data/splits and baseline protocol are explicit. Do not wait for completed training to establish ownership/binding contracts, and do not make those contracts encode an unqualified model choice.

Each future implementation record must add immutable author-code/graph revisions, exact adopted equations and deviations, common numerical/geometry vectors, conversion/native/Linux receipts, and measured operating points. The existing [NIST track](../../biometric/nist/README.md) governs the real C++ adapter/harness, fork/thread/error behavior and official validation separately from the null-reference mechanics already integrated.

## 7. Foundational motion and human-presence research

[A-Live 2606.05126v1, Sections 4-5.1, PDF pp. 4-5](papers/2606.05126v1.pdf)
frames human-presence inference from six-axis acceleration/gyroscope sequences,
using one-second windows while preserving fine motion structure. Its stated input
units are m/s² and rad/s. Our integrations must distinguish gravity-inclusive
acceleration from platform-fused user acceleration in g before attempting a comparison.
This is a reference for motion across passport, document and selfie workflows.
Only the named sections were reviewed for this entry; no classifier, training
recipe, threshold or reported performance has been reproduced or adopted. The
downloaded revision, licence link, byte count and SHA-256 are pinned in the manifest.
