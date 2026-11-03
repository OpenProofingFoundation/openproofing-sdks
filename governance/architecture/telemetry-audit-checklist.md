# Foundational telemetry audit checklist

Created: 2026-10-26. Status: first foundation increment implemented; adoption separately scoped.

This is the persistent task record for reusing the sensor, mathematical, fusion
and BFF work already implemented in Pulse and reconciling it with the shared SDK
contracts. Start from the existing implementation and its tests. Record concrete
gaps before proposing new work. Update this file as work completes and resume
from its unchecked items in subsequent sessions.

The governing authority is [APP-ARCH-001](APP-ARCH-001.md). Implementation planning
belongs in that document's Appendix A. The owner's subsequent instruction
authorized the first foundation increment recorded in A.20. This checklist tracks
its implementation and evidence; application migration remains separately scoped.

## Tracking rules

- Keep task IDs stable. Check an item only when its stated output exists and its
  evidence is recorded here or linked from here.
- For each completed audit item, record the date, exact source paths and revision
  or file hashes, findings, and remaining limits. Read cited source files in full.
- Discovery through search is not a completed source audit. Initial file reads
  do not establish complete coverage of their surrounding subsystem.
- Record executed commands, counts, outcomes and receipt paths for verification.
  Reading tests does not establish that they pass.
- Recheck source state before relying on earlier findings. If relevant inputs
  change, reopen affected items and record why.
- Keep source inspection, automated verification, installation, physical
  acceptance and independent qualification as separate evidence claims.
- Preserve unrelated dirty work, branches, device records and custody. Keep real
  measurements, identity data and private artifacts outside the repository.

## Scope and boundaries

Motion is a shared foundation for passport, document and selfie workflows.
`pulse-ios` is a primary implementation baseline for acquisition, storage,
mathematics, fusion and BFF consumption, alongside the existing `KenshikiMotion`
package. Inventory existing mechanisms before designing replacements.

Preserve atomic measurements and fine micromovement. Distinguish recorded numeric
precision from sensor resolution, platform fusion from native measurements, and
inference hypotheses from demonstrated performance. Derived results must identify
their exact inputs, interval, method/version, configuration and limitations.

The first delivery is a shared measurement/window contract, existing-operator
inventory and meaningful conformance cases. Workflow migration, a new collector,
liveness-model implementation and arbitrary liveness thresholds are outside it.
Synthetic mathematical fixtures can test operators; physical liveness claims need
separately labelled real captures and independent ground truth.

## Completed orientation

- [x] T01 — Read the supplied handoff and capture its scope and boundaries above.
- [x] T02 — Read `pulse-ios/AGENTS.md` and its complete `CLAUDE.md`.
- [x] T03 — Perform initial full-file reads of the six Pulse implementations
  listed in the initial evidence record below. This is an orientation task only.
- [x] T04 — Read `kenshiki-sdks/AGENTS.md`, `CLAUDE.md`, the complete
  `APP-ARCH-001.md` and its architecture index.

## First-increment work

- [x] T07 — Establish the reusable Pulse baseline. Record current source state,
  read the relevant active acquisition → storage → mathematics → fusion → BFF
  paths and their existing tests. Output one source-backed map naming mechanisms,
  mathematical definitions, versions, existing verification and reuse boundaries.
- [x] T26 — Compare that baseline with `KenshikiMotion` and the document, selfie,
  passport and workflow integrations. Output a reuse/difference/gap table. Include
  independent capability consumption and application-owned responsibilities.
  Every proposed addition must address a demonstrated gap.
- [x] T32 — Reconcile the shared measurement/window contract from those existing
  mechanisms. Specify only the decisions and differences that need resolution;
  preserve compatible implementations and pinned historical semantics.
- [x] T34 — Reuse and execute the relevant existing conformance tests. Add cases
  only for demonstrated coverage gaps or changed contract behavior. Record exact
  inputs, commands, executed counts, outcomes and limitations.
- [x] T35 — Report what is already implemented, what can be reused, the exact
  remaining changes, verification results and separately needed physical evidence.

These five outcomes consolidate the former detailed audit tasks; consolidation
marks none of the underlying investigation complete. The earlier task IDs are
retained for these outcomes. Detailed topics below are coverage questions within
this bounded comparison, not separate projects or implementation commitments.

## Canonical consolidation checkpoint — 2026-10-26

- [x] C01 — Consolidate the SDK source and finish the private licence extraction
  through [PR #20](https://github.com/Kenshiki-Labs/kenshiki-sdks/pull/20), merged as
  `254e95a268bd6441a3776f40c9d52518482146d8`. At the recorded checkpoint, the only
  local and remote branch tips were `dev` and `main`, both at that exact commit;
  all four retained SDK worktrees were clean at the same revision. Subsequent QA
  topic work is separate from this completed parity/pruning checkpoint.
- [x] C02 — Preserve previous SDK references and working source in verified Git
  bundles and source receipts under
  `/Users/shf/Developer/kenshiki-sdks-consolidation-20261026/` before pruning.
  `preservation.json`, `consolidation-checkpoint.json` and `canonical-parity.json`
  retain the source snapshot, original-file comparison, allowed consolidation
  differences and final clean-tip/worktree record. No other repository's pruning
  or migration is covered by this SDK checkpoint.
- [x] C03 — Qualify the two private licence npm artifacts on Node 22.22.2:
  165 tests passed (14 core, 151 adapter), including all 66 pinned synthetic
  vectors and actual loopback HTTP integration. Offline packed JavaScript and
  TypeScript-declaration consumers and separate adversarial probes passed with
  unchanged source hashes. Exact receipts are in that external preservation
  root's `licence-validation/` directory. No vendor was called; route admission,
  authentication, replay/storage hosting, Persona and supplier qualification
  remain outside the [package scope](../../services/licence-check/README.md).
- [x] C04 — Run the existing canonical `npm run check` baseline on clean commit
  `254e95a268bd6441a3776f40c9d52518482146d8`: all 13 stages passed, including
  322 governance tests. This baseline result does not establish the expanded
  licence inventories/CI work being introduced afterward.
- [x] C05 — Implement the mandatory licence inventory and CI qualification lane
  in [commit `0a1a5c0a5e72f64de89cb84ef99ce4fb6d50f131`](https://github.com/Kenshiki-Labs/kenshiki-sdks/commit/0a1a5c0a5e72f64de89cb84ef99ce4fb6d50f131).
  On the frozen source subsequently committed as that revision, expanded
  `npm run check` passed all 14 stages,
  including 334 governance tests (the 322-test baseline plus 12 licence adversarial
  cases). On that exact clean code revision, the licence guard's `--execute` run
  on Node 22.22.2 passed all 165 package
  tests (14 core, 151 adapter), with no failures or skips, a fresh external packed
  package consumer and 16 compiled artifacts. All 35 input hashes matched before
  and after execution. The local receipt is
  `.build/licence-check/node-7rop15lx/receipt.json`; the external preservation root
  above retains `clean-code-licence-qualification.json`, binding the clean checkout,
  unchanged code commit and receipt. This completes local inventory/CI delivery
  and frozen-source package qualification. Hosted final-head checks and Git closure
  remain separately tracked in the qualification PR and are not claimed passed
  here. The package, supplier, host and physical limits in C03 and below still apply.
- [x] C06 — Supersede C05's initial qualification with the reviewed repairs in
  [commit `3c50c37e5bf6205b7deeab5bca9d8c59b22a2d66`](https://github.com/Kenshiki-Labs/kenshiki-sdks/commit/3c50c37e5bf6205b7deeab5bca9d8c59b22a2d66):
  fresh ESM test output, checkout/platform-bound receipts, preserved admission
  failures and approved dependency-installation/package-execution registration in
  the all-platform runner. Regression coverage includes stale runtime configuration
  and emitted tests, failed input admission, checkout drift and install failure.
  Full root `npm run check` passed all 14 stages and 341 governance tests on the
  frozen source subsequently committed as that revision. Then the actual approved
  root `run_licence` helper installed locked dependencies and executed the package
  wrapper on that exact clean commit, using Node 22.22.2 and Python 3.15.0. This ran
  the licence lane used by `check:all`; the entire `check:all` aggregate was not run.
  Both commands passed; their receipts and logs are
  `.build/validation/licence-check-dependencies.{json,log}` and
  `.build/validation/licence-check-packages.{json,log}`. Wrapper receipt
  `.build/licence-check/node-4iw3cyb9/receipt.json` records 165 passing package tests
  (14 core, 151 adapter), zero failures or skips, a fresh packed-package consumer,
  16 compiled artifacts and all 35 input hashes unchanged. Its repository revision
  and clean working-tree status also matched before and after execution. C05's
  334-test result remains historical evidence. Hosted-head results and Git
  closure are tracked separately in [PR #21](https://github.com/Kenshiki-Labs/kenshiki-sdks/pull/21);
  no supplier, service-host, application-adoption or physical qualification is added.
- [x] C07 — Correct the independently reproduced pre-dispatch expiry defect in
  [commit `b628433d5f62b04dbea397096737ea59213ac5f9`](https://github.com/Kenshiki-Labs/kenshiki-sdks/commit/b628433d5f62b04dbea397096737ea59213ac5f9).
  Expiry before a POST invocation now returns `not_dispatched` with zero fetches;
  failures after POST invocation and expiry before a subsequent GET retain an
  unknown outcome. Five boundary cases cover before/at/after expiry, request
  preparation and post-create retrieval. The installed packed artifact also tests
  expiry and attempted-dispatch uncertainty through its public adapter. The defect
  failed both source and packed-consumer regressions before the correction.
  Full root checks passed all 14 stages and 341 governance tests on frozen source
  subsequently committed as that revision. On that exact clean commit, Node
  22.22.2/Python 3.15.0 qualification passed 170 package tests (14 core, 156 adapter),
  zero skips, a fresh six-assertion packed consumer and 16 compiled artifacts, with
  all 35 inputs and checkout identity unchanged. Receipt:
  `.build/licence-check/node-_ublhge6/receipt.json`. Before/after logs and preserved
  receipts are under the external preservation root's `licence-expiry-fix/`.
  Integration and hosted affected checks are recorded by the correction PR;
  broader native, supplier, hosting, adoption and physical limits remain unchanged.

Sensors adoption, durable acquisition/replay/erasure integration and all physical
acceptance limits below remain unchanged. This consolidation checkpoint adds no
new sensor installation, device run, production service deployment or release.

## Merged baseline — 2026-10-26

Historical first-increment checkpoint; canonical branch parity is recorded above.

At this earlier checkpoint, the baseline was `dev` commit `91e89f7b542e9b7cdf9b6ca3afbeba1c2ae1220d`,
squash-merged through [PR #15](https://github.com/Kenshiki-Labs/kenshiki-sdks/pull/15).
The implementation topic branch was deleted locally and remotely. No promotion
to `main`, publication, deployment or application migration had been performed
at that checkpoint; canonical branch parity was completed separately above.

| Area | Existing work and current shared-SDK state |
| --- | --- |
| Product boundary | `KenshikiSensors` is an independently consumable local Swift package inside `foundation/sensors/`; Swift 6, iOS 18/macOS 13. Android and remote distribution remain separate work. |
| Measurement and processing | Shared v1 evidence contract and Pulse clock/window/statistics/processed-motion/raw-acceleration core are implemented. Nine donor files and 24 donor cases were reused. |
| Existing ceremony motion | `KenshikiMotion` remains available with its existing APIs, mathematics and hash semantics; this increment did not migrate its consumers. |
| Acquisition and durable custody | Existing Pulse and capability mechanisms are mapped in the [acquisition/custody audit](telemetry-audit/acquisition-custody.md) and [SDK comparison](telemetry-audit/sdk-comparison.md). A production Sensors acquisition/persistence adapter and sensor-to-custody/recovery integration have not been delivered by this increment. |
| Fusion and BFFs | Existing Pulse implementations are mapped in the [fusion/BFF audit](telemetry-audit/fusion-bff.md). Their neutral extraction and adoption remain open; the shared package does not implement the complete sensor-to-fusion/BFF chain. |
| Physical acceptance | No installation, live sensor/camera timing qualification, sensor-authenticity proof, human-handling ground truth or PAD qualification was performed. |

The [qualification summary](../../foundation/sensors/validation/2026-10-26-foundation.json)
preserves native execution on clean source revision
`ad304a9d997298ab111808e41047dd0a590aa06e`: 58 required tests each on macOS
and iOS simulator, device compilation/API comparison with zero device tests, and
seven assertions in a separate SwiftPM consumer. The 20 packaging/runner tests,
four public-API integration cases and 13 shared vectors establish their named
structural and mathematical scope; they do not establish durable or physical
end-to-end behavior.

All 67 final PR-head check runs passed. The recorded Sonar gate passed with 0.0%
new-code duplication; two initializer-parameter-count maintainability findings
remain open. After merging, `npm run check` passed all 13 guard stages, including
307 governance tests. These are retained execution results, not newly executed
native tests for this baseline update.

This baseline refresh fetched `origin/dev`, confirmed the merge through GitHub,
verified the three preserved native receipt hashes, and compared all 32 qualified
native input hashes against the merged checkout. All matched. The primary
`kenshiki-sdks` checkout also matched those 32 inputs, but remains on a separate
branch with unrelated uncommitted work; it is not a clean qualification baseline.

The next increment to scope is one production acquisition-to-evidence/custody
adapter using the audited existing mechanisms, with an explicit retention profile,
acknowledgement boundary and retry/recovery/erasure evidence. This is a proposed
bounded continuation, not a claim that the existing Pulse collector, fusion or
BFF needs replacement, and not a completed application migration.

## Contract coverage within the comparison

Record how existing code handles native versus platform-fused measurements;
units, gravity, frames and transformations; sensor/receipt/wall clocks and
uncertainty; requested versus actual cadence; gaps, duplicates, reordering and
invalid samples; window boundaries, overlap, retention and eligibility; durable
custody, source identity and derived-result bindings; and explicit missing,
partial and unavailable evidence. Trace journal acknowledgement, backpressure,
replay and erasure where they affect those guarantees.

For existing mathematics, record sample/time weighting, irregular sampling,
filtering, spectral normalization, Nyquist constraints, numerical precision and
sensor-resolution limits. For fusion and BFFs, record temporal alignment, source
dependence, contradiction/abstention, provenance and decision authority. Preserve
fine micromovement and workflow-wide temporal ranges.

Consult the supplied SHF data and research where they resolve a concrete contract
or mathematical question. Sparse points cannot establish a dense waveform or
human handling. A-Live's omitted implementation details and unreproduced results
do not authorize a guessed model. Neither a new research programme nor liveness
qualification is a prerequisite to documenting and reusing established code.

## Motion-first reuse audit — 2026-10-26

T07 and T26: completed for the motion-first slice in the
[reuse map](telemetry-audit/README.md), with separate acquisition/custody,
mathematics/tests, fusion/BFF and SDK-comparison reports. Exact source identities,
dirty checkout baselines and per-report coverage limits accompany the reports.
This completion does not cover every other Pulse sensor or complete SQL/server
internals. The approved product destination is `foundation/sensors/` inside
`kenshiki-sdks`; no source package or migration was created in this audit.

T34 partial progress: `python3 foundation/motion/check.py` executed all 18 required
shared-package tests successfully with unchanged source. See the
[verification record](telemetry-audit/verification.json). Pulse iOS and capability
integration suites remain unexecuted in this audit. T32, T34 and T35 remain open.

At this audit checkpoint, contract reconciliation and implementation were still
pending. The subsequent completed increment is recorded below. Implementation
planning continues to belong in APP-ARCH-001 Appendix A.

## First foundation increment — 2026-10-26

T32: implemented the independently consumed local Swift `KenshikiSensors` package
under `foundation/sensors/`, reusing nine Pulse source files with exact source
provenance. The [v1 contract](../../contracts/sensor-measurement-window-v1.md)
and three new evidence source files define units/gravity, frames, clock domains,
correlation uncertainty, windows, explicit retention/absence/omissions and complete
immutable derivation bindings. Valid-input Pulse mathematics is preserved; defensive-admission
changes have five focused cases. Existing `KenshikiMotion` is unchanged.

T34: final macOS and iOS simulator lanes each passed all 58 required tests with
unchanged source and no skips. The iOS device lane compiled and compared its public
API, with zero tests executed. The 58 comprise 24 ported Pulse cases, five defensive
core cases, 25 contract cases and four public API integration cases, including 13 shared vectors. Existing motion
separately passed 18 tests. Repository `npm run check` passed, including 307
governance regressions and all three capability guard lanes. Inventories,
adversarial guards, compiler API snapshots and three required CI lanes are present.
Twenty Sensors packaging/runner tests include executable graph and forged-execution
mutations. The macOS lane independently built and ran the documented SwiftPM
consumer product with seven assertions and bound binary/output hashes.
Hosted checks and Git integration are recorded in [PR #15](https://github.com/Kenshiki-Labs/kenshiki-sdks/pull/15).
App installation and physical sensor acceptance were not performed.

T35: [package/result report](../../foundation/sensors/README.md) and
[qualification summary](../../foundation/sensors/validation/2026-10-26-foundation.json)
record reused mechanisms, exact mathematical definitions, executed conformance,
current source identities and remaining decisions/physical evidence. Independent
review's nested-commitment conflict was repaired and regression-tested before the
final source-bound runs. All first-increment items are complete for this Swift slice.

Further app adoption, collector consolidation, additional value shapes/sensors,
Android, remote packaging and calibrated physical/liveness qualification remain
separate delivery work. No migration or new collector was introduced here.

## Initial evidence record — 2026-10-26

T01: the owner-supplied handoff was read in full from
`/Users/shf/.codex/attachments/caa8a433-3117-4ebb-98ef-283a013fec53/Pasted text.txt`.
Its continuing requirements are captured in Scope and boundaries above.

T02: both repository instruction files were read in full. The SHA-256 of
`pulse-ios/CLAUDE.md` at the initial read checkpoint was
`2f6ec1dc3f01892737b17f84fd9b3e1f70c5c48c018dfb37a1b2ed18975abc40`.

T03: complete file reads established the initial orientation below. Paths are
relative to `/Users/shf/Developer/pulse-ios`; SHA-256 values were recorded when
creating this checklist. These reads do not complete the reusable-baseline task T07.

| File | SHA-256 |
| --- | --- |
| `Sources/KenshikiDeviceSDK/DeviceMotionEvidenceWindow.swift` | `f8923d58099d4593385fb2268384eb08f1bae40f4c53c822ee8102843a70372e` |
| `Samples/KenshikiDeviceDemo/Sources/ForegroundDeviceMotionAggregation.swift` | `7bbfe2ccb6797b802893840c2fa5204b87ac1c059262791674f591cb8863e449` |
| `Samples/KenshikiDeviceDemo/Sources/DevicePhysicsFusion.swift` | `0efd6a2dca824e56c8d87c40e1e51178b486203892d7f3be38d92963df47e705` |
| `Samples/KenshikiDeviceDemo/Sources/DevicePhysicsFusionProducer.swift` | `9ddae135f3b12d18e091531ec5ded90b9829a3c756d3cdfe3a618bb57d26ea79` |
| `Samples/KenshikiDeviceDemo/Sources/HomePhysicsBFF.swift` | `97c7d41af7077f61b8c9788508f20ad93957a2971ed90a3f24dd8cdd512b2429` |
| `Samples/KenshikiDeviceDemo/Sources/CrossLaneKinematicsBFF.swift` | `6de2e848e305959cb437f2321a77ca9cd7a627f6efee8798d1b4ca70cd8fcd79` |

T04: the four named documents were read in full while preparing this file.
`APP-ARCH-001.md` declares revision 0.2 and includes later adoption appendices.

Initial Git observations; refresh source provenance when T07 begins:

| Checkout | Branch | HEAD | Observed state |
| --- | --- | --- | --- |
| `kenshiki-sdks` | `fix/canonical-front-capture-20261025` | `04309902f45cea28505713a2b229f2b582d823c1` | Existing modified and untracked files; preserve them. |
| `pulse-ios` | `fix/gateway-licence-wiring-20261025` | `d6d544a75d3b79106eb8224a6f93f0b7536d2e2f` | Existing modified and untracked files; preserve them. |

External analysis root:
`/Users/shf/Developer/workbench/pulse-motion-analysis-20261026/`.
Research inputs: `governance/research/manifest.json`,
`governance/research/method-notes.md`,
`governance/research/papers/2606.05126v1.pdf` and the supplied TeX at
`/Users/shf/Downloads/arXiv-2606.05126v1/liveness_compsoc.tex`.

No sensor tests, native builds, installations or physical qualification were
executed as part of these initial reads.
