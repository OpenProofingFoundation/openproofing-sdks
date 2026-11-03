# QA framework and migration coverage

The monorepo uses one shared boundary engine and quality-tooling implementation in `quality/`, with thin capability entry points and zero allowed findings. `Gates/import-provenance.json` retains the original identity SDK source hashes and records the shared destination, reviewed refactoring and current digest. Root `governance/tooling-lock.json` pins every shared QA file; unregistered files fail the root gate. All required code is in this checkout.

## Enforced now

- Manifest-discovered Swift targets, host/profile classification, no authored prose or vendor wire identifiers, no ambient dependencies or unattributed policy numbers, no product verdict/rendering APIs, leaf direction, public-surface escapes and persisted-store registry coverage. The upstream adversarial discovery/parser/self-test suite remains intact, including synthetic React Native probes.
- No inherited baseline debt, vendor/profile exemptions or source-marker exemptions. The public gate has no baseline-reset switches. Additional production roots, source languages, modules, native binaries or model/image assets require explicit guard and provenance support before addition.
- Kotlin source coverage and lexical guards for ambient state, prose, logging, networking, rendering, product identity verdicts and policy constants. Interpolated strings currently require reviewed mechanism support. The reviewed Android package declaration is excluded from brand-token checks; arbitrary declarations are not.
- Swift payload logging and mandatory networking are prohibited in neutral code. Diagnostics must cross a reviewed reason-code interface. Source checks are conservative lexical checks, not general taint/data-flow verification.
- Android build graph/source redirection, manifest permissions/components, version pinning and Gradle distribution checksum; npm exact-version and archive-integrity validation. New runtime dependencies require an explicit extension to the inventory/provenance checks.
- Swift/Kotlin outcome vocabulary parity. Compiler-derived public API snapshots for macOS, iOS device, iOS simulator and Android catch surface drift. Regenerate only as an explicit compatibility/versioning review with `python3 scripts/guards/public_api.py LANE --write`; normal checks never update snapshots.
- Post-build AAR inspection checks archive names and nested class names for vendor/product dependencies and undeclared native/model assets. It is not a complete binary semantic or malware analysis.
- Adversarial regression tests exercise real scanners with temporary mutated repositories: source hiding, CI bypasses, vendor imports, source redirection, forgotten stores, provenance tampering, assets, contract drift and packaged classes.

## Local and CI enforcement

Install pinned tooling once with `npm ci --ignore-scripts`. Run `npm run check` for guards, or `scripts/check.sh all` for guards, macOS tests, both iOS builds and Android build/lint/unit-test tasks. Individual lanes are `guards`, `macos`, `ios-device`, `ios-simulator`, `apple`, `android`.

`swift test` also invokes the guard runner on macOS, so enforcement is not CI-only. Missing scripts fail; they are not skipped. CI independently runs five mandatory lanes on push and pull request: guards, macOS tests, iOS device, iOS simulator and Android. Actions are pinned to immutable commits; jobs are bounded and cannot soften required steps. No binary build cache is restored. The configuration guard parses YAML and rejects missing/conditional required lanes or disabled entry points. Guard results, input hashes, dirty state and individual logs are retained in `.build/quality/` and uploaded even when a lane fails. An unborn local repository records a null revision until its first commit.

## Suites that move with their implementation

| Existing SDK protection | Capability / activation |
| --- | --- |
| Parser corpus, ASan/libFuzzer and TSan exercises | Document: migrate with the AAMVA/MRZ parsers and their exact source dependencies |
| Geometry/temporal recording, clock, lifecycle and erasure regression suites | Document: migrate with capture/custody operators; keep hosted iOS execution and required-test-count checks |
| Face route, aggregation, admission, custody and policy parity suites | Face: migrate with the comparator/admission implementation; preserve synthetic embeddings and iOS execution |
| Hash-pinned OpenCV/native bridge build, symbol and shipped-file scans | Relevant native capability: migrate with the bridge rather than requiring absent binaries in this scaffold |
| React Native bridge/schema generation, fuzzing, semver, type/coverage/lint/duplication and sample-boundary checks | Add with an optional wrapper; the upstream boundary engine already retains its RN scanner and probes, but no wrapper is shipped here |
| Passport PACE/BAC diagnostics and authentication harness | Optional document chip module: migrate when that module is introduced |
| Supplier/licence provisioning, attestation and product backend tests | Keep in the corresponding optional adapter or identity-product repository; standalone capability packages must not require product accounts |

The entries above are migration obligations, not passing component suites in these scaffolds. Each extraction slice must bring its applicable tests, fixtures, guard extensions and CI lane in the same change. Guards prevent unreviewed scope expansion; they do not establish biometric accuracy, physical capture performance or installed-device acceptance.

## Monorepo CI

The executed workflow is `../../.github/workflows/ci.yml`. Root guards validate its complete three-product/five-lane matrix and its actual commands. `../Gates/native-lanes.yml` preserves the original per-product lane recipe for capability guard regression tests; GitHub does not execute that file. Root checks and receipts apply to every SDK lane.

## NIST tooling enforcement

Biometric guards verify the exact 24-file upstream source inventory and reviewed manifest digest, with adversarial tests for source tampering, inventory expansion/removal, symlinks and pin divergence. Root CI has an additional mandatory `nist-linux` job, guarded against skipping or command redirection, which compiles/links the official driver and upstream null reference and exercises synthetic forked I/O. This tooling-only reference library is outside mobile targets and does not implement face recognition. Detailed evidence is uploaded from `.build/nist/`.

## Optional capture enforcement

`Gates/capture-sources.json` records exact donor and destination hashes for the optional capture/preview products and their nine test files. Shared capture guards enforce the closed product/source/dependency graph, platform imports, private mutable frame ownership and absence of custody/transport. All imported neutral rules still apply; preview rendering receives no workflow exemption. Adversarial mutations cover hidden/deleted/symlinked files, provenance changes, dependency reversal, logging/ambient/policy/verdict boundaries and analysis in preview.

`bash ../scripts/python.sh ../scripts/capture_check.py` (from this directory) executes the complete iOS capture test inventory in `Gates/capture-tests.json`. The root aggregate check and mandatory `biometric / capture iOS` CI job run the same runner. Fresh result summaries, unique required IDs, no skips/expected failures, source stability and binary/log/result digests are checked; prior attempts remain separate. Optional public API snapshots live under `api/BiometricCapture/` and `api/BiometricCapturePreview/`; preview has only iOS lanes. Existing headless snapshots remain independently checked.

The reference app has additional controller/native UI required IDs under the presentation runner. Their execution proves their named synthetic/lifecycle/unsupported assertions; actual TrueDepth and VoiceOver acceptance remains in the reference-app acceptance record.
