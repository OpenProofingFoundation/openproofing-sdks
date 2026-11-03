# Pulse motion fusion and BFF reuse map

Audit date: 2026-10-26. Scope: source inspection of the motion-related fusion,
its producer/readiness consumers, and descriptive kinematic composition. This is
an extraction map, not approval to migrate Pulse or change its policy.

Pulse already implements the important mechanisms: a pure fusion evaluator,
source accounting, explicit abstention/contradiction, versioned policy inputs,
checkpoint audit writes, typed motion-window admission, endpoint-bound joins,
limited valid aggregate composition, and application presentation. The Sensors SDK
should reuse these mechanisms through neutral inputs. Pulse action policy,
stories, consent, storage scheduling and display prose remain product composition.

## Evidence and scope

The adjacent [source manifest](fusion-bff.sources.json) records 35 files read in
full and 38 existing test methods inspected. No tests, builds, installation,
physical capture, server requests or source edits were performed by this audit.
29 files have matching initial/final hashes. Six subsequently discovered files
have final hashes only; this limitation is explicit per entry. The initial snapshot
was captured after the first authority/fusion reads, before the remaining trace;
it does not establish pre-read identities for those initial reads. Both repositories
were already dirty. Their revisions/branches/status are recorded in the manifest.

All Pulse paths below are relative to `/Users/shf/Developer/pulse-ios/`.
`AppSources/` abbreviates `Samples/KenshikiDeviceDemo/Sources/` and `AppTests/`
abbreviates `Samples/KenshikiDeviceDemo/Tests/KenshikiDeviceDemoTests/`.
The authority read includes complete root instructions, APP-ARCH-001, evidence
graph, sensor atom contract, module boundaries, and the Connect boundary documents.
Those documents contain dated findings and target contracts; their statements do
not substitute for the active call edges below.

## Active call edges

| Path | Current source edge | Consequence for extraction |
| --- | --- | --- |
| Checkpoint scheduling | `AppSources/ContinuityEngine.swift:594`: after successful authoritative check-in journal append, summary update and post-seal history submission, `performRefresh` launches `Task { await ContinuityCheckpointProducers.record(...) }`. | The fusion audit write is asynchronous relative to sealing. It is not a prerequisite for the returned check-in outcome. |
| Producer roster | `ContinuityCheckpointProducers.record` awaits `DevicePhysicsFusionProducer.record`, then `HolderContinuityProducer.record`. | Keep scheduling and product consent out of a pure Sensors evaluator. The holder producer's implementation was not traced here. |
| Inputs and evaluation | `DevicePhysicsFusionProducer.swift:45` queries evaluator-derived sensor IDs over trailing 12 hours, with a 12,000-row limit; unavailable reads return `.unavailable`; cap saturation sets an anomaly. It invokes `DevicePhysicsFusionEvaluator.evaluate`. | Reuse the single classifier/query vocabulary and explicit incomplete-input metadata. This is broad interval fusion, not synchronized waveform fusion. |
| Audit publication | Producer `window(for:)` creates `device_physics_fusion/fusion_decision`, source `derived`, with outcome, level, source names/counts, supporting row IDs, policy version and anomalies. Default commit awaits `recordSensorWindow` but discards its returned health. | A returned evaluated decision is not proof of durable success. Preserve the existing adapter separately; acknowledged publication is a distinct destination requirement. |
| Current Home projection | `DayReadCoordinator.swift:563` calls `DayReadPipeline.devicePhysicsSlice`, degrades unavailable results to `[]`, then at line 596 calls `HomeDevicePhysicsRead.project` off main. Result enters `DayDestinationReadAssembler.NonStoryInput`; publication is fenced by run ownership and privacy epoch. | The slice loader and destination assembler internals were not read here. No claim about their query completeness or every view path follows. |
| Current fusion read | `HomeDevicePhysicsRead.swift:95` constructs a trailing 12-hour window and calls the evaluator on supplied rows with current bootstrap policy. | It **re-evaluates current rows**. It does not recover the persisted audit decision. Stale comments and private `decodeDecision` describe older plumbing. |
| Local readiness | `PulsePolicyBFF.read` passes supplied `home.devicePhysics` through its thread into `ConnectPolicyEvaluator.evaluate`; evaluator tests only whether the outcome is `.contradicts`, gated by each action's manifest veto flag. | Local readiness is product composition. Corroboration does not authorize an action. Execution/server acceptance was not audited. |
| Kinematic projection | `DayReadCoordinator.swift:551` calls `CrossLaneKinematicsBFF.project` once off main on the current history snapshot and passes outputs to testimony/day sequence. `DayKinematicEpisodeTestimony` can also call CrossLane directly when no shared outputs are supplied. | Reuse the one-run/input-reuse pattern. Registry loading and all downstream presentation were not separately traced. |
| Kinematic joins | CrossLane pairs canonical location endpoints, computes displacement and jitter floor, then calls `KinematicEpisodeClassification.makeOutput`; it joins pedometer/activity by exact endpoint IDs or contained canonical subchain, and motion aggregates by contained intervals. | Retain interval identities and exact boundary precedence. Do not replace this with latest-value matching. |
| Story projection | `DayKinematicEpisodeTestimony` admits corroborated non-insufficient journeys; device-motion counts/maxima become descriptive facts and contributing sensor IDs. | Story admission, subject, prose, day membership and product evidence grammar stay application-owned. |

## Fusion semantics already present

`DevicePhysicsFusion.swift` maps many radio/network/Bluetooth rows to one
`radio_environment` source. Qualified `device_motion_window` evidence maps to
`handset_imu`; legacy scalar points do not. `watch_link` requires the row's
`watch_reachable == "true"`; merely paired does not count. Unattested
`verified_call` rows are demoted to asserted `call_session`, with an anomaly.
The attestation classifier checks nonempty payload keys other than the exact
string `false`; it does not perform cryptographic verification. Its own comment
says the key list has not been reconciled against a captured live call.

Radio, IMU and magnetometer are separate accounting sources on one handset.
The code separately exposes `isIndependentOfHandset`: only paired-watch hardware
and classified verified calls return true. The default ladder can nevertheless
reach its corroborating level from two handset accounting sources. A test named
`testTwoIndependentPhysicalSourcesCorroborate` uses radio plus handset IMU;
that name must not become a claim of independent hardware or statistical independence.

Support requires interval overlap, `.observed`, `.available`, and non-status
kind. Source multiplicity cannot increase the physical-source count. Qualifying
IMU evidence is admitted through `DeviceMotionEvidenceLakeAdapter.decode(...)
?.isCoverageQualified`; this audit treats that as a dependency edge, with its
internal measurement contract audited separately.

A mapped contradictory non-status row overrides the ladder, even if unavailable
and even if its source produced no supporting row. Absence abstains. Partial
corroboration also abstains. The default top rung requires at least two accounting
sources, two consequential sources, and a consequential ratio of at least 0.5.
The lower rung requires two, one, and 0.25. These are existing Pulse policy values,
not newly selected Sensors SDK defaults or independently validated thresholds.

The bundled `Content/connect-runtime-manifest-v2.json` is manifest version 2,
policyVersion 10, producerVersion `device-physics-fusion-v1`. All six action
contradiction-veto flags are false. `ConnectRuntimeManifest.validate` rejects
unknown/missing/duplicate action entries and unsafe fusion semantic flags.
Bootstrap falls back to the compiled fusion floor when policy loading fails;
Connect readiness separately becomes policy unavailable.

## Kinematic mathematics and eligibility

CrossLane's endpoint interval must have positive elapsed time within the supplied
policy's maximum gap. Endpoint admission requires canonical observed/available
Core Location rows, precise status, admitted simulated-location policy, finite
coordinates and accuracy in 0...100 m. This states the source predicate; Apple
framework behavior and `SimulatedLocationPolicy` internals were not evaluated.
The displacement implementation is delegated to `PlaceAnchorModel.metersBetween`,
not re-derived in this audit. The jitter floor is:

`max(minimumDisplacementMeters, accuracyMultiplier × (startAccuracy + endAccuracy))`.

Pedometer and activity joins prefer exact canonical endpoint IDs. If exact observed
rows are absent, a canonical contained subchain may be recovered. Observed rows
must be contained within the interval with five seconds of tolerance. Deduplication
uses sensor, kind, source, boundaries and complete payload, rather than row ID alone.
Activity duration sums clipped row intervals by class; this is not an interval-union
algorithm. Pedometer steps/distance sum nonnegative decoded values. These reductions
rely on admitted input-window semantics; they do not independently prove disjointness.

The state rule combines steps, walking/running duration, automotive duration, and
whether displacement exceeds jitter. Watched zero movement with changed position
can produce `.contradicted`; missing lanes produce `.insufficient`. Lane reads retain
observed/observed-empty/unavailable/missing distinctions and source row IDs.
The attestation calculation deduplicates declared independence domains separately
within asserted and consequential classes, then uses their ratio; these are
registry-defined domains, not measured statistical independence.

`KinematicDeviceMotionAggregateSummary` admits only typed coverage-qualified
windows with measurements. It sums retained window/sample counts and takes maxima
of acceleration and angular-rate maxima. It deliberately does **not** merge RMS,
median, p95, coverage, clocks or reference frames. Device inertial `supportsClaim`
is false: these aggregates describe an episode without raising its verdict or
attestation. `KinematicJourneyAssembler` preserves the same count/maxima treatment,
row lineage, contiguous endpoint grouping and explicit displacement/path limitations.

## Proposed reuse boundary

| Existing mechanism | Sensors SDK candidate | Pulse retains |
| --- | --- | --- |
| Typed window admission and descriptive count/maxima reduction | Neutral contracts, eligibility/reason codes, declared composition invariants, versioned operators and their tests | Lake decoding and story-specific output fields |
| Exact-boundary join, explicit missing/empty/unavailable coverage | Generic interval/source identity and join result contracts, if the first extracted consumer needs them | Canonical location history conventions, registry, story/journey semantics |
| Pure fusion structure | Deterministic evaluation over typed inputs; separate accounting-source and independent-hardware facts; explicit abstention/contradiction and provenance | Device Physics source taxonomy, ladder values, calls/watch admission policy, Connect manifest and decisions |
| Producer write/read seams | Acknowledged result publication via existing custody mechanisms | Check-in scheduling, Pulse lake rows, 12-hour horizon and row limits |
| `HomePhysicsBFF` | Only neutral measured values and separately justified operators, where needed | Display cards, labels, salience, sticky/daily rotation, meters, formatting and threshold wording |
| `HolderContinuityEvaluator` | No direct Sensors extraction proposed | Consent, behavioral hour histogram/cosine, thresholds, identity interpretation and device-local policy |

`HomePhysicsBFF` currently projects magnetic/pressure/connectivity snapshots;
its source explicitly leaves motion and rotation on Live. Magnetic absolute bands
require calibrated context, while variability remains separately represented.
Its finite-positive guards, optional evidence and explicit calibration distinctions
are useful precedents. Its hardcoded field bands, relative-altitude wording,
formatted decimals, meter scales and prioritization are application interpretation.
Copying this BFF wholesale would violate the neutral headless SDK boundary.

## Concrete gaps to resolve at extraction

1. Freeze neutral contracts around existing measurements/operators before moving
   code; replace dependencies on `HomeDevicePhysicsRead`, Pulse copy, runtime
   manifest and day-story registry with scoped typed ports where actually needed.
2. Bind a derivative to all decision-relevant evidence, policy/configuration and
   interval. Current fusion records supporting IDs but no input digests, policy
   hash or complete rejected/contradictory input set. Contradictory rows can decide
   the outcome without appearing among `sourceRecordIDs`, which are built from
   support rows. This is a source-level lineage limitation, not a reproduced device defect.
3. Preserve failure acknowledgement. The default producer discards commit health;
   cap saturation is recorded but does not force abstention. The current Home read
   re-evaluates without the producer's truncation flag. These behaviors need explicit
   destination contracts rather than accidental reinterpretation.
4. Separate temporal overlap from co-temporal correlation: existing Device Physics
   fusion accepts sources anywhere overlapping a 12-hour window. A current reachable
   watch payload or unrelated older sensor row does not by itself establish exact
   capture-time co-presence or synchronized sensor correlation.
5. Preserve original policy identity for historical audit rows. Current Home policy
   re-evaluation and committed checkpoint evaluation are distinct artifacts; neither
   promises to equal the other across changed rows, timing or policy.
6. State disjointness/duplicate/overlap rules before summing aggregate sample counts
   or activity durations. Existing payload deduplication and contained-window joins
   are valuable but are not a universal overlap-safe reduction contract.

These are bounded extraction requirements. They do not justify replacing Pulse's
existing stack, adding liveness thresholds, enabling contradiction enforcement,
or claiming sensor authenticity or complete identity acceptance.

## Existing verification assets inspected

38 methods were read, zero executed by this agent. Complete IDs are in the manifest.
Relevant retained suites are:

- `DevicePhysicsFusionTests` — 24 methods: physical-source deduplication, qualified
  aggregate eligibility, status exclusion, absence/contradiction, partial abstention,
  producer seams, rolling-window/midnight behavior, source/query coverage,
  watch/call classification, no affirmative Connect authority, shadowed veto and
  injected enforcing-veto behavior. The enforcing test may skip if bundle policy
  loading is unavailable; a future receipt must account for that explicitly.
- `KinematicMotionAggregateProjectionTests` — 4 methods: descriptive-only aggregate
  behavior and exact composable measurements; degraded/malformed/outside rejection;
  malformed same-boundary non-eviction; journey count/maxima composition.
- `HomePhysicsBFFTests` — 10 methods: evidence availability, field/calibration separation,
  magnetic band boundaries, pressure/connection presentation, sensor attribution,
  raw-reading/meters and a RightNow projection test.

Two producer tests include raw inputs beside the committed row when invoking
`HomeDevicePhysicsRead.project`; despite round-trip names/comments, their assertions
are compatible with re-evaluation and do not establish recovery from the committed
row alone. Dedicated tests for complete negative-input lineage and commit-health
failure are not present in the fully read `DevicePhysicsFusionTests` file; this
is not a repository-wide absence claim.

`CrossLaneKinematicsBFFTests`, broader Holder/Nocturnal/ambulatory suites, registry
loader implementation, deeper lake queries, storage internals, view wiring, runtime
bundle packaging and server execution remain outside this bounded report. Their
existence was located where relevant, without using search hits as behavior evidence.
The root audit's separate execution receipts must be assessed on their own scope.
