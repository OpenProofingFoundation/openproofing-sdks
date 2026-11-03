# Existing SDK motion integration comparison

Reviewed: 2026-10-26. Scope: current source and existing tests; no migration.

This comparison reads the existing shared motion package, document motion path,
selfie binding and reference journey recording. Pulse's additional acquisition,
mathematical and fusion mechanisms are documented in the other audit reports.
This is a reuse inventory, not a new collector design or platform qualification.

## Existing paths

| Path | Existing mechanism | Retained evidence | Ownership |
| --- | --- | --- | --- |
| Shared ceremony motion | `PulseCeremonyMotionWitness` → `PulseCeremonyMotionTrace` → `PulseCeremonyMotionSummarizer` | Rolling maximum five seconds / 300 admitted samples, requested 50 Hz; acceleration, rotation, gravity and optional magnetic magnitude; summary and exact-window hash | Independent `KenshikiMotion` package; owner supplies acquisition lifecycle and retention |
| Native selfie | `NativeSelfieSession.startCamera` → `NativeSelfieMotion.start`; `bindCapture` → `motion.evidence` | Receipt binds original image SHA-256 and frame timestamp to monotonic window bounds, requested rate, clock/alignment labels and summary; receipt does not contain raw window | Biometric capability owns image admission and receipt; shared package owns witness |
| Composed passport/selfie journey | `PassportFaceJourneyHost` constructs `WorkflowSensorHost` and `WorkflowEvidenceRecorder` with store-backed persistence ports | Raw `SavedWorkflowMotion` samples plus recomputed summary in `SavedWorkflowEvent`; actions, permissions, recording segments and optional location remain separate fields | Reference application owns workflow, event persistence and sensor lifecycle |
| Workflow projection | Recorder flush → persisted `loadEvents` → `WorkflowMotionProjection` | Ranges, counts, duplicate counts, within-segment observed durations and gaps through exact acknowledged event | Existing app read model; no identity/liveness verdict |
| Document front | `DocumentFrontCaptureController.start` → `DocumentLevelMotionSource.startRecording` → `DocumentTemporalMotionCollector`; capture → recorder finish → attached evidence | Requested 100 Hz; first 600 admitted callbacks; quaternion, acceleration, rotation, gravity, clock correlations, issues and omission counters; still digest/media timestamp binding | Capability owns capture binding; collection/recording primitives are candidates for shared ownership |
| Standalone reference passport | `PassportFlowHost` / `PassportNativeEffects` own MRZ/NFC effects | This host does not construct the journey's motion recorder; its enclosing composition must supply workflow motion | Credential reading remains a capability; workflow recording is optional composition |

The ambient/recorded Pulse aggregates are separate products of their acquisition
paths. Neither a minute aggregate nor a selfie summary can reconstruct raw
callbacks that were not retained. Conversely, those aggregate paths do not mean
the composed reference journey lacks retained raw samples.

## Existing behavior to preserve

The shared summary source is hash-pinned to the original Pulse implementation in
[`foundation/motion/sources.json`](../../../foundation/motion/sources.json).
The shared test suite preserves nine summary cases and adds six bounded-trace and
three permission cases. Current public ceremony names, hash bytes, spectral
definition and undefined-feature behavior are compatibility inputs.

`PulseCeremonyMotionTrace` rejects invalid values and non-increasing callbacks,
rebases selected samples, and bounds both count and time. A snapshot excludes
future samples, requires at least two samples and refuses a last sample more than
0.2 seconds before the requested cutoff. Its public output does not count rejected
callbacks or evicted samples. Calibration is a selected-window majority flag,
not a per-sample calibration history. The witness currently selects a reference
frame internally without returning the selected frame in the sample contract.

`NativeSelfieMotion.evidence` checks frame age against host uptime before asking
for a cutoff snapshot. The result labels this `host_uptime_checked`; the source
does not compute camera-to-IMU calibration or synchronization uncertainty.
`NativeSelfieSession` owns a different witness from `WorkflowSensorHost`; the two
sets of samples and fingerprints are not interchangeable. The session's snapshot
override is an internal test seam, not a public shared-recorder injection API.

`WorkflowEvidenceJournal` retains a failed prepared event at the head of a bounded
32-entry FIFO and retries the same event ID/bytes. Its high-water mark advances
after acknowledged append. Overlap trimming operates within a recording segment;
erasure retires the journal and awaits the active storage call. The persistence
port and acknowledgement boundary were read; this report does not independently
audit every underlying SQL transaction or storage migration.

`SavedWorkflowMotion.validate` requires requested rate 50, bounded monotonic
samples, agreement of wall/uptime durations and equality of the recomputed summary.
Its overlap trim uses a one-nanosecond tolerance. The journal's recorded gap uses
a fixed 0.02-second expected period. These are existing 50-Hz semantics, not a
general configurable sensor-timeline contract.

`WorkflowMotionProjection` joins durations only within a segment when adjacent
samples are within 1.5 requested periods plus numerical tolerance. Duplicate
timestamps must have identical values; conflicting or stale evidence fails.
Recorded axis/magnitude extrema preserve small values. Window-summary extrema
are distinguished from sample extrema. It retains bounded recent sample tails
while accumulating the workflow's ranges; a resumed segment does not fill the
unobserved interval with invented coverage.

`DocumentMotionRecorder` preserves explicit invalid/out-of-window omissions,
callback issues and clock discontinuities. It can retain a non-increasing sample
while recording the discontinuity, unlike the shared trace's rejection behavior.
After its first 600 admitted samples, it counts omissions rather than rolling
forward. `recorded` means a bounded record without issues/omissions; it is not the
Pulse minute-window coverage qualification. `DocumentMotionEvidence.requireValid`
binds the still digest/media timestamp while requiring `stillHostTimeSeconds` nil.
The document still association does not establish measured exposure alignment.

## Reuse and difference table

| Mechanism | Reuse boundary | Difference requiring an explicit contract |
| --- | --- | --- |
| Pulse timing/window/reducer primitives | Candidate Sensors SDK core; see acquisition and mathematics reports | Distinguish aggregate observation windows from retained raw sample windows |
| Existing shared witness and summarizer | Preserve implementation, vectors and compatibility API | Additive metadata/quality contract must not reinterpret legacy summaries/hashes |
| Document callback/clock/issue handling | Reuse existing primitives after ownership separation | First-N retention, discontinuity retention, quaternion/reference-frame and omission semantics differ from rolling shared trace |
| Selfie image/window association | Keep typed adapter at capability boundary | Any future common recorder must preserve exact capture interval and original binding; latest-window substitution is invalid |
| Workflow journal/overlap/range mechanisms | Reusable behavior exists; identify neutral pieces | Current types depend on face/passport records and app persistence; generation, actions, consent and retention remain host decisions |
| Pulse fusion/kinematics and BFFs | Reuse audited mathematical/observation mechanisms | Product policy, story copy and server identity acceptance remain outside a neutral sensor core |
| Packaging | Existing independent local motion package and tests | Root SwiftPM manifest does not export motion; standalone distribution needs an explicit product/package decision |

These are reconciliation points, not evidence that a replacement implementation
is needed. The audit has introduced no new sensor operator, threshold or collector.

## Existing conformance evidence

Executed `python3 foundation/motion/check.py`: **18 required tests passed**,
source hashes unchanged. This exercises the shared summary, bounded trace and
permission state machine on the macOS host. The copied execution record and
report digests are in `verification.json`; original logs/XML/receipt remain under
`.build/foundation-motion/`. This does not execute live iOS sensor callbacks.

Read in full, not executed in this audit:

- `DocumentMotionEvidenceTests.swift`: raw round trip and native binding,
  sample/issue capacity and omissions, invalid/old/future/reversed callbacks,
  distinct unavailable reasons, late-generation refusal, cross-session/attempt
  binding refusal and malformed public-record validation.
- `WorkflowEvidenceTests.swift`: long workflow extrema/coverage with bounded
  retained tails; overlap/conflict/order/resume behavior; permission/magnetic
  absence; historical boundary paging; persisted projection; byte-bounded pages;
  failed-write retry; lost acknowledgements; erasure retirement; and refusing
  sensor start before the workflow-start record commits.

The assertions and names are existing coverage, not newly executed results.
Required capability native lanes, Pulse iOS suites, installed behavior and physical
acceptance remain separate from the 18 shared-package tests above.

## Source record

Paths below are relative to `/Users/shf/Developer/kenshiki-sdks`. Files cited in
this report were read in full; hashes and read/hash interval limits are recorded
in `sdk-comparison.sources.json` and `baseline.json`.

- `foundation/motion/Package.swift`, `README.md`, `sources.json`, `check.py`,
  all four `Sources/KenshikiMotion/*.swift` files and all three test files.
- `document/docs/capture-telemetry.md`; `DocumentFrontCaptureController.swift`,
  `DocumentLevelMotionSource.swift`, `DocumentTemporalMotionCollector.swift`,
  `DocumentMotionRecorder.swift`, `DocumentMotionEvidence.swift`,
  `DocumentTemporalEvidence.swift`, `DocumentTemporalEvidenceManifest.swift`;
  `document/ios/Tests/AppleTests/DocumentMotionEvidenceTests.swift`.
- `biometric/ios/Sources/BiometricCapture/NativeSelfieSession.swift`,
  `NativeSelfieMotion.swift`, `SelfieMotionEvidence.swift`,
  `SelfieAdmissionReceipt.swift`.
- `reference-apps/ios/Sources/WorkflowSensorHost.swift`,
  `WorkflowEvidenceRecorder.swift`, `WorkflowMotionProjection.swift`,
  `SavedFaceWorkflow.swift`, `PassportFlowHost.swift`,
  `PassportFaceJourneyHost.swift`; `ControllerTests/WorkflowEvidenceTests.swift`.
- Root `Package.swift`, `README.md`, `governance/monorepo.md` and the governing
  repository/capability instruction files.

Other sensors, Android acquisition, physical ground truth and the external SHF
snapshot/research are outside this source-comparison slice. No claim of their
qualification follows from the motion reuse inventory.
