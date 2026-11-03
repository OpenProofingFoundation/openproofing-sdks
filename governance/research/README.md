# Verification research references

This is the active engineering literature pack, separate from the frozen specification snapshots in `governance/references/`. [manifest.json](manifest.json) records exact arXiv revisions, authors, source URLs, retrieved times, source-declared licence links, PDF byte counts and SHA-256 digests. The PDFs are downloaded reference copies, not selected SDK models or weights. Published figures remain part of the papers; do not ingest them as training/evaluation media. Keep paper, implementation-code, dataset and weight rights separate; this private review pack does not grant public redistribution rights for every source.

[Method notes](method-notes.md) record the specific equations/sections inspected, their scope and the resulting contract/test obligations. This is a curated foundation, not an exhaustive literature review. A source's presence is not evidence that its model has been reproduced or evaluated here. Algorithm changes must identify the source revision/section and the exact numerical or behavioral test that applies it; do not cite only a model name or substitute recalled formulas.

| Reference | Source copy | Design use |
| --- | --- | --- |
| FaceNet | [1503.03832v3](papers/1503.03832v3.pdf) | Unit embeddings, triplet learning and comparison geometry |
| SphereFace | [1704.08063v4](papers/1704.08063v4.pdf) | Multiplicative angular margins and their domain |
| CosFace | [1801.09414v2](papers/1801.09414v2.pdf) | Normalized cosine-margin training |
| ArcFace | [1801.07698v4](papers/1801.07698v4.pdf) | Additive angular margin and hypersphere geometry |
| AdaFace | [2204.00964v2](papers/2204.00964v2.pdf) | Model-dependent feature norm and adaptive training margins |
| MagFace | [2103.06627v4](papers/2103.06627v4.pdf) | Magnitude-aware margin/regularization assumptions |
| Probabilistic Face Embeddings | [1904.09658v4](papers/1904.09658v4.pdf) | Uncertainty and a score distinct from cosine |
| MobileFaceNets | [1804.07573v4](papers/1804.07573v4.pdf) | Mobile face backbone and spatial aggregation |
| SCRFD | [2105.04714v1](papers/2105.04714v1.pdf) | Efficient detector training/computation allocation |
| MobileViT | [2110.02178v2](papers/2110.02178v2.pdf) | Local/global mobile feature processing |
| CDCN | [2003.04092v1](papers/2003.04092v1.pdf) | Central-difference operator and face PAD supervision |
| DeepPixBiS | [1907.04047v1](papers/1907.04047v1.pdf) | Frame-level pixel-supervised face PAD |
| Document PAD / MMDT | [2404.06663v1](papers/2404.06663v1.pdf) | Recapture traces and document-specific domain shift |
| A-Live (preprint) | [2606.05126v1](papers/2606.05126v1.pdf) | Passive IMU micro-motion research for human-presence inference across workflows; reference only |
| DigiFace-1M | [2210.02579v1](papers/2210.02579v1.pdf) | Synthetic identity/variation design and real-domain adaptation |
| Kabsch-Umeyama justification | [1902.03138v6](papers/1902.03138v6.pdf) | Orientation-preserving rigid fit via SVD; NIST-authored geometry reference |

Other primary authorities are the [integrated NIST 1:1 source/interface pins](../../biometric/nist/README.md), the [official API](https://pages.nist.gov/frvt/api/FRVT_ongoing_11_api.pdf), [general specifications](https://pages.nist.gov/frvt/api/FRVT_common.pdf), [FRTE metric definitions](https://pages.nist.gov/frvt/html/frvt11.html) and [NISTIR 7740](https://www.nist.gov/publications/comparison-confidence-intervals-large-operational-biometric-data-parametric-and-non). Direct PDF retrieval of the NIST-hosted documents returned HTTP 403 during this acquisition; those URLs are references, not locally cached PDFs. The local NIST-authored geometry paper was acquired from its versioned arXiv copy. Existing official headers/driver/source manifests remain the offline NIST implementation authority.

## Working from the references

Read the applicable method sections and their limitations before implementing or changing an operator. Record whether a formula is reproduced, algebraically derived here, or an explicit Kenshiki numerical/resource choice. Add common positive/negative vectors and native parity evidence. A paper's reported accuracy, parameter count or runtime is not a measurement of our artifact or target hardware.

The [model-role record](../model-selection.md) still says no deployment model is selected. Qualify the artifact and training/evaluation recipe alongside contract development. Freeze preprocessing/output interfaces against actual exports before an adapter is accepted. C++20/Linux/NIST, Swift/Core ML and Kotlin/Android are required consumers; graph conversion alone does not prove numerical or decision parity.

Reference integrity is exercised by the governance suite. PDFs are read-only source artifacts; corrections use a new version/digest with reviewed notes, never an in-place overwrite hidden behind the same citation.
