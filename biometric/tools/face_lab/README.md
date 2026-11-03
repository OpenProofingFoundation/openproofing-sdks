# Local face development workbench

The workbench prepares local Mac training/conversion tooling and the AXON public samples. Training data, reference source checkouts, virtual environments and generated model artifacts stay in an explicitly selected directory outside the entire monorepo. Run the following commands from `biometric/`.

```sh
tools/face_lab/setup.sh /absolute/external/workbench
/absolute/external/workbench/venv/bin/python tools/face_lab/data.py acquire --workdir /absolute/external/workbench
/absolute/external/workbench/venv/bin/python tools/face_lab/sample_index.py --workdir /absolute/external/workbench
```

`setup.sh` requires native arm64 Python 3.11. The hash-locked environment pins PyTorch 2.7.0/torchvision 0.22.0, Core ML Tools 9.0, ONNX 1.18.0, ONNX Runtime 1.22.0, NumPy/Pillow/HEIF decoding, safetensors, CMake and Ninja. The 2.7 conversion baseline follows [Core ML Tools 9's support](https://github.com/apple/coremltools/releases/tag/9.0), rather than adopting a newer training runtime without checking conversion.

Setup checks installed dependencies, performs a real optimizer step on MPS when available, exports a synthetic convolution network to ONNX and Core ML FP16, and compares runtime outputs with PyTorch. It writes actual versions, execution backends, errors and artifact hashes to an external receipt. This is a toolchain exercise using generated tensors; the face detector/backbone/loss and training recipe are the next implementation slice.

The resolver used to generate the lock is pip 25.1.1 with pip-tools 7.5.0. Explicit regeneration:

```sh
/absolute/external/workbench/venv/bin/python -m pip install pip-tools==7.5.0
/absolute/external/workbench/venv/bin/pip-compile --generate-hashes --strip-extras --output-file tools/face_lab/requirements-macos.lock.txt tools/face_lab/requirements-macos.in
```

## AXON samples

The active corpus has expanded to the relevant public catalogue samples; use [docs/axon-data.md](../../docs/axon-data.md) and our [canonical corpus contract](../../../contracts/corpus-v1.md). The single-archive counts below are historical. The owner selected one canonical corpus and authorized retiring verified ZIPs/vendor folders; query the canonical index for current counts.

The owner selected the public samples for the starting development dataset. `data.py` follows all file-list pages, pins dataset version 6, checks the downloaded ZIP against the complete advertised file inventory, validates bounded archive paths/sizes and hashes each file. It inspects image formats rather than trusting filename extensions; eight JPEG-named files in this sample are HEIC and use the pinned HEIF decoder.

The observed archive has 315 files: 313 images, one JSON and one CSV; 312 distinct image hashes. Its two sample collections yield 30 provisional source-folder groups, 59 reference candidates and 254 selfie candidates. All 30 groups contain both candidate roles. Folder labels and filename-based roles remain provisional; 50 image-containing directories include category subfolders and are not 50 identities. The index retains source path, exact bytes/digest, dimensions and provisional label basis. It does not invent verified person counts or evaluation splits.

Historically, raw metadata, ZIP and private index lived under `data/quarantine/axon-selfie-id-v6`; that redundant tree has since been retired after migration into `data/canonical/`. `summary.json` and `sample-index-summary.json` report inspected counts. Exact-duplicate detection is not proof that visually duplicated people are absent. Reconcile labels and aliases before subject-disjoint training/calibration/evaluation partitions. Sample experiments remain tagged as such; commercial training/model publication has its own provenance record. [Source listing](https://www.kaggle.com/datasets/axondata/selfie-and-official-id-photo-dataset-18k-images).

## NIST development lane

See [nist/README.md](../../nist/README.md). The official C++ interfaces are pinned independently of mobile APIs. Local commands stage verified headers and compile a C++20 interface probe. The Linux development container additionally checks g++ 13.3.0/x86_64 compilation and execution under emulation on this Mac. The official validation driver and common code are now integrated under `nist/upstream/` with a source manifest, guards and a separate Linux CI job. `nist/check.py` executes synthetic driver mechanics using NIST's null reference; the actual algorithm adapter and full official validation follow the selected face artifact.

## Tests and evidence

`npm run check` includes synthetic archive traversal/symlink/duplicate-entry and metadata-pagination/version tests plus provisional-label and pinned-requirement checks. No real images enter those tests or CI. Local smoke/data/NIST receipts are summarized in [docs/face-workbench-status.json](../../docs/face-workbench-status.json); detailed logs and artifacts remain external.
