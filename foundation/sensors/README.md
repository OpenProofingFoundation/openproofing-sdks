# Kenshiki Sensors

The first Sensors foundation increment extracts Pulse's existing clock, window,
distribution and motion-reducer core into an independently consumable local Swift
package. It adds a versioned measurement/window evidence boundary. Passport,
document and selfie consumers can share these primitives without depending on one
another, the Pulse app, a datastore, a service account or UI.

The product is `KenshikiSensors`, under Swift 6 with iOS 18 and macOS 13 deployment
minimums. This increment contains pure data and processing code, not a live sensor
collector. Android bindings, remote package distribution and capability migration
are separate delivery work. A monorepo Git URL does not independently distribute
this nested Swift package.

## Existing mechanisms reused

- `SensorVector3` and `EmpiricalDistribution`: existing sample RMS, R7 median/p95
  and maximum definitions.
- `SensorClockAnchor`, source-session and timestamped-sample values:
  explicit sensor/receipt clocks with fixed wall-clock projection.
- `SensorWindowSpecification`, `TumblingSensorWindow` and the internal temporal
  summary: canonical half-open routing, nominal support cells, actual cadence,
  gap/count quality and explicit completion/rejection accounting.
- `DeviceMotionWindowReducer`: processed user acceleration, angular velocity,
  gravity mean and reference-frame/location/calibration provenance.
- `RecordedAccelerationWindowProjection` and reducer: deterministic retrospective
  ordering/deduplication, conflicting-identity refusal, gravity-including raw
  acceleration and declared batch identity summaries.

[Core provenance](core-provenance.json) records the exact donor revision, source
hashes, destination hashes and adaptations. Existing known-answer tests accompany
the extraction. Public-access adaptations and defensive rejection of unrepresentable
clock/bin inputs are explicit; valid-input mathematics is preserved.

The existing `KenshikiMotion` package, ceremony summarizer, hash serialization and
all existing consumers remain unchanged. Its spectral features are not redefined
or promoted into a new generalized spectral API by this package.

## Measurement and evidence contract

[Sensor measurement/window v1](../../contracts/sensor-measurement-window-v1.md)
is the normative contract. The new throwing constructors separate:

- native, platform-fused and derived values; quantity/unit, scalar/vector shape,
  gravity inclusion, frame/transformation lineage and unknown instrument resolution;
- clock domain and recording session, point/interval bounds, measured clock pairs
  and supplied correlation uncertainty;
- retained inline samples, externally retained raw batches, aggregate-only evidence
  and explicit absence, including partial evidence and omissions;
- immutable source references, complete ordered derivation inputs with roles and
  time extents, method/version, exact configuration commitment and limitations.

The evidence constructors validate structural compatibility and declared bounds.
They do not acquire sensors, read referenced artifacts, hash unprovided bytes,
acknowledge a durable commit or independently establish sensor authenticity.
Producers must retain/verify their referenced bytes through the selected custody
mechanism and provide every deciding input, including contradictory or rejected
inputs. A well-shaped digest is not proof that those obligations were fulfilled.

Availability and timing quality are distinct. An observed retained measurement
does not establish continuous temporal coverage. Preserve the explicit timing
profile, cadence, gaps and limitations when deriving a result. Missing evidence
never becomes a zero-valued measurement or a stationary interval.

The low-level extracted types retain their documented configuration preconditions
and mathematical input assumptions. Result-record copy initializers do not admit
or authenticate arbitrary observations. The strict evidence boundary is separate.
The nominal expected-count bound prevents unsafe numeric conversions; it does not
independently cap supernominal callbacks or establish a whole-workflow memory bound.
Host acquisition/retention owners must enforce their declared capacity and report
omissions.

No portable wire encoder or durable recorder is introduced. Adapters own versioned
serialization, exact retained bytes and lifecycle. Tests consume the shared JSON
conformance vectors copied byte-for-byte into their packaged test resources; the
guard rejects drift between that resource and the canonical contract vectors.

## Local consumption

An adopting Swift package can select the local package:

```swift
dependencies: [
    .package(path: "../kenshiki-sdks/foundation/sensors")
]
// In the consumer target's dependencies:
.product(name: "KenshikiSensors", package: "sensors")
```

Host adapters own permission, lifecycle, source identities, namespaces, retention,
durability and workflow composition. Document/selfie adapters retain exact capture
bindings. Pulse story interpretation and action policy stay in their application;
complete identity acceptance remains server-owned.

## Verification

Run from the monorepo root:

```sh
bash scripts/python.sh foundation/sensors/check.py --guards
bash scripts/python.sh foundation/sensors/check.py --platform macos
bash scripts/python.sh foundation/sensors/check.py --platform ios-device
bash scripts/python.sh foundation/sensors/check.py --platform ios-simulator
```

The runner checks closed source/test/dependency inventories, provenance, shared
vectors and compiler-derived public APIs. Native lanes record exact inputs,
required/executed test IDs, toolchain, artifacts, source stability and actual
outcomes under `.build/sensors-qualification/`. CI runs the same three platform
lanes. `--write-api` is an explicit API-snapshot authoring operation, never an
automatic CI repair.

Compilation, conformance execution, installation, physical sensor acceptance and
liveness qualification remain separate claims. The tests use mathematical fixtures;
they do not establish sensor resolution, human handling or PAD performance.

## Adversarial and integration coverage

The 20 packaging/runner tests mutate executable package graphs, dependency paths,
source/resource inventories, provenance, required test IDs and consumer execution.
They reject repinned graph changes, hidden inputs, forged success, reused scratch
outputs, redirected binaries and binary changes during execution. The root suite
also checks mandatory CI execution and shared foundation boundaries.

The [four public API integration cases](Tests/KenshikiSensorsTests/SensorCoreIntegrationTests.swift)
compose retained atoms, actual window/reducer operators, exact fixture-byte SHA-256
commitments and strict derived evidence. They cover value/lineage preservation,
changed-input rebinding, gaps, duplicate/out-of-order callbacks, session/boundary
rejection and live/historical raw-acceleration parity. Negative checks assert their
specific typed refusal reasons. Test-owned encoding is not a shipped custody codec.

The macOS lane also builds and executes a [separate SwiftPM consumer](Integration/Consumer/Package.swift)
using the documented `KenshikiSensors` product dependency. Its seven assertions run
against a freshly built binary; qualification records commands, output, exit status
and matching before/after binary hashes. This establishes local public-product
consumption on macOS. iOS has separate package compilation/API and simulator tests.

Physical acquisition, durable custody/recovery, cross-window replay prevention,
fusion and BFF end-to-end adoption remain unimplemented or unverified in this slice.

## First increment evidence — 2026-10-26

The [qualification summary](validation/2026-10-26-foundation.json) and preserved
native receipts bind the actual current source inputs. Final macOS and iOS
simulator runs each executed all 58 required tests without failures or skips;
the iOS device lane compiled and compared its public API without executing tests.
All three compiler API snapshots agree. Existing `KenshikiMotion` separately
passed its 18 required tests. `npm run check` passed, including 307 governance
regressions and the document/passport/biometric guard lanes.

The increment reuses nine Pulse core source files and 24 existing cases, adds five
input-safety cases and 25 evidence-contract cases plus four public-API integration cases, and consumes 13 shared vectors.
Independent review exposed conflicting nested record commitments and Unicode-equivalent
duplicate inputs. Constructors reconcile calibration, transformation, derivation and
window references using consistent identity equality. Maximum-size partial-window
regressions also cover precomputed gap/clock omission admission. Producing code
retains internal construction for the four extracted aggregate/timing result types;
callers read their immutable public fields.

Remaining decisions concern adapter-specific acquisition/retention profiles,
historical aggregates without exact source sample identities, measured sensor and
camera correlation, additional sensor value shapes, Android and remote distribution.
Physical sensor accuracy, human-handling ground truth and PAD performance require
separate real captures and qualification. This increment includes no app migration,
installation, model, collector or product acceptance threshold.
