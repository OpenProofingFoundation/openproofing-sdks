# Sensor measurement, window and derivation contract v1

Contract identity: `kenshiki.sensor_measurement_window.v1`. Status: implemented Swift
foundation contract; platform acquisition, durable-storage adapters and cross-platform
qualification remain separate. The SDK product is `KenshikiSensors` under
`foundation/sensors`. Existing Pulse and `KenshikiMotion` consumers are unchanged.

This contract preserves acquired values and makes their interpretation explicit. It
defines neither a collector nor an identity, authenticity, liveness or handling verdict.
Constructing a valid value establishes its structural invariants, not that a sensor
or caller told the truth. The host owns disclosure, retention and product decisions.

## Measurements and sources

`SensorMeasurement` is an immutable admitted value with a stable caller-assigned sample
ID, sequence, descriptor, validity timestamp, optional receipt timestamp and optional
derivation. IDs are scoped by their stream and source clock session; the caller MUST
avoid identity reuse when source epochs or acquisition profiles change. Sequence
records the stream's source ordering before retention selection, not array position.

The descriptor MUST distinguish `nativeSensor`, `platformFused` and `derived`. Its
`sourceID` identifies an immutable versioned acquisition profile, including native
source/adapter revision and declared sensor placement. A platform-produced estimate
does not become a raw native measurement because an application copied its scalars.
Calibration references are exact immutable record commitments; absent calibration and
absent resolution mean unknown. Numeric representation precision is not resolution.

Quantities and compatible units are closed: acceleration uses standard gravity or
meters/second squared; angular velocity uses radians/second; magnetic field uses
microtesla; pressure uses kilopascals; angle uses radians; dimensionless uses its own
unit. `standardGravity` means 9.80665 meters/second squared. No implicit conversion
occurs. Acceleration MUST declare gravity included, excluded or gravity-only. Other
quantities MUST declare gravity not applicable. Scalar and vector3 shapes are explicit;
the source profile identifies scalar axis/magnitude or vector component semantics.

Frame IDs identify versioned axis/orientation conventions, including handedness and
sensor-to-device mounting where known. They MUST NOT be display-orientation labels
masquerading as measured calibration. `reported` records the source's declaration;
`notExposed` records its absence. A transformed frame MUST use derived origin and bind
its source frame ID, target descriptor frame ID and complete transformation derivation
(method version, configuration commitment and exact ordered inputs). This initial
contract does not implement a coordinate transform or infer an unavailable matrix.

Every component and timestamp MUST be finite. A derived measurement MUST carry a
derivation; a native/platform-fused one MUST NOT falsely claim a locally performed
derivation. Instrument-specific physical ranges remain the source profile's declared
limits; this contract does not invent sensor hardware limits.

## Clocks and windows

`SensorClockDomain` identifies a monotonic, wall-clock or provider-defined domain plus
its exact source session. Timestamp numbers from different domains/sessions MUST NOT
be compared as one stream. `SensorClockCorrelation` retains a measured source/target
time pair and finite nonnegative uncertainty in seconds. It does not promise a
continuous affine mapping, drift bound, exposure alignment or reboot continuity.
Additional measured correlations remain available to a separately versioned mapper.

`SensorEvidenceInterval` is a finite, positive-duration, half-open interval `[start,end)`
in one declared clock domain. A sample exactly at `end` belongs to the next interval.
`SensorEvidenceWindow` declares one descriptor/domain, nominal period when requested,
raw-retention mode, availability, explicit omissions and measured correlations.
Same-domain receipt time cannot precede sample validity. A foreign-domain receipt
requires a matching declared correlation or an explicit `clockUncorrelated` omission;
the contract performs no implicit clock conversion.

Inline samples MUST match the complete descriptor and domain/session, have unique IDs,
strictly increasing sequence and nondecreasing validity times, and fall within the
bounds. A discontinuous sequence requires a `gap` omission. Do not interpolate across
missing intervals. The acquisition adapter separately records cadence/time gaps that
source sequence numbering alone cannot expose.

Retention is explicit: inline raw samples; an external exact-byte raw-batch reference
plus ordered sample IDs; aggregate-only references plus the exact ordered source sample
IDs; or none. Aggregate-only requires `rawNotRetained`. Hashes and aggregate values do
not reconstruct source samples. External IDs are declarations until the caller reads,
verifies and validates their referenced contents using this same contract. The SDK
does not create or access a database, file, key, network service or durable identity.

`observed` requires retained samples and no declared omissions. It does not mean
continuous coverage or acquisition qualification. `partial` requires retained sample
identities plus omissions. `empty` and `unavailable` require no retained samples and
an explicit omission/reason; measured zero is a valid sample and is never substituted
for absence. Omission intervals, when known, MUST use and lie within the window clock
bounds. Unknown omission extents remain unknown, not fabricated full-window gaps.

Identifier and selector comparisons use Unicode canonical equivalence. Retain the
original spelling; equivalent spellings cannot create distinct record/selector pairs.

Engineering bounds: identifiers are 1–256 UTF-8 bytes without control characters;
sample IDs/inline samples and omissions are each bounded to 65,536 per window; clock
correlations to 256; derivation inputs to 4,096; limitations to eight unique reason
codes. Nominal-period expected-count arithmetic must be finite, round to 1–1,000,000
and use a positive period no longer than the interval. These are allocation/conversion
bounds, not a sampling-rate recommendation or a liveness threshold. A producer MUST
split segments or report capacity failure rather than silently truncate evidence.

## Derivation and historical mathematics

`SensorArtifactReference` commits a caller-owned record ID to exactly 64 lowercase
hexadecimal SHA-256 characters. Shape checking is not digest verification, durable
custody acknowledgement or acquisition authenticity. The producer MUST canonicalize
and store the exact bytes; readers verify those bytes before consumption.

Every `SensorDerivationBinding` retains method ID/version, immutable configuration
reference, ordered complete inputs and an explicitly supplied limitations array. Each
input binds its record commitment, selector, role and typed temporal extent: either
an exact point in a clock/session or a positive half-open interval. Selectors do not
replace timing. Roles include supporting, contradicting, rejected, context and omission.
Rejected/omission inputs require a reason. Negative deciding inputs MUST be retained,
including measurements that caused contradiction, exclusion or abstention; support-only
lineage is incomplete. Duplicate record/selector pairs or conflicting commitments for
the same record ID are refused. Commitment consistency also spans calibration,
frame-transformation bindings, measurement derivation and composed window references;
the same record ID cannot acquire different digests in nested admitted evidence.
Different sources may have different clock extents;
a method MUST bind its alignment configuration/correlations and declare uncertainty
rather than pretending they share a clock. Constructors cannot discover omitted inputs.

Limitations are closed: partial or unavailable input, raw samples not retained, uncertain
clock alignment, unavailable calibration, unknown resolution, unverified source
authenticity, and method not qualified. An empty array is an explicit producer declaration,
not independent proof of qualification. Transform bindings are included as deciding
inputs when their outputs are used. Configuration changes require a new exact commitment;
method changes require a new method version. Historical results keep their old meanings.

The extracted Pulse core retains its historical numerical semantics: vector magnitude
is `sqrt(x*x+y*y+z*z)`; RMS is `sqrt(sum(x*x)/n)`; quantiles use sorted Hyndman–Fan
type 7 interpolation at `(n-1)*p`; gravity mean is sample-weighted. Temporal support is
the union of nominal half-period cells clipped to the bin, divided by duration;
observed rate is the reciprocal median positive adjacent gap. Window gap reporting
includes leading/trailing edges. Existing v1 quality policy defaults remain 95% count,
95% support and maximum gap three nominal periods. These are acquisition-quality
semantics, not physical truth, time-weighted statistics or liveness qualification.
The legacy result types remain separate from this richer evidence contract; wrapping
an aggregate cannot manufacture missing raw records, clocks, input IDs or provenance.

No new filter, spectral estimator, resampler, collector or fusion verdict is introduced.
Finite inputs can still exceed an operator's safe numerical range; a producer MUST
refuse a nonfinite derived value through `SensorMeasurement` rather than present it as
a valid measurement. New numerically different operators require new method identities.

## Conformance and lifecycle

Canonical vectors are [sensor-measurement-window-v1.vectors.json](sensor-measurement-window-v1.vectors.json).
The exact test resource copy is package-owned; tests read that bundle resource, never
repository documentation at runtime. Native contract tests also exercise nonfinite
inputs, incompatible units/frames/domains, identity/order violations, retention modes,
negative deciding inputs, clock correlations, transformation lineage and capacity bounds.

Swift values use immutable public fields and throwing admission constructors. This
increment defines no public wire codec, unknown-version fallback, migration or remote
submission. Future codecs MUST reject unsupported versions and unknown required semantics,
preserve exact committed bytes and use independent positive/negative vectors. Shared
storage/erase/cancellation mechanisms remain independently owned foundation products;
these value contracts perform no asynchronous work. Cancellation, durable acknowledgement,
interruption recovery, erasure and physical sensor acceptance require adapter-specific
tests and receipts. None follows from passing this contract suite.
