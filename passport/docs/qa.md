# QA framework and migration coverage

The monorepo uses one shared boundary engine and quality-tooling implementation in `quality/`, with thin capability entry points and zero allowed findings. `Gates/import-provenance.json` retains the original identity SDK source hashes and records the shared destination, reviewed refactoring and current digest. Root `governance/tooling-lock.json` pins every shared QA file; unregistered files fail the root gate. All required code is in this checkout.

## Enforced now

- Manifest-discovered Swift targets, host/profile classification, no authored prose or vendor wire identifiers, no ambient dependencies or unattributed policy numbers, no product verdict/rendering APIs, leaf direction, public-surface escapes and persisted-store registry coverage. The upstream adversarial discovery/parser/self-test suite remains intact, including synthetic React Native probes.
- No inherited baseline debt, authored-code vendor/profile exemptions or source-marker exemptions. The explicitly inventoried upstream reader uses the preserved third-party supplier classification: licence/patch provenance, exact source hashes, independent import boundaries and public-surface checks remain mandatory; its upstream prose is not misrepresented as neutral authored SDK copy. The public gate has no baseline-reset switches. Additional production roots, source languages, modules, native binaries or model/image assets require explicit guard and provenance support before addition.
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
| Parser corpus, ASan/libFuzzer and TSan exercises | Passport: migrate with MRZ/credential parsers and their exact source dependencies |
| Geometry/temporal recording, clock, lifecycle and erasure regression suites | Passport: migrate with MRZ/custody operators; keep hosted iOS execution and required-test-count checks |
| Face route, aggregation, admission, custody and policy parity suites | Biometric SDK: migrate with the comparator/admission implementation; preserve synthetic embeddings and iOS execution |
| Hash-pinned OpenCV/native bridge build, symbol and shipped-file scans | Relevant native capability: migrate with the bridge rather than requiring absent binaries in this scaffold |
| React Native bridge/schema generation, fuzzing, semver, type/coverage/lint/duplication and sample-boundary checks | Add with an optional wrapper; the upstream boundary engine already retains its RN scanner and probes, but no wrapper is shipped here |
| Passport PACE/BAC diagnostics and authentication harness | Passport capability: migrate with access/authentication implementation |
| Supplier/licence provisioning, attestation and product backend tests | Keep in the corresponding optional adapter or identity-product repository; standalone capability packages must not require product accounts |

The entries above are migration obligations, not passing component suites in these scaffolds. Each extraction slice must bring its applicable tests, fixtures, guard extensions and CI lane in the same change. Guards prevent unreviewed scope expansion; they do not establish biometric accuracy, physical capture performance or installed-device acceptance.

## Monorepo CI

The executed workflow is `../../.github/workflows/ci.yml`. Root guards validate its complete three-product/five-lane matrix and its actual commands. `../Gates/native-lanes.yml` preserves the original per-product lane recipe for capability guard regression tests; GitHub does not execute that file. Root checks and receipts apply to every SDK lane.

## Ported iOS suite

`../../scripts/passport_check.py` executes the exact required passport/MRZ test IDs from `Gates/passport-tests.json` with fresh xcresult, no skipped/expected-failure cases and unchanged input hashes. The optional reader and camera products retain full neutral boundary rules. `quality/passport_guards.py` checks exact target/dependency/source inventories, forbidden product coupling, supplier hashes and the exact OpenSSL revision. Root CI requires the independent `passport-ios` lane; the aggregate local all-platform command runs it too.
