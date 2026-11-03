# FRTE 1:1 C++ adapter and validation track

This is a required face SDK delivery track. It produces a Linux C++ algorithm adapter around the selected face artifact, a local adversarial/compatibility harness, and integration with NIST's official validation package. The official validation code is integrated under `upstream/`, separately from mobile SDK targets. Its 24 source/build/script/input-list/license files are pinned by `upstream-manifest.json` and an independently reviewed manifest digest in `Gates/nist_integrity.py`. Biometric guards reject unreviewed modifications, missing/additional files and symlinks. Four Bash scripts carry attributed reliability patches (Bash conditionals, stderr diagnostics, command substitutions, explicit returns and the HTTPS submission link); their original and patched digests are preserved in the manifest. The API headers, C++ driver and reference implementation remain unmodified. Real validation images remain external. No Kenshiki recognition library is implemented by this integration.

[sources.json](sources.json) is the authoritative source/digest manifest. It pins unmodified `frvt11.h`, `frvt_structs.h`, validation README and build metadata at upstream revision `18c2f84d80c0636cede6ff1db0479fe068aedac4`. The checked requirements are 1:1 API 6.0.1 and General Specifications 3.1.

## Integrated code and executed mechanics

From the monorepo root:

```sh
python3 biometric/nist/check.py --compiler clang++
# Linux CI uses the same runner with g++-13:
python3 biometric/nist/check.py --compiler g++-13
# On this Mac, exercise the same Linux compiler/driver in the existing image:
python3 biometric/nist/check.py --compiler g++-13 --container-image kenshiki-face-frte-dev:20261016 --build-root .build/nist-linux
```

The runner builds the unmodified NIST null reference as a shared library and links the actual official `validate11` driver and common utilities. It runs enrollment and verification using generated non-face RGB/grayscale inputs, including a multi-image input, followed by matching, with two forked children per invocation. It checks output records and templates, and records compiler/host, source pin, commands, binary/log hashes and outcomes under `.build/nist/`. The `biometric / NIST tooling` Linux CI job executes this separately from the 15 native SDK lanes and uploads its evidence even on failure.

The null implementation belongs to NIST and supplies dummy features/scores; it is confined to this tooling mechanics test and is never linked into an SDK or presented as our adapter. This is not execution of the full official validation package or biometric performance evidence. The future real adapter must satisfy the contracts below. Upstream `run_validate_11.sh` includes package installation and submission-archive preparation; the mechanics runner does not invoke it.

Attribution and terms are preserved verbatim in [upstream/LICENSE.md](upstream/LICENSE.md) and in upstream source notices. All imported files come from the same revision as the earlier interface pins.

## External header probe and Linux development image

From `biometric/`:

```sh
docker build --platform linux/amd64 -f tools/face_lab/nist.Dockerfile -t kenshiki-face-frte-dev:20261016 tools/face_lab
/absolute/external/workbench/venv/bin/python tools/face_lab/nist_sources.py --workdir /absolute/external/workbench --linux-check
```

The source tool stages bytes from the integrated, pinned source tree without downloading them again, verifies their digests, compiles the official headers using local C++20, and optionally compiles/runs the same header probe under the Linux development image with no network and a read-only source mount. The host Python runner can also execute the compiler and driver in this image, with network disabled and a read-only source mount; generated inputs and build artifacts have a separate writable mount. The receipt records compiler, architecture, image identity and scope. It performs no face extraction or matching.

## Required adapter/harness contracts

- Implement the official factory, initialization, face-template overloads and matcher; return the required unsupported code for iris. Preserve API roles, eye-coordinate associations and multiple-image/multiple-face semantics.
- Define bounded, versioned template bytes. Validate lengths, artifact compatibility, finite embeddings/norms and malformed inputs. Failed or zero-length extraction must remain safe input to matching, with the exact API return/score behavior.
- Exercise initialization **before fork**, then actual extraction/comparison in forked children. Enforce and measure single-thread execution and safe runtime initialization; environment variables alone are not evidence.
- Run deterministic extraction/comparison and Python-to-C++ preprocessing/embedding parity on allowed fixtures. Check RGB/grayscale, multi-image inputs, malformed buffers, failures, empty templates, dependencies, CPU instructions and resource behavior.
- Build the submission `.so` for Linux x86_64 with C++20/g++ 13.3.0 compatibility and run official validation in NIST's specified Ubuntu 24.04.3 environment. The pinned development container currently identifies as Ubuntu 24.04.5; it is a compatibility-development environment, not that exact qualification installation. Apple Silicon emulation is not a NIST timing platform.
- Record model/preprocessing, compiler/OS/CPU, thread count, exact commands, source/library hashes, official validation output and package provenance. Current API timings and announced effective dates govern; internal targets are separate.
- Keep validation, signing/encryption, submission, NIST execution and published results separate. Actual submission/contact is outside local implementation work.

The [official 1:1 API](https://pages.nist.gov/frvt/api/FRVT_ongoing_11_api.pdf), [general specifications](https://pages.nist.gov/frvt/api/FRVT_common.pdf), [validation source](https://github.com/usnistgov/frvt/tree/18c2f84d80c0636cede6ff1db0479fe068aedac4/11) and [status/participation page](https://pages.nist.gov/frvt/html/frvt11.html) govern. Recheck them at qualification/submission, including the announced November 30, 2026 execution changes. The official validation images are validation inputs, not face-training data.

## Portable contract core

The runner now first compiles [the Kenshiki C++20 primitives](../cpp/README.md) with strict warnings, ASan/UBSan and fatal sanitizer recovery. It generates cases directly from the root portrait and embedding fixtures (200 + 30 cases), then runs additional ownership, request-substitution, lifecycle/concurrency and numerical attacks. Source/vector hashes and binary/log hashes are retained in its receipt. OpenSSL EVP (`libssl-dev`) supplies SHA-256 on Linux; Apple uses CommonCrypto. This core is separate from the upstream null reference and is ready for reuse by the real algorithm adapter. No template encoding, preprocessing or inference is supplied by this slice.

## Aligned-input inference track

The separate optional [C++ AuraFace CPU target](../cpp/README.md#optional-aligned-input-inference) now executes the selected embedder on already-aligned RGB112 pixels. This is not yet the NIST algorithm interface or portable template format. The existing Linux CI job additionally builds and tests this target using generated ONNX graphs and pinned ORT, with no real images or learned weights. Local actual-weight receipts establish synthetic numerical parity only. The unmodified official driver still exercises its upstream null reference; recognition evaluation is not claimed.
