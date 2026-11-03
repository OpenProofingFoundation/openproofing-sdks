# Pulse motion mathematics and conformance reuse map

Reviewed 2026-10-26. This is source inspection of the current dirty checkouts, not a release or physical qualification. The accompanying [source manifest](mathematics-tests.sources.json) records absolute paths, revisions, inspected test IDs and SHA-256 values. Its start/end hashes cover report finalization **after** the initial full-file reads, not the whole session. No Pulse native tests were executed by this auditor; package-pin changes in another session preclude treating a new native run as a frozen integration baseline.

## Reuse conclusion

Pulse already supplies the main mathematical building blocks. The first Sensors SDK extraction should carry the existing distribution, temporal-support, routing and reducer kernels with their current tests, while retaining existing ceremony-summary semantics as a pinned compatibility profile. Creating a replacement statistics or spectral implementation is unnecessary for this boundary.

The existing shared `KenshikiMotion` summary is byte-identical to Pulse's current `PulseCeremonyMotionSummary.swift`. Its numerical test file differs only in the imported module. `foundation/motion/check.py` explicitly pins the donor summary and requires nine summary test identities; changing that algorithm is a separate compatibility decision, not incidental extraction cleanup.

## Implemented operators

Paths in this table are relative to `/Users/shf/Developer/pulse-ios/Sources/KenshikiDeviceSDK/` unless explicitly qualified. Each file was read in full.

| Source / operator | Exact current definition | Reuse and limits |
| --- | --- | --- |
| `SensorVector3.swift` | Three `Double` axes; magnitude `sqrt(x²+y²+z²)`; finite iff all components finite. | Portable primitive. No unit/frame tag is embedded in this type. Finite components alone do not guarantee finite squared magnitude. |
| `EmpiricalDistribution.swift` | Sample RMS `sqrt(sum(vᵢ²)/N)`; sorted R7 median/p95, maximum and count. For probability p, h=(N−1)p, interpolate sorted floor(h)/ceil(h). Empty or nonfinite input returns nil. | Existing portable distribution kernel; sample weighted, with no elapsed-time weights. No variance/stddev or minimum field. No stabilized sum-of-squares. |
| `SensorSampleTime.swift` | Fixed clock projection `wall(t)=anchor.wall+(t−anchor.sensor)`; source-session identity and sample/receipt clocks. | Host correlation remains separate from measurements. No drift or uncertainty estimation in this kernel. |
| `SensorWindowTiming.swift` | Half-open canonical bins start at `floor(t/T)T`. Expected count `max(1, round(T/period))`. Admission rejects nonfinite clocks, dates outside bounds, equal last timestamp and timestamp regressions. | Carry version `pulse.sensor_window_timing.v1`, counters and separate sensor/receipt clocks. Timestamp regression in a prior canonical bin is counted invalid by routing rather than out-of-order. |
| `SensorTemporalSummary.swift` | Temporal support is the union length of `[tᵢ−period/2,tᵢ+period/2]` clipped to bin bounds, divided by configured duration. Maximum gap includes leading, internal and trailing gaps. Delivered rate is reciprocal median positive timestamp difference. | Portable shared math already used by live and recorded paths. Support is explicitly a nominal sampling-cell estimate; it is not measured continuous coverage. |
| `SensorTemporalSummary.swift` quality | Empty if N=0; otherwise observed iff `N ≥ ceil(expected×minimumCountFraction)`, support ≥ minimum support fraction, maximum gap ≤ period×maximumGapPeriods. Defaults: 95%, 95%, three periods. | Keep acquisition quality distinct from observed-value interpretation. Sparse callbacks cannot become stationary evidence. |
| `BoundedSensorWindow.swift` | `TumblingSensorWindow` routes source-ordered samples to canonical bins; a later-bin callback closes the previous bin and starts its own. `accepts` precedes timing admission and reduction. No empty intermediate bins are synthesized. Flush retains completion reason. | Reuse generic routing and reducer port. Acquisition owns missing-history accounting and source-session changes. A reducer's public `ingest` does not itself enforce `accepts`; callers must preserve this precondition. |
| `DeviceMotionAggregate.swift` | Distribution of processed user-acceleration magnitude in g; angular-rate magnitude in rad/s; arithmetic mean gravity vector; per-calibration-label counts. Requires finite axes, nonempty frame/location/calibration and fixed frame/location within reducer. | Portable processed-motion reducer. Carries `additionalBiasApplied=false`, `biasVectorSource=not_exposed_by_core_motion`; introduces no inferred bias correction. Individual acceleration/rotation axes are not retained in its aggregate. |
| `RecordedAccelerationAggregate.swift` | Raw acceleration magnitude and each signed axis get RMS/R7/maximum. Distinct recording batch IDs sorted, serialized UInt64 big-endian and SHA-256 hashed. | Portable raw-acceleration reducer, **including gravity**. Batch digest binds distinct batch IDs, not exact sample content/order. Aggregate statistics do not retain/reconstruct samples. |
| `RecordedAccelerationWindow.swift` | Closed 60-second wall-clock bins, nominal 0.02 s. Identity=(batch ID, wall-time bits, sensor-time bits). Exact bitwise duplicates collapse with counts; conflicting values sharing identity are all rejected. Deterministic order includes bit patterns, including signed zero. Sensor-time regressions are counted while wall time determines temporal math. | Reuse deterministic historical projection and rejection accounting. This is intentionally different from live monotonic routing; no callback latency concept. No synthetic windows for unobserved bins. |
| `DeviceMotionEvidenceWindow.swift` | Typed fixed profile: 60 s, requested 12 Hz, expected 720. Validates timing, consistency of quality, distribution ordering, gravity/frame/location, calibration count totals and explicit no-extra-bias provenance. | Profile-specific adapter, not the generic kernel. Keep profile version rather than generalizing away its historical constants. `maximumSampleGapSeconds` convenience getter maps nil to zero even though canonical timing retains nil. |
| `DeviceMotionWindow.swift` | Collector compatibility record: counts every event but reports **last event** acceleration/rotation/gravity magnitudes; calibrated magnetometer count and **last usable** finite positive field. | Preserve historical semantics; silently substituting window RMS/mean changes existing fields. This type is separate from the aggregate reducer. |

## Existing ceremony summary: preserve exact semantics

Sources: Pulse and shared `PulseCeremonyMotionSummary.swift`; Pulse witness and `Samples/KenshikiDeviceDemo/Sources/CeremonyMotionLakeWriter.swift`.

- Acceleration and angular-rate features are sample RMS of Euclidean magnitude; dimensions remain g and rad/s. Describing these as physical energy is imprecise: they are RMS amplitudes, without mass, inertia or time integration.
- Gravity dominance uses the **mean vector**: largest absolute component divided by mean-vector magnitude. Gravity drift uses first and last vectors, `acos(clamp(dot/(norm product),−1,1))`. Zero endpoint norm currently yields **zero angle**, not unavailable. Opposing endpoint vectors can cancel the mean without implying stable posture.
- Approach is sample RMS where offset <0.5 s. Settle is sample RMS where offset ≥duration−0.2 s, divided by whole-window RMS; zero overall RMS produces nil. These intervals are relative to the supplied returned window, not proof of gesture onset or completion.
- Magnetic delta is max−min over present magnitude values. No values produces nil. The summary does not independently validate magnetic finiteness/calibration.
- Effective rate is `(N−1)/(lastOffset−firstOffset)` when positive span exists, otherwise requested rate. Interior offsets do not affect spectral calculation.
- Per acceleration axis, subtract its sample mean and run Goertzel at integer frequencies `f=1,2,…` with `f < effectiveRate/2`. Recurrence: `s[n]=x[n]+2cos(2πf/fs)s[n−1]−s[n−2]`; power `s_last²+s_prev²−2cos(2πf/fs)s_last s_prev`.
- Ratio is summed power across axes/bins in inclusive 8–12 Hz divided by all evaluated ≥1 Hz bins. It operates **per signed axis**, avoiding rectification/frequency doubling from a magnitude-first spectrum. It returns nil if fewer than `floor(fs)` samples, fewer than two samples, or total power is not positive.
- There is no resampling, jitter/gap qualification, taper/window correction, anti-alias filter or PSD normalization in this implementation. Its dimensionless ratio cancels a common amplitude factor; that does not make it integrated physical band energy or a calibrated PSD. Uniform-spacing assumptions need to be explicit at admission. At ≤24 Hz, Nyquist prevents evaluation of at least part of the declared 8–12 Hz band; the implementation can still return a partial-band/zero ratio rather than an unsupported result. The fixed 12 Hz foreground stream cannot resolve that band.
- Fingerprint serialization binds every window field and raw sample using big-endian IEEE-754 bit patterns, length-prefixed ceremony string and optional-value markers. It preserves fine numeric differences without decimal rounding. The digest alone cannot reconstruct discarded measurements, identify sensor resolution or establish authentic acquisition.

The original Pulse witness uses callback wall time for offsets and retains its ceremony samples in memory until stop. Its lake writer persists summary values using `String(Double)`, a `ceremony-motion-summary.v1` label, optional absence as `unavailable`, and buckets beside values. It explicitly does **not** persist the raw ceremony trace. Its row quality is observed when sample count >0; that is a different meaning from the foreground 95% count/support/gap-qualified profile. Do not unify those labels without versioning.

## Tests actually inspected

The manifest records all 68 test methods read across these files: 43 Pulse SDK methods, 16 Pulse app methods and nine shared summary methods. This is an inspection count, not an execution result. Class/method names below are real selectors; every listed test file was read in full.

| Suite | Methods | Meaningful existing falsification coverage |
| --- | ---: | --- |
| `KenshikiDeviceSDKTests/SensorWindowTimingTests` | 7 | Perfect support value 59.5/60; missing internal samples; isolated callback; exact half-open boundary; wall-clock jump cannot reroute; duplicate/nonfinite rejection; independent `[0,1,2,3]` R7 oracle (RMS √3.5, median 1.5, p95 2.85). |
| `KenshikiDeviceSDKTests/SensorTemporalSummaryTests` | 5 | Inclusive 95% count boundary; exact support threshold versus epsilon below; exact max-gap boundary versus epsilon above; clock translation across negative/positive domains; equivalent live/recorded temporal evidence. |
| `KenshikiDeviceSDKTests/DeviceMotionWindowTests` | 6 | Every callback counted; last-event magnitude semantics; calibrated subset/last usable magnetic reading survives final calibration loss; complete absence; raw magnetometer fallback. |
| `KenshikiDeviceSDKTests/MotionAggregateReducerTests` | 3 | Known magnitude/R7 values and unchanged processed provenance; mixed frame rejection; raw recorder counts/axes/batch bounds and digest length. |
| `KenshikiDeviceSDKTests/DeviceMotionEvidenceWindowTests` | 4 | Observed/partial/empty typed round trips; wrong envelope source/quality, impossible distribution ordering and false extra-bias claim refused. |
| `KenshikiDeviceSDKTests/RecordedAccelerationWindowTests` | 9 | Reorder invariance/dedup; conflicting identity refuses both values; nonfinite wall dates; signed zero; sensor regression; cutoff/half-open bins; 3000-sample 50 Hz minute; internal missing support; raw gravity remains ~1 g. |
| `KenshikiDeviceSDKTests/PulseCeremonyMotionSummaryTests` | 9 | Still zero amplitude with undefined ratio; 10 Hz in-band versus 2 Hz out-of-band; approach/settle; π/2 gravity drift; 4.9 µT range; missing magnetic reference is nil; short-window spectral absence; exact hash sensitivity to 1e−7 perturbation. |
| App `CeremonyMotionWitnessTests.swift` | 16 across two classes | Summary atoms/bands/version/absence; identity versus attempt custody and selective erase; newest ceremony read; unavailable lake versus no witness; stale subject/read/write-completion fencing. These tests exercise application composition, not portable spectral definitions. |
| Shared `KenshikiMotionTests/PulseCeremonyMotionSummaryTests` | 9 | Same nine numerical definitions, changed module import. Existing extraction baseline; carry unchanged. |

The seven Pulse SDK suites total 43 methods; the shared duplicate nine are not nine additional independent mathematical oracles. Synthetic known-answer vectors are appropriate for mathematical conformance; they do not qualify human handling, PAD or sensor accuracy.

## Concrete remaining conformance gaps

These are gaps in the inspected operator suites and source contracts, not an assertion that no other repository test exists.

1. **Irregular-time spectral admission.** Two traces with the same values, count and endpoint offsets but radically different interior timing currently produce the same spectrum. Add a vector that falsifies treating that result as uniformly sampled evidence; either retain an explicit uniformity precondition and abstain outside it, or introduce separately versioned processing. Preserve v1 output for historical readers.
2. **Band completeness and short-span boundaries.** Add exact 8/12 Hz edges, low rates (12, 16, 24 Hz), Nyquist equality, one-second/just-under-one-second support, dropped callbacks, noninteger-duration and leakage cases. `count >= floor(fs)` is not itself proof of a full second's temporal support.
3. **Independent spectral oracle and normalization.** Compare Goertzel power to an independently evaluated direct complex sum on known signals, axis rotations, scale changes and mixed frequencies. Require an explicit answer about bin-sum ratio versus PSD integration before offering a generalized spectrum API.
4. **Numeric rejection and bounded work.** Test finite axes whose squares/sums overflow; nonfinite/reordered ceremony offsets, nonfinite vectors, negative durations, invalid/huge requested rates, and very small amplitudes. The ceremony types/summarizer have no complete admission validator. Finite axes can pass reducer acceptance then yield nonfinite derived magnitudes. A new SDK entry point needs explicit bounded input/finite-output behavior; no evidence here establishes physical sensor precision.
5. **Undefined orientation and window intervals.** Add zero/near-zero endpoint gravity, cancelling means, dominant-axis ties, negative/out-of-window offsets, no approach/settle samples and exact 0.5/0.2 s boundaries. Keep v1 zero-angle fallback documented rather than silently rewriting stored meaning.
6. **Sample-weighting contract and exact provenance.** Use uneven sample density with known values to pin existing sample RMS and expose its difference from time-weighted RMS. Preserve exact input IDs/range/method/configuration independently of summary/batch digests. Add exact known digest bytes and one-field-at-a-time mutations; current tests check equality, length and one sample perturbation, not a frozen serialization oracle.
7. **Fine micromovement and profile distinctions.** Add very small nonzero signed-axis values, signed zero, mixed small/large dynamic range and decimal round-trip preservation, without claiming a sensor noise floor. Confirm last-event check-in values, foreground RMS, gravity-including recorder RMS and ceremony RMS retain their distinct identities. Generic atoms must preserve unavailable versus measured zero; the gap convenience getter deserves explicit negative coverage.

## Extraction boundary and next checks

Carry `SensorVector3`, `EmpiricalDistribution`, `SensorTemporalSummary`, clock/sample types, generic timing/window routing and the two reducer families with their tests into selected sensor products after API/version ownership is fixed. Keep the raw-recorder and processed-device-motion profiles distinguishable. Keep lake encoders, subject linkage, Pulse read labels/stores and `TelemetryBands` application composition outside the portable core. Fusion and BFF ownership are mapped by the companion audit; this mathematical review does not authorize moving their product policies.

The smallest next implementation is an extraction of these existing kernels and their existing known-answer vectors, plus only the admission/versioning changes needed for the shared contract. It is not a rewrite of Pulse mathematics.

Commands inspected, **not executed by this auditor**:

```sh
# Pulse SDK lane of record; scripts/test_sdk.sh regenerates Xcode project.
cd /Users/shf/Developer/pulse-ios
make test

# Focused existing selectors, when package pins/source are stable.
make test-app-focused TESTS='KenshikiDeviceSDKTests/SensorWindowTimingTests KenshikiDeviceSDKTests/SensorTemporalSummaryTests KenshikiDeviceSDKTests/MotionAggregateReducerTests KenshikiDeviceSDKTests/RecordedAccelerationWindowTests KenshikiDeviceSDKTests/DeviceMotionWindowTests KenshikiDeviceSDKTests/DeviceMotionEvidenceWindowTests KenshikiDeviceSDKTests/PulseCeremonyMotionSummaryTests'
make test-app-focused TESTS='KenshikiDeviceDemoTests/CeremonyMotionWitnessTests KenshikiDeviceDemoTests/CeremonyMotionWitnessStoreTests'

# Existing shared-source/provenance guard plus 18 required native test IDs.
cd /Users/shf/Developer/kenshiki-sdks
python3 foundation/motion/check.py
```

The focused Pulse runner regenerates, prepares the frozen package graph, builds for testing, then executes selected tests without rebuilding. It is not a whole release gate. Shared `check.py` runs SwiftPM with warnings as errors and validates required XCTest IDs plus source hashes in its receipt; it is a macOS test of the shared package, not iOS sensor acceptance. The integrator separately reported a current successful run of that shared check (18 required tests); its receipt must be assessed by the integrator and is not a Pulse test result.
