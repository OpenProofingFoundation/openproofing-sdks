---
title: The boundary contract
status: current
version: 6
created: 2026-09-17
updated: 2026-10-09
---

# The boundary contract

What this SDK owns, what the host owns, and how you can tell which side a thing belongs on.

This is the contract the package is being built to. It is **not** a description of the package as
it stands today — [`adopter-guide.md`](adopter-guide.md) says what actually works right now, and
[`extraction-ledger.md`](extraction-ledger.md) tracks the migration. Where the two disagree, this
file is the target and the ledger is the truth.

## The decision this rests on

The SDK will be adopted by **other organisations** — a bank, an agency, a partner — not only by
Kenshiki's own apps (owner, 2026-09-17). That single answer decides everything below. An SDK for
one company may author its own error sentences, speak its own server's wire format and read files
out of the host app's bundle. An SDK for many may not.

## The rule, in one line

**The host supplies every name, location and number. The SDK keeps every construction.**

The host says *which* Keychain service, *which* directory, *which* thresholds, *what words the
holder reads*. The SDK keeps key generation, signing, canonical serialisation, Merkle append,
salted derivation, the erase barrier, and the Keychain and file implementations with their
measured protection classes.

Put the other way: **identity is injected, mechanism never is.** A host that supplies a name cannot
weaken a guarantee. A host that supplies a mechanism can — silently — and that is the line.

## The five rules

Each is written so a script can answer yes or no. A rule a reviewer has to remember is a rule that
rots; these live in `Gates/` and run in `swift test`.

### Rule 1 — the SDK authors no prose

No `LocalizedError`, no `errorDescription`, no `.localizedDescription` in a neutral target. Failure
and uncertainty cross the boundary as a `ReasonCode`, and the host writes the sentence.

*Why:* the current passport reader tells a holder "Hold the phone steady against the back cover."
That is a product decision, in English, inside a component a bank would ship to its own customers
in its own voice. It also causes a real defect class — Pulse's tamper detection is currently
unreachable because it works by substring-matching its own prose, and no error string contains the
substrings it looks for. Reason codes make that bug unexpressible.

### Rule 2 — the SDK speaks no vendor wire format

No `kenshiki`, `pulse` or `credit.` in any string literal, type name, file name, symbol or queue
label in a neutral target. No vendor DTO in a neutral target.

*Why:* a wire format is a contract with one company's server. An adopter compiling against it
inherits a shape they cannot use and cannot remove.

### Rule 3 — the SDK constructs no ambient dependency

No `Bundle.main`, no `UserDefaults.standard`, no `FileManager.default` roots, no ambient clock. The
host names every location; the SDK opens it.

*Why:* `Bundle.main` in a package is the *app's* bundle. Today the passport reader looks there for
a 1,195,404-byte certificate list under a filename only a source reader would learn. Miss it and
everything compiles, nothing warns, and every passport read fails before the NFC sheet appears.
That is the ambient-reach failure mode in its purest form.

### Rule 4 — the SDK holds no *unattributed* policy number

**Amended from the drafted rule, by owner decision 2026-09-17.** The original rule forbade policy
numbers in neutral targets outright. The owner chose to ship Kenshiki's calibrated defaults so the
SDK works out of the box.

The amendment that keeps that honest: a default is permitted **only** as a *named, attributed
calibration value*, and the calibration that produced a result is **recorded in that result**.

So `ContinuityCalibration.kenshikiV1` is allowed and documented as "measured against Kenshiki's
own population, 2026"; a bare `static let tHalfDays = 45.0` is not. An adopter gets working numbers
immediately, and anyone reading a score can see whose evidence set them.

*Why the attribution is not optional:* the fourteen continuity constants — a 45-day half-life, a 90
check-in target, a 1.28 lower credible bound — were measured against Kenshiki's users. Shipped
anonymously, a bank's risk scores would look authoritative while resting on someone else's
population, and nothing in the API would say so.

### Rule 5 — the SDK returns no verdict and renders nothing

No public `is…`/`has…`/`can…` Bool that encodes a pass, no display-ready image or formatted string
as a primary output. The SDK reports an evaluation, its terms, its uncertainty and a disclosed
grade. What passes is the host's policy.

*Why:* `ContinuityState.isLocked` is a gate. The threshold behind it is Kenshiki's risk appetite,
not an adopter's.

### Rule 6 — the host reaches past no public surface

Applies to hosts, profiles, vendor adapters and third-party code, not to neutral targets. No `@testable import`, no underscored
attribute (`@_spi`, `@_implementationOnly`, `@_exported`, …), no underscored member, no runtime
reach around access control (`Mirror`, `NSClassFromString`, `dlsym`, `unsafeBitCast`), and none of
the manifest-side equivalents: `unsafeFlags`, `enable-testing`, or depending on a module no
`.library` product exports.

*Why:* a host exists to prove the PUBLIC surface is sufficient. The moment it can reach past that
surface to make itself work, it stops being evidence the boundary holds and becomes evidence it
does not, while still reporting green. When a host or a debug UI cannot show something, that is a
finding about the public API — the thing becomes real public API, or it stays hidden. It is never
a licence to reach around.

## Who each rule applies to

Added 2026-09-17, when the first host target was built. The five rules above govern **neutral**
targets — the SDK itself. A host application legitimately authors prose, names its vendor, holds
its own numbers and decides what passes; that is what a host IS. So the gate carries five roles
(vendor adapter and third-party added 2026-10-08, below).

| Role | Exempt from | Bound by |
| --- | --- | --- |
| neutral | nothing | Rules 1, 2, 3, 4, 5 |
| host | the five neutral rules | Rule 6 |
| profile | the five neutral rules | Rule 6 |
| vendor adapter | the five neutral rules | Rule 6; nothing neutral may depend on or import it |
| third-party | the five neutral rules, only with complete provenance | Rule 6; patch review; imports none of this repository's modules |

**Vendor adapters, by owner decision 2026-10-08.** A vendor adapter is an exported library whose
job is one vendor's wire format, so Rules 1–5 would count its purpose as debt. It is declared in
exactly one place, `VENDOR_ADAPTERS` in `Gates/boundary_gates.py`, with the vendor named:
`Packages/IdentityGateway` for Pulse, which its README already calls the Pulse vendor adapter. The
gate does not infer the role from a README, a directory or a comment. It checks the declaration
against the build graph, and each failure is a fatal conflict. A manifest must declare the target as
a `.target`, and a `.library` product must export it. No neutral target may depend on it, by target
name, by `.product`, or through a neutral `project.yml` target's `packages:`. No neutral source may
import it. The exemption costs the same as a host's: the neutral SDK cannot reach the adapter. An
adapter is bound by both halves of Rule 6, its sources and its own `Package.swift`. Its persisted
stores stay inside the erase registry check.

**Third-party code, by owner decision 2026-10-08.** Vendored upstream code under `ThirdParty/` is
exempt from Rules 1–5 **only** while its package carries a complete `provenance.json`. That file
gives the upstream name, version, https URL, licence and licence file, and lists every local patch
with the files it touches and what it changes. Packages are declared in `THIRD_PARTY_PACKAGES`, so
missing or incomplete provenance on a declared package is fatal; while the conflict stands, the gate
scans the package as neutral. An undeclared `ThirdParty/` package stays neutral.
`ThirdParty/FaceMatching` is Kenshiki's own fork from the capture stack, not upstream code, and gets
all five rules. A third-party source may not import a module this repository declares: upstream
cannot depend on our code, so moving SDK code into a vendored directory buys a conflict, not an
exemption. The one package declared today is `ThirdParty/NFCPassportReader`, AndyQ's
NFCPassportReader 2.3.1.

**Local patches to third-party code stay reviewed, Rule 6-style.** A patch is code this SDK ships.
Each one is listed in `provenance.json` with the files it touches and what it changes, and is
reviewed as a change to the boundary. It may not reach past any public surface: no `@testable`, no
underscored attribute or member, and no `Mirror`, `NSClassFromString` or other runtime reach. It may
not import this repository's modules. The gate runs Rule 6's source and manifest checks over the
whole vendored package and the import check over every file, so a patch that adds a reach fails
the gate as well as review. An upgrade re-diffs upstream and rewrites the patch list in the same
commit.

**Hosts are exempt from Rule 3 by owner decision, 2026-09-17.** A host reading `Bundle.main`,
`UserDefaults.standard` or the clock is not ambient reach — it is the host performing exactly the
naming Rule 3 demands of it. Until that decision the sample host injected a *frozen* clock purely
to hold its counter at zero, which made the one target whose job is to model what an adopter writes
model an application that never learns what time it is.

**The roles are read out of the build graph, never out of the scanned text.** A host is an
executable the root manifest declares, exported by no `.library` product, depended on by no
non-test target, and named by no import in any neutral target. A profile is the same minus the
executable. Those conditions say one thing from several directions: *nothing can import it.*

**An XcodeGen application is a host too, added 2026-09-17 with the first device host.** An iOS
application cannot be a SwiftPM target — no app product, no Info.plist, no scheme — so the only
kind of host a person can hold in their hand had to be an Xcode project, and deriving targets from
`Package.swift` made exactly that kind invisible to Rule 6. The gate now reads `project.yml` files
and scans each application target's `sources:` directories as a host. Here "nothing can import it"
is not a condition to satisfy but the shape of the build system: `Package.swift` can depend on a
SwiftPM package or on a target in its own manifest, and an `.xcodeproj` is neither, so the arrow
runs one way only. The gate checks the observable shadows of that claim rather than assuming it —
no manifest declares a target of the name, no `.library` exports it, no directory is both a package
and an Xcode project, and the source roots are disjoint from every neutral target's. XcodeGen
**test bundles** are not scanned, on the same rule that has always excluded `.testTarget` from every
manifest-derived scan; `--report` prints what each one would have scored, so an excluded target is
still a seen one.

That is the whole reason the exemption is safe. The exemption and the thing worth exempting are the
same property, so the forgery does not buy a false exemption — it buys a true one, and it costs you
the module. This replaced a name list (`PROFILE_TARGETS`) that granted the same exemption for one
line in `Package.swift`, which was cheaper than the Rule 4 forgery described below.

A rejected definition, recorded so it is not proposed again: *a library target that no other target
depends on.* Measured against this manifest it makes profiles of `KenshikiSensors`,
`KenshikiCapture`, `IdentityEvidencePreview` and `CaptureSelfiePreview` — four shipped modules —
because a library nothing depends on is exactly what a top-level SDK module looks like.

**React Native targets are measured too (2026-10-08).** A `package.json` that is not
`"private": true` is a publishable npm package and therefore **neutral**:
`ReactNative/identity-capture` receives Rules 1–5 over the directories its own `files` field ships
(`src/` TypeScript, `ios/` Objective-C++), through TypeScript and Objective-C models of each rule in
`Gates/boundary_gates.py`. A `"private"` or unreadable manifest is a classification conflict, not a
guess. `Examples/ReactNativeCaptureHost` is a **host**, bound by Rule 6: it imports the package only
through its public entry (`@kenshiki/identity-capture`, never a sub-path or a path into the
package's sources); it does not reach the package's native module or component around that API
(`TurboModuleRegistry`, `NativeModules`, `requireNativeComponent`, `codegenNativeComponent`,
`UIManager`, or a name from the package's `codegenConfig`); it does not switch off the type checker
(`@ts-ignore` and kin), read a member the package declares private, or import a header the podspec
does not publish; and its Swift and build scripts are held to the Swift-side doors listed under
Rule 6.

This host has no manifest of its own — `create-host.py` generates the app outside the repository
and copies these sources in — so it is declared by path in `REACT_NATIVE_HOSTS`, and the gate checks
that the declaration is honest rather than trusting it: no `package.json` governs it, it is not a
Swift package or Xcode project, it overlaps no neutral source root, and no neutral package source
imports into it. Any TypeScript file that no package governs and no host declares is a conflict.

Four React Native questions were decided on 2026-10-08:

- **The package's own product name in build files is not scanned.** The npm name
  `@kenshiki/identity-capture` and the podspec's author live in `package.json` and the podspec,
  which are build files. No exemption for the name exists: if the package's own sources spell it,
  Rule 2 counts it.
- **`import React` is not rendering.** Rule 5's rendering check stays a display-formatted string;
  importing React is not one.
- **Host test files are not scanned**, matching the `.testTarget` and XcodeGen test bundles no rule
  has ever scanned. Jest's `*.test.ts` and `*.test.tsx` files are skipped only while no non-test
  host source imports one. The Swift UI test the host's build script places in the generated app's
  UI-test bundle (`ArtifactIntegrationTests.swift`) is declared by path in `RN_HOST_UI_TESTS` and
  skipped only while it exists and imports XCTest. `--report` prints what the skipped files would
  score: 12 files, 0, on 2026-10-09.
- **`RCTPresentedViewController()` stays ambient.** The bridge reaching for the presented view
  controller is a presenter the host did not name, and Rule 3 keeps counting it.

**TypeScript inside an XcodeGen test bundle is covered by that bundle (2026-10-09).**
`Distribution/IdentityCaptureRuntime/Tests/Fixtures/SubscriberSchemaFixtures.ts` is a schema
fixture the runtime's Swift tests read by path. A test bundle is excluded from every rule, so a file
inside one is a seen file in an excluded target, not a file outside every rule. A neutral package
importing from a test bundle is still a conflict.

## What the host must supply

**Distributable Xcode frameworks are neutral targets (2026-10-07).** The iOS React Native
runtime is an XcodeGen `framework`, so it receives all five neutral rules over every declared
source directory. It receives no host exemption. An app sharing those source roots still raises
a classification conflict. Other unclassified Xcode target types continue to fail closed.

Twenty-two injection points in the full design. The ones that shape an integration:

| Host supplies | Default | If absent |
| --- | --- | --- |
| Application identity | none | does not compile |
| Domain separators | none | does not compile |
| Custody naming (Keychain service/account stems) | access group defaults to app-only | does not compile |
| Storage naming (durable root, protection class) | protection defaults to `completeUntilFirstUserAuthentication`, floor-enforced | does not compile |
| Monotonic clock | none | does not compile |
| Continuity calibration | `kenshikiV1`, attributed | uses the attributed default |
| Consent state | none | does not compile |
| External time anchor | nil | every span grades `locallyWitnessed` and says so |
| Diagnostic sink | discard | collects nothing |

Note the asymmetry. Defaults exist only where the default is the *safest* option (app-only access
group, strictest file protection, collect nothing) or where it is explicitly attributed. Nothing
defaults to a value that would quietly weaken a guarantee.

## What the host may NOT supply

**Secret storage and durable evidence storage.** The host names the slots; the SDK keeps the
implementations (owner decision, 2026-09-17).

*Why this one is closed:* a host-supplied secret store can set `kSecAttrAccessible` to `.always`,
and a host-supplied file store can drop `completeUntilFirstUserAuthentication`. Both destroy
properties this SDK currently claims, both are invisible until they matter, and neither would fail
a test. An adopter with its own hardened storage layer cannot reuse it here, and that cost is
accepted deliberately.

## How the boundary gets exercised

A boundary with one caller, always passing the same arguments, is not a boundary — it is a
parameter list nobody has varied.

So the repository is to carry **two** profiles. `Profiles/Pulse` will hold Kenshiki's names,
numbers, copy and wire format. `Profiles/ExampleAgency` is to be a deliberately hostile second
adopter with different domains, different storage roots, different calibration and no copy table at
all — no host application, existing solely to fail the build when a Kenshiki assumption leaks back
into a neutral target.

**NEITHER EXISTS YET.** There is no `Profiles` directory. Until both are real and building in CI,
this package has exactly one caller shape and nothing has tested its neutrality — so no claim in
this document that rests on a second adopter has been demonstrated.

This paragraph read "the repository carries two profiles", in the present tense, from 2026-09-17
until later the same day. That was a design intention written as a shipped fact, in the document
whose whole job is to be the thing people trust — the same failure this file criticises elsewhere,
committed here. Caught by a reader, not by me.

A further trap to avoid when they are built: two profiles in two separate app launches prove
nothing about isolation. They must be instantiated in ONE process, because this package currently
holds THREE process-globals — Keychain policy (`KenshikiKeychainCustody`), the erase barrier
(`EraseBarrier`), and the injected environment (`HostEnvironmentHolder`, added 2026-09-17,
whose own doc comment admits it is "exactly the shape this SDK is removing elsewhere") — and
separate launches would hide interference between them.

`Hosts/ExampleHostApp` is the first step toward this and is NOT the second profile. It applies two
adopter profiles in one process and prints what the second did to the first, so the interference is
shown rather than described. The profiles themselves are still two inline structs, not targets;
`Profiles/Pulse` and `Profiles/ExampleAgency` remain unbuilt.

## Current distance from the contract

Enforced by `Gates/boundary_gates.py`, wired into `swift test`. **Re-measured 2026-09-17 after an
empirical audit found four of six gates were theatre.** Baselines are per rule per target, across
the targets the manifests declare — 19 neutral and 3 hosts as of 2026-09-17 (one SwiftPM executable
and two XcodeGen applications), not the ten this table was first written against:

| Rule | Debt | Previous counter | What the old gate was doing |
| --- | --- | --- | --- |
| 1a — no error-description prose channel | 32 | 14 | caught 1 of 21; could not see the contract's own worked example |
| 1b — no sentence the SDK wrote | 134 | 98 | blind to multi-line literals entirely |
| 2 — no vendor wire format | 252 | 252 | 11 of 20 — the only counter with real signal |
| 3 — no ambient dependency | 85 | 27 | caught **0 of 23** |
| 4 — no unattributed policy number | 98 | 35 | caught 2 of 20, and was FORGEABLE to a permanent zero |
| 5 — no verdict, no rendering | 156 | 11 | caught 3 of 20, with false positives on Codable wire fields |
| Layer — the leaf stays a leaf | 2 | 2 | 6 of 19; attributed imports escaped |
| 6 — the host reaches past no public surface | 0 | — | added 2026-09-17 with the first host |
| **Total** | **789** | 439 | |

Of the 789, **445** belongs to the four `Kenshiki*` targets, **342** to the capture-stack
targets and 2 to the layer check, which has no target. The capture targets were written before any
gate could see them.

**The forgery is the one to understand.** Rule 4's exemption read `"CalibrationProfile" in text` —
file-wide — so a single comment line exempted every number in a file. Verified end to end:
prepending it to each file took the counter from 35 to 0 and `--write-baseline` banked that as an
improvement. The exemption is now brace-scoped to a declaration that genuinely conforms AND carries
the population line this contract's amendment asks for. The same forgery attempt now yields 98.

**Two structural fixes matter more than any single rule.** The scan list is derived from
`Package.swift` rather than hardcoded, so a target cannot be born outside the rules — eight
exported targets were invisible, and renaming `Sources/` made every counter report "improved".
And baselines are per-target, so adding a module creates new keys and can never raise an existing
ceiling.

**React Native, first measured 2026-10-08.** Two targets joined the scan and were banked at what
they measured:

| Target | Rule | Debt |
| --- | --- | --- |
| `ReactNative/identity-capture` | 1a, 1b, 2, 4 | 0 each |
| | 3 — no ambient dependency | 9 |
| | 5 — no verdict, no rendering | 1 |
| `Examples/ReactNativeCaptureHost` | 6 — the host reaches past no public surface | 0 |

The nine are all in the Objective-C++ bridge. `IDCaptureRuntimeProvider.mm` builds a process-global
runtime with `dispatch_once` and fills its clock and presenter slots itself —
`CACurrentMediaTime()`, `[NSDate date]`, `RCTPresentedViewController()` — instead of taking them
from the host; `RCTIdentityCapture.mm` reaches `dispatch_get_main_queue()` five times. The one
verdict is `permitsCapture: boolean` on the `selfieReadiness` event in `src/index.tsx`. Every other
line of the package's TypeScript is at zero on every rule.

**Re-classified 2026-10-08, by owner decision.** Two targets changed role, and the gate's
`--establish --baseline-target` re-established their counters and nothing else. It copies every
other counter as banked, so no improvement or regression elsewhere was banked with them.

| Target | Before | After |
| --- | --- | --- |
| `Packages/IdentityGateway/IdentityGateway`, now a vendor adapter (Pulse) | neutral, banked 1a 8, 1b 56, 2 371, 3 4, 4 3, 5 2 = **444**; measured 526 at re-classification (Rule 2 at 453, 82 over its baseline) | Rule 6: **0** |
| `ThirdParty/NFCPassportReader/NFCPassportReader`, now third-party | neutral but never banked, so the gate failed on six unmeasured counters; it measured 1a 23, 1b 329, 2 0, 3 2, 4 24, 5 22 = **400** | Rule 6: **0** |
| `Examples/ReactNativeCaptureHost`, test files skipped | Rule 6: 0 | Rule 6: **0** (the 12 skipped files score 0) |

These findings were not paid; their counters were retired by a change of role, and this table is
the record. The adapter's 526 remain in its sources, and the owner decision says they belong there.

A fifth module is forced: `KenshikiEvidenceCore` is not dependency-free today, because
`KeychainCustody.swift:3` imports `Security` into it. That is the 2 in the layer row.

The reshaping happens **entirely inside this repository**. pulse-ios references this package
nowhere — verified — so there is no downstream consumer to keep compiling, and no step before the
final wiring commit requires both repositories to change together.
