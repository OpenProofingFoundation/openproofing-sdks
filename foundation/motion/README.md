# Kenshiki Motion: current SDK APIs and workflow integrations

Implementation inventory reviewed 2026-10-26 against the current checkout,
including pending integration changes. This is an as-built guide, not a new API
design, released-version guarantee or physical liveness qualification.

Motion is a foundational input across passport, document and selfie workflows.
The shared `KenshikiMotion` Swift package already lives here. Its APIs are used by
selfie capture and the reference passport-to-selfie journey. Document capture
currently has a separate recorder and evidence shape. A single recorder, schema
and timeline shared by every workflow is **not yet implemented**.

The shared product was extracted from `pulse-ios` revision
`c77d87bacd166eabcc69e2de1afadbd8fa7d8de8`. The original summary implementation,
field names, units, fingerprint and nine numerical test vectors were retained.
[Source provenance](sources.json) records donor hashes and adaptations. This
package has no dependency on the Pulse application or its UI; its existence does
not establish that every predecessor application has migrated to import it.

## Products, ownership and current coverage

`foundation/motion/Package.swift` independently exports `KenshikiMotion`, targeting
iOS 18 and macOS 13. Live collection is implemented for iOS/Core Motion; the macOS
build supports the portable types/summary code, not the live iOS witness. There is
no Android sensor implementation in this package. Applications select this package
directly or consume it through the biometric product's dependency.

| Layer / API | Current responsibility | Current integration |
| --- | --- | --- |
| `KenshikiMotion.PulseCeremonyMotionWitness` | Bounded device-motion collection, raw windows and monotonic snapshots | Used by native selfie capture and reference journey sensors |
| `PulseMotionPermission` | Explicit Motion & Fitness permission adapter | Used by selfie and reference journey owners |
| `PulseCeremonyMotionSummarizer` | Deterministic features and exact-window fingerprint | Used by selfie receipts and persisted workflow motion |
| `BiometricCapture.NativeSelfieSession` | Binds motion summary/window timing to admitted selfie bytes | A camera-lifetime witness; summary in `SelfieAdmissionReceipt` |
| Reference-app `WorkflowEvidenceRecorder` | Session-wide sampling/draining and durable workflow-event journal | Passport page/MRZ, NFC handling, selfie and review/comparison within the composed journey |
| Reference-app `WorkflowMotionProjection` | Read-only ranges and coverage from acknowledged persisted events | Detailed workflow telemetry and exports |
| `DocumentCaptureApple.DocumentFrontCaptureController` | Front camera ownership, bubble-level motion and bounded raw motion | Separate document collector; raw evidence bound to the still |
| `DocumentTemporalConfiguration` | Optional frame/motion/geometry/camera-state window | Available in document camera; disabled in current reference document flow |

The passport MRZ/NFC products themselves do not automatically start a motion
witness. Their consumer owns the enclosing workflow. The reference app's standalone
`PassportFlowHost` has no motion recorder; `PassportFaceJourneyHost` supplies the
workflow recorder when composing the full journey. Do not infer equivalent coverage
from using a passport SDK API or simply selecting a capability tab.

Source: [package](Package.swift), [selfie adapter](../../biometric/ios/Sources/BiometricCapture/NativeSelfieMotion.swift),
[journey composition](../../reference-apps/ios/Sources/PassportFaceJourneyHost.swift),
[document details](../../document/docs/capture-telemetry.md).

## Shared raw sensor contract

`PulseCeremonyMotionSample` contains platform-fused Core Motion values copied in
device-frame axes. It does not contain separate raw accelerometer/gyro hardware
streams, camera-frame coordinates or a calibrated camera-to-IMU transformation.

| Field | Meaning / units |
| --- | --- |
| `offsetSeconds` | Seconds from this returned window's start |
| `userAcceleration.x/y/z` | Acceleration with gravity removed, in g |
| `rotationRate.x/y/z` | Angular velocity, rad/s |
| `gravity.x/y/z` | Platform gravity vector in device axes, in g |
| `magneticFieldMicrotesla` | Optional magnetic-field **magnitude**, microtesla; no three-axis field or heading is returned |

The witness chooses `xMagneticNorthZVertical` when available, otherwise
`xArbitraryZVertical`. No selected-reference-frame field or attitude quaternion is
exposed in this shared sample shape. A missing magnetic reference, invalid magnitude
or zero-filled field becomes `nil`; calibration is recorded separately as a
window-level flag, true when at least half the retained samples have platform
accuracy other than `uncalibrated`. Uncalibrated readings can remain present. The flag is
not a per-sample calibration history or an assertion of accuracy.

`PulseCeremonyMotionWindow` contains ceremony, start/end dates, requested rate,
samples and `magnetometerCalibrated`. `PulseCeremonyMotionCapture` adds
`startUptime` and `endUptime` to bind the window to a monotonic interval.
`PulseCeremonyKind` currently declares `passportPageScan`, `passportChipRead` and
`faceMatch`; declaring a kind does not start collection or establish the action
actually performed. There is currently no document/licence ceremony case.

Source: [sample/window types](Sources/KenshikiMotion/PulseCeremonyMotionSummary.swift),
[collector](Sources/KenshikiMotion/PulseCeremonyMotionWitness.swift).

## Collection, permissions, timing and loss

`PulseCeremonyMotionWitness(ceremony:sampleRateHz:)` defaults to a requested 50 Hz.
It owns its own motion manager/private serial queue. It retains a rolling maximum
of **five seconds / 300 samples**, evicting older samples. Actual callback cadence
is not guaranteed. The trace admits finite, increasing timestamps and refuses
invalid samples/rates; it currently has no public per-sample rejection, eviction,
callback-error or omission counters.

- `isAvailable` reports whether the platform can produce device motion, not the
  permission state or evidence completeness.
- `start(at:)` begins one ceremony; repeated start while active is ignored. Its
  date establishes the wall-time anchor; callbacks use boot-time offsets.
- `snapshot(endingAtUptime:)` does not stop collection. It returns the retained
  samples at/before the supplied time, requires at least two samples and a final
  sample no more than 0.2 seconds before that time. Older evicted samples cannot
  be recovered by asking for a historical snapshot.
- `stop(at:)` ends collection and returns the retained window, or nil when none
  exists. The current implementation derives window dates from sample timing;
  its `at` argument is not an additional measured end-of-recording boundary.

`PulseMotionPermission` exposes `notRequested`, `requesting`, `authorized`, `denied`
and `unavailable`, with `request(completion:)` and `cancel()`. It requests the
product's Motion & Fitness grant using a bounded activity query and discards the
activity data. It does not create an activity-history recording. The witness itself
does not invoke this permission adapter. The host supplies localized
`NSMotionUsageDescription` and owns visible/foreground/consent lifecycle.
The product's activity-permission gate is not a claim that every Core Motion API
requires the activity-manager authorization grant. Request it after user consent.

Window dates are anchored from the start date plus boot-time offsets; there is no
continuous remeasurement of wall-clock correlation in this witness. Returned
monotonic bounds and sample offsets should be retained with any frame/event binding.
Permission, availability, freshness and data coverage are separate facts.

Source: [permission](Sources/KenshikiMotion/PulseMotionPermission.swift),
[bounded trace](Sources/KenshikiMotion/PulseCeremonyMotionTrace.swift).

## Minimal public acquisition example

The host retains this owner, starts it for an explicitly admitted workflow, and
stops it on retirement/backgrounding. The caller owns persistence of returned raw
windows. This example does not bind a camera image, save a record or decide liveness.

```swift
import Foundation
import KenshikiMotion

@MainActor
final class CeremonyMotionOwner {
    private let permission = PulseMotionPermission()
    private let witness = PulseCeremonyMotionWitness(ceremony: .passportChipRead)

    func start() {
        permission.request { [weak self] status in
            guard status == .authorized else { return }
            self?.witness.start()
        }
    }

    func snapshot(endingAtUptime timestamp: Double) -> PulseCeremonyMotionCapture? {
        witness.snapshot(endingAtUptime: timestamp)
    }

    func stop() -> PulseCeremonyMotionWindow? {
        permission.cancel()
        return witness.stop()
    }
}
```

The public window/sample types are `Sendable`/`Equatable`; the raw window is not a
public `Codable` persistence schema. Preserve exact values through an explicit
adapter. A summary digest alone cannot reconstruct or independently audit discarded
raw samples. The reference workflow's raw persistence adapter is described below.

## Existing derived motion features

`PulseCeremonyMotionSummarizer.summarize(_:)` already produces a
`PulseCeremonyMotionSummary`. It reports sample count, duration, ceremony,
calibration flag and a deterministic `rawWindowSHA256`, plus:

| Feature | Current calculation / units |
| --- | --- |
| `accelerationRMSg` | RMS acceleration magnitude, g |
| `rotationRMSRadPerSecond` | RMS angular-speed magnitude, rad/s |
| `tremorBandRatio` | 8–12 Hz energy divided by energy at integer-Hz bins starting at 1 Hz (inclusive), below Nyquist; computed per acceleration axis |
| `gravityDominantAxis`, `gravityDominance` | Largest absolute mean-gravity component and its share of mean-vector magnitude |
| `gravityDriftRadians` | Angle between first/last gravity vectors, radians |
| `approachRMSg` | Acceleration-magnitude RMS during the first 0.5 seconds of the returned window |
| `settleRatio` | Final 0.2-second acceleration RMS divided by whole-window RMS |
| `magneticDeltaMicrotesla` | Maximum minus minimum available magnetic magnitude, microtesla |

Several unavailable/undefined features return nil. The current gravity-angle
calculation instead returns zero when either endpoint gravity vector has zero
magnitude; that fallback is not evidence of stable orientation. These names describe
implemented feature calculations, not validated behavioral conclusions. In a rolling window, "approach"
is the window's first interval, not necessarily the beginning of the user gesture.
The tremor-band ratio does not establish that a human held the phone. No calibrated
human/document liveness score or cross-sensor acceptance model is implemented here.

Source: [summary and implementation](Sources/KenshikiMotion/PulseCeremonyMotionSummary.swift).

## Passport-to-selfie workflow recording as built

The reference app owns `WorkflowSensorHost` and `WorkflowEvidenceRecorder` for the
composed journey. The sensor host uses a shared witness and a separate Core Location
manager. Its witness is currently tagged `faceMatch` throughout the journey;
event actions identify passport/MRZ/selfie phases. The tag must not be treated as
proof that every retained window is a selfie-only interval.

The recorder starts with the workflow, records actions, and requests a motion
snapshot every second. `SavedWorkflowMotion` retains raw acceleration/rotation/
gravity vectors, optional magnetic magnitude, monotonic bounds, rate and summary.
`WorkflowEvidenceJournal` trims overlapping samples after its acknowledged watermark
and retries a failed append with the same prepared event. The persistence adapter
validates/recomputes the summary from raw values. Bounded journal capacity, failed
writes and window eviction can limit coverage; a one-second ticker does not prove
gapless retention. Restart/resume creates a new segment.

`WorkflowMotionProjection` reads acknowledged durable events and reports ranges,
sample/window counts, deduplication, observed intervals and gaps. It only joins
sample durations within a segment and within 1.5 requested sample periods. It does
not count an unobserved resume interval as recorded coverage. Detailed telemetry
and exports use the projection while preserving raw event records.

These recorder, storage DTO and projection types are currently **internal reference-
app composition**, not independently exported `KenshikiMotion` workflow APIs.
Passport credential authentication and motion/handling evidence remain separate
results. A restored passport record does not imply fresh NFC or historical sensor
coverage that was never recorded.

Source: [sensor host](../../reference-apps/ios/Sources/WorkflowSensorHost.swift),
[recorder/journal](../../reference-apps/ios/Sources/WorkflowEvidenceRecorder.swift),
[saved raw values](../../reference-apps/ios/Sources/SavedFaceWorkflow.swift),
[projection](../../reference-apps/ios/Sources/WorkflowMotionProjection.swift).

## Selfie capture binding as built

`NativeSelfieSession` owns a camera-lifetime shared witness through
`NativeSelfieMotion`. At admission it attaches `SelfieMotionEvidence` to
`SelfieAdmissionReceipt`, binding the exact image SHA-256, AR frame timestamp,
monotonic window bounds, requested sample rate, `clockDomain`, `alignment` and
motion summary. `motionStatus` records permission separately. The adapter checks
frame age against host uptime (at most one second) before snapshotting. It currently
labels the binding `core_motion_boot_seconds` / `host_uptime_checked`; this is
proximity checking, not a calibrated exposure-time synchronization result.

The selfie receipt retains the **summary and fingerprint**, not the raw IMU window.
The composed journey's workflow journal separately retains raw motion through its
own witness. These are distinct collector instances/windows; their samples and
digests must not be described as one shared recording. Joining them requires their
actual identities and timing evidence. The internal snapshot injection used in
tests is not a public API for supplying a workflow-wide witness.

ARKit face/blink/depth observations have their own same-frame receipts and policies.
They are additional capability evidence; the presence of a motion summary does not
establish that a combined liveness model ran.

Source: [session](../../biometric/ios/Sources/BiometricCapture/NativeSelfieSession.swift),
[motion adapter](../../biometric/ios/Sources/BiometricCapture/NativeSelfieMotion.swift),
[motion receipt](../../biometric/ios/Sources/BiometricCapture/SelfieMotionEvidence.swift).

## Document capture differences and current unification gaps

The [document telemetry guide](../../document/docs/capture-telemetry.md) is a
capability-specific companion to this foundational guide. Its current recorder
requests 100 Hz and keeps the **first 600** admitted samples plus explicit issue/
omission counts. It includes an attitude quaternion and fixed arbitrary-vertical
reference-frame label, but no magnetic field. Its clock correlations, raw evidence
and still binding differ from the shared rolling witness's contract. The reference
app signs document-motion rows and commits them with the document snapshot.

These differences are real implementation gaps to resolve deliberately. Current
documentation must not imply a common cross-capability schema, shared single sensor
owner, interchangeable windows, automatic full-workflow persistence, or one fusion
engine. The document app's disabled temporal camera recording is a document-path
fact, not a statement that passport/selfie workflow motion is absent.

## Fusion discussion boundary

Existing work includes platform device-motion fusion, deterministic motion features,
workflow coverage/range projection and capability-specific capture bindings.
Cross-sensor inference for continuity and liveness remains a separate design and
qualification task. Applicable questions span passport handling/NFC, document
presentation and selfie acquisition; each has different observations and targets.

For future inference, identify the exact retained windows/events/images, clock and
coordinate transformations, overlap/coverage uncertainty and method/version. Keep
raw evidence available alongside derived rows. A motion feature, digest, local
signature, successful NFC read or face capture alone is not a calibrated liveness
decision. No new fusion API, threshold or classifier is introduced by this guide.

## Validation entry point

For passive human-presence research, see the pinned [A-Live preprint, 2606.05126v1](../../governance/research/papers/2606.05126v1.pdf)
and its [review scope and integration notes](../../governance/research/method-notes.md#7-foundational-motion-and-human-presence-research).
This reference has no adopted implementation or reproduced performance result here.

Run `python3 foundation/motion/check.py` from the repository root for the package's
source/provenance checks, native numerical tests and receipt. A passing suite
qualifies the exercised implementation behavior, not real-device sensor accuracy,
human-versus-injection detection or presentation attack detection. Full SDK/app
validation remains governed by the repository and consumer-specific check runners.
