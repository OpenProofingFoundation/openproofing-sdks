# Capture telemetry: current iOS API

Implementation inventory reviewed 2026-10-26. This describes the current checkout,
including its pending front-motion integration; it is not a released-version or
physical-device qualification claim. The current package targets iOS 18 or later;
Android capture remains unimplemented.

This is the document-specific companion to the [foundational motion API and
workflow guide](../../foundation/motion/README.md). Motion also supports passport
and selfie workflows. Shared collection, existing motion features, workflow raw
retention and the current differences between capability integrations are documented
there; this page does not define the whole SDK's motion or fusion architecture.

## Start here

`DocumentCaptureApple` returns acquisition facts in `CapturedDocumentPhoto`.
The public front controller adds bounded phone-motion evidence. Collection and
durable custody are separate operations: receiving a photo does not save or sign it.

| API/output | Purpose | Default and current reference-app use |
| --- | --- | --- |
| `CapturedDocumentPhoto.fidelity` | Typed facts about retained encoded image bytes | Produced for each photo |
| `.platformMetadata` | Complete serializable platform/encoded metadata and auxiliary-image type names | Retained where available; individual values are platform-dependent |
| `.admission` | Native request-time camera state and the quality observation used for admission | Optional in the contract; preserve absence on historical records |
| `.motionEvidence` | Bounded motion samples attached by `DocumentFrontCaptureController` | Collected during front acquisition; no back-motion collection in the reference app |
| `.temporalEvidence` | Opt-in full-scene frame window, motion, geometry and camera-state observations | `DocumentTemporalConfiguration.enabled` defaults to `false`; disabled for both reference-app sides |
| `.location` | Host-supplied location assertion and embedding outcome | Defaults to `nil`; the reference document flow supplies none |
| `DocumentCameraTelemetry` | Optional lifecycle/diagnostic event callback | Defaults to `.disabled`; it is not the motion-evidence or custody API |

Source: [photo output](../ios/Sources/DocumentCaptureApple/CapturedDocumentPhoto.swift),
[front controller](../ios/Sources/DocumentCaptureApple/DocumentFrontCaptureController.swift),
[camera events](../ios/Sources/DocumentCaptureApple/DocumentCameraTelemetry.swift).

## Sensor inventory and units

### Phone motion

The collector uses Core Motion `startDeviceMotionUpdates(using: .xArbitraryZVertical)`.
These are platform-fused device-motion values, not separate raw accelerometer and
gyroscope streams. The SDK copies components without transforming them into image,
card or world coordinates. The reference frame is not a compass heading.

| `DocumentTemporalMotionSample` field | Meaning / units |
| --- | --- |
| `bootTimeSeconds` | Platform motion timestamp, seconds since boot; not a wall-clock date |
| `attitude.x/y/z/w` | Platform attitude quaternion, dimensionless components |
| `rotationRate.x/y/z` | Platform device-axis angular velocity, radians/second |
| `gravity.x/y/z` | Platform device-axis gravity vector, in g |
| `userAcceleration.x/y/z` | Platform device-axis acceleration with gravity removed, in g |
| `referenceFrame` | Currently `xArbitraryZVertical_rotation_radians_per_second_acceleration_g` |

Axes/quaternion components retain Core Motion's native conventions. No camera
rotation, image-orientation correction, card-pose conversion, Euler-angle conversion
or camera-to-IMU calibration is applied to these stored samples. Fusion must make
those transformations explicit rather than equating a sensor axis with an image axis.

The collector requests a 0.01-second update interval (100 Hz). Actual delivery is
not guaranteed at that rate; inspect timestamps rather than assuming fixed spacing.
The same source supplies `DocumentFrontCaptureController.latestMotion` for the
advisory bubble level. That latest value is not a substitute for retained samples.

Source: [collector](../ios/Sources/DocumentCaptureApple/DocumentTemporalMotionCollector.swift),
[sample contract](../ios/Sources/DocumentCaptureApple/DocumentTemporalEvidenceManifest.swift),
[level source](../ios/Sources/DocumentCaptureApple/DocumentLevelMotionSource.swift).

### Camera and optics

`PhotoFidelityMetadata` records pixel width/height, encoded byte count, UTI,
SHA-256 and, when supplied by the encoded image, orientation, camera/lens model,
exposure time (seconds), f-number and ISO. Its optional `optical` record carries
focal length (mm), 35-mm equivalent, lens specification, digital zoom ratio,
EXIF composite-image value and HDR gain-map presence.

`CapturedPhotoPlatformMetadata` separately retains binary property lists for
`AVCapturePhoto.metadata` and properties read back from the encoded original.
`auxiliaryDataTypes` names auxiliary images already in the original;
`unrepresentableKeys` identifies top-level entries that serialization dropped.
Maker notes remain opaque platform metadata, not a decoded additional sensor stream.
Absence of a reported field must remain absence, not a substituted zero.

Admission may include `DocumentCameraNativeSnapshot`: selected/logical/active camera
identities, optical revision, zoom and limits, focus mode/lens position, adjustment
flags, supported focus controls, video/photo dimensions and native readback timing.
These are state readbacks, not proof of an exclusive physical sensor or calibrated
camera model. Intrinsics, lens-distortion calibration and subject distance are not
recorded by `PhotoFidelityMetadata`.

Source: [fidelity](../ios/Sources/DocumentCaptureApple/PhotoFidelityMetadata.swift),
[platform metadata](../ios/Sources/DocumentCaptureApple/CapturedPhotoPlatformMetadata.swift),
[native state](../ios/Sources/DocumentCaptureApple/DocumentCameraNativeDiagnostics.swift).

### Location and other sensors

`DocumentCaptureRequest.locationAssertion` accepts host-supplied latitude/longitude
(degrees), optional accuracy radii and altitude (metres), fix time and declared
source. The capture layer does not obtain a fix or request location permission.
`CaptureLocationRecord.disposition` distinguishes embedded, malformed/refused and
requested-but-absent values. The separate `DocumentCapture.CaptureSessionLocation`
helper can obtain host-side location; the reference document flow does not use it.
The public front controller's current capture method does not expose a location
argument; do not assume it inherits location from another app feature.

No dedicated magnetometer/heading, barometer, microphone, proximity, ambient-light
or LiDAR/depth stream is enabled by the current reference document flow. An auxiliary
image reported in photo metadata is not a continuously recorded depth stream.

Source: [location contract](../ios/Sources/DocumentSDK/CaptureLocationAssertion.swift),
[request](../ios/Sources/DocumentCaptureApple/DocumentCaptureRequest.swift),
[optional location helper](../ios/Sources/DocumentCapture/CaptureSessionLocation.swift).

## Derived camera observations and admission

`DocumentCaptureObservationSnapshot` preserves the admission-time observation:

- Metrics: document/guide fill, aspect ratio, position, containment, sharpness,
  image-based motion, mean luminance and clipped-highlight ratio.
- Assessment: readiness, blocking reasons and stable-frame count.
- Observation identity: sequence, geometry revision and observation time.
- Optional document bounds and camera-control snapshot, including focus/zoom state.
- Live-content counts when that analysis is enabled. The current reference front
  and back disable live-content analysis; empty counts do not prove absence of text.

These are derived image/control observations. Image-based `metrics.motion` is not
the gyroscope reading; luminance is not a separate ambient-light sensor. Quality
readiness is provisional capture policy, not document authenticity or liveness.

`DocumentCaptureAdmissionSnapshot` binds session, side, attempt, quality gate,
request/admission times, photo-settings ID, queue latency and observation age
(milliseconds), plus optional observation, guide, orientation and native camera.
Manual front capture uses `operatorInitiatedAdvisory`; automatic front capture uses
`qualityDrivenAutoCapture` with its triggering observation identity. Reference-app
PDF417 acquisition uses `livePDF417AutoCapture`; back-image OCR/preparation is not
required for that path.

The quality stream is advisory and buffers only its newest observation. The saved
admission snapshot is one observation, not a saved history of every preview frame.
The native layer independently checks admission when the capture is requested.

Source: [quality contracts](../ios/Sources/DocumentCaptureApple/DocumentCaptureQuality.swift),
[admission](../ios/Sources/DocumentCaptureApple/DocumentCaptureRequest.swift).

## Front-motion lifecycle, limits and statuses

`DocumentFrontCaptureController.start()` starts motion recording after camera startup.
A successful `capture(...)` attaches evidence and stops recording. Capture failure
restarts the recording window; `stop()` discards pending evidence. Cancellation,
backgrounding and visibility changes must retire the host's acquisition owner.

The current recorder keeps the **first 600 admitted samples**, not a rolling final
window around shutter time. Subsequent samples increment `omittedSampleCount`.
At the requested rate this can fill in roughly six seconds, but timestamps define
actual coverage. It keeps at most 128 issues and counts further omissions. These
front-motion limits come from the current default configuration and are not exposed
as public front-controller tuning parameters.

| `DocumentMotionEvidence.status` | Current meaning |
| --- | --- |
| `recorded` | Samples exist, with no recorded issues or omissions |
| `partial` | Samples exist and there are issues or omissions |
| `unavailable` | No samples were retained |
| Optional evidence is `nil` | No attached motion record; distinct from an attached `unavailable` record |

Issue codes cover unavailable motion/reference frame/platform, callback errors,
invalid samples, clock discontinuity and samples outside the observation window.
`recorded` does not establish continuous coverage, a maximum inter-sample gap,
alignment to the still exposure, sensor authenticity or a liveness result.
`requireValid()` checks structure, bounds and consistency; it is not a PAD classifier.

Source: [motion evidence](../ios/Sources/DocumentCaptureApple/DocumentMotionEvidence.swift),
[recorder](../ios/Sources/DocumentCaptureApple/DocumentMotionRecorder.swift).

## Clocks and source binding

`requestedAt`, `processedAt`, admission times and observation dates are wall-clock
`Date` values. `captureTimestamp` is an AVFoundation media timestamp with value,
timescale, flags, epoch and declared capture-session synchronization clock.
`bootTimeSeconds` belongs to the motion clock. Do not subtract these clock domains
directly or reinterpret a media timestamp as a wall-clock date.

Motion evidence records start/end `DocumentTemporalClockCorrelation` values:
host-clock reads bracketing a boot-time read, with a method identifier. Its binding
contains session, attempt where available, side, still digest and still media
timestamp. The front-only recorder currently leaves `binding.stillHostTimeSeconds`
nil. Binding names the associated still; it does not supply exposure-time alignment.
There is no current fusion or calibrated synchronization-error result.

## Consuming the public front API

Create and retain a `DocumentFrontCaptureController(now: { Date() },
notifications: .default)` on the main actor. Connect the public preview/guidance
surface and current guide geometry, then start in response to an explicit visible
capture action. The host needs its localized camera usage description and lifecycle
handling. The reference target also declares `NSMotionUsageDescription`; the collector
reports availability/errors rather than exposing a separate permission-request API.
Hardware capture/motion acceptance requires a real supported device.

For an already-started, presented controller, a manual action can consume the output:

```swift
import Foundation
import DocumentCaptureApple

@MainActor
func captureIfAvailable(using front: DocumentFrontCaptureController) async throws
    -> CapturedDocumentPhoto? {
    guard front.manualCaptureAvailable else { return nil }
    let photo = try await front.capture()
    if let motion = photo.motionEvidence {
        try motion.requireValid()
        // Consume samples, issues, limits, omissions and binding together.
        // Preserve nil/partial/unavailable states in the application's result model.
    }
    return photo // Acquisition output; durable custody remains a separate operation.
}
```

For automatic capture, use the identity delivered by `onAutomaticCapture` in
`capture(observationIdentity:)`; do not replace it with an unbound manual request.
Retire the controller with `try await front.stop()` on withdrawal/backgrounding.
See the [reference camera adapter](../../reference-apps/ios/Sources/NativeDocumentFlowCamera.swift)
and [presentation composition](../../reference-apps/ios/Sources/DocumentFlowHost.swift)
for the existing native integration. These are examples, not additional SDK APIs.

## Optional temporal recording is a separate path

Constructing `DocumentCamera` with
`DocumentCaptureConfiguration(temporalEvidence: DocumentTemporalConfiguration(enabled: true))`
opts into temporal evidence. Defaults are a 1-second pre-capture and 0.5-second
post-capture window, 134,217,728 bytes, 120 frames, 600 motion samples and 128 diagnostics.
The resulting manifest includes frame/motion observations, clocks, source binding,
status, termination, issues, gaps and eviction counters. Consume these together;
the requested interval is not proof of complete or usable delivery.

The public front controller currently constructs its own camera with temporal
recording disabled and has no public temporal-configuration parameter. Its
`motionEvidence` is collected independently of this optional frame recorder.
Neither current reference side enables the temporal frame window.

Source: [temporal configuration](../ios/Sources/DocumentCaptureApple/DocumentTemporalEvidence.swift),
[manifest](../ios/Sources/DocumentCaptureApple/DocumentTemporalEvidenceManifest.swift).

## Persistence and interpretation boundary

The reference app serializes the native facts in `DocumentFlowCaptureMetadata`.
Its protected SQLite adapter signs each declared front-motion record independently
and atomically publishes the motion rows, signed capture snapshot and current pointer.
Pairing a back capture preserves the existing front-motion proof. Reopen verifies
the declared set and restores historical evidence without acquisition or processing.
This adapter is app composition, not automatic persistence by `CapturedDocumentPhoto`.

Local signatures bind retained bytes to their signing key. They do not establish
sensor truth, uninterrupted document continuity, physical-document authenticity or
human liveness. There is no current sensor-fusion/PAD verdict. No temporal camera
sequence or back-motion evidence should be inferred from the reference app's still
photo and bounded front-motion record. A future interpretation must retain its exact
input references, clock/coordinate handling, coverage, method/version, uncertainty
and evaluation evidence as a separate processing stage.

Source: [app metadata](../../reference-apps/ios/Sources/DocumentFlowCaptureMetadata.swift),
[transactional custody](../../reference-apps/ios/Sources/DocumentFlowSQLiteStore.swift).
