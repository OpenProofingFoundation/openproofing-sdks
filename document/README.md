# Kenshiki Document SDK

The iOS document implementation is extracted from `kenshiki-identity-sdk` into this
package. It includes AVFoundation acquisition, Apple Vision OCR/PDF417 and face-region
extraction, the AAMVA structural parser, OpenCV card geometry/normalization and spatial
inspection, temporal recording, source-bound processing and durable front/back recovery.
It has no mandatory identity-product, face-matching, NFC or paid-service dependency.

| Product | Responsibility |
| --- | --- |
| `DocumentSDK` | Portable document/coordinate types, AAMVA parsing and individual-check outcomes |
| `DocumentCaptureApple` | Native camera, guidance, image processing, OCR/barcode and portrait observations |
| `DocumentCapturePreview` | Optional native camera preview and framing overlay |
| `DocumentCaptureJournal` | Bounded temporal recording and its diagnostics |
| `DocumentCapture` | Front/back acquisition, processing, source binding and workflow recovery |

The same-checkout foundation exports `CaptureEvidenceCustody`, backed by its existing
protected storage and evidence-manifest products. The host supplies storage/key namespaces,
its stable installation identity, the native signing adapter, explicit clocks and the
notification centre used by its platform. Public construction never falls back to synthetic
custody when platform keys are unavailable. Debug test fixtures remain explicit and isolated.

## Capture telemetry API

Start with the [foundational motion API and workflow guide](../foundation/motion/README.md)
for motion across passport, document and selfie workflows and current integration gaps.
The [capture telemetry guide](docs/capture-telemetry.md) documents the current iOS
sensor fields, units and reference frames, public acquisition/consumption APIs,
defaults and permissions, bounded front-motion retention, optional temporal frame
recording, clocks, admission and custody bindings. It separates SDK capabilities
from what the reference app enables and describes missing/partial evidence without
claiming continuity, authenticity or liveness from acquisition alone.

## Build and validate

From the monorepo root:

```sh
npm ci --ignore-scripts
npm run bootstrap
bash scripts/python.sh document/scripts/provision_native.py
bash scripts/python.sh document/scripts/provision_test_assets.py
npm run check
bash scripts/python.sh scripts/check.py --sdk document --platform all
bash scripts/python.sh scripts/document_capture_check.py
```

Native provisioning verifies the pinned OpenCV archive and rebuilds the bridge from the
checked-in source. Generated frameworks and the public-domain Vision positive-control
image live under ignored `.build/`; no runtime licence, model weights or sample images
are committed. A previously installed verified OpenCV tree can be supplied explicitly to
`provision_native.py --opencv-source PATH`; it is checked against the same inventory.

The [independent iOS sample](examples/ios/project.yml) uses public APIs, generated JSONC
design/localization resources, and in-memory front/back acquisition and processing. After
provisioning, generate its project with `xcodegen generate --spec document/examples/ios/project.yml`
and open `DocumentCaptureExample.xcodeproj`. It requires a real camera for acquisition;
simulator compilation does not establish physical capture. The sample has no server account,
identity verification or durable signing adapter. App/device acceptance remains separate.

The main native suites use synthetic controls and a pinned public positive portrait.
Private retained-corpus replay is an explicit [assurance harness](assurance/README.md),
excluded from the public required suite and unavailable without its external inputs.
Invoking that harness without the corpus fails; it never reports a skipped qualification.

## Contracts and migration boundary

New profile encodings use stable codes. Historical profile identifiers decode through named
compatibility aliases; original encrypted/signed record bytes are not rewritten. Selected
observation property renames preserve their Codable field names. Current native extraction
uses schema 4; earlier extraction observations remain historical and are recomputed as new
immutable stages when needed. Portrait source/derivative/crop lineage remains explicit.

Passport parsing and NFC remain in the passport capability. Optical passport profile tags
can be retained, but this document package reports their passport assessment as unsupported;
it does not invent a readable MRZ. Face comparison and paid issuing-state checks remain
separate composition. Scan observations do not establish authenticity, liveness or identity.

Android retains its existing outcome-contract scaffold; this extraction adds no Android
camera or processing implementation. Public product releases and nested SwiftPM distribution
remain separate from this local source extraction. Pulse and SSA still consume their existing
SDK inputs until their explicit, reviewed cutovers.

[Extraction provenance](Gates/capture-sources.json), [native provenance](Gates/native-sources.json),
[the extraction ledger](docs/extraction-ledger.md) and [QA](docs/qa.md) record ownership and
executed evidence. Fresh lane receipts live under the repository's ignored `.build/`; dated
checked-in receipts do not qualify a changed tree.
