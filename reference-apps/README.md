# Native reference applications

## iOS capability examples

The app opens with visible Document, Passport and Biometric capability tabs. Document
capture starts only after an explicit action and reviews both original images,
prepared card images, OCR, PDF417 and provisional portrait candidates. Its review clears from memory on withdrawal or backgrounding. Each captured side is saved in a dedicated protected SQLite store with a local signed manifest before the workflow advances. Front capture also retains a bounded segment of actual phone-motion callbacks, its native source bindings, clock correlations and explicit issues/omissions. Its independently signed motion row, the capture snapshot and the current revision pointer commit together. Pairing a back image preserves the original front-motion row; back motion is not collected in this increment. **Open saved capture** verifies the whole declared set and restores the exact historical images and observations without camera acquisition or reprocessing; a front-only save can continue with an explicit back capture. **Delete saved capture** requires confirmation and erases document custody separately from session reset. These observations and their local signatures do not verify identity, sensor authenticity or document authenticity. Passport and biometric examples use
their live SDK products. Android retains simulated examples.

The [foundational motion API and workflow guide](../foundation/motion/README.md)
traces existing passport-to-selfie recording, selfie capture bindings and document
motion, including differences in raw retention and public versus app-owned APIs.
The [document capture telemetry API guide](../document/docs/capture-telemetry.md)
records the current sensor inventory, units, clocks, retention limits and the
difference between public SDK options and this app's enabled capture paths.

The guided **Passport → Selfie → Result** route remains available through an explicit
Debug regression launch argument. Begin admits passport capture
after visibility; manual MRZ input remains a fallback before NFC. Chip-read and
verification failures offer retry/cancel without manual-entry recovery. One confirmation starts
the chip read. The original chip portrait and Continue to selfie lead to live
capture, review, Compare faces and a combined result. Retake selfie retains the
passport; Done and Cancel clear the session. Technical passport and motion details open in a separate sheet. Done is the
only fixed result action; retake and retry use the result menu.

Real backgrounding clears active acquisition and allows a new Begin; committed evidence remains available for explicit recovery. CoreNFC's
resign-active sheet does not count as backgrounding. Starting another journey
waits for the retired NFC/camera owner to settle. Late or foreign completions
cannot enter the replacement session. The same original portrait and reviewed selfie feed AuraFace's cosine observation.
The pending capture, comparison boundary and settled Aura outcome remain durable;
recovery reuses matching committed results. The output is uncalibrated and does
not authorize identity acceptance.

Liquid inference, pass orchestration, model provisioning, MLX dependencies and
active visual-report UI were removed on 22 October 2026. App-owned passive
compatibility readers retain existing visual-stage/pass records and raw workflow
archives, including their original profile and input bindings. Historical data
can be exported diagnostically without loading a model or resuming retired passes.
The comparison-time evidence snapshot remains fixed on retry.

Within the guided Debug route, SDK examples opens the capability tabs and Done
returns to the guided entry. Normal capability navigation keeps the tabs visible.
Android configuration recreation retains controllers through a ViewModel;
process-death restoration is not implemented.

Controllers own state, admission, validation, cancellation and effects. Native
hosts own composition, localization and lifecycle forwarding. Renderers consume
prepared content and emit supplied events. `NativePageContainer` owns bounded
scrolling, insets, keyboard accommodation and action placement. The
[design system](../design-system/README.md) generates copy, semantic controls and
[Icon Composer artwork](../design-system/APP-ICON.md). The optional headless SDKs
remain independent of this app composition. The app owns its saved passport
checkpoint; attestation and BFF policy remain separate. See [APP-ARCH-001 A.7](../governance/architecture/APP-ARCH-001.md#a7-guided-native-passport-and-selfie-reference-journey).

The guided Debug start screen has one primary action, **Start new comparison**. **Saved work**
contains passport reuse, the last comparison and unfinished chip reads; capture
dates appear there. Deletion requires a separate confirmation from Saved work.
Developer tools contains the independent SDK examples and recording status.

The live selfie preview stays mounted across readiness updates. Guidance below
it reserves its localized height and settles for 250 ms before changing. A
capture refusal disables the shutter immediately; the SDK retains all original
freshness, blink, depth and automatic-capture requirements.

## MRZ acquisition and camera selection

The host consumes `NativeMRZSession.onFrame` continuously, matching Pulse's
`MRZCapture` candidate delivery. The existing complete-read parser, check digits,
ambiguity refusal, durable commit and explicit confirmation still gate NFC. The
reference flow does not wait for the optional SDK guide/three-frame hold; that
`onReady` interface remains available unchanged to other hosts. Restarted and
retired camera callbacks remain generation-fenced.

The camera uses the established identity SDK policy: rear dual-wide, triple,
wide, ultra-wide, then telephoto, with resolution and stable-ID tie breaking.
Virtual devices use native automatic constituent switching, bounded switch-over
baseline zoom and continuous focus/exposure. Full-frame accurate Vision OCR and
its existing candidate settings are unchanged. The exact donor files and hashes
are recorded in the [passport extraction inventory](../passport/Gates/extraction-sources.json).
This source repair and its native tests do not establish physical MRZ speed or
focus behavior on SHF; that requires a scan on the installed build.

The correspondence recovery messages and key/family/given-name precedence reuse
Pulse's `NFCPassportStepView.identityMismatchMessage` at `bf68a710`, file SHA-256
`8c9f1c23fd35b09b15b18b645cb15cea6c451bd36b92db84ca9cd91b6fc45369`.
The SDK comparison uses authenticated DG1 MRZ names rather than the vendor model's
DG11-preferred display names, preserving original DG11 data. Genuine differences
still refuse the read. Post-server diagnostics contain only typed field/comparison
states and checkpoint outcomes, never field values or credentials.

## Build and runtime inputs

Open `ios/KenshikiReference.xcodeproj` and run scheme `KenshikiReference` on an
iOS 18+ simulator/device. The bundle is `com.kenshiki.reference`.
Regenerate the checked-in project after editing `ios/project.yml`:

```sh
xcodegen generate --spec reference-apps/ios/project.yml
xcodebuild -project reference-apps/ios/KenshikiReference.xcodeproj -scheme KenshikiReference -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/reference-ios CODE_SIGNING_ALLOWED=NO build
```

The primary journey requires hardware-backed protected storage, which the iOS
simulator cannot provide. Simulator UI tests exercise that refusal and its recovery
controls; injected controller tests exercise the complete durable journey. The
separate SDK examples remain available in the simulator.

Live acquisition requires a supported TrueDepth/NFC device. Simulator tests use
controlled controller/host seams and unsupported-hardware paths; there is no
shipped capture bypass. [The inference route](../contracts/apple-face-alignment-v1.md)
owns ImageIO decoding, exactly-one-face landmarks, alignment and AuraFace processing.

`provision_reference_model.py` packages external AuraFace weights only after
checking their pinned size/hash. The C++ session checks the actual consumed bytes
again. Liquid weights and prompt resources are no longer provisioned into any
reference-app build.
`provision_reference_trust.py` packages the external public CSCA bundle and
manifest; the host checks its hash before passing an explicit URL to the reader.
The local trust source is `~/Library/Application Support/Kenshiki/PassportTrust/csca.pem`;
`governance/passport-trust.json` pins it. Missing external inputs produce compile-only
artifacts with explicit unavailability. Verify packaged model/trust material
before delivery. No model weights, trust bundle, private key or identity media
are committed. The existing bundle is not a newly qualified global trust-update
service; the preserved OpenSSL reader owns certificate verification.

Android uses `android/` in Android Studio, JDK 17 and platform 37.0 with the app's
pinned Gradle 9.8.2 wrapper and AGP 9.4.1. Preserve strict dependency verification
and lint.

## Validation and acceptance

Debug builds on a physical device support direct retrieval of the committed
comparison JSON. With the app foregrounded, run from the Mac using a compatible
active Xcode toolchain:

```sh
bash scripts/python.sh scripts/pull_reference_diagnostics.py --device SHF --output /private/tmp/kenshiki-comparison.json
```

The command waits for inference to settle, then retrieves the matching response
from `Library/Caches/KenshikiDiagnostics/response.json` in the app container.
The `report` member contains the comparison report and individual persisted Liquid
passes. It excludes image bytes, encryption keys and the full raw workflow archive.
Document DOB and current-age candidates are redacted from exported inputs; age
results remain available. Input hashes refer to the original records, so these
redacted projections cannot be used as exact request replays. The export worker
shares the journey's store lifecycle across deletion and subsequent captures.
Use `--operation-id <UUID>` to select an older saved comparison. No NFC rescan,
selfie recapture, clipboard access or app restart is required for retrieval.
The handoff is debug-only, foreground-only and bounded; see APP-ARCH-001 A.11.

Run `bash scripts/python.sh scripts/presentation_check.py --platform <lane>` for
`macos`, `ios-device`, `ios-simulator`, `ios-ui` or `android`. Source governance,
generator drift, typed controller tests and compiled resources accompany the
native lanes. Current receipts include exact source/test/artifact identities in
`.build/presentation/`; inspect `passed`, timestamps and required test IDs.
[HANDOFF.md](../HANDOFF.md) records the current delivery checkpoint and hosted
blockers without duplicating them here.

[Accessibility acceptance](ACCESSIBILITY-ACCEPTANCE.md) and the
[criterion matrix](WCAG-MATRIX.md) retain manual and physical gates. Local UI
screenshots, synthetic host tests, signed builds and installation do not establish
VoiceOver/TalkBack, complete physical flows, calibrated recognition or PAD accuracy.

The iOS result screen and biometric example provide **Copy report**. This explicit
clipboard action copies the Aura state, full-precision score and sensor values,
source hashes and the capture receipt; image bytes remain excluded. Existing
visual history stays available to the explicit diagnostic export as historical
records. New captures do not create or resume Liquid analyses. Copying reads
committed records and is not the save boundary.

The default journey commits its completed, locally checked NFC capture to the shared protected
SQLCipher store at `Application Support/PassportCheckpoint/passport.sqlite`.
It shows the passport result and enables Continue only after that commit succeeds.
A failed write retains the captured data for a storage retry without another NFC scan.
Leaving after a write is admitted does not cancel that write, but its completion cannot
reopen the retired screen. MRZ commits independently before confirmation, and the admitted selfie commits before
review. Continue does not defer either capture's persistence.
**Use saved passport** starts a new selfie attempt with the exact original portrait;
it does not start NFC or reuse a selfie. **Open saved comparison** restores recorded
results without acquisition or inference; **Retry incomplete analysis** retries
AuraFace using stored images and matching completed results. **Resume chip
reading from saved MRZ** starts at confirmation without optical reacquisition.
**Delete saved workflow data** erases the database family and its key through
foundation lifecycle fencing. The Document example uses its own protected capture store and confirmed deletion action; other standalone examples retain their existing session-only behavior.

Schema version 1 introduced one checkpoint, its capture identifier/time, local scope,
payload/portrait/SOD digests, and a bounded binary-property-list payload containing
the MRZ, original DG2/portrait, data groups, certificate and protocol observations.
The capture time comes from completion of the original local read. The payload and
binding columns must agree before restoration. A checksummed migration history and
SQLite `user_version` govern initial creation and future upgrades. Schema creation
and replacement writes are transactional; unsupported or inconsistent schemas are
refused without destructive recovery. Startup completes only an already recorded
erase intent, including interruption after ciphertext deletion. Key custody uses
the resolved app-only Keychain group and the foreground device-protection profile.

Schema version 2 adds immutable selfie/comparison records and workflow events;
version 3 adds the indexed, append-only Liquid pass journal. Version 4 preserves
that journal while expanding task identifiers and adding immutable comparison
snapshots. Migrations are checksummed and transactional; v3 rows remain readable
but cannot satisfy a v4 request. Historical pass descriptors were committed and
read back before inference. Their completed and failed outcomes preserve source/model/prompt
binding, raw output and token/time diagnostics. Failed writes stop the dependent
step; retries never replace the original outcome. Full workflow motion is drained
in bounded windows with explicit gaps, while capture-time location includes its
permission, accuracy and timestamp. EXIF is not treated as an authenticity proof.

Live acquisition composes Pulse App Attest registration, a server nonce, Chip
Authentication challenge relay and server verification around the existing SDK
reader. DG2 and portrait bytes remain on the device. Local authenticity checks
and the server verdict remain separate. Saved evidence retains the original
trust-bundle digest and, when available, SOD-bound historical server metadata;
restoration makes no fresh NFC, App Attest, nonce, revocation or verification
claim. Older local-only records remain explicitly without server verification.
Physical server-ceremony acceptance is still open; see [HANDOFF.md](../HANDOFF.md).
