# Kenshiki Passport SDK

Independent passport MRZ/NFC mechanisms. iOS implements MRZ parsing and camera
capture, the patched NFC reader, BAC/PACE and secure messaging, passive
authentication, AA/CA observations and original DG2 portrait extraction. Android
currently supplies outcome contracts; its reader remains unimplemented.

## Products and integration

- `PassportSDK`: neutral parsing, access-key, typed observation and authenticated-portrait primitives.
- `PassportNFC`: optional native reader and credential verification.
- `PassportMRZCapture`: headless camera/OCR orchestration.
- `PassportMRZPreview`: supplied-session UIKit preview.
- `android/passport-sdk`: Android outcome library.

The iOS reference app composes these products in its Passport → Selfie → Result
journey. Hosts supply trust anchors explicitly; the reference app verifies its
public trust source through `governance/passport-trust.json`. The SDK has no
mandatory biometric, document, identity-product or paid-backend dependency.
The host owns wording, namespaces, storage and final identity policy. mDL remains
separately scoped.

Motion is a shared foundational input. The [motion API and workflow guide](../foundation/motion/README.md)
documents the current passport-to-selfie journey's raw motion journal and phase/event
bindings. MRZ/NFC APIs do not automatically enable that recorder; the enclosing
workflow owns it. Credential authentication and motion-derived observations remain
separate evidence.

The original portrait is admitted through verified DG2/SOD lineage and retains
its original bytes. Current digest-algorithm inference and credential-protocol
limitations are documented in [the extraction ledger](docs/extraction-ledger.md).
Do not interpret passive authentication or portrait availability as complete
identity acceptance. Broader device/protocol qualification, physical wizard and
VoiceOver acceptance remain separate gates.

## Automatic MRZ capture

The supplied preview maps its visible guide into unrotated camera coordinates.
`NativeMRZSession.onReady` requires two complete 44-character TD3 rows (or one
exact 88-character merged observation), confidence-ranked OCR selection within
each physical row, all five
line-2 check digits, and the same complete observation in at least three frames
spanning 0.5 seconds. Gaps over 0.75 seconds, missing/changed rows, preview layout
changes and acquisition retirement reset the hold. Selected rows must lie fully
inside the guide with a 1% interior margin. Separate rows must have the name row
above the key row, a gap no larger than twice the row height, width ratio at
least 0.75, and horizontal overlap at least 90% of the narrower row. These are engineering capture
thresholds, not accuracy or document-authenticity claims.

`onFrame` remains the raw OCR observation callback. Headless hosts opting into
`onReady` must provide their current guide via the preview SPI; missing geometry
never silently defaults to the whole camera frame. The general-purpose `parse`
API retains partial-read behavior, while `parseComplete` rejects truncated,
oversized, competing physical-row documents and same-observation alternative pairs.
Lower-ranked guesses from one physical row do not veto its best valid read.
Acquisition diagnostics log only gate reasons and counts, never passport text.

## Build and validation

From the monorepo root, install tooling as described in [the repository guide](../README.md), then run:

```sh
bash scripts/python.sh scripts/check.py --sdk passport --platform all
bash scripts/python.sh scripts/passport_check.py
```

Individual native lanes include `guards`, `macos`, `ios-device`, `ios-simulator`
and `android`. Deployment floors and dependencies are pinned in `Package.swift`
and the Android Gradle project. Supported physical reader/device paths require
qualification beyond compilation.

[QA](docs/qa.md) records protocol, malformed input, trust/portrait and recovery
obligations. [Port evidence](docs/port-validation.json) and historical scaffold
`docs/qa-validation.json` retain dated source/test identities; fresh behavior,
API and compiler receipts come from the runners. See [HANDOFF.md](../HANDOFF.md)
for the current delivery checkpoint and hosted blockers.

[APP-ARCH-001 revision 0.2](../governance/architecture/APP-ARCH-001.md) governs
integration. [SPEC-IDBIO-200](../governance/references/edge-verification/SPEC-IDBIO-200.md)
§6.2 and Appendix A govern credential evidence. The MIT reader licence, donor
patch lineage and exact crypto supplier revision are retained in
`third-party/NFCPassportReader` and `Gates/extraction-sources.json`. SDK/public
release rights and adopter migration require separate review.
