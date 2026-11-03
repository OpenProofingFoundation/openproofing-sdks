# Liquid AI cookbook references

Pinned on 20 October 2026 for the frozen LFM2.5-VL-1.6B face-comparison baseline.
[manifest.json](manifest.json) records source repositories, immutable revisions,
URLs, exact byte counts, SHA-256 hashes, licence evidence and archive locations.
These are reference copies; none is part of the SDK's compiled source graph.

## Baseline resources

| Resource | What to use |
| --- | --- |
| [Vision capabilities guide](https://github.com/Liquid4All/cookbook/blob/744c5b628a27adb4f219ff4a1d11e3d70259b369/guides/lfm25_vl_image_understanding.ipynb) | Image-plus-text messages, labelled `Media-1`/`Media-2` ordering, processor/chat-template preparation and bounded generation. The guide describes 3B as strongest for multi-image tasks; this does not change the owner's selected 1.6B baseline. |
| [iOS inference source](ios-vision/VLMStore.swift.txt) | The publisher's example selects `LFM2.5-VL-1.6B`, `Q4_0`, loads with `Leap.shared.load`, creates a conversation and streams image-plus-text responses. Its supplied example sends one image; the baseline must separately establish two-image execution. |
| [iOS build recipe](ios-vision/project.yml.txt) | LEAP SDK 0.10.0, iOS 17 floor, `LeapModelDownloader`, nested framework linkage and dylib signing. |
| [macOS inference source](macos-vision/VLMStore.swift.txt) | Companion LEAP flow for native desktop comparison. |
| [Upstream renderer](ios-vision/ContentView.swift.txt) and [app entry](ios-vision/LeapVLMExampleApp.swift.txt) | Reference context only. Kenshiki keeps inference/lifecycle behavior outside renderers under APP-ARCH-001. |

The MIT example copies retain the original [Liquid AI licence](ios-vision/LICENSE).
Their `.txt` suffix makes their reference-only status explicit; do not register
them as executable SDK sources.

Original notebooks, the cookbook catalogue and the pinned LEAP package manifest
are retained in the durable external archive:
`/Users/shf/Developer/kenshiki-face-workbench/references/liquid-cookbook/`.
Notebook `.source.md` companions retain source cells without rendered outputs.
The inspected cookbook/SDK trees did not provide a repository-level licence;
their originals remain in that private archive rather than being vendored here.
The manifest supports byte verification and reacquisition from immutable URLs.

## Baseline application

Use frozen model artifacts, inputs and prompt/generation settings. Record native
loading, raw output, parse/failure states, latency, process memory and runtime/model
digests. Keep AuraFace's cosine and the VLM's observations independently bound to
the same input pair. The iOS recipe's Q4_0 artifact and our local MLX affine 4-bit
conversion are distinct artifacts; record their lineage independently. This pack
does not establish Swift integration, SHF execution, biometric accuracy or a
combined acceptance policy. See [model selection](../../model-selection.md).

## Later reference

The pinned [vision LoRA/TRL notebook](https://github.com/Liquid4All/cookbook/blob/744c5b628a27adb4f219ff4a1d11e3d70259b369/finetuning/notebooks/sft_for_vision_language_model_with_trl.ipynb)
is archived for later work. It has not been executed. Training and corpus-label
changes are outside the current frozen-baseline step.
