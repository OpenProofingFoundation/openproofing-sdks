#!/usr/bin/env python3
"""The boundary rules, as checks a script can answer yes or no to.

WHY THESE EXIST. docs/boundary-contract.md decides what this SDK owns and what the host supplies,
because the package will be adopted by organisations that are not Kenshiki. A boundary that lives
only in a document rots: the document is read once, the code drifts, and nobody finds out until an
adopter compiles against a vendor's server format or ships a holder a sentence somebody else wrote.

WHY THIS FILE WAS REWRITTEN ON 2026-09-17, which is the most important thing to know about it.
The first version was written from a READING of the rules. An empirical audit then constructed
violations each rule forbids, ran the gates, and measured what escaped:

    Rule 4  policy numbers        2/20 =  10%   and FORGEABLE to a permanent zero
    Rule 3  ambient dependencies  0/23 =   0%
    Rule 1a prose                 1/21 =   5%   could not see the contract's own worked example
    Rule 5  verdicts              3/20 =  15%   plus false positives on Codable wire fields
    Layer   leaf purity           6/19 =  32%
    Rule 2  vendor identifiers   11/20 =  55%   the only one with real signal

Four of six were theatre: they reported green while the violations they are named after walked
past. That is worse than having no gate, because an absent gate is honest. The forgery was verified
end to end — prepending `// See CalibrationProfile` to each file took Rule 4 from 35 to 0, and
`--write-baseline` banked it as an improvement.

Three structural causes, all fixed here:

  1. EACH CHECK WAS A LIST OF SPELLINGS, not a model of its rule. Rule 1a looked for three
     identifiers; Rule 3 for nine substrings. A rule's subject is a CLASS of construct, and a fixed
     list catches only the members someone happened to think of.
  2. THE SCAN LIST WAS FOUR HARDCODED NAMES. `Sources/` grew to twelve directories and the manifest
     exports ten libraries, so eight exported targets were invisible — and renaming `Sources/` made
     every counter report "improved, bank it". Targets are now DERIVED FROM Package.swift, so one
     cannot be born outside the rules.
  3. COMMENTS AND LITERALS WERE NOT MASKED CONSISTENTLY, so a marker inside a string counted as a
     construction, and a rule explaining itself could trip itself.

WHY A SIXTH RULE WAS ADDED ON 2026-09-17. The package needs a sample and debug-UI app inside the
repository to prove the PUBLIC SURFACE is sufficient — something that fails to compile when the
public API is too thin. But a host application authors holder-facing prose, names its vendor,
carries its own thresholds and decides what passes, so Rules 1, 2, 4 and 5 would report a correct
host as hundreds of violations. Host and example targets are therefore exempt from those four, and
in exchange are bound by Rule 6: the host gets exactly the access an outside adopter gets, and
nothing more. Rule 3 joined that exemption on owner decision later the same day — see HOST_EXEMPT
for what excluding it was costing. The classification is read out of the build graph, never out of
the scanned text; the comment above `_inventory()` argues at length why that is the only shape an
exemption can safely take here.

WHY PROFILE_TARGETS STOPPED BEING A NAME LIST ON 2026-09-17. It read
`{"KenshikiPulseProfile", "ExampleAgencyProfile"}` — two hardcoded strings — and any target named
either one was exempt from all five neutral rules. Minting one cost a single line in Package.swift,
which is CHEAPER than the Rule 4 comment forgery this file was rewritten to defeat, and it sat
directly beside a host rule built so that an exemption could not be claimed by writing anything at
all. It was closed structurally while it was still empty: no profile exists yet. The replacement
is above `_profile_names()`.

WHY THE GATE LEARNED TO READ `project.yml` ON 2026-09-17. Deriving targets from `Package.swift`
was structural fix 2 above, and it was incomplete in one specific way: an iOS APPLICATION cannot be
a SwiftPM target — there is no app product, no Info.plist and no scheme in a manifest — so the only
kind of host a person can hold in their hand, plug a cable into and watch a sensor change had to be
an Xcode project, and was therefore invisible to every rule including Rule 6, the one rule that
governs hosts. A host outside the rules is worse than no host, because it looks like proof and is
not. `project.yml` files are now discovered, their targets' `sources:` directories scanned as hosts,
and the classification is checked rather than assumed — see the long comment above
`XCODEGEN_MANIFEST_NAMES` for why an Xcode application is a host by construction, what is verified,
and the one thing (Xcode's own Debug `ENABLE_TESTABILITY` default) that cannot be verified here.

WHY THE GATE LEARNED TO READ `package.json` ON 2026-10-08. Every rule scanned Swift only, so the
published React Native package (`ReactNative/identity-capture`: TypeScript and Objective-C++) and
its reference app (`Examples/ReactNativeCaptureHost`) sat outside all six. A published npm package
is now neutral by construction and gets TypeScript/Objective-C models of Rules 1-5; the reference
app is a declared React Native host bound by Rule 6, and the declaration is checked as conflicts
rather than trusted. See the block above `NPM_MANIFEST` for both arguments and what is not seen.

WHY TWO MORE ROLES ON 2026-10-08, BY OWNER DECISION. `Packages/IdentityGateway` is a vendor
adapter: speaking one company's wire format is its job, so Rules 1-5 counted the job as debt.
`ThirdParty/NFCPassportReader` is upstream code with local patches: its prose, numbers and
verdicts are upstream's, and it had never been baselined at all. A VENDOR ADAPTER is declared in
`VENDOR_ADAPTERS` with its vendor named, and must be an exported library no neutral target depends
on or imports. THIRD-PARTY code is declared in `THIRD_PARTY_PACKAGES`, must sit under `ThirdParty/`
and carry a complete `provenance.json`, and must import none of this repository's modules. Both are
exempt from Rules 1-5 and bound by Rule 6; every condition is a fatal conflict. See the block above
`VENDOR_ADAPTERS`.

WHY A REACT NATIVE HOST GOT A UI CHECK ON 2026-10-09, BY OWNER DECISION (RN architecture plan 6a).
The reference app's look and words moved out of TypeScript into `ui/tokens.jsonc` and
`locales/<language>.jsonc`, compiled into typed modules by the app's own generator. `no_inline_ui`
keeps them there: a color literal, a color built in place, a type or spacing number, or a sentence in
any other script of a React Native host is a finding against that host's own baseline. The generated
modules are exempt by declaration in `RN_HOST_UI_RESOURCES`, and only while their generator's
`--check` passes. JSON a host script imports is declared the same way, since no check reads its words.
See the block above `RN_HOST_UI_RESOURCES`.

BASELINES ARE PER RULE PER TARGET. A new target adds new keys and can never raise an existing
ceiling — which stops "we added a module" becoming the excuse that launders debt. A baseline is
banked after an improvement, never raised to admit one; `--write-baseline` refuses to raise.
`--establish` exists only for when a CHECK's definition changes, and says so loudly when used.

Usage:
    python3 Gates/boundary_gates.py                  # every check, against the baselines
    python3 Gates/boundary_gates.py --report         # what each rule finds; never fails
    python3 Gates/boundary_gates.py --write-baseline # bank an improvement, never a regression
    python3 Gates/boundary_gates.py --establish      # re-establish; only when a CHECK changed
    python3 Gates/boundary_gates.py --establish --baseline-target KEY
                                                     # re-establish only the targets whose CHECK
                                                     # changed; every other counter is untouched
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import json
import re
import shutil
from pathlib import Path

SWIFT_MANIFEST_NAME = 'Package.swift'
XCODEGEN_PROJECT_NAME = 'project.yml'
NPM_MANIFEST_NAME = 'package.json'
REFERENCE_HOST_PATH = 'Examples/ReactNativeCaptureHost'
ARTIFACT_TEST_NAME = 'ArtifactIntegrationTests.swift'
GENERATED_TOKEN_PATH = 'ui/tokens.generated.ts'
NEW_TARGET_AMBIENT_KEY = 'no_ambient::CaptureNew'
PROBE_IMPORT = 'import CaptureProbe\n'
PROBE_TESTABLE_IMPORT = '@testable import CaptureProbe\n'
PROBE_SPI_IMPORT = '@_spi(Internal) import CaptureProbe\n'
PROBE_MIRROR_SOURCE = 'import CaptureProbe\nlet fields = Mirror(reflecting: probe)\n'
PROFILE_AMBIENT_KEY = 'no_ambient::ExampleAgencyProfile'
APP_SOURCE_PATH = 'AppSources/App.swift'
EXTRA_SOURCE_PATH = 'Extra/More.swift'
NEUTRAL_OVERLAP_MESSAGE = 'overlaps neutral target'
UNGOVERNED_TYPESCRIPT_MESSAGE = 'TypeScript outside every rule'
PROBE_HOST_PATH = 'Examples/ProbeHost'
APP_DELEGATE_NAME = 'AppDelegate.swift'
HOST_CONFIG_SCRIPT_NAME = 'configure-host.rb'
GOVERNED_MESSAGE = 'governs it'
GENERATOR_SCRIPT_NAME = 'generate.py'
PROBE_UPSTREAM_PATH = 'ThirdParty/ProbeUpstream'

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
MANIFEST = ROOT / SWIFT_MANIFEST_NAME
BASELINE_PATH = ROOT / "Gates" / "baselines.json"

TARGET_DECL = re.compile(r'\.(?:target|executableTarget)\s*\(\s*name:\s*"([^"]+)"')
ANY_TARGET_DECL = re.compile(
    r'\.(?:target|executableTarget|testTarget|binaryTarget|systemLibrary|plugin|macro)'
    r'\s*\(\s*name:\s*"([^"]+)"')
TEST_TARGET_DECL = re.compile(r'\.testTarget\s*\(\s*name:\s*"([^"]+)"')
EXECUTABLE_DECL = re.compile(r'\.executableTarget\s*\(\s*name:\s*"([^"]+)"')
LIBRARY_PRODUCT = re.compile(r'\.library\s*\(\s*name:\s*"[^"]*"\s*,\s*targets:\s*\[([^\]]*)\]')
LIBRARY_PRODUCT_NAME = re.compile(r'\.library\s*\(\s*name:\s*"([^"]+)"')
DEPENDENCIES_RE = re.compile(r"\bdependencies\s*:\s*\[([^\]]*)\]")
QUOTED = re.compile(r'"([^"]*)"')
# Swift 6 access-qualified imports name the same dependency as an unqualified import.
# Share this parser between vendor, leaf-direction and host-classification checks so adding
# `internal` neither invents a vendor finding nor hides a forbidden module dependency.
IMPORT_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|package|internal|fileprivate|private)\s+)?"
    r"import\s+(?:\w+\s+)?(\w+)"
)


# Installed or generated trees no manifest of this repository owns. `node_modules` joined the list on
# 2026-10-09: the root quality tooling (see `RN_TOOLING_MANIFESTS`) installs React Native packages,
# and some ship a `Package.swift` of their own. An npm install tree is a dependency checkout, the
# same thing `checkouts` is for SwiftPM; it is not repository source and was never committed.
GENERATED_TREES = {".build", "checkouts", ".git", "DerivedData", "node_modules"}


def _manifests() -> list[Path]:
    """All package manifests, pruning generated checkout/build trees before traversal."""
    found: list[Path] = []
    for directory, children, files in os.walk(ROOT):
        children[:] = sorted(name for name in children if name not in GENERATED_TREES)
        if SWIFT_MANIFEST_NAME in files:
            found.append(Path(directory) / SWIFT_MANIFEST_NAME)
    return sorted(found)


# =================================================================================================
# XCODEGEN HOSTS. WHY THE GATE HAD TO LEARN TO SEE THEM, AND WHY THEY CANNOT BE FORGED.
#
# THE HOLE THIS CLOSES. Every target this file scanned was derived from a `Package.swift`, because
# cause 2 of the rewrite above was a hardcoded scan list and deriving from the manifest was the fix.
# But an iOS APPLICATION cannot be a SwiftPM target at all: SwiftPM has no app product, no
# Info.plist, no scheme, and `swift build` cannot produce a `.app`. So a real device host — the only
# kind you can hold in your hand, plug a cable into and watch a sensor change — has to be an Xcode
# project, and `Examples/CaptureTestHost` already was one. Deriving targets from `Package.swift`
# therefore did not make targets impossible to be born outside the rules; it made exactly one KIND
# of target invisible, and it is the kind Rule 6 exists for. A host outside the rules is worse than
# no host, because it looks like proof and is not.
#
# WHY AN XCODEGEN APP IS STRUCTURALLY A HOST. The host exemption is paid for by one property:
# NOTHING CAN IMPORT IT. For an SPM executable that is three conditions checked against the
# manifest (no `.library` exports it, no non-test target depends on it, no neutral target imports
# it). For an Xcode application it is not a condition at all — it is the shape of the build system:
#
#   * `Package.swift` can name two kinds of dependency, and neither can reach here. A package
#     dependency (`.package(path:)`, `.package(url:)`) names another SWIFTPM PACKAGE, which is a
#     directory containing a `Package.swift`; an `.xcodeproj` is not one and resolution fails on it.
#     A target dependency names a target in the same manifest or `.product(name:package:)` of a
#     resolved package. There is no spelling for "a target in an Xcode project".
#
#     VERIFIED, not reasoned about. A probe manifest with `.package(path: "SensorHost.xcodeproj")`
#     and `swift build` answers: *the package manifest at '…/SensorHost.xcodeproj/Package.swift'
#     cannot be accessed … doesn't exist in file system*. SwiftPM resolves a path dependency by
#     demanding a `Package.swift` inside it, and an `.xcodeproj` has none. Putting one there would
#     make the directory a package as well as a project, which `_xcodegen_conflicts()` refuses.
#   * The arrow only runs the other way: an Xcode project consumes a package through
#     `packages:` + `product:`, which is the door an outside adopter walks through.
#
# So "nothing can import it" holds by construction rather than by permission, and the forgery that
# worries the SPM side — mint a host cheaply, collect the exemption — has nothing to buy. Writing a
# `project.yml` beside a module does not exempt that module: the module keeps its own neutral
# counters from `Package.swift`, and pointing `sources:` at it raises a classification conflict.
#
# CHECKED, NOT ASSUMED. The argument above is about a build system, so this file does not take it on
# faith. `_xcodegen_conflicts()` verifies the observable shadows of the claim — no manifest declares
# a target of this name, no `.library` product exports it, no directory is both a package and an
# Xcode project, and the source roots are disjoint from every neutral target's — and the generic
# host checks in `classification_conflicts()` verify that no neutral target imports the module.
#
# THE DEPENDENCY LIST IS THE MANIFEST HALF OF RULE 6 HERE. `_project_surface_escapes()` is to a
# `project.yml` what `_manifest_surface_escapes()` is to `Package.swift`: a `product:` that no
# `.library` declares is a module no adopter could have depended on, and `ENABLE_TESTABILITY` or
# `-enable-testing` in the project settings makes `@testable` compile. Neither appears anywhere in
# the Swift files, so if this does not look, nothing does.
#
# THE ONE THING THIS CANNOT CHECK, stated rather than hidden. Xcode's own Debug configuration sets
# `ENABLE_TESTABILITY = YES` by default, in the generated `.pbxproj`, without anyone writing it in
# `project.yml`. Reading the `.pbxproj` instead would mean reading a generated file that is
# gitignored and absent on a clean checkout. So for an XcodeGen host the SOURCE half of Rule 6 —
# `@testable` in a scanned file — is the binding check, and the settings check below catches only
# the deliberate spelling. The mutation probe in the self test is against the source half for that
# reason.

XCODEGEN_MANIFEST_NAMES = (XCODEGEN_PROJECT_NAME, "project.yaml")
# `type:` values that make a target a HOST: something an adopter's app is shaped like.
XCODEGEN_HOST_TYPES = ("application",)
# Distributable frameworks get every neutral check, regardless of their build system.
XCODEGEN_NEUTRAL_TYPES = ("framework",)
# `type:` values that make a target a TEST BUNDLE, excluded from the scan.
#
# THIS IS PARITY WITH `Package.swift`, NOT AN EXEMPTION INVENTED HERE. `_target_declarations()`
# matches `.target` and `.executableTarget` only, so no `.testTarget` in this repository has ever
# been scanned by any rule — an XCTest suite is expected to use `@testable`, that is what a test
# target IS, and `classification_conflicts()` already says so out loud by tolerating a test target
# that depends on a host. Treating an XcodeGen test bundle differently from a SwiftPM test target
# would mean the same file was governed or not depending on which build system compiled it.
#
# IT COSTS SOMETHING AND THE COST IS PRINTED. `--report` lists every excluded test bundle WITH the
# Rule 6 count it would have scored, so an excluded target is still a seen target. Read that list:
# `Examples/CaptureTestHost`'s test bundle compiles this package's own `Tests/` directories, so the
# number there is the SDK's own suites using `@testable` exactly as they are meant to.
XCODEGEN_TEST_TYPES = ("bundle.unit-test", "bundle.ui-testing")


class YamlSubsetError(Exception):
    """A `project.yml` this file cannot read with certainty.

    RAISED, NOT SWALLOWED, ON PURPOSE. The whole point of discovering these manifests is that a
    target must not be able to exist outside the rules. A parser that returned `{}` for anything it
    did not understand would turn every unsupported YAML construct into a silent exemption — the
    same failure shape as the Rule 4 comment forgery, reached by accident instead of on purpose.
    Failing the gate is loud, and the fix (teach the parser, or simplify the manifest) is a diff
    someone reviews.
    """


def _yaml_lines(text: str) -> list[tuple[int, str, int]]:
    """(indent, content, line number) for every significant line."""
    out: list[tuple[int, str, int]] = []
    for number, raw in enumerate(text.split("\n"), start=1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        if "\t" in raw[:indent]:
            raise YamlSubsetError(f"line {number}: tab indentation")
        out.append((indent, raw.strip(), number))
    return out


def _yaml_scalar(text: str, number: int):
    text = text.strip()
    if text.startswith("["):
        if not text.endswith("]"):
            raise YamlSubsetError(f"line {number}: unterminated flow sequence")
        inner = text[1:-1].strip()
        return [] if not inner else [_yaml_scalar(part, number) for part in inner.split(",")]
    if text and text[0] in "{&*!|>":
        raise YamlSubsetError(f"line {number}: unsupported YAML construct {text[0]!r}")
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    cut = text.find(" #")
    return text[:cut].rstrip() if cut != -1 else text


def _yaml_block(lines: list[tuple[int, str, int]], cursor: int, indent: int):
    if cursor >= len(lines) or lines[cursor][0] < indent:
        return None, cursor
    if lines[cursor][1] == "-" or lines[cursor][1].startswith("- "):
        return _yaml_sequence(lines, cursor, indent)
    return _yaml_mapping(lines, cursor, indent)


def _yaml_mapping(lines: list[tuple[int, str, int]], cursor: int, indent: int):
    result: dict = {}
    while cursor < len(lines):
        level, text, number = lines[cursor]
        if level < indent:
            break
        if level > indent:
            raise YamlSubsetError(f'line {number}: unexpected indentation')
        if text.startswith('- '):
            break
        key, separator, tail = text.partition(':')
        if not separator:
            raise YamlSubsetError(f'line {number}: not a mapping entry: {text!r}')
        value, cursor = _yaml_mapping_value(lines, cursor + 1, indent, tail, number)
        result[key.strip()] = value
    return result, cursor


def _yaml_sequence(lines: list[tuple[int, str, int]], cursor: int, indent: int):
    result: list = []
    while cursor < len(lines):
        level, text, _ = lines[cursor]
        if level != indent or not (text == '-' or text.startswith('- ')):
            break
        value, cursor = _yaml_sequence_entry(lines, cursor, indent)
        result.append(value)
    return result, cursor


def _yaml_subset(text: str) -> dict:
    lines = _yaml_lines(text)
    if not lines:
        return {}
    document, cursor = _yaml_block(lines, 0, lines[0][0])
    if cursor != len(lines):
        raise YamlSubsetError(f"line {lines[cursor][2]}: trailing content the parser cannot place")
    return document if isinstance(document, dict) else {}


def _xcodegen_manifests() -> list[Path]:
    """Every `project.yml`, pruning generated checkout/build trees before traversal."""
    found: list[Path] = []
    for directory, children, files in os.walk(ROOT):
        children[:] = sorted(name for name in children
                             if name not in GENERATED_TREES and not name.endswith(".xcodeproj"))
        for name in XCODEGEN_MANIFEST_NAMES:
            if name in files:
                found.append(Path(directory) / name)
    return sorted(found)


def _xcodegen_source_paths(body: dict) -> list:
    """The `sources:` entries of one target, as written.

    XcodeGen's own default when `sources:` is absent is a directory named after the target, so that
    is what is returned then — a target must not fall out of the scan by omitting a key.
    """
    sources = body.get("sources")
    if sources is None:
        return [body.get("__name__", "")]
    return sources if isinstance(sources, list) else [sources]


def _xcodegen_records() -> list[dict]:
    """One record per XcodeGen target: its key, role, source directories and declaring manifest."""
    records: list[dict] = []
    for manifest in _xcodegen_manifests():
        project_root = manifest.parent
        label = project_root.relative_to(ROOT).as_posix() if project_root != ROOT else ""
        document = _yaml_subset(manifest.read_text(encoding="utf-8"))
        if "include" in document:
            # XcodeGen's `include:` splits a project across files, so targets may be declared
            # somewhere this parser never looked — and a target nobody looks at is the hole this
            # discovery exists to close. Refused loudly rather than half-read.
            raise YamlSubsetError(
                f"{rel(manifest)}: `include:` may declare targets in another file; inline them or "
                "teach _xcodegen_records() to follow the include")
        targets = document.get("targets") or {}
        if not isinstance(targets, dict):
            raise YamlSubsetError(f"{rel(manifest)}: `targets:` is not a mapping")
        for name, body in targets.items():
            _append_xcodegen_target(name, body, manifest, project_root, label, document, records)
    return records


def _declarations(text: str, pattern: re.Pattern) -> list[tuple[str, str]]:
    """(name, declaration body) for each LITERAL target declaration the pattern matches.

    Comments are blanked before the parenthesis walk, so a commented-out declaration is not a
    target and a `)` inside a comment cannot close one early.
    """
    result: list[tuple[str, str]] = []
    literals_kept = mask(text, keep_literals=True)
    code = mask(text)
    for match in pattern.finditer(literals_kept):
        start = code.index("(", match.start())
        depth = 1
        end = start + 1
        while end < len(code) and depth:
            depth += (code[end] == "(") - (code[end] == ")")
            end += 1
        result.append((match.group(1), literals_kept[start:end]))
    return result


def _target_declarations(text: str) -> list[tuple[str, str | None]]:
    """Read literal target names/custom paths without counting comments or nested parentheses."""
    result: list[tuple[str, str | None]] = []
    for name, body in _declarations(text, TARGET_DECL):
        custom = re.search(r'\bpath\s*:\s*"([^"\n]*)"', body)
        result.append((name, custom.group(1) if custom else None))
    return result


def _root_manifest_text() -> str:
    return MANIFEST.read_text(encoding="utf-8") if MANIFEST.exists() else ""


def _exported_targets(text: str) -> set[str]:
    """Targets a `.library` product exports — the only modules an outside adopter can import."""
    out: set[str] = set()
    for match in LIBRARY_PRODUCT.finditer(mask(text, keep_literals=True)):
        out.update(QUOTED.findall(match.group(1)))
    return out


def _declared_dependencies(body: str) -> set[str]:
    named: set[str] = set()
    for match in DEPENDENCIES_RE.finditer(body):
        named.update(QUOTED.findall(match.group(1)))
    return named


def _dependency_edges(text: str) -> list[tuple[str, bool, set[str]]]:
    """(target, is a test target, the names it lists as dependencies) for every declaration kind."""
    tests = {name for name, _ in _declarations(text, TEST_TARGET_DECL)}
    return [(name, name in tests, _declared_dependencies(body))
            for name, body in _declarations(text, ANY_TARGET_DECL)]


# HOW A TARGET BECOMES A PROFILE, AND WHY THAT CANNOT BE FORGED.
#
# A profile is WHERE one adopter's vendor facts are supposed to live — its names, numbers, copy and
# wire format — so scanning one against the five neutral rules would report the design itself as a
# violation. `docs/boundary-contract.md`, "How the boundary gets exercised", is why profiles are to
# exist at all: a boundary with one caller, always passing the same arguments, is not a boundary.
#
# UNTIL 2026-09-17 THIS WAS TWO HARDCODED NAMES. `PROFILE_TARGETS = {"KenshikiPulseProfile",
# "ExampleAgencyProfile"}` exempted any target called either one from all five rules. That is a
# one-line diff in Package.swift — a cheaper forgery than the comment that took Rule 4 from 35 to
# 0 — sitting beside a host rule built precisely so that no claim a target makes about itself can
# exempt it. It is closed here while it is still empty; neither profile has been written yet.
#
# The replacement rests on the same property as the host rule: NOTHING NEUTRAL CAN IMPORT IT.
#
#   1. declared by the ROOT manifest (a vendored subpackage cannot mint a profile),
#   2. exported by no `.library` product, and
#   3. depended on by no NEUTRAL target.
#
# Condition 3 is "no neutral target", deliberately NOT the host rule's "no non-test target": a host
# application is expected to apply a profile, and one profile may rest on another, while a neutral
# SDK module reaching into a profile is the leak the whole contract exists to stop. It is resolved
# to a FIXED POINT, so a candidate demoted for being reachable from neutral code also demotes
# whatever only that candidate was holding up.
#
# WHY EVERY MODULE IN THIS PACKAGE IS PROTECTED BY IT: all twelve are exported by a `.library`
# product, so all twelve fail condition 2. To make `KenshikiIdentity` a profile you must delete its
# library product AND strike it from `KenshikiSensors`' dependencies — after which no adopter and
# no sibling module can reach it. Same shape as the host rule: the forgery is not cheap, it is
# fatal, because it costs the target the only property that made exempting it worth anything.
#
# A RULE THAT WAS PROPOSED AND MEASURED FALSE, recorded so it is not proposed again: "a library
# target that no other target in this package depends on". Run against this manifest it makes
# CaptureSelfiePreview, IdentityEvidencePreview, KenshikiCapture and KenshikiSensors into profiles
# — four shipped SDK modules, exempted from all five rules, because their only dependents are test
# targets. Requiring "no target at all, tests included" still makes a profile of
# CaptureSelfiePreview, which nothing depends on and a `.library` product exports.
#
# A host satisfies all three conditions as well, so `_inventory()` checks HOST FIRST. The host role
# carries strictly more obligation — `classification_conflicts()`, and the manifest half of Rule 6
# — and an executable must not be able to shed either by also looking like a profile.


def _profile_names(root_text: str, hosts: set[str]) -> set[str]:
    """Root-declared targets no `.library` exports and no neutral target reaches."""
    exported = _exported_targets(root_text)
    if not exported:
        # A manifest that exports NOTHING distinguishes nothing, and "unexported" would then be
        # true of every target at once — deleting the whole `products:` array would reclassify the
        # entire package as vendor profiles and take its debt with it. That is the one edit cheap
        # enough to be worth guarding against separately, so the degenerate case reads as "no
        # profiles" rather than "all of them". Stripping products ONE AT A TIME still works, and
        # still costs each module the ability to be imported by anyone; that cost is the rule.
        return set()
    declared = {name for name, _ in _target_declarations(root_text)}
    candidates = {name for name in declared if name not in hosts and name not in exported}
    edges = [(name, named) for name, is_test, named in _dependency_edges(root_text) if not is_test]
    while candidates:
        reached: set[str] = set()
        for name, named in edges:
            if name in hosts or name in candidates:
                continue  # a host applies a profile, and a profile may rest on another
            reached |= named
        demoted = candidates & reached
        if not demoted:
            break
        candidates -= demoted
    return candidates


# HOW A TARGET BECOMES A HOST, AND WHY THAT CANNOT BE FORGED.
#
# A host or example target — a sample app, a debug UI — is EXEMPT from all five neutral rules,
# because authoring holder-facing copy, naming its vendor, carrying its own thresholds, deciding
# what passes and naming its own bundle, defaults and clock is precisely a host's job. Reporting
# those as debt would bury the counters that matter. (Rule 3 was the last to be exempted, by owner
# decision on 2026-09-17; HOST_EXEMPT carries the argument and what excluding it had cost.)
#
# An exemption needs a gate of its own, and the gate cannot be a claim the exempted code makes
# about itself. Rule 4 already proved that: its exemption was `"CalibrationProfile" in text`, one
# comment line took the counter from 35 to 0, and `--write-baseline` banked it as an improvement.
# A marker comment, a filename convention, an `Examples/` directory and a `*Sample*` name prefix
# are all the same mechanism — free to write, so worth nothing.
#
# So classification is a fact about the BUILD GRAPH, read out of the root `Package.swift`:
#
#   1. declared by the ROOT manifest (a vendored subpackage cannot mint a host),
#   2. declared as `.executableTarget`,
#   3. exported by no `.library` product,
#   4. depended on by no non-test target,
#   5. its source root disjoint from every neutral target's source root,
#   6. named by no `import` in any neutral target.
#
# Conditions 3, 4 and 6 all say one thing: NOTHING CAN IMPORT IT. That is what makes the exemption
# unforgeable. To exempt `KenshikiIdentity` you must delete its `.library` product and strike it
# from `KenshikiSensors`' dependencies — at which point no adopter and no sibling module can reach
# it and `KenshikiSensors` stops compiling. The exemption is not cheap to forge; it is fatal to
# forge, because it costs the target the only property that made exempting it worth anything.
#
# Conditions 3, 4 and 5 are checked as CONFLICTS, not counters. There is no baseline for being
# both a host and part of the SDK surface: a target is one or the other.


def _inventory() -> list[tuple[str, Path, str]]:
    """(key, source directory, role) for every literal target declaration in every manifest.

    Keys carry the full relative package path, so two subpackages may declare the same target name
    without colliding. Role is "neutral" (the full rule set), "host", "profile", "vendor-adapter" or
    "third-party". Every role but neutral carries the same SCAN today — Rule 6 only — but they are
    not the same role: each has its own fatal conflicts, and only an executable can be a host.

    XCODEGEN APPLICATIONS APPEAR HERE TOO, as hosts, with one entry per `sources:` directory — a
    target with two source directories must not be able to hide a file in the second. See the
    comment block above `XCODEGEN_MANIFEST_NAMES` for why an Xcode application is structurally a
    host and what is checked rather than assumed.
    """
    root_text = _root_manifest_text()
    hosts = {name for name, _ in _declarations(root_text, EXECUTABLE_DECL)}
    profiles = _profile_names(root_text, hosts)
    third_party = _third_party_roots()
    out: list[tuple[str, Path, str]] = []
    for manifest in _manifests():
        package_root = manifest.parent
        is_root = manifest == MANIFEST
        label = "" if is_root else package_root.relative_to(ROOT).as_posix() + "/"
        text = root_text if is_root else manifest.read_text(encoding="utf-8")
        for name, custom_path in _target_declarations(text):
            _append_manifest_target(name, custom_path, package_root, is_root, label, hosts, profiles, third_party, out)
    for record in _xcodegen_records():
        _append_inventory_record(record, out)
    # React Native: published npm packages are neutral, declared reference apps are hosts. See the
    # block above `NPM_MANIFEST`; `_react_native_conflicts()` checks both before either is trusted.
    for record in _npm_records() + _rn_host_records():
        _append_inventory_record(record, out)
    return sorted(set(out))


def target_roots() -> list[tuple[str, Path]]:
    """Manifest-owned source directories subject to the NEUTRAL rule set."""
    return [(key, directory) for key, directory, role in _inventory() if role == "neutral"]


def host_roots() -> list[tuple[str, Path]]:
    return [(key, directory) for key, directory, role in _inventory() if role == "host"]


def _unique(keys: list[str]) -> list[str]:
    """Keys in order, once each. A target with several source directories has several inventory
    rows and exactly one counter; duplicating it would double-count nothing and print it twice."""
    return list(dict.fromkeys(keys))


def neutral_targets() -> list[str]:
    return _unique([key for key, _ in target_roots()])


def host_targets() -> list[str]:
    return _unique([key for key, _ in host_roots()])


def profile_targets() -> list[str]:
    return _unique([key for key, _, role in _inventory() if role == "profile"])


def _directories_for(key: str) -> list[Path]:
    """EVERY source directory the key owns. This returned the FIRST match until XcodeGen targets
    arrived; a target whose `sources:` names two directories would then have had its second
    directory scanned by nothing at all."""
    return [directory for name, directory, _ in _inventory() if name == key]


def classification_conflicts() -> list[str]:
    """A target claiming the host exemption while still being part of the SDK surface.

    Unbaselined and fatal on purpose. A counter says "this is debt, shrink it"; this says "the
    manifest is lying about what this target is", and there is no honest number for that.
    """
    root_text = _root_manifest_text()
    hosts = {name for name, _ in _declarations(root_text, EXECUTABLE_DECL)}
    if not hosts:
        # The React Native, vendor-adapter and third-party checks do not depend on a SwiftPM host
        # existing, so they run either way.
        return sorted(set(_react_native_conflicts() + _vendor_adapter_conflicts()
                          + _third_party_conflicts()))
    conflicts: list[str] = []
    exported = _exported_targets(root_text)
    for name in sorted(hosts):
        _append_host_dependency_conflicts(name, exported, root_text, conflicts)
    neutral = target_roots()
    for key, directory in host_roots():
        _append_host_overlap_conflicts(key, directory, neutral, conflicts)
    host_modules = {key.rsplit("/", 1)[-1] for key, _ in host_roots()}
    if host_modules:
        for neutral_key, _ in neutral:
            _append_host_import_conflicts(neutral_key, host_modules, conflicts)
    return sorted(set(conflicts + _xcodegen_conflicts() + _react_native_conflicts()
                      + _vendor_adapter_conflicts() + _third_party_conflicts()))


def _xcodegen_conflicts() -> list[str]:
    """THE ARGUMENT FOR AN XCODEGEN HOST, CHECKED INSTEAD OF ASSUMED.

    The claim is that nothing in any `Package.swift` can depend on a target inside an `.xcodeproj`,
    so such a target satisfies "nothing can import it" by construction. That is a statement about
    SwiftPM's dependency vocabulary, and a statement is not evidence, so what is verified here is
    its observable shadows. If the claim were false — if some spelling did let a manifest reach an
    Xcode target — it would have to show up as one of these, and each is fatal rather than
    baselined for the same reason the SPM host conflicts are: there is no honest number for a
    manifest that is lying about what a target is.

    The remaining two shadows are checked by the generic loops in `classification_conflicts()`,
    which already walk `host_roots()`: source roots overlapping a neutral target, and a neutral
    target naming the host module in an `import`.
    """
    conflicts: list[str] = []
    declared: set[str] = set()
    exported_anywhere: set[str] = set()
    for manifest in _manifests():
        text = manifest.read_text(encoding="utf-8")
        declared |= {name for name, _ in _declarations(text, ANY_TARGET_DECL)}
        exported_anywhere |= _exported_targets(text)
    for record in _xcodegen_records():
        _append_xcodegen_conflicts(record, declared, exported_anywhere, conflicts)
    return conflicts


# =================================================================================================
# VENDOR ADAPTERS AND THIRD-PARTY CODE. TWO ROLES ADDED BY OWNER DECISION, 2026-10-08.
#
# Both were neutral until then, and the five neutral rules described something neither one is.
# `Packages/IdentityGateway` is the Pulse vendor adapter — its README says so, and its job is to
# speak one company's wire format, which is precisely what Rule 2 forbids a NEUTRAL target to do.
# `ThirdParty/NFCPassportReader` is AndyQ's NFCPassportReader 2.3.1 with local patches: its prose,
# numbers and verdicts are upstream's, nothing in this repository can pay them down short of
# forking it further, and it had never been baselined at all.
#
# VENDOR ADAPTER: exempt from Rules 1-5, bound by Rule 6 (source half and manifest half). The role
# is DECLARED below, with the vendor named, and never inferred from a README, a directory or a
# comment — a claim code makes about itself is the forgery this file was rewritten to stop. The
# declaration is then CHECKED against the build graph by `_vendor_adapter_conflicts()`, fatally:
#
#   1. a manifest declares the target as a `.target`, and a `.library` product of that manifest
#      exports it — an adapter is an optional library an adopter adds, never an executable;
#   2. no neutral target depends on it: not by target name or `.product(name:package:)` in any
#      `Package.swift`, and not through a `packages:` dependency of a neutral `project.yml` target;
#   3. no neutral Swift source imports it.
#
# Conditions 2 and 3 are the price of the exemption, the same price the host rule charges: the
# neutral SDK cannot reach it. Declaring a neutral module an adapter therefore buys a conflict the
# moment any sibling uses it; an adapter that stays out of the neutral graph is genuinely optional.
#
# THIRD-PARTY: vendored upstream code under `ThirdParty/`. Exempt from Rules 1-5 ONLY while its
# package carries a complete `provenance.json` — upstream name, version, https URL, licence and
# licence file, and the list of local patches, each naming the files it touches (which must exist)
# and saying what it changes — and bound by Rule 6. It is DECLARED too, in `THIRD_PARTY_PACKAGES`,
# so that a missing or incomplete provenance file is a fatal conflict rather than a quiet return
# to neutral; while the conflict stands the package is scanned as neutral. An undeclared package
# under `ThirdParty/` stays neutral and gets all five rules: `ThirdParty/FaceMatching` is
# Kenshiki's own fork from the capture stack, not upstream code. `_third_party_conflicts()` also
# checks the one structural shadow of "written upstream" a script can see: no source in the package
# imports a module this repository declares. Upstream cannot depend on our modules, so moving SDK
# code into a vendored directory buys a conflict, not an exemption.
#
# LOCAL PATCHES STAY REVIEWED. The provenance list is what a reviewer reads, Rule 6's source checks
# run over the whole package, and the import check above runs over every file, patched or not.

# The ONE place a vendor adapter is declared: scan key -> the vendor it speaks for.
VENDOR_ADAPTERS = {"Packages/IdentityGateway/IdentityGateway": "Pulse"}
# The ONE place third-party packages are declared, by package directory.
THIRD_PARTY_ROOT = "ThirdParty"
THIRD_PARTY_PACKAGES = ("ThirdParty/NFCPassportReader",)
THIRD_PARTY_PROVENANCE = "provenance.json"
PROVENANCE_FIELDS = ("name", "version", "url", "licence", "licenceFile")
PACKAGE_PATH_DEPENDENCY = re.compile(
    r'\.package\s*\(\s*(?:name\s*:\s*"([^"]+)"\s*,\s*)?path\s*:\s*"([^"]+)"')
PRODUCT_DEPENDENCY = re.compile(r'\.product\s*\(\s*name\s*:\s*"([^"]+)"\s*,\s*package\s*:\s*"([^"]+)"')


def _provenance_problems(package_root: Path) -> list[str]:
    """Why a third-party package's provenance is not complete; empty when it is."""
    path = package_root / THIRD_PARTY_PROVENANCE
    where = rel(path)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return [f"{where}: missing or unreadable ({error.__class__.__name__})"]
    if not isinstance(document, dict) or not isinstance(document.get("upstream"), dict):
        return [f"{where}: no `upstream` object"]
    upstream = document["upstream"]
    problems: list[str] = []
    for field in PROVENANCE_FIELDS:
        if not (isinstance(upstream.get(field), str) and upstream[field].strip()):
            problems.append(f"{where}: upstream.{field} is missing or empty")
    if isinstance(upstream.get("url"), str) and not upstream["url"].startswith("https://"):
        problems.append(f"{where}: upstream.url is not an https URL")
    licence = upstream.get("licenceFile")
    if isinstance(licence, str) and licence.strip() and not (package_root / licence).is_file():
        problems.append(f"{where}: upstream.licenceFile {licence} does not exist")
    patches = document.get("patches")
    if not isinstance(patches, list):
        problems.append(f"{where}: `patches` is not a list (an unpatched copy says [])")
        return problems
    for index, patch in enumerate(patches):
        _append_patch_problems(index, patch, where, package_root, problems)
    return problems


def _third_party_location_problems(written: str) -> list[str]:
    parts = Path(written).parts
    if len(parts) != 2 or parts[0] != THIRD_PARTY_ROOT:
        return [f"{written}: declared in THIRD_PARTY_PACKAGES but not a directory directly under "
                f"{THIRD_PARTY_ROOT}/"]
    if not (ROOT / written / SWIFT_MANIFEST_NAME).is_file():
        return [f"{written}: declared in THIRD_PARTY_PACKAGES but holds no Package.swift"]
    return []


def _third_party_roots() -> set[Path]:
    """Declared third-party package roots whose location and provenance are both in order."""
    return {ROOT / written for written in THIRD_PARTY_PACKAGES
            if not _third_party_location_problems(written)
            and not _provenance_problems(ROOT / written)}


def _local_packages(manifest: Path, text: str) -> dict[str, Path]:
    """Package identity -> directory, for every `.package(path:)` a manifest declares."""
    found: dict[str, Path] = {}
    for match in PACKAGE_PATH_DEPENDENCY.finditer(mask(text, keep_literals=True)):
        directory = Path(os.path.normpath(manifest.parent / match.group(2)))
        found[match.group(1) or directory.name] = directory
    return found


def _vendor_adapter_conflicts() -> list[str]:
    """THE VENDOR ADAPTER DECLARATION, CHECKED AGAINST THE BUILD GRAPH. Fatal and unbaselined."""
    if not VENDOR_ADAPTERS:
        return []
    conflicts: list[str] = []
    inventory = _inventory()
    roles = {key: role for key, _, role in inventory}
    adapters: dict[str, tuple[str, Path]] = {}
    for key, vendor in sorted(VENDOR_ADAPTERS.items()):
        _append_vendor_declaration_conflicts(key, vendor, roles, adapters, conflicts)
    neutral = {key for key, role in roles.items() if role == "neutral"}
    for manifest in _manifests():
        _append_vendor_manifest_conflicts(manifest, neutral, adapters, conflicts)
    for record in _xcodegen_records():
        _append_vendor_project_conflicts(record, adapters, conflicts)
    modules = {name: key for key, (name, _) in adapters.items()}
    for neutral_key in sorted(neutral):
        _append_vendor_import_conflicts(neutral_key, modules, conflicts)
    return conflicts


def _third_party_conflicts() -> list[str]:
    """THE THIRD-PARTY DECLARATION, CHECKED. Fatal and unbaselined."""
    if not THIRD_PARTY_PACKAGES:
        return []
    conflicts: list[str] = []
    inventory = _inventory()
    ours = {key.rsplit("/", 1)[-1] for key, _, role in inventory if role != "third-party"}
    for written in THIRD_PARTY_PACKAGES:
        located = _third_party_location_problems(written)
        if located:
            conflicts += located
            continue
        package_root = ROOT / written
        conflicts += _provenance_problems(package_root)
        for _, directory, _ in inventory:
            _append_third_party_import_conflicts(directory, package_root, ours, conflicts)
    return conflicts


def _package_manifest_escapes(target: str) -> list[str]:
    """The manifest half of Rule 6 for a vendor adapter or third-party target: what its own
    `Package.swift` widens. The same three things the root-manifest half looks for — unsafe flags,
    testing enabled, and a dependency on something no `.library` product declares."""
    label, _, name = target.rpartition("/")
    manifest = (ROOT / label if label else ROOT) / SWIFT_MANIFEST_NAME
    if not manifest.is_file():
        return []
    text = manifest.read_text(encoding="utf-8")
    where = rel(manifest)
    body = dict(_declarations(text, ANY_TARGET_DECL)).get(name, "")
    hits: list[str] = []
    if "unsafeFlags" in mask(body):
        hits.append(f"{where}:0 {name} declares unsafeFlags — its access is a compiler flag away")
    if "enable-testing" in mask(text, keep_literals=True):
        hits.append(f"{where}:0 the manifest enables testing, so @testable would compile")
    exported = _exported_targets(text)
    declared = {declared_name for declared_name, _ in _declarations(text, ANY_TARGET_DECL)}
    for dependency in sorted((_declared_dependencies(body) & declared) - {name}):
        if dependency not in exported:
            hits.append(f"{where}:0 {name} depends on {dependency}, which no .library product exports")
    packages = _local_packages(manifest, text)
    for product, package in PRODUCT_DEPENDENCY.findall(mask(body, keep_literals=True)):
        consumed = packages.get(package)
        if consumed is None:
            continue  # a remote package is outside this repository's boundary to judge
        other = consumed / SWIFT_MANIFEST_NAME
        if not other.is_file() or product not in _library_product_names(other.read_text(encoding="utf-8")):
            hits.append(f"{where}:0 {name} depends on {product}, which {rel(other)} does not declare "
                        "as a .library product")
    return hits


def _swift_files_in(directories: list[Path]) -> list[Path]:
    found: set[Path] = set()
    for directory in directories:
        if not directory.is_dir():
            continue
        found.update(path for path in directory.rglob("*.swift")
                     if path.name != SWIFT_MANIFEST_NAME
                     and not any(part in GENERATED_TREES
                                 for part in path.relative_to(directory).parts))
    return sorted(found)


def swift_files(target: str) -> list[Path]:
    files = _swift_files_in(_directories_for(target))
    if target in REACT_NATIVE_HOSTS:
        # A React Native host's declared UI tests are a test bundle; see `RN_HOST_UI_TESTS`.
        files = [path for path in files if not _rn_host_test_file(target, path)]
    return files


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def mask(text: str, *, keep_literals: bool = False) -> str:
    """Blank comments and optionally literals, preserving offsets and newlines."""
    output = list(text)
    cursor = 0
    limit = len(text)
    while cursor < limit:
        end, comment = _mask_span(text, cursor, limit)
        if comment is True or (comment is False and not keep_literals):
            _blank_mask_span(output, cursor, end)
        cursor = end
    return ''.join(output)


def literals(text: str) -> list[tuple[int, str]]:
    """Every string literal with its line number, including multi-line ones."""
    found: list[tuple[int, str]] = []
    code = mask(text, keep_literals=True)
    n = len(code)
    i = 0
    while i < n:
        if code.startswith('"""', i):
            j = code.find('"""', i + 3)
            j = n if j == -1 else j
            found.append((code.count("\n", 0, i) + 1, code[i + 3:j]))
            i = j + 3
        elif code[i] == '"':
            j = i + 1
            j = _quoted_literal_end(code, j, n)
            found.append((code.count("\n", 0, i) + 1, code[i + 1:j]))
            i = j + 1
        else:
            i += 1
    return found


# --- Rule 1a: no error-description prose channel. Was 1/21. ------------------------------------
# The three identifiers the contract names are EXAMPLES of the channel, not its definition. The
# gate treating them as the definition is why it could not see "Hold the phone steady against the
# back cover" — the sentence the contract itself cites as the reason the rule exists.

PROSE_CHANNELS = (
    "LocalizedError", "errorDescription", "localizedDescription", "failureReason",
    "recoverySuggestion", "helpAnchor", "CustomStringConvertible", "CustomDebugStringConvertible",
    "CustomNSError", "errorUserInfo", "NSLocalizedDescriptionKey",
    "NSLocalizedFailureReasonErrorKey", "NSLocalizedRecoverySuggestionErrorKey",
    "NSLocalizedString", "String(localized:", "LocalizedStringResource", "LocalizedStringKey",
)
PROSE_SHAPE = re.compile(
    r"\bpublic\s+(?:static\s+)?(?:var|let|func)\s+(\w*(?:message|description|explanation|reason|"
    r"detail|summary|hint|advice|instruction)\w*)\s*(?:\([^)]*\))?\s*(?::|->)\s*String"
)

# A stored protocol field is input data, not an error-description channel. `messageHash` was
# reported as prose even though its entire value is a SHA-256 digest, and a service-supplied
# message body was reported as SDK-authored copy. Recognise only immutable record fields with
# no default and either a synthesized memberwise initializer or direct initializer forwarding.
# This is source structure, not a field/target allowlist. Error/failure records, unknown conformances,
# mutable/computed members and internally constructed defaults remain findings. Rule 1b still
# scans every literal, including literals inside initializers and at record construction sites.
# Keep adjacent lexical runs disjoint: one whitespace span before the colon/brace,
# and one conformance span after the colon. Missing delimiters cannot repartition whitespace.
_RECORD_DECL = re.compile(
    r"\b(struct|class|enum|actor|protocol|extension)\s+(\w+)\s*(?::([^{}]*))?\{")
_DATA_CONFORMANCES = {"Codable", "Encodable", "Decodable", "Sendable", "Equatable", "Hashable"}


def _record_spans(code: str) -> list[tuple[str, str, set[str], int, int]]:
    records = []
    for match in _RECORD_DECL.finditer(code):
        start = match.end()
        depth, end = 1, start
        while end < len(code) and depth:
            depth += (code[end] == "{") - (code[end] == "}")
            end += 1
        if depth == 0:
            inherited = set(re.findall(r"\b\w+\b", match.group(3) or ""))
            records.append((match.group(1), match.group(2), inherited, start, end - 1))
    return records


def _input_string_field(code: str, offset: int, prohibited: set[str]) -> bool:
    declaration = re.match(r"public\s+let\s+(\w+)\s*:\s*String\b", code[offset:])
    if not declaration:
        return False
    field = declaration.group(1)
    following = code[offset + declaration.end():]
    # No initializer, optional/compound type, getter or continued expression. A following
    # declaration/closing brace is the only shape this deliberately small parser accepts.
    if not re.match(r"\s*(?:;|\}|(?:public|private|internal|fileprivate|package|let|var|init|func|"
                    r"struct|enum|static)\b|@)", following):
        return False
    records = [record for record in _record_spans(code) if record[3] <= offset < record[4]]
    if not records:
        return False
    kind, name, inherited, start, end = max(records, key=lambda record: record[3])
    if kind != "struct" or name in prohibited or not inherited.issubset(_DATA_CONFORMANCES):
        return False
    prefix = code[start:offset]
    if prefix.count("{") != prefix.count("}"):
        return False  # local/nested declarations cannot borrow an outer record's classification
    body = code[start:end]
    initializers = list(re.finditer(r"\binit\s*\(([^)]*)\)\s*(?:throws\s*)?\{", body))
    if not initializers:
        # An unrecognised explicit initializer must not masquerade as synthesis.
        return not re.search(r"\binit\b", body)
    assignments = list(re.finditer(r"\bself\s*\.\s*" + re.escape(field) + r"\s*=([^\n;}]+)", body))
    if len(assignments) != len(initializers):
        return False
    for initializer in initializers:
        if not re.search(r"(?:^|,)\s*" + re.escape(field) + r"\s*:\s*String\s*(?:,|$)",
                         initializer.group(1)):
            return False
    return all(assignment.group(1).strip() == field for assignment in assignments)


def check_no_prose(target: str) -> list[str]:
    hits: list[str] = []
    sources = [(path, mask(path.read_text(encoding="utf-8"))) for path in swift_files(target)]
    # Include separate-file extensions: moving `: Error` must not turn its fields into inputs.
    declarations = [record for _, code in sources for record in _record_spans(code)]
    prohibited = {name for _, name, inherited, _, _ in declarations
                  if inherited - _DATA_CONFORMANCES
                  or re.search(r"(?:Error|Failure)(?:$|[A-Z_])", name)}
    while True:
        inherited_prose = {name for _, name, inherited, _, _ in declarations
                           if inherited & prohibited}
        if inherited_prose <= prohibited:
            break
        prohibited |= inherited_prose
    for path, code in sources:
        _append_prose_hits(path, code, prohibited, hits)
    return hits


# --- Rule 1b: no sentence the SDK wrote. Now sees multi-line literals. -------------------------

SENTENCE_MIN_WORDS = 2
SENTENCE_MIN_CHARS = 8


def _is_authored_sentence(text: str) -> bool:
    stripped = text.strip()
    if len(stripped) < SENTENCE_MIN_CHARS:
        return False
    if re.fullmatch(r"[\w.\-:/|%@]+", stripped):
        return False  # an identifier, key or domain separator travels as one token
    if re.match(r"^\s*(?:SELECT|INSERT|UPDATE|DELETE|CREATE|PRAGMA|BEGIN|COMMIT|DROP)\b", text, re.I):
        return False  # SQL is mechanism, not prose
    # PRINTED DOCUMENT FIELD LABELS ARE NOT PROSE. `"GIVEN NAMES"`, `"PASSPORT CARD NO."` and their
    # kin are the text printed on the physical credential, matched against what OCR reads back.
    # They are input data, not words the SDK chose to show anyone — and "translating" them would
    # break passport parsing outright. The discriminator is that a printed field label is fully
    # upper case; authored copy is a sentence.
    if stripped == stripped.upper() and re.fullmatch(r"[A-Z0-9 ,./'’\-]+", stripped):
        return False
    words = [w for w in text.split() if re.fullmatch(r"[A-Za-z][A-Za-z'’,.\-]*", w)]
    return len(words) >= SENTENCE_MIN_WORDS


def check_no_authored_sentence(target: str) -> list[str]:
    hits: list[str] = []
    for path in swift_files(target):
        for number, text in literals(path.read_text(encoding="utf-8")):
            if _is_authored_sentence(text):
                hits.append(f'{rel(path)}:{number} authored: "{text.strip()[:56]}"')
    return hits


# --- Rule 2: no vendor wire format. ------------------------------------------------------------

VENDOR = re.compile(r"kenshiki|pulse|credit\.", re.IGNORECASE)


def _own_modules() -> set[str]:
    """Every target this package tree declares — i.e. the modules an import can legitimately name."""
    return {key.rsplit("/", 1)[-1] for key in neutral_targets()}


def check_no_vendor_identifiers(target: str) -> list[str]:
    """Vendor tokens an ADOPTER would encounter: type names, literals, file names.

    INTRA-PACKAGE MODULE IMPORTS ARE EXEMPT, and that exemption matters more than it looks.
    `import KenshikiEvidenceCore` was 350-odd of this counter's hits on 2026-09-17 — the largest
    single class in the whole gate — and every one of them was noise. An adopter never types a
    module import of ours; it cannot be removed without deleting the module system; and the module
    will be renamed once, in one commit, if the package is ever renamed.

    Leaving them in was the more dangerous failure of the two this gate has had. A gate that
    reports 5% of its rule gets fixed when someone notices. A gate that reports hundreds of hits
    nobody can act on gets IGNORED, and an ignored gate is theatre by a slower route.
    """
    own = _own_modules()
    hits: list[str] = []
    for path in swift_files(target):
        _append_vendor_identifier_hits(path, own, hits)
    return hits


# --- Rule 3: no ambient dependency. Was 0/23; this pattern set measured 23/23 in the audit. -----

_D = r"\s*\.\s*"
AMBIENT_RE = re.compile(
    r"\bBundle" + _D + r"(?:main|module)\b"
    r"|\bBundle\s*\(\s*(?:for|identifier|path|url)\s*:"
    r"|\bUserDefaults" + _D + r"standard\b"
    r"|\bUserDefaults\s*\("
    r"|\bFileManager" + _D + r"default\b"
    r"|\bFileManager\s*\(\s*\)"
    r"|\bNS(?:Temporary|Home)Directory\s*\("
    r"|\bURL" + _D + r"\w*Directory\b"
    # ProcessInfo: the AMBIENT-CONFIGURATION members only. `.environment`, `.arguments` and
    # `.processIdentifier` are the process talking about itself, which a host must supply.
    # `.thermalState`, `.isLowPowerModeEnabled`, `.operatingSystemVersion`, `.systemUptime` and
    # their kin are DEVICE FACTS — reading them is what a device-physics collector is FOR, and
    # flagging them told us a thermometer was reaching for ambient state. Same correction as
    # removing CGImage from the render list: measuring the thing is not the same as depending on it.
    r"|\bProcessInfo" + _D + r"processInfo" + _D + r"(?:environment|arguments|processIdentifier|globallyUniqueString|hostName|userName|fullUserName)\b"
    r"|\bProcessInfo\s*\(\s*\)"
    r"|\bgetenv\s*\("
    r"|\bCommandLine\s*\."
    r"|\b(?:Locale|TimeZone|Calendar)" + _D + r"(?:current|autoupdatingCurrent)\b"
    r"|\bDate\s*\(\s*\)"
    r"|\bDate" + _D + r"now\b"
    r"|\b(?:ContinuousClock|SuspendingClock|UTCClock)\s*\("
    r"|\b(?:DispatchTime|DispatchWallTime)" + _D + r"now\s*\("
    r"|\bCFAbsoluteTimeGetCurrent\s*\("
    r"|\bmach_(?:absolute|continuous)_time\s*\("
    r"|\btimeIntervalSinceNow\b"
    r"|\bURLSession" + _D + r"shared\b"
    r"|\bNotificationCenter" + _D + r"default\b"
    r"|\bDispatchQueue" + _D + r"(?:main|global)\b"
)


# The ONE file allowed to construct ambient dependencies, because constructing them is its whole
# job: it is the adapter that turns host-supplied names into the objects the SDK uses, so that
# every other file can ask it instead of reaching for the process.
#
# EXEMPTED BY PATH, deliberately, and not by a marker in the source. Rule 4's exemption was a
# marker — `"CalibrationProfile" in text` — and one comment line forged that counter from 35 to 0.
# A path list cannot be extended by writing a comment; extending it is a diff someone reviews.
# If this list ever has a second entry, that is the signal that the adapter has been copied rather
# than used.
AMBIENT_ADAPTERS = {"Sources/KenshikiEvidenceCore/HostEnvironment.swift"}


def check_no_ambient(target: str) -> list[str]:
    hits: list[str] = []
    for path in swift_files(target):
        if rel(path) in AMBIENT_ADAPTERS:
            continue
        text = path.read_text(encoding="utf-8")
        masked = mask(text)
        lines = text.split("\n")
        for match in AMBIENT_RE.finditer(masked):
            number = masked.count("\n", 0, match.start()) + 1
            hits.append(f"{rel(path)}:{number} {lines[number - 1].strip()[:80]}")
    return hits


# --- Rule 4: no UNATTRIBUTED policy number. ----------------------------------------------------
#
# Was 2/20 AND forgeable. The exemption read `ATTRIBUTED_MARKER in text` — file-wide — so one
# comment line exempted every number in a file. Now BRACE-SCOPED to a declaration that genuinely
# conforms to CalibrationProfile AND carries the population line the contract's amendment asks for.
# A marker alone is a comment anyone can type; the population statement is what makes a shipped
# default honest.

POLICY_NUMBER = re.compile(
    r"(?:static\s+(?:let|var)\s+\w+\s*(?::\s*[\w<>\[\], ]+)?\s*=|"
    r":\s*(?:Double|Float|TimeInterval|CGFloat)\s*=)\s*-?\d+(?:\.\d+)?"
)
CALIBRATION_DECL = re.compile(
    r"^\s*(?:public\s+)?(?:struct|enum|final\s+class|class)\s+\w+\s*:[^{]*\bCalibrationProfile\b[^{]*\{"
)
POPULATION_DOC = re.compile(r"///.*\b(?:measured against|calibrated on|population)\b", re.I)


def _attributed_spans(text: str) -> list[tuple[int, int]]:
    lines = text.split("\n")
    masked = mask(text).split("\n")
    spans: list[tuple[int, int]] = []
    for index, line in enumerate(masked):
        if not CALIBRATION_DECL.match(line):
            continue
        window = "\n".join(lines[max(0, index - 12):index])
        if not POPULATION_DOC.search(window):
            continue  # marked but unattributed: not exempt, which is the point of the rule
        depth = 0
        for j in range(index, len(masked)):
            depth += masked[j].count("{") - masked[j].count("}")
            if depth == 0 and j > index:
                spans.append((index + 1, j + 1))
                break
    return spans


def check_no_policy_numbers(target: str) -> list[str]:
    hits: list[str] = []
    for path in swift_files(target):
        text = path.read_text(encoding="utf-8")
        spans = _attributed_spans(text)
        for number, line in enumerate(mask(text).split("\n"), start=1):
            if not POLICY_NUMBER.search(line):
                continue
            if any(start <= number <= end for start, end in spans):
                continue
            hits.append(f"{rel(path)}:{number} {line.strip()[:80]}")
    return hits


# --- Rule 5: no verdict, no rendering. Was 3/20, with false positives on Codable wire fields. ---

_MODS = (r"(?:static|class|final|private\(set\)|internal\(set\)|fileprivate\(set\)|dynamic|override"
         r"|mutating|nonmutating|lazy|weak|unowned|convenience|required|indirect|@\w+)")
DECL = re.compile(
    r"(?:^|[^.\w])(?P<pub>(?:public|open)\s+(?:" + _MODS + r"\s+)*)"
    r"(?P<kw>var|let|func)\b\s*(?P<name>[A-Za-z_]\w*)"
)
VERDICT_PREFIX = re.compile(r"^(?:is|has|can|allows?|should|must|may)[A-Z_]")
VERDICT_WORD = re.compile(
    r"pass|approv|eligib|qualif|meets|exceed|satisf|permit|allowed|denied|accept|reject"
    r"|verdict|complian|authoris|authoriz|granted|locked|blocked|trusted|cleared",
    re.IGNORECASE,
)
# Rendering FOR A READER, which the SDK must not do. Deliberately NOT the same list as "touches an
# image type": a capture SDK whose whole job is acquiring document and portrait frames must handle
# CGImage and CVPixelBuffer, and flagging that told us a camera was rendering. `CGImage` and
# `CIImage` are therefore absent from this list; what remains is display-ready OUTPUT — a formatted
# string, an attributed string, a platform view image — and SwiftUI.
RENDER_TYPES = ("UIImage", "NSImage", "jpegData", "pngData", "SwiftUI",
                "NSAttributedString", "AttributedString", "DateFormatter", "NumberFormatter")
# Targets whose product IS image acquisition. Inside these, even UIImage/NSImage is mechanism
# rather than presentation, so only the formatter and SwiftUI shapes count.
PIXEL_TARGETS = ("Capture", "IdentityEvidenceApple", "FaceMatching", "Regula", "BlinkID", "Preview")
# Reviewed exemptions, named one at a time. Standard-library conformances are not verdicts, and a
# Codable wire field is data rather than a judgement — flagging those made the counter unzeroable.
VERDICT_EXEMPT = {"isEmpty", "hasPrefix", "hasSuffix", "isMultiple", "isCancelled", "contains",
                  "isLive", "scanAvailable", "isFinite", "isNaN", "isExpired"}


def check_no_verdict(target: str) -> list[str]:
    hits: list[str] = []
    for path in swift_files(target):
        code = mask(path.read_text(encoding="utf-8"))
        for number, line in enumerate(code.split("\n"), start=1):
            _append_verdict_line_hits(number, line, path, target, hits)
    return hits


# --- Layer direction: the leaf stays a leaf. Was 6/19; attributed imports escaped. --------------

LEAF = "KenshikiEvidenceCore"
LEAF_ALLOWED = {"Foundation", "SQLite3"}
# IMPORT_RE lives with the classification helpers: the host rule reads imports too.


def check_layer_direction(_target: str | None = None) -> list[str]:
    hits: list[str] = []
    for path in swift_files(LEAF):
        for number, line in enumerate(mask(path.read_text(encoding="utf-8")).split("\n"), start=1):
            match = IMPORT_RE.match(line)
            if match and match.group(1) not in LEAF_ALLOWED:
                hits.append(f"{rel(path)}:{number} leaf imports {match.group(1)}")
    return hits


# --- The erase registry names every store. NEW. It is what makes a hand-written list safe. -----
#
# WHY THIS CHECK IS THE POINT AND THE REGISTRY IS NOT. `PersistedStore`'s own doc says a
# hand-written list of stores is the exact defect the protocol exists to remove, and names four
# stores that shipped while erasure never learned about them. Swift cannot enumerate a protocol's
# conformances at runtime, so `PersistedStoreRegistry`'s lists are ALSO written by hand. Publishing
# them without this check would not remove the defect; it would move it inside the SDK, where an
# adopter cannot see it rot and a holder finds out years later.
#
# So the list is not trusted — it is MEASURED against the conformances. Every `: PersistedStore`
# in a neutral target is found here, and a store no registry names fails the gate on the commit
# that introduces it. The list stays correct under review instead of by memory, which is the only
# property that made publishing one worth doing.
#
# FATAL AND UNBASELINED, like `classification_conflicts()` and unlike every counter in this file.
# A counter says "this is debt, shrink it", and debt is the right shape for prose or a policy
# number that is already shipped. An unregistered store is not debt: it is holder data that a
# documented erase-all silently does not reach, and there is no honest number for how many of
# those are acceptable. It starts at zero because every conformance in the package is registered
# today; the only way it becomes non-zero is a new store, and the fix is one line.
#
# ONLY SHIPPED LIBRARY TARGETS ARE SCANNED, on both sides, and that is deliberate on the registry
# side. `Hosts/SensorHost` held exactly such a list, in the one target built to prove the public
# surface is sufficient. If a host's array could satisfy this check, the host could take its
# hand-written list back and the gate would call it registered. "Shipped library" is neutral plus
# the two roles added on 2026-10-08, vendor adapter and third-party: both ship to adopters, so
# leaving the five neutral rules must not also take their stores out of erase-all.
STORE_ROLES = {"neutral", "vendor-adapter", "third-party"}
STORE_PROTOCOL = re.compile(r"\bPersistedStore\b")
STORE_CONFORMANCE = re.compile(
    r"\b(extension|struct|enum|actor|class|protocol)\s+(\w+)\s*(?::([^{]*))?\{", re.S)
# `allStores = [...]`, however the element type is spelled. The annotation is optional and may not
# run past its own line, so the protocol's `{ get }` requirement is not mistaken for a list and a
# stray `allStores` cannot reach forward to some later array in the same file.
REGISTRY_LIST = re.compile(r"\ballStores\b\s*(?::[^=\n]*)?=\s*\[(.*?)\]", re.S)
REGISTRY_ENTRY = re.compile(r"\b(\w+)\s*\.\s*self\b")


def _persisted_stores() -> tuple[dict[str, str], set[str], list[str]]:
    """(conforming store -> where it is declared, every name a registry lists, refusals)."""
    conformances: dict[str, str] = {}
    registered: set[str] = set()
    refinements: list[str] = []
    for key in _unique([key for key, _, role in _inventory() if role in STORE_ROLES]):
        for path in swift_files(key):
            _append_persisted_store_file(path, conformances, registered, refinements)
    return conformances, registered, refinements


def persistence_registry_gaps() -> list[str]:
    """A store that conforms to the persistence contract and no registry names.

    The composition side — a host that holds one registry and forgets another — is NOT checked
    here and cannot be: which modules a host embeds is the host's choice, and a module it never
    imported has no stores on that device. What is checked is the half a person can get wrong
    silently: a store inside a module the adopter DID embed, missing from that module's list.
    """
    conformances, registered, refinements = _persisted_stores()
    gaps = [
        f"{where} {name} conforms to PersistedStore and no registry's `allStores` names it — "
        "holder data a documented erase-all does not reach"
        for name, where in sorted(conformances.items()) if name not in registered
    ]
    return sorted(gaps + refinements)


# --- Rule 6: the host reaches past no public surface. NEW, and it pays for the host exemption. --
#
# The sample and debug UI exist to prove the PUBLIC SURFACE is sufficient. That proof is only worth
# something if the sample has exactly the access an outside adopter has: the moment it can see an
# internal symbol, it stops measuring the surface and starts measuring the module. When the debug
# UI cannot display something, that is a FINDING about the public API — the thing becomes real
# public API, or it stays hidden. It is never a reason to reach around.
#
# The subject is a CLASS of construct, not a list of spellings, because that is the mistake this
# file was rewritten to stop making. The class is: every door Swift provides into a module that an
# ordinary `import` does not open.
#
#   @testable                 the module's internals, wholesale
#   @_spi / @_implementationOnly / @_exported and every other underscored attribute
#                             compiler-private doors; the underscore IS the marker
#   .`_something`             an underscored member is not surface, whatever its access level
#   Mirror / NSClassFromString / NSSelectorFromString / dlopen / dlsym / unsafeBitCast
#                             reading or calling past access control at runtime instead of at
#                             compile time — `Mirror(reflecting:)` will happily enumerate the
#                             stored properties of a public type that declared none of them public
#   unsafeFlags / -enable-testing in the manifest
#                             the declaration itself widening what the source is allowed to do
#   a dependency no .library product exports
#                             a module an adopter could not have depended on in the first place
#
# The manifest half matters as much as the source half. A host that lists `-enable-testing` has
# made `@testable` legal, and a host that depends on an unexported target is using something no
# adopter can reach — neither is visible anywhere in the Swift files.

TESTABLE = re.compile(r"@testable\b")
PRIVATE_ATTRIBUTE = re.compile(r"@(_\w+)")
UNDERSCORED_MEMBER = re.compile(r"\.\s*(_[A-Za-z]\w*)")
DYNAMIC_REACH = ("NSClassFromString", "NSSelectorFromString", "dlopen(", "dlsym(",
                 "unsafeBitCast(", "Mirror(", "_typeByName")


def _manifest_surface_escapes(target: str) -> list[str]:
    """Access the target's own DECLARATION widens, for every target Rule 6 governs.

    This read the `.executableTarget` table and returned `[]` for anything else, on the reasoning
    that "only a host has a declaration; a profile is a library". Both halves are wrong. A `.target`
    declaration carries `swiftSettings` exactly as an executable one does, and a profile that
    depends on an unexported module is using something no adopter could have depended on — which is
    the point of the clause. Neither escape appears anywhere in the Swift files, so if this does not
    look, nothing does.
    """
    for record in _xcodegen_records():
        if record["key"] == target and record["role"] == "host":
            # An XcodeGen host has no `Package.swift` declaration to widen; its declaration is the
            # `project.yml`, and the escapes it can write there are different spellings of the same
            # two things. See `_project_surface_escapes`.
            return _project_surface_escapes(record)
    for record in _rn_host_records():
        if record["key"] == target:
            # A React Native host's declaration is its own build scripts, not `Package.swift`.
            return _rn_host_manifest_escapes(record)
    if any(key == target and role in {"vendor-adapter", "third-party"}
           for key, _, role in _inventory()):
        # Declared by its own package's manifest, not the root one. See `_package_manifest_escapes`.
        return _package_manifest_escapes(target)
    name = target.rsplit("/", 1)[-1]
    governed = {key.rsplit("/", 1)[-1] for key, _, role in _inventory() if role in {"host", "profile"}}
    if name not in governed:
        return []
    root_text = _root_manifest_text()
    body = dict(_declarations(root_text, ANY_TARGET_DECL)).get(name, "")
    hits: list[str] = []
    if "unsafeFlags" in mask(body):
        hits.append(f"Package.swift:0 {name} declares unsafeFlags — its access is a compiler flag away")
    if "enable-testing" in mask(root_text, keep_literals=True):
        hits.append("Package.swift:0 the manifest enables testing, so @testable would compile")
    exported = _exported_targets(root_text)
    declared = {declared_name for declared_name, _ in _declarations(root_text, ANY_TARGET_DECL)}
    for dependency in sorted(_declared_dependencies(body) & declared):
        if dependency not in exported:
            hits.append(
                f"Package.swift:0 {name} depends on {dependency}, which no .library product exports")
    return hits


TESTABILITY_SETTING = re.compile(r"ENABLE_TESTABILITY\s*:\s*['\"]?(?:YES|true)", re.IGNORECASE)


def _library_product_names(text: str) -> set[str]:
    """The `.library` product NAMES a manifest declares — what an XcodeGen `product:` can name.

    Deliberately not `_exported_targets()`, which returns the TARGETS those products export. They
    happen to be spelled the same in this package and need not be in general, and a `product:` that
    names a target rather than a library product is precisely the reach this check is looking for.
    """
    return set(LIBRARY_PRODUCT_NAME.findall(mask(text, keep_literals=True)))


def _project_surface_escapes(record: dict) -> list[str]:
    """The manifest half of Rule 6 for an XcodeGen host: what its `project.yml` widens.

    Two things, the same two the `Package.swift` half looks for. A setting that makes `@testable`
    compile, and a dependency on something no adopter could have depended on — here a `product:`
    that the consumed package does not declare as a `.library`. Neither appears anywhere in the
    Swift files.

    The known limit is recorded above `XCODEGEN_MANIFEST_NAMES`: Xcode's Debug configuration sets
    `ENABLE_TESTABILITY` itself, in a generated file, so this catches the deliberate spelling and
    the source-side `@testable` check is what actually binds.
    """
    manifest = record["manifest"]
    text = manifest.read_text(encoding="utf-8")
    hits: list[str] = []
    if TESTABILITY_SETTING.search(text):
        hits.append(f"{rel(manifest)}:0 ENABLE_TESTABILITY is set, so @testable would compile")
    if "-enable-testing" in text:
        hits.append(f"{rel(manifest)}:0 -enable-testing is passed, so @testable would compile")
    packages = record["document"].get("packages") or {}
    dependencies = record["body"].get("dependencies") or []
    for dependency in dependencies if isinstance(dependencies, list) else []:
        _append_project_dependency_escape(dependency, packages, record, manifest, hits)
    return hits


def _surface_escapes_in_files(files: list[Path]) -> list[str]:
    hits: list[str] = []
    for path in files:
        code = mask(path.read_text(encoding="utf-8"))
        for number, line in enumerate(code.split("\n"), start=1):
            _append_surface_line_escapes(number, line, path, hits)
    return hits


def check_no_surface_escape(target: str) -> list[str]:
    return _surface_escapes_in_files(swift_files(target)) + _manifest_surface_escapes(target)


# =================================================================================================
# REACT NATIVE. WHY THE GATE LEARNED TO READ `package.json` ON 2026-10-08.
#
# THE HOLE. Every target above is Swift. `ReactNative/identity-capture` is a published npm package
# — TypeScript an adopter's JavaScript calls, and Objective-C++ that bridges it to the runtime — and
# `Examples/ReactNativeCaptureHost` is the reference app built against it. Neither was scanned by
# any rule, so the one surface a React Native adopter actually types against could author prose,
# name its vendor, read the clock, hold a threshold or return a verdict, and every counter read 0.
# `Distribution/IdentityCaptureRuntime` (the Swift half of the same delivery) was already neutral;
# the half that sits in front of it was not.
#
# THE NEUTRAL SIDE IS DERIVED FROM THE BUILD GRAPH, like `Package.swift` and `project.yml`. An npm
# manifest that is not `"private": true` can be published, and a published package is SDK surface,
# so it is NEUTRAL and receives Rules 1-5. It is scanned over exactly the directories its own
# `files` field ships, because that is what reaches an adopter. A `"private": true` manifest is an
# application or a tool; no role is guessed for it — it is a conflict until someone classifies it,
# the same fail-closed rule as an unknown XcodeGen `type:`.
#
# THE HOST SIDE IS DECLARED, AND THE DECLARATION IS CHECKED. A React Native reference host in this
# repository has no manifest of its own: `create-host.py` generates a fresh app OUTSIDE the tree
# and copies these sources into it, then installs the package's built tarball. So there is no
# build file to read a role out of, and "any TypeScript without a `package.json`" is not one
# either — `Tools/` holds browser JavaScript that is not a React Native app at all. The role is
# therefore named by path in `REACT_NATIVE_HOSTS`, the shape `AMBIENT_ADAPTERS` already has: a
# path list cannot be extended by writing a comment, and extending it is a diff someone reviews.
#
# What makes that safe is the same property that pays for every host exemption here: NOTHING CAN
# IMPORT IT. `_react_native_conflicts()` checks the observable shadows of that claim and each one
# is fatal, not baselined — no `package.json` governs the directory (so npm cannot depend on it),
# it is not a Swift package or an Xcode project, it overlaps no neutral source root, and no neutral
# package source imports a path inside it. Declaring a neutral directory a host therefore buys a
# conflict, not an exemption. And no TypeScript file can be born outside the rules: one that no
# package governs and no host declares is itself a conflict.
#
# WHAT IS NOT SEEN, stated rather than hidden. Plain JavaScript outside every `package.json`
# (`Tools/`, browser tooling) is not classified; only TypeScript is held to the coverage check. The
# package's `package.json` and podspec are build files, not scanned sources, so the product name
# they carry (`@kenshiki/identity-capture`, author `Kenshiki`) is not counted by Rule 2. The
# contract is silent on a package's own product name, and no exemption for it exists here: if the
# package's own sources spell it, Rule 2 counts it like any other vendor token.
#
# REPOSITORY TOOLING, ADDED 2026-10-09 BY OWNER DECISION. The repository root carries a
# `"private": true` manifest whose only job is to install the React Native quality tooling (Biome,
# TypeScript, ESLint, Jest, jscpd) and run `npm run check`. It never ships: `private` keeps it off
# every registry, and no delivery copies it. It is classified by PATH in `RN_TOOLING_MANIFESTS`,
# like a host, and the classification is checked, not trusted — `_react_native_conflicts()` makes
# each of these fatal: a declared tooling manifest that is not `"private": true`, one that declares
# a native module (`codegenConfig`) or npm workspaces, one that sits inside a host or a neutral
# package's shipped directories, and a declaration that names no manifest. A tooling manifest
# covers no TypeScript: the coverage check ignores it, so it cannot become the `package.json` that
# "governs" every file below the root. Any OTHER private manifest is still unclassified and fatal,
# including one placed inside the React Native package or a host.

NPM_MANIFEST = NPM_MANIFEST_NAME
# Private manifests that only install and run repository tooling, by directory. See above.
RN_TOOLING_MANIFESTS = (".",)
RN_SCRIPT_EXTENSIONS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs")
RN_NATIVE_EXTENSIONS = (".m", ".mm", ".h")
RN_TYPESCRIPT_EXTENSIONS = (".ts", ".tsx")
RN_JSX_EXTENSIONS = (".tsx", ".jsx")
# Generated and vendored trees, plus binary build products whose headers are not authored here.
_RN_PRUNE = {".build", "checkouts", ".git", "DerivedData", "node_modules", "Pods"}
_RN_PRUNE_SUFFIXES = (".xcodeproj", ".xcworkspace", ".xcframework", ".framework", ".bundle")
# React Native reference hosts, by repository path. See the block above for why this is a list and
# what `_react_native_conflicts()` verifies before the exemption it grants is worth anything.
REACT_NATIVE_HOSTS = (REFERENCE_HOST_PATH,)
# The files a React Native host builds itself with, for the manifest half of Rule 6.
RN_HOST_BUILD_FILES = (".rb", ".py", ".json", ".yml", ".yaml", ".xcconfig")
# A React Native host's TESTS are not scanned, by owner decision 2026-10-08 — parity with the
# `.testTarget` and XcodeGen test bundles no rule has ever scanned: a test is expected to reach
# past the surface, and that is what a test IS. Two kinds, both checked rather than trusted by
# `_react_native_conflicts()`:
#   * `*.test.ts` / `*.test.tsx`, Jest's own test-file convention, and only while no non-test host
#     source imports one — a name is free to write, so the exemption is paid for the same way the
#     host's is: nothing that ships can reach it;
#   * the Swift files the host's build script places in its generated app's UI-test bundle,
#     declared by path below, and only while each exists and imports XCTest.
# `--report` prints what the skipped files would have scored, so they are excluded, not hidden.
RN_HOST_TEST_SUFFIXES = (".test.ts", ".test.tsx")
RN_HOST_UI_TESTS = {REFERENCE_HOST_PATH: (ARTIFACT_TEST_NAME,)}


def _rn_walk(start: Path):
    for directory, children, files in os.walk(start):
        children[:] = sorted(name for name in children
                             if name not in _RN_PRUNE and not name.endswith(_RN_PRUNE_SUFFIXES))
        yield Path(directory), files


def _npm_record_at(directory: Path) -> dict:
    """The role and scan roots one `package.json` declares. Never raises: an unreadable manifest is
    recorded with role "unknown" and becomes a conflict, because a parser that returned nothing
    would turn a typo into a package outside every rule."""
    manifest = directory / NPM_MANIFEST
    key = directory.relative_to(ROOT).as_posix() if directory != ROOT else "."
    record = {"key": key, "role": "unknown", "why": "", "directory": directory, "manifest": manifest,
              "directories": [], "name": None, "spec_dir": None, "native_names": set()}
    try:
        document = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        record["why"] = f"unreadable ({error.__class__.__name__})"
        return record
    if not isinstance(document, dict):
        record["why"] = "is not a JSON object"
        return record
    record["name"] = document.get("name") if isinstance(document.get("name"), str) else None
    if document.get("private") is True:
        if key in RN_TOOLING_MANIFESTS:
            # Declared repository tooling: scanned by no rule and covering no source, so its
            # conditions are checked in `_react_native_conflicts()`.
            record["role"] = "tooling"
            record["document"] = document
            return record
        record["why"] = ('is "private": true — an application or tool, neither a published package '
                         "(neutral) nor a declared React Native host")
        return record
    if not _npm_shipped_directories(document, directory, record):
        return record
    record["role"] = "neutral"
    _npm_codegen_metadata(document, directory, record)
    return record


def _npm_shipped_directories(document: dict, directory: Path, record: dict) -> bool:
    shipped = document.get("files")
    if shipped is None:
        record["directories"] = [directory]  # npm ships the whole directory when `files` is absent
    elif not isinstance(shipped, list):
        record["why"] = "`files` is not a list"
        return False
    else:
        for entry in shipped:
            if not isinstance(entry, str) or any(mark in entry for mark in "*?[]{}!"):
                record["why"] = f"`files` entry {entry!r} is a pattern this gate does not resolve"
                return False
            candidate = Path(os.path.normpath(directory / entry))
            if candidate.is_dir():
                record["directories"].append(candidate)
    return True


def _npm_codegen_metadata(document: dict, directory: Path, record: dict) -> None:
    codegen = document.get("codegenConfig") if isinstance(document.get("codegenConfig"), dict) else {}
    if isinstance(codegen.get("jsSrcsDir"), str):
        record["spec_dir"] = Path(os.path.normpath(directory / codegen["jsSrcsDir"]))
    names: set[str] = set()
    if isinstance(codegen.get("name"), str):
        names.add(codegen["name"])
    ios = codegen.get("ios") if isinstance(codegen.get("ios"), dict) else {}
    for table in ("modulesProvider", "componentProvider"):
        providers = ios.get(table) if isinstance(ios.get(table), dict) else {}
        names |= {str(value) for pair in providers.items() for value in pair}
    record["native_names"] = names


def _npm_records() -> list[dict]:
    return [_npm_record_at(directory) for directory, files in _rn_walk(ROOT) if NPM_MANIFEST in files]


def _rn_host_records() -> list[dict]:
    records = []
    for written in REACT_NATIVE_HOSTS:
        directory = Path(os.path.normpath(ROOT / written))
        records.append({"key": written, "role": "host", "directory": directory,
                        "directories": [directory] if directory.is_dir() else []})
    return records


def _rn_host_test_file(host: str, path: Path) -> bool:
    """A test file of a declared React Native host, which Rule 6 does not scan."""
    if path.name.endswith(RN_HOST_TEST_SUFFIXES):
        return True
    return (path.name in RN_HOST_UI_TESTS.get(host, ())
            and path.parent == Path(os.path.normpath(ROOT / host)))


def _rn_host_test_files(host: str) -> list[Path]:
    record = next((record for record in _rn_host_records() if record["key"] == host), None)
    if record is None:
        return []
    found = _rn_source_files(record["directories"], RN_SCRIPT_EXTENSIONS + RN_NATIVE_EXTENSIONS)
    found += _swift_files_in(record["directories"])
    return sorted(path for path in set(found) if _rn_host_test_file(host, path))


def _rn_record(target: str) -> dict | None:
    """The React Native record a scan key names, without walking the tree for every check."""
    if target in REACT_NATIVE_HOSTS:
        return next(record for record in _rn_host_records() if record["key"] == target)
    directory = ROOT / target
    if (directory / NPM_MANIFEST).is_file():
        return _npm_record_at(directory)
    return None


def _rn_source_files(directories: list[Path], extensions: tuple[str, ...]) -> list[Path]:
    found: set[Path] = set()
    for start in directories:
        if start.is_dir():
            for directory, files in _rn_walk(start):
                found.update(directory / name for name in files if name.endswith(extensions))
    return sorted(found)


def rn_files(target: str) -> list[Path]:
    """TypeScript/JavaScript and Objective-C sources a React Native target owns; empty otherwise."""
    record = _rn_record(target)
    if record is None or record["role"] not in {"neutral", "host"}:
        return []
    found = _rn_source_files(record["directories"], RN_SCRIPT_EXTENSIONS + RN_NATIVE_EXTENSIONS)
    if record["role"] == "host":
        found = [path for path in found if not _rn_host_test_file(target, path)]
    return found


def _rn_dialect(path: Path) -> str:
    return "ts" if path.name.endswith(RN_SCRIPT_EXTENSIONS) else "objc"


# --- A lexer, because the rules' subjects are literals and constructions, not lines. ------------
# Same contract as `mask()`: offsets are preserved, so a hit reports its real source line. TypeScript
# needs three things Swift's masker never met — single-quoted strings, template literals whose
# `${…}` holes are CODE, and regex literals (a `/'/` must not open a string). Objective-C adds
# character literals. Known limit: a straight apostrophe in JSX text opens a string to the end of
# its line; the damage is line-local because single-line strings stop at a newline.

_JS_REGEX_PRECEDERS = set("(,=:[!&|?{};+-*%~^")
_JS_REGEX_KEYWORDS = {"return", "typeof", "case", "do", "else", "in", "of", "void", "yield",
                      "await", "delete", "instanceof", "new", "throw"}



class _CFamilyScanner:
    """Offset-preserving lexical state for C-family comments, strings and template holes."""
    def __init__(self, text: str, dialect: str):
        self.text, self.n, self.is_ts = text, len(text), dialect == "ts"
        self.comments, self.found, self.blanks = [], [], []
        self.holes, self.prev, self.i = [], "", 0

    def template_text(self, start: int, blank_from: int) -> tuple[int, bool]:
        j = start
        while j < self.n:
            if self.text[j] == "\\":
                j += 2
                continue
            if self.text[j] == "`":
                self.found.append((start, self.text[start:j]))
                self.blanks.append((blank_from, j + 1))
                return j + 1, False
            if self.text.startswith("${", j):
                self.found.append((start, self.text[start:j]))
                self.blanks.append((blank_from, j))
                return j + 2, True
            j += 1
        self.found.append((start, self.text[start:self.n]))
        self.blanks.append((blank_from, self.n))
        return self.n, False

    def comment(self) -> bool:
        if self.text.startswith("//", self.i):
            end = self.text.find("\n", self.i)
        elif self.text.startswith("/*", self.i):
            end = self.text.find("*/", self.i + 2)
            if end != -1:
                end += 2
        else:
            return False
        end = self.n if end == -1 else end
        self.comments.append((self.i, self.text[self.i:end]))
        self.i = end
        return True

    def quoted_literal(self, ch: str) -> None:
        j = self.i + 1
        while j < self.n and self.text[j] not in (ch, "\n"):
            j += 2 if self.text[j] == "\\" else 1
        j = min(j, self.n)
        self.found.append((self.i + 1, self.text[self.i + 1:j]))
        end = min(j + 1, self.n)
        self.blanks.append((self.i, end))
        self.i, self.prev = end, ch

    def regex_end(self) -> int:
        j, in_class = self.i + 1, False
        while j < self.n and self.text[j] != "\n":
            ch = self.text[j]
            if ch == "\\":
                j += 2
                continue
            if ch == "[":
                in_class = True
            elif ch == "]":
                in_class = False
            elif ch == "/" and not in_class:
                break
            j += 1
        return j

    def regex_literal(self, ch: str) -> bool:
        if not (self.is_ts and ch == "/" and not self.text.startswith("/>", self.i)):
            return False
        if self.prev and self.prev not in _JS_REGEX_PRECEDERS and self.prev not in _JS_REGEX_KEYWORDS:
            return False
        j = self.regex_end()
        if j >= self.n or self.text[j] != "/":
            return False
        j += 1
        while j < self.n and (self.text[j].isalnum() or self.text[j] == "_"):
            j += 1
        self.blanks.append((self.i, j))
        self.i, self.prev = j, "/re/"
        return True

    def template_hole(self, ch: str) -> bool:
        if not self.is_ts or not self.holes:
            return False
        if ch == "{":
            self.holes[-1] += 1
        elif ch == "}":
            if self.holes[-1] == 0:
                self.holes.pop()
                self.i, opened = self.template_text(self.i + 1, self.i + 1)
                if opened:
                    self.holes.append(0)
                self.prev = "{" if opened else "`"
                return True
            self.holes[-1] -= 1
        return False

    def advance_token(self, ch: str) -> None:
        if ch.isalnum() or ch in "_$":
            j = self.i
            while j < self.n and (self.text[j].isalnum() or self.text[j] in "_$"):
                j += 1
            self.prev, self.i = self.text[self.i:j], j
            return
        if not ch.isspace():
            self.prev = ch
        self.i += 1

    def start_template(self, ch: str) -> bool:
        if not self.is_ts or ch != "`":
            return False
        self.i, opened = self.template_text(self.i + 1, self.i)
        if opened:
            self.holes.append(0)
        self.prev = "{" if opened else "`"
        return True

    def scan(self):
        while self.i < self.n:
            ch = self.text[self.i]
            if self.comment():
                continue
            if self.start_template(ch):
                continue
            if ch in "\"'":
                self.quoted_literal(ch)
                continue
            if self.regex_literal(ch) or self.template_hole(ch):
                continue
            self.advance_token(ch)
        return self.comments, self.found, self.blanks


def _c_family_scan(text: str, dialect: str):
    """Comments, literal parts and blanking spans, preserving source offsets."""
    return _CFamilyScanner(text, dialect).scan()


def _rn_mask(text: str, dialect: str, *, keep_literals: bool = False) -> str:
    comments, _, blanks = _c_family_scan(text, dialect)
    out = list(text)
    spans = [(start, start + len(body)) for start, body in comments]
    if not keep_literals:
        spans += blanks
    for start, end in spans:
        for k in range(start, min(end, len(out))):
            if out[k] != "\n":
                out[k] = " "
    return "".join(out)


def _line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


# JSX text is prose that is not a string literal: `<Text>Hold the phone steady.</Text>`. A regex
# over `>…<` cannot tell element children from a class body followed by a generic method
# (`}\n  private async command<T>` reads as three words), so this walks masked code with a mode
# stack: CODE, and the CHILDREN of an open element, where `{…}` re-enters code. A `<` opens an
# element only where an expression can start — not after an identifier, `)` or `]` (a generic or
# a comparison) — and `<T extends …>` / `<T,>` are generic arrows, not elements.
_JSX_KEYWORDS = {"return", "yield", "await", "default", "else", "case", "do", "in", "of", "typeof", "void"}



class _JSXTextScanner:
    """Track code and element children separately so generics never become authored text."""
    def __init__(self, code: str):
        self.code, self.n = code, len(code)
        self.runs, self.frames = [], [["code", 0]]
        self.prev, self.text_from, self.i = "", None, 0

    def flush(self, end: int) -> None:
        if self.text_from is not None and end > self.text_from:
            self.runs.append((self.text_from, self.code[self.text_from:end]))
        self.text_from = None

    def open_element(self, k: int) -> int:
        depth, j = 0, k + 1
        while j < self.n:
            if self.code[j] == "{":
                depth += 1
            elif self.code[j] == "}":
                depth = max(0, depth - 1)
            elif self.code[j] == ">" and depth == 0 and self.code[j - 1] != "=":
                if self.code[j - 1] != "/":
                    self.frames.append(["children", 0])
                    self.text_from = j + 1
                return j + 1
            j += 1
        return self.n

    def element_can_open(self, k: int) -> bool:
        if k + 1 >= self.n or not (self.code[k + 1].isalpha() or self.code[k + 1] == ">"):
            return False
        if re.match(r"<[A-Za-z][\w.]*\s*(?:,|extends\b)", self.code[k:k + 80]):
            return False
        return (self.prev == "" or self.prev in _JSX_KEYWORDS
                or not (self.prev[-1].isalnum() or self.prev[-1] in "_$)]."))

    def child_element(self) -> bool:
        if self.code.startswith("</", self.i):
            self.flush(self.i)
            close = self.code.find(">", self.i)
            self.i = self.n if close == -1 else close + 1
            if len(self.frames) > 1:
                self.frames.pop()
            if self.frames[-1][0] == "children":
                self.text_from = self.i
            self.prev = ">"
            return True
        return self.open_child_element()

    def open_child_element(self) -> bool:
        if (self.code[self.i] == "<" and self.i + 1 < self.n
                and (self.code[self.i + 1].isalpha() or self.code[self.i + 1] == ">")):
            self.flush(self.i)
            self.i = self.open_element(self.i)
            if self.frames[-1][0] != "children" or self.text_from is None:
                self.text_from = self.i if self.frames[-1][0] == "children" else None
            return True
        return False

    def children(self) -> None:
        if self.code[self.i] == "{":
            self.flush(self.i)
            self.frames.append(["code", 1])
            self.prev, self.i = "{", self.i + 1
            return
        if self.child_element():
            return
        if self.text_from is None:
            self.text_from = self.i
        self.i += 1

    def code_boundary(self, ch: str) -> bool:
        if ch == "{":
            self.frames[-1][1] += 1
        elif ch == "}":
            self.frames[-1][1] -= 1
            if self.frames[-1][1] <= 0 and len(self.frames) > 1:
                self.frames.pop()
                self.i += 1
                self.text_from = self.i if self.frames[-1][0] == "children" else None
                return True
        elif ch == "<" and self.element_can_open(self.i):
            self.i = self.open_element(self.i)
            return True
        return False

    def code_token(self, ch: str) -> None:
        if ch.isalnum() or ch in "_$":
            j = self.i
            while j < self.n and (self.code[j].isalnum() or self.code[j] in "_$"):
                j += 1
            self.prev, self.i = self.code[self.i:j], j
            return
        if not ch.isspace():
            self.prev = ch
        self.i += 1

    def scan(self):
        while self.i < self.n:
            if self.frames[-1][0] == "children":
                self.children()
                continue
            ch = self.code[self.i]
            if not self.code_boundary(ch):
                self.code_token(ch)
        self.flush(self.n if self.frames[-1][0] == "children" else (self.text_from or self.n))
        return self.runs


def _jsx_text_runs(code: str) -> list[tuple[int, str]]:
    return _JSXTextScanner(code).scan()


def _depths(code: str) -> tuple[list[int], list[int]]:
    """Brace depth and bracket/paren depth BEFORE each offset, over masked code."""
    brace, paren = [0] * (len(code) + 1), [0] * (len(code) + 1)
    b = p = 0
    for k, ch in enumerate(code):
        brace[k], paren[k] = b, p
        if ch == "{":
            b += 1
        elif ch == "}":
            b = max(0, b - 1)
        elif ch in "([":
            p += 1
        elif ch in ")]":
            p = max(0, p - 1)
    brace[len(code)], paren[len(code)] = b, p
    return brace, paren


_TS_TOP_DECL = re.compile(
    r"^export\s+(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?(?:async\s+)?"
    r"(type|interface|class|function|const|let|var|enum|namespace)\b", re.M)



def _ts_region_end(code: str, match, brace: list[int], paren: list[int]) -> int:
    kind, k, n = match.group(1), match.end(), len(code)
    while k < n:
        ch, top = code[k], brace[k] == 0 and paren[k] == 0
        if top and ch == ";":
            return k + 1
        if _ts_body_ends(ch, kind, brace[k], paren[k]):
            return k + 1
        if top and ch == "\n" and k + 1 < n and code[k + 1] not in " \t\n|&})].,=>?:":
            return k
        k += 1
    return k


def _ts_body_ends(ch: str, kind: str, brace: int, paren: int) -> bool:
    return (ch == "}" and brace == 1 and paren == 0
            and kind in {"class", "function", "interface", "enum", "namespace"})


def _ts_public_regions(code: str) -> list[tuple[int, int, str]]:
    """Top-level exported regions with lexical delimiter depths preserved."""
    brace, paren = _depths(code)
    return [(match.start(), _ts_region_end(code, match, brace, paren), match.group(1))
            for match in _TS_TOP_DECL.finditer(code) if not (brace[match.start()] or paren[match.start()])]



def _ts_member_is_public(code: str, kind: str, at: int, depth: int) -> bool:
    if kind in {"type", "interface"}:
        return depth >= 1
    if kind == "class":
        line_start = code.rfind("\n", 0, at) + 1
        return depth == 1 and not re.search(r"\b(?:private|protected)\b|#", code[line_start:at + 1])
    if kind in {"function", "const", "let", "var"}:
        return depth == 0
    return True


def _ts_public_members(code: str, pattern: re.Pattern, *, kinds: set[str]):
    """Yield public declarations, excluding locals, parameters and private members."""
    brace, paren = _depths(code)
    for start, end, kind in _ts_public_regions(code):
        if kind not in kinds:
            continue
        for match in pattern.finditer(code, start, end):
            at = match.start()
            if paren[at] == paren[start] and _ts_member_is_public(code, kind, at, brace[at] - brace[start]):
                yield kind, code[start:end], match


# --- Rule 1a, TypeScript and Objective-C: the prose CHANNELS. ------------------------------------
# JavaScript's prose channel is `Error`: its `message` is the sentence, and constructing, extending
# or reading it is the TypeScript spelling of `LocalizedError`/`errorDescription`. Objective-C uses
# Foundation's own NSLocalized* keys, so `PROSE_CHANNELS` applies to it unchanged. The shape check
# matches Swift's `PROSE_SHAPE` — a public member NAMED like prose that RETURNS a string — but
# case-insensitively, so `failureMessage()` is seen. A field of an exported data type is input data
# (the `_input_string_field` argument), unless the type is named as an error or failure.
JS_PROSE_CHANNEL = re.compile(
    r"\bnew\s+[A-Za-z_$]*Error\s*\(|\bextends\s+[A-Za-z_$]*Error\b|\.message\b"
    r"|\btoString\s*\(\s*\)\s*(?::\s*string\s*)?\{")
_PROSE_WORD = re.compile(r"message|description|explanation|reason|detail|summary|hint|advice|instruction",
                         re.I)
_TS_STRING_RETURN = r"\s*(?:<[^<>()]*>)?\s*\([^()]*\)\s*:\s*(?:Promise\s*<\s*)?string\b"
JS_PROSE_MEMBER = re.compile(
    r"(?<![\w$#.])(?:get\s+|function\s+)?([A-Za-z_$][\w$]*)" + _TS_STRING_RETURN
    + r"|(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::\s*string\b|=\s*(?:async\s*)?\([^()]*\)\s*:"
      r"\s*(?:Promise\s*<\s*)?string\b)")
JS_STRING_FIELD = re.compile(r"(?<![\w$#.])([A-Za-z_$][\w$]*)\s*(?:\?\s*)?:\s*string\b")
OBJC_DESCRIPTION_OVERRIDE = re.compile(
    r"[-+]\s*\(\s*NSString\s*\*\s*\)\s*(?:description|debugDescription|localizedDescription"
    r"|localizedFailureReason|localizedRecoverySuggestion)\b")


def _rn_no_prose(target: str) -> list[str]:
    hits: list[str] = []
    for path in rn_files(target):
        text = path.read_text(encoding="utf-8")
        dialect = _rn_dialect(path)
        code = _rn_mask(text, dialect)
        if dialect == "objc":
            hits += _objc_prose_hits(path, code)
            continue
        for match in JS_PROSE_CHANNEL.finditer(code):
            hits.append(f"{rel(path)}:{_line_of(code, match.start())} Error prose channel: "
                        f"{match.group(0).strip()[:40]}")
        for _, _, match in _ts_public_members(code, JS_PROSE_MEMBER,
                                              kinds={"class", "function", "const", "let", "var"}):
            name = match.group(1) or match.group(2)
            if _PROSE_WORD.search(name):
                hits.append(f"{rel(path)}:{_line_of(code, match.start())} prose-shaped member: {name}")
        hits += _ts_prose_fields(path, code)
    return hits

def _objc_prose_hits(path: Path, code: str) -> list[str]:
    hits = []
    for number, line in enumerate(code.split("\n"), start=1):
        hits += [f"{rel(path)}:{number} {channel}" for channel in PROSE_CHANNELS if channel in line]
        if OBJC_DESCRIPTION_OVERRIDE.search(line):
            hits.append(f"{rel(path)}:{number} description override")
    return hits


def _ts_prose_fields(path: Path, code: str) -> list[str]:
    hits = []
    for _, region, match in _ts_public_members(code, JS_STRING_FIELD, kinds={"type", "interface"}):
        declared = re.match(r"export\s+(?:declare\s+)?(?:type|interface)\s+(\w+)", region)
        if (declared and re.search(r"(?:Error|Failure)(?:$|[A-Z_])", declared.group(1))
                and _PROSE_WORD.search(match.group(1))):
            hits.append(f"{rel(path)}:{_line_of(code, match.start())} prose field on "
                        f"{declared.group(1)}: {match.group(1)}")
    return hits


# --- Rule 1b, TypeScript and Objective-C: sentences, including JSX text. ------------------------
# Scope and directive syntax come from the pinned TypeScript parser, never indentation or brace
# counts. A compiler may emit unindented function locals; strings, templates, comments and regexes
# may contain arbitrary braces. None of those spellings changes a declaration's lexical owner.
# The tool root is fixed even when self-test swaps ROOT for its synthetic repository. A missing
# compiler or a parse error is an unbaselined classification conflict, not a permissive fallback.
_RN_PARSER_ROOT = Path(__file__).resolve().parent.parent
_RN_SYNTAX_CACHE: dict[Path, tuple[str, dict]] = {}
_RN_SYNTAX_PARSER = r"""
const fs = require('node:fs');
let ts;
try {
    ts = require(require('node:path').join(process.cwd(), 'node_modules/typescript'));
} catch (error) {
    process.stdout.write(JSON.stringify({error: `TypeScript parser unavailable: ${error.message}`}));
    process.exit(1);
}
const results = JSON.parse(fs.readFileSync(0, 'utf8')).map(({path, text}) => {
    const source = ts.createSourceFile(path, text, ts.ScriptTarget.Latest, true);
    // TypeScript offsets are UTF-16; the Python lexical scanner uses Unicode code points.
    const offset = position => Array.from(text.slice(0, position)).length;
    const mutable = [];
    const strict = [];
    const directives = statements => {
        for (const statement of statements) {
            if (!ts.isExpressionStatement(statement) || !ts.isStringLiteral(statement.expression)) break;
            const raw = statement.expression.getText(source);
            if (raw === '\"use strict\"' || raw === "'use strict'") {
                strict.push(offset(statement.expression.getStart(source) + 1));
            }
        }
    };
    const visit = (node, functionDepth) => {
        if (ts.isVariableDeclarationList(node) && functionDepth === 0
                && !(node.flags & ts.NodeFlags.Const)) {
            mutable.push(offset(node.getStart(source)));
        }
        if (ts.isSourceFile(node)) directives(node.statements);
        if (ts.isFunctionLike(node) && node.body && ts.isBlock(node.body)) {
            directives(node.body.statements);
        }
        const nestedDepth = functionDepth + (ts.isFunctionLike(node) ? 1 : 0);
        ts.forEachChild(node, child => visit(child, nestedDepth));
    };
    visit(source, 0);
    const errors = source.parseDiagnostics.map(diagnostic => {
        const line = source.getLineAndCharacterOfPosition(diagnostic.start ?? 0).line + 1;
        return `${line}: ${ts.flattenDiagnosticMessageText(diagnostic.messageText, ' ')}`;
    });
    return {path, mutable, strict, errors};
});
process.stdout.write(JSON.stringify(results));
"""


def _rn_script_syntax(sources: dict[Path, str]) -> dict[Path, dict]:
    pending = {path: text for path, text in sources.items()
               if path not in _RN_SYNTAX_CACHE or _RN_SYNTAX_CACHE[path][0] != text}
    if pending:
        try:
            result = subprocess.run(
                ["node", "--input-type=commonjs", "-e", _RN_SYNTAX_PARSER],
                input=json.dumps([{"path": str(path), "text": text} for path, text in pending.items()]),
                cwd=_RN_PARSER_ROOT, capture_output=True, text=True, timeout=60)
            parsed = json.loads(result.stdout)
            if result.returncode != 0 or not isinstance(parsed, list):
                detail = parsed.get("error") if isinstance(parsed, dict) else None
                raise ValueError(detail or f"TypeScript parser exited {result.returncode}")
            by_path = {Path(item["path"]): item for item in parsed}
            if set(by_path) != set(pending):
                raise ValueError("TypeScript parser did not classify every requested source")
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
            by_path = {path: {"mutable": [], "strict": [], "errors": [str(error)]}
                       for path in pending}
        for path, text in pending.items():
            _RN_SYNTAX_CACHE[path] = (text, by_path[path])
    return {path: _RN_SYNTAX_CACHE[path][1] for path in sources}


# Every string literal and template-literal text part goes through `_is_authored_sentence`, the
# same discriminator Swift uses, so a closed code ('invalidConfiguration'), a type literal
# ('notPerformed' | 'succeeded') or an identifier-shaped key ('passport-read-v1') is not a
# sentence and 'Hold the phone steady.' is. A real use-strict directive is language syntax, not
# prose; an identical string assigned to a variable or outside a directive prologue still counts.
def _rn_no_authored_sentence(target: str) -> list[str]:
    hits: list[str] = []
    for path in rn_files(target):
        text = path.read_text(encoding="utf-8")
        dialect = _rn_dialect(path)
        strict = _rn_strict_directives(path, text, dialect, hits)
        _, found, _ = _c_family_scan(text, dialect)
        for offset, body in found:
            if offset not in strict and _is_authored_sentence(body):
                hits.append(f'{rel(path)}:{_line_of(text, offset)} authored: "{body.strip()[:56]}"')
        hits += _rn_authored_jsx_hits(path, text, dialect)
    return hits

def _rn_authored_jsx_hits(path, text, dialect) -> list[str]:
    hits = []
    if path.name.endswith(RN_JSX_EXTENSIONS):
        code = _rn_mask(text, dialect)
        for offset, run in _jsx_text_runs(code):
            if _is_authored_sentence(run):
                start = offset + len(run) - len(run.lstrip())
                hits.append(f'{rel(path)}:{_line_of(code, start)} authored JSX text: '
                            f'"{run.strip()[:56]}"')
    return hits

def _rn_strict_directives(path: Path, text: str, dialect: str, hits: list[str]) -> set[int]:
    strict: set[int] = set()
    if dialect == "ts":
        syntax = _rn_script_syntax({path: text})[path]
        if syntax["errors"]:
            hits.append(f"{rel(path)}: unproven TypeScript syntax: {syntax['errors'][0]}")
        else:
            strict = set(syntax["strict"])
    return strict


# --- Rule 2, TypeScript and Objective-C. --------------------------------------------------------
# The Swift check exempts imports of the package's own Swift modules. There is NO counterpart here:
# the contract does not exempt a package's product name, so a neutral source that imports or spells
# `@kenshiki/...` is counted like any other vendor token.
def _rn_no_vendor_identifiers(target: str) -> list[str]:
    hits: list[str] = []
    for path in rn_files(target):
        if VENDOR.search(path.name):
            hits.append(f"{rel(path)}:0 filename carries a vendor name")
        code = _rn_mask(path.read_text(encoding="utf-8"), _rn_dialect(path), keep_literals=True)
        for number, line in enumerate(code.split("\n"), start=1):
            if VENDOR.search(line):
                hits.append(f"{rel(path)}:{number} {line.strip()[:80]}")
    return hits


# --- Rule 3, TypeScript and Objective-C: no ambient dependency. ---------------------------------
# Same classes as `AMBIENT_RE`, in each language's spelling: the clock, process environment,
# process-global stores and buses, shared network sessions, the main/global queue, and two that
# React Native adds — module-scope mutable state and `dispatch_once` singletons (a process-global
# the host never named), and native-module registries reached outside the package's codegen spec.
# The TurboModule spec directory is read from `codegenConfig.jsSrcsDir`: codegen requires
# `TurboModuleRegistry`/`codegenNativeComponent` there, and only there.
JS_AMBIENT_RE = re.compile(
    r"\bDate\s*\.\s*now\s*\(|\bnew\s+Date\s*\(\s*\)|\bperformance\s*\.\s*now\s*\("
    r"|\b(?:globalThis|global|window)\s*\.\s*[A-Za-z_$]|\bprocess\s*\.\s*env\b"
    r"|\b(?:NativeModules|TurboModuleRegistry|requireNativeComponent|codegenNativeComponent)\b"
    r"|\b(?:DeviceEventEmitter|NativeAppEventEmitter)\b|\bnew\s+NativeEventEmitter\s*\("
    r"|\bAppState\s*\.\s*(?:addEventListener|currentState)\b"
    r"|\b(?:AsyncStorage|localStorage|sessionStorage)\b"
    r"|\b(?:setTimeout|setInterval|requestAnimationFrame)\s*\("
    r"|(?<![.\w$])fetch\s*\(|\bnew\s+(?:XMLHttpRequest|WebSocket)\s*\(|\.resolvedOptions\s*\("
    r"|^\s+static\s+(?!readonly\b|async\b|get\b|set\b)[A-Za-z_$][\w$]*\s*(?::[^=;(){}]+)?=(?!=)",
    re.M)
_JS_SPEC_ONLY = re.compile(r"\b(?:TurboModuleRegistry|codegenNativeComponent)\b")
OBJC_AMBIENT_RE = re.compile(
    r"\[\s*NSDate\s+(?:date|new)\s*\]|\bNSDate\s*\.\s*date\b"
    r"|\b(?:CACurrentMediaTime|CFAbsoluteTimeGetCurrent|mach_absolute_time|mach_continuous_time)\s*\("
    r"|\[\s*NSUserDefaults\s+standardUserDefaults\s*\]|\bNSUserDefaults\s*\.\s*standardUserDefaults\b"
    r"|\[\s*NSBundle\s+mainBundle\s*\]|\bNSBundle\s*\.\s*mainBundle\b"
    r"|\[\s*NSFileManager\s+defaultManager\s*\]|\bNSFileManager\s*\.\s*defaultManager\b"
    r"|\bNS(?:Temporary|Home)Directory\s*\(|\bgetenv\s*\("
    r"|\bprocessInfo\s*\]?\s*\.?\s*(?:environment|arguments|processIdentifier|globallyUniqueString"
    r"|hostName|userName|fullUserName)\b"
    r"|\[\s*NSNotificationCenter\s+defaultCenter\s*\]|\bNSNotificationCenter\s*\.\s*defaultCenter\b"
    r"|\bdispatch_get_(?:main|global)_queue\s*\("
    r"|\[\s*NSURLSession\s+sharedSession\s*\]|\bNSURLSession\s*\.\s*sharedSession\b"
    r"|\[\s*NS(?:Locale|TimeZone|Calendar)\s+(?:current|autoupdatingCurrent|local|system)\w*\s*\]"
    r"|\bdispatch_once\s*\("
    r"|\bRCT(?:PresentedViewController|KeyWindow|SharedApplication)\s*\("
    r"|\[\s*UIApplication\s+sharedApplication\s*\]|\bUIApplication\s*\.\s*sharedApplication\b")


def _rn_no_ambient(target: str) -> list[str]:
    record = _rn_record(target)
    spec_dir = record.get("spec_dir") if record else None
    hits: list[str] = []
    for path in rn_files(target):
        text = path.read_text(encoding="utf-8")
        dialect = _rn_dialect(path)
        code = _rn_mask(text, dialect)
        lines = text.split("\n")
        hits += _rn_mutable_state_hits(path, text, dialect, lines)
        in_spec = spec_dir is not None and (path.parent == spec_dir or spec_dir in path.parents)
        for match in (JS_AMBIENT_RE if dialect == "ts" else OBJC_AMBIENT_RE).finditer(code):
            if in_spec and _JS_SPEC_ONLY.fullmatch(match.group(0).strip()):
                continue  # the codegen spec itself; see the block comment above
            number = _line_of(code, match.start())
            hits.append(f"{rel(path)}:{number} {lines[number - 1].strip()[:80]}")
    return hits

def _rn_mutable_state_hits(path: Path, text: str, dialect: str, lines: list[str]) -> list[str]:
    hits = []
    if dialect == "ts":
        syntax = _rn_script_syntax({path: text})[path]
        if syntax["errors"]:
            hits.append(f"{rel(path)}: unproven TypeScript syntax: {syntax['errors'][0]}")
        for offset in syntax["mutable"]:
            number = _line_of(text, offset)
            hits.append(f"{rel(path)}:{number} {lines[number - 1].strip()[:80]}")
    return hits


# --- Rule 4, TypeScript and Objective-C: no unattributed policy number. -------------------------
# Same shape as `POLICY_NUMBER`: a named constant or a typed number field whose value is a literal.
# There is no TypeScript or Objective-C calibration-attribution mechanism, so there is no
# exemption either — a comment naming `CalibrationProfile` buys nothing, as in Swift.
JS_POLICY_NUMBER = re.compile(
    r"(?:\b(?:const|static|readonly)\s+(?:readonly\s+)?[A-Za-z_$][\w$]*\s*(?::\s*number\s*)?=|"
    r":\s*number\s*=)\s*-?(?:\d[\d_]*(?:\.\d+)?|\.\d+)(?:[eE][-+]?\d+)?(?![\w$.])")
OBJC_POLICY_NUMBER = re.compile(
    r"^\s*#\s*define\s+\w+\s+\(?\s*-?\d"
    r"|\b(?:static|const|constexpr)\b[^;=\n(]*?\b\w+\s*=\s*\(?\s*-?\d")


def _rn_no_policy_numbers(target: str) -> list[str]:
    hits: list[str] = []
    for path in rn_files(target):
        dialect = _rn_dialect(path)
        code = _rn_mask(path.read_text(encoding="utf-8"), dialect)
        pattern = JS_POLICY_NUMBER if dialect == "ts" else OBJC_POLICY_NUMBER
        for number, line in enumerate(code.split("\n"), start=1):
            if pattern.search(line):
                hits.append(f"{rel(path)}:{number} {line.strip()[:80]}")
    return hits


# --- Rule 5, TypeScript and Objective-C: no verdict, no rendering. ------------------------------
# A verdict is a PUBLIC BOOLEAN named like a pass — the contract's own definition — tested with
# Swift's `VERDICT_PREFIX`/`VERDICT_WORD`/`VERDICT_EXEMPT`. Restricting to booleans is what keeps
# `readPassport(): Promise<PassportObservation>` from reading as "pass". Rendering is a
# display-formatted string: `Intl`, `toLocale*String`, `toFixed`/`toPrecision`, `toDate/TimeString`
# and Foundation's display formatters. ISO-8601 is a wire format and is not rendering.
_TS_BOOLEAN = r"(?:boolean|true|false)\b"
JS_BOOLEAN_MEMBER = re.compile(
    r"(?<![\w$#.])(?:get\s+|function\s+)?([A-Za-z_$][\w$]*)\s*(?:<[^<>()]*>)?\s*\([^()]*\)\s*:\s*"
    r"(?:Promise\s*<\s*)?boolean\b"
    r"|(?<![\w$#.])([A-Za-z_$][\w$]*)\s*\??\s*:\s*" + _TS_BOOLEAN
    + r"|(?<![\w$#.])([A-Za-z_$][\w$]*)\s*=\s*(?:true|false)\b"
      r"|(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\([^()]*\)|[A-Za-z_$][\w$]*)\s*"
      r"(?::\s*(?:Promise\s*<\s*)?boolean\b|=>\s*\(?\s*!)")
JS_RENDER = re.compile(
    r"\bIntl\s*\.\s*\w+|\.toLocale(?:Date|Time)?String\s*\(|\.to(?:Date|Time)String\s*\("
    r"|\.to(?:Fixed|Precision)\s*\(")
OBJC_BOOL_DECL = re.compile(
    r"[-+]\s*\(\s*BOOL\s*\)\s*(\w+)|@property\s*(?:\([^)]*\))?\s*BOOL\s+(\w+)"
    r"|\b(?:FOUNDATION_EXPORT|FOUNDATION_EXTERN|extern|RCT_EXTERN)\s+BOOL\s+(\w+)\s*\(")
OBJC_RENDER = re.compile(
    r"\bNS(?:Mutable)?AttributedString\b"
    r"|\bNS(?:Date|Number|DateComponents|DateInterval|Measurement|ByteCount|PersonNameComponents)Formatter\b"
    r"|\blocalizedStringFrom\w*")


def _verdict_named(name: str) -> bool:
    return name not in VERDICT_EXEMPT and bool(VERDICT_PREFIX.match(name) or VERDICT_WORD.search(name))


def _rn_no_verdict(target: str) -> list[str]:
    hits: list[str] = []
    for path in rn_files(target):
        dialect = _rn_dialect(path)
        code = _rn_mask(path.read_text(encoding="utf-8"), dialect)
        hits += _rn_boolean_verdict_hits(path, code, dialect)
        render = JS_RENDER if dialect == "ts" else OBJC_RENDER
        for match in render.finditer(code):
            hits.append(f"{rel(path)}:{_line_of(code, match.start())} renders: {match.group(0).strip()}")
    return hits

def _rn_boolean_verdict_hits(path: Path, code: str, dialect: str) -> list[str]:
    hits = []
    if dialect == "ts":
        for _, _, match in _ts_public_members(
                code, JS_BOOLEAN_MEMBER,
                kinds={"type", "interface", "class", "function", "const", "let", "var"}):
            name = next(group for group in match.groups() if group)
            if _verdict_named(name):
                hits.append(f"{rel(path)}:{_line_of(code, match.start())} verdict-named: {name}")
    elif path.suffix == ".h":  # the Objective-C public surface is its headers
        for match in OBJC_BOOL_DECL.finditer(code):
            name = next(group for group in match.groups() if group)
            if _verdict_named(name):
                hits.append(f"{rel(path)}:{_line_of(code, match.start())} verdict-named: {name}")
    return hits


# --- Rule 6, React Native host: the package's public entry and nothing past it. -----------------
# The class of door, in React Native's spelling:
#
#   '@pkg/sub/path', '../../pkg/src/x'   a deep import: the package's internals by module path
#   require / import() / jest.mock(...)  the same reach through a loader instead of an import
#   TurboModuleRegistry, NativeModules, requireNativeComponent, codegenNativeComponent, UIManager
#                                        the package's native surface without the package
#   a literal naming the package's native module or component (from its own `codegenConfig`)
#   @ts-ignore / @ts-expect-error / @ts-nocheck
#                                        the type checker switched off: TypeScript's `@testable`
#   obj['member'] on a member the package declares private, `new` on a private constructor
#                                        reading past access control, TypeScript's `Mirror`
#   #import of a package header its podspec does not publish
#
# plus every Swift door `_surface_escapes_in_files` already models, over the host's Swift, and the
# manifest half over the host's own build scripts: a setting that makes `@testable` compile.
JS_IMPORT_SPECIFIER = re.compile(
    r"""\bfrom\s*(['"])([^'"\n]+)\1"""
    r"""|\bimport\s*(['"])([^'"\n]+)\3"""
    r"""|\b(?:require|import)\s*\(\s*(['"])([^'"\n]+)\5\s*\)"""
    r"""|\bjest\s*\.\s*(?:mock|unmock|doMock|dontMock|setMock|requireActual|requireMock"""
    r"""|createMockFromModule)\s*\(\s*(['"])([^'"\n]+)\7""")
JS_NATIVE_REACH = re.compile(
    r"\b(?:TurboModuleRegistry|NativeModules|requireNativeComponent|codegenNativeComponent|UIManager)\b")
JS_CHECKER_SUPPRESSION = re.compile(r"@ts-(?:ignore|expect-error|nocheck)\b")
OBJC_HEADER_IMPORT = re.compile(r"#\s*(?:import|include)\s*[<\"]([^>\"]+)[>\"]")
GENERIC_TESTABILITY = re.compile(r"ENABLE_TESTABILITY['\"\]\s]*(?:=>|=|:)\s*['\"]?(?:YES|true)",
                                 re.IGNORECASE)


def _js_import_specifiers(path: Path) -> list[tuple[int, str]]:
    code = _rn_mask(path.read_text(encoding="utf-8"), "ts", keep_literals=True)
    out = []
    for match in JS_IMPORT_SPECIFIER.finditer(code):
        specifier = next(group for index, group in enumerate(match.groups()) if index % 2 and group)
        out.append((_line_of(code, match.start()), specifier))
    return out


def _resolve_js_specifier(path: Path, specifier: str) -> Path | None:
    if specifier.startswith("."):
        return Path(os.path.normpath(path.parent / specifier))
    if specifier.startswith("/"):
        return Path(os.path.normpath(specifier))
    return None


def _within(path: Path, directory: Path) -> bool:
    return path == directory or directory in path.parents


def _js_class_bodies(code: str):
    """Find class names and balanced bodies without overlapping identifier/body regex runs."""
    declaration = re.compile(r"\bclass\s+([A-Za-z_$][\w$]*)")
    cursor = 0
    while cursor < len(code):
        match = declaration.search(code, cursor)
        if match is None:
            return
        opening = code.find("{", match.end())
        if opening == -1:
            return
        # Match the previous declaration scanner: its next search starts after this opening,
        # so nested classes remain visible even while this body's bounds are measured.
        cursor = opening + 1
        depth, end = 1, cursor
        while end < len(code) and depth:
            depth += (code[end] == "{") - (code[end] == "}")
            end += 1
        yield match.group(1), code[cursor:end]


def _package_private_surface(record: dict) -> tuple[set[str], set[str], set[str]]:
    """(private member names, classes with a private constructor, unpublished header names)."""
    members: set[str] = set()
    classes: set[str] = set()
    for path in _rn_source_files(record["directories"], RN_SCRIPT_EXTENSIONS):
        code = _rn_mask(path.read_text(encoding="utf-8"), "ts")
        members |= set(re.findall(r"\b(?:private|protected)\s+(?:readonly\s+|static\s+|async\s+)*"
                                  r"(?!constructor\b)([A-Za-z_$][\w$]*)", code))
        members |= set(re.findall(r"(?<![\w$])#([A-Za-z_$][\w$]*)", code))
        for name, body in _js_class_bodies(code):
            if re.search(r"\b(?:private|protected)\s+constructor\b", body):
                classes.add(name)
    headers = {path.name for path in _rn_source_files(record["directories"], (".h",))}
    published: set[str] = set()
    for podspec in record["directory"].glob("*.podspec"):
        for _, pattern in re.findall(r"public_header_files\s*=\s*(['\"])([^'\"]+)\1",
                                     podspec.read_text(encoding="utf-8")):
            published |= {match.name for match in record["directory"].glob(pattern)}
    private_headers = headers - published if published else set()
    return members, classes, private_headers


def _rn_surface_escapes(target: str, files: list[Path] | None = None) -> list[str]:
    """Rule 6 over a React Native host's scripts and Objective-C; `files` overrides which ones, so
    `--report` can score the skipped test files with the same implementation."""
    record = _rn_record(target)
    if record is None or record["role"] != "host":
        return []
    packages = [package for package in _npm_records() if package["role"] == "neutral"]
    native_names: set[str] = set()
    private_members: set[str] = set()
    private_classes: set[str] = set()
    private_headers: set[str] = set()
    for package in packages:
        native_names |= package["native_names"]
        members, classes, headers = _package_private_surface(package)
        private_members |= members
        private_classes |= classes
        private_headers |= headers
    hits: list[str] = []
    for path in rn_files(target) if files is None else files:
        text = path.read_text(encoding="utf-8")
        dialect = _rn_dialect(path)
        code = _rn_mask(text, dialect)
        literal_code = _rn_mask(text, dialect, keep_literals=True)
        if dialect == "objc":
            hits += _objc_surface_hits(path, code, literal_code, private_headers)
            continue
        hits += _rn_import_surface_hits(path, packages)
        hits += _rn_native_surface_hits(path, text, code, dialect, native_names)
        hits += _rn_private_surface_hits(path, code, literal_code, private_members, private_classes)
    return hits


def _objc_surface_hits(path, code, literal_code, private_headers) -> list[str]:
    hits = []
    for match in OBJC_HEADER_IMPORT.finditer(literal_code):
        if Path(match.group(1)).name in private_headers:
            hits.append(f"{rel(path)}:{_line_of(code, match.start())} imports unpublished "
                        f"package header {match.group(1)}")
    for number, line in enumerate(code.split("\n"), start=1):
        hits += [f"{rel(path)}:{number} reaches past access control at runtime: {token}"
                 for token in DYNAMIC_REACH if token in line]
    return hits


def _rn_import_surface_hits(path, packages) -> list[str]:
    hits = []
    for number, specifier in _js_import_specifiers(path):
        for package in packages:
            name = package["name"]
            if name and specifier.startswith(name + "/"):
                hits.append(f"{rel(path)}:{number} deep import past the public entry: {specifier}")
            resolved = _resolve_js_specifier(path, specifier)
            if resolved is not None and _within(resolved, package["directory"]):
                hits.append(f"{rel(path)}:{number} imports package source by path: {specifier}")
    return hits


def _rn_native_surface_hits(path, text, code, dialect, native_names) -> list[str]:
    hits = []
    for match in JS_NATIVE_REACH.finditer(code):
        hits.append(f"{rel(path)}:{_line_of(code, match.start())} reaches the native surface "
                    f"past the package API: {match.group(0)}")
    comments, found, _ = _c_family_scan(text, dialect)
    for offset, body in found:
        if body in native_names:
            hits.append(f"{rel(path)}:{_line_of(text, offset)} names the package's native "
                        f"module or component: {body}")
    for offset, body in comments:
        for match in JS_CHECKER_SUPPRESSION.finditer(body):
            hits.append(f"{rel(path)}:{_line_of(text, offset)} type checker suppressed: {match.group(0)}")
    return hits


def _rn_private_surface_hits(path, code, literal_code, private_members, private_classes) -> list[str]:
    hits = []
    for name in sorted(private_members):
        for match in re.finditer(r"\[\s*(['\"`])" + re.escape(name) + r"\1\s*\]", literal_code):
            hits.append(f"{rel(path)}:{_line_of(code, match.start())} reads private member "
                        f"through brackets: {name}")
    for name in sorted(private_classes):
        for match in re.finditer(r"\bnew\s+" + re.escape(name) + r"\s*[(<]", code):
            hits.append(f"{rel(path)}:{_line_of(code, match.start())} calls a private "
                        f"constructor: {name}")
    return hits


def _rn_host_manifest_escapes(record: dict) -> list[str]:
    """The manifest half of Rule 6 for a React Native host: its own build scripts. The same two
    spellings `_project_surface_escapes` looks for in a `project.yml`."""
    hits: list[str] = []
    directory = record["directory"]
    if not directory.is_dir():
        return hits
    for path in _rn_source_files([directory], RN_HOST_BUILD_FILES):
        text = path.read_text(encoding="utf-8")
        if GENERIC_TESTABILITY.search(text):
            hits.append(f"{rel(path)}:0 ENABLE_TESTABILITY is set, so @testable would compile")
        if "-enable-testing" in text:
            hits.append(f"{rel(path)}:0 -enable-testing is passed, so @testable would compile")
    return hits


# --- React Native host: the look and the words come from their files (plan 6a, owner, 2026-10-09).
# A host owns its words and its look; Rules 1 and 5 bind the SDK, not the host. The reference app
# keeps both in two source files — `ui/tokens.jsonc` and `locales/<language>.jsonc` — which its own
# generator compiles into typed modules the screens import. This check is what keeps them there.
# In every other script of a React Native host it refuses:
#
#   a color literal                  a hex string, rgb()/hsl()/hwb(), or a CSS named color
#   a color built in place           PlatformColor(...) or DynamicColorIOS(...): a token written
#                                    into a screen is still a hard-coded token
#   a typographic or spacing number  fontSize, lineHeight, letterSpacing, any *Radius, a border
#                                    width, padding, margin or gap given as a number, and a
#                                    fontWeight given as a string
#   a user-facing sentence           any string literal, template text or JSX text that
#                                    `_is_authored_sentence` reads as prose, Rule 1b's own model
#
# Test files are not scanned, as for Rule 6. The GENERATED MODULES are exempt by declaration in
# `RN_HOST_UI_RESOURCES` — a path list, like every exemption here — and the exemption is paid for:
# `_rn_host_ui_conflicts()` runs the declared generator's `--check`, and a generated module that
# differs from what its source files produce is a fatal conflict. Hand-writing a literal into a
# generated module therefore buys a conflict, not an exemption.
#
# GENERATED UI DATA, ADDED 2026-10-09 WITH THE SENSOR BOARD PORT. A host may also read words and
# layout numbers from JSON another generator produces: the sensor screens show SensorHost's own copy,
# configuration and documentation pages, copied from `Hosts/SensorHost/Sources` by
# `sensor-presentation/generate.py` so the React Native board says exactly what the Swift one does.
# JSON is not a script, so no check reads its words — which makes an undeclared JSON file the cheapest
# way past this one. So a host script importing JSON that no declaration names is a finding, and a
# declared JSON resource is held to its generator's `--check` exactly as a generated module is. A
# host declares as many generators as it has; each is checked on its own.
RN_HOST_UI_RESOURCES = {
    REFERENCE_HOST_PATH: (
        {"generator": "generate-ui-resources.py",
         "generated": (GENERATED_TOKEN_PATH, "locales/strings.generated.ts")},
        {"generator": "sensor-presentation/generate.py",
         "generated": ("sensor-presentation/config.json", "sensor-presentation/copy.json",
                       "sensor-presentation/pages.json")},
    ),
}
# Data a generated declaration may name besides scripts, and that a host script may import only
# when declared.
RN_UI_DATA_EXTENSIONS = (".json",)
CSS_NAMED_COLORS = frozenset("""
    aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet
    brown burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue
    darkcyan darkgoldenrod darkgray darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange
    darkorchid darkred darksalmon darkseagreen darkslateblue darkslategray darkslategrey darkturquoise
    darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue firebrick floralwhite forestgreen
    fuchsia gainsboro ghostwhite gold goldenrod gray green greenyellow grey honeydew hotpink indianred
    indigo ivory khaki lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan
    lightgoldenrodyellow lightgray lightgreen lightgrey lightpink lightsalmon lightseagreen
    lightskyblue lightslategray lightslategrey lightsteelblue lightyellow lime limegreen linen magenta
    maroon mediumaquamarine mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue
    mediumspringgreen mediumturquoise mediumvioletred midnightblue mintcream mistyrose moccasin
    navajowhite navy oldlace olive olivedrab orange orangered orchid palegoldenrod palegreen
    paleturquoise palevioletred papayawhip peachpuff peru pink plum powderblue purple rebeccapurple red
    rosybrown royalblue saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue slateblue
    slategray slategrey snow springgreen steelblue tan teal thistle tomato turquoise violet wheat white
    whitesmoke yellow yellowgreen transparent
""".split())
HEX_COLOR = re.compile(r"#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})")
FUNCTIONAL_COLOR = re.compile(r"\b(?:rgba?|hsla?|hwb)\s*\(", re.IGNORECASE)
JS_COLOR_CONSTRUCTION = re.compile(r"\b(?:PlatformColor|DynamicColorIOS)\s*\(")
JS_STYLE_NUMBER = re.compile(
    r"(?<![\w$.])(fontSize|lineHeight|letterSpacing|[A-Za-z]*[Rr]adius"
    r"|border(?:Top|Bottom|Left|Right|Start|End|Horizontal|Vertical)?Width"
    r"|(?:padding|margin)(?:Top|Bottom|Left|Right|Start|End|Horizontal|Vertical|Block|Inline)?"
    r"|gap|rowGap|columnGap)\s*:\s*-?(?:\d|\.\d)")
JS_FONT_WEIGHT = re.compile(r"(?<![\w$.])fontWeight\s*:\s*['\"`]")


def _rn_host_generated_files(host: str) -> set[Path]:
    directory = Path(os.path.normpath(ROOT / host))
    return {Path(os.path.normpath(directory / written))
            for resources in RN_HOST_UI_RESOURCES.get(host, ())
            for written in resources["generated"]}


def _rn_host_inline_ui(target: str) -> list[str]:
    """A color, type or spacing value, or a sentence, written into a React Native host's script
    instead of its token and locale files."""
    record = _rn_record(target)
    if record is None or record["role"] != "host":
        return []
    generated = _rn_host_generated_files(target)
    hits: list[str] = []
    for path in rn_files(target):
        if _rn_dialect(path) != "ts" or path in generated:
            continue
        text = path.read_text(encoding="utf-8")
        code = _rn_mask(text, "ts")
        literal_code = _rn_mask(text, "ts", keep_literals=True)
        hits += _rn_inline_literal_hits(path, text)
        hits += _rn_inline_jsx_hits(path, code)
        hits += _rn_inline_style_hits(path, code, literal_code)
        hits += _rn_undeclared_data_hits(path, generated)
    return hits

def _rn_inline_literal_hits(path, text) -> list[str]:
    hits = []
    _, found, _ = _c_family_scan(text, "ts")
    for offset, body in found:
        stripped = body.strip()
        if (HEX_COLOR.fullmatch(stripped) or FUNCTIONAL_COLOR.search(stripped)
                or stripped.lower() in CSS_NAMED_COLORS):
            hits.append(f'{rel(path)}:{_line_of(text, offset)} color literal: "{stripped[:40]}"')
        elif _is_authored_sentence(body):
            hits.append(f'{rel(path)}:{_line_of(text, offset)} user-facing sentence: "{stripped[:56]}"')
    return hits


def _rn_inline_jsx_hits(path, code) -> list[str]:
    hits = []
    if path.name.endswith(RN_JSX_EXTENSIONS):
        for offset, run in _jsx_text_runs(code):
            if _is_authored_sentence(run):
                start = offset + len(run) - len(run.lstrip())
                hits.append(f'{rel(path)}:{_line_of(code, start)} user-facing JSX text: '
                            f'"{run.strip()[:56]}"')
    return hits


def _rn_inline_style_hits(path, code, literal_code) -> list[str]:
    hits = []
    for match in JS_COLOR_CONSTRUCTION.finditer(code):
        hits.append(f"{rel(path)}:{_line_of(code, match.start())} color built outside the token "
                    f"module: {match.group(0).strip()}")
    for match in JS_STYLE_NUMBER.finditer(code):
        hits.append(f"{rel(path)}:{_line_of(code, match.start())} style number outside the token "
                    f"module: {match.group(1)}")
    for match in JS_FONT_WEIGHT.finditer(literal_code):
        hits.append(f"{rel(path)}:{_line_of(code, match.start())} font weight outside the token "
                    "module")
    return hits


def _rn_undeclared_data_hits(path, generated) -> list[str]:
    hits = []
    for number, specifier in _js_import_specifiers(path):
        resolved = _resolve_js_specifier(path, specifier)
        if (resolved is not None and resolved.name.endswith(RN_UI_DATA_EXTENSIONS)
                and resolved not in generated):
            hits.append(f"{rel(path)}:{number} imports UI data no generator declares: {specifier}")
    return hits


def _rn_host_ui_conflicts() -> list[str]:
    """THE GENERATED-MODULE EXEMPTION, CHECKED. Fatal and unbaselined: a generated module that its
    generator would not produce is hand-written code claiming an exemption."""
    conflicts: list[str] = []
    for host, declarations in sorted(RN_HOST_UI_RESOURCES.items()):
        if host not in REACT_NATIVE_HOSTS:
            conflicts.append(f"{host}: RN_HOST_UI_RESOURCES names a directory REACT_NATIVE_HOSTS does "
                             "not declare")
            continue
        directory = Path(os.path.normpath(ROOT / host))
        for resources in declarations:
            conflicts += _rn_generated_resource_conflicts(host, directory, resources)
    return conflicts

def _rn_generated_resource_conflicts(host, directory, resources) -> list[str]:
    conflicts = []
    generator = Path(os.path.normpath(directory / resources["generator"]))
    if not _within(generator, directory) or not generator.is_file():
        conflicts.append(f"{host}: the declared generator {resources['generator']} does not exist")
        return conflicts
    for written in resources["generated"]:
        path = Path(os.path.normpath(directory / written))
        if (not _within(path, directory)
                or not path.name.endswith(RN_SCRIPT_EXTENSIONS + RN_UI_DATA_EXTENSIONS)):
            conflicts.append(f"{host}: generated file {written} is not a script or JSON data "
                             "inside the host")
        elif not path.is_file():
            conflicts.append(f"{host}: generated file {written} does not exist")
    result = subprocess.run([sys.executable, str(generator), "--check"], cwd=directory,
                            capture_output=True, text=True)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        conflicts.append(f"{host}: {resources['generator']} --check failed, so the files it "
                         f"exempts are stale or unproven: "
                         f"{detail[-1] if detail else 'exit ' + str(result.returncode)}")
    return conflicts


def _react_native_conflicts() -> list[str]:
    """THE REACT NATIVE CLASSIFICATION, CHECKED. Fatal and unbaselined for the reason the XcodeGen
    and SwiftPM conflicts are: there is no honest number for a target whose role is unknown, or for
    a host exemption whose price — nothing can import it — has not been paid."""
    conflicts: list[str] = []
    packages = _npm_records()
    hosts = _rn_host_records()
    conflicts += _rn_syntax_conflicts(packages)
    conflicts += _rn_package_role_conflicts(packages)
    conflicts += _rn_tooling_conflicts(packages, hosts)
    conflicts += _rn_host_role_conflicts(packages, hosts)
    host_directories = [host["directory"] for host in hosts]
    # XcodeGen test bundles are excluded from every rule (`XCODEGEN_TEST_TYPES`), so TypeScript
    # inside one — a schema fixture a Swift test reads by path — is a seen file in an excluded
    # target, not a file outside every rule. A neutral package still may not import from one.
    test_directories = [directory for record in _xcodegen_records() if record["role"] == "test"
                        for directory in record["directories"]]
    conflicts += _rn_neutral_import_conflicts(packages, host_directories, test_directories)
    conflicts += _rn_coverage_conflicts(packages, host_directories, test_directories)
    return conflicts + _rn_host_ui_conflicts()


def _rn_syntax_conflicts(packages) -> list[str]:
    conflicts = []
    scripts = {path: path.read_text(encoding="utf-8")
               for package in packages if package["role"] == "neutral"
               for path in _rn_source_files(package["directories"], RN_SCRIPT_EXTENSIONS)}
    for path, syntax in _rn_script_syntax(scripts).items():
        for error in syntax["errors"]:
            conflicts.append(f"{rel(path)}: cannot establish TypeScript syntax: {error}")
    return conflicts


def _rn_package_role_conflicts(packages) -> list[str]:
    conflicts = []
    for package in packages:
        if package["role"] == "unknown":
            conflicts.append(f"{rel(package['manifest'])}: {package['why']} — classify it in "
                             "boundary_gates.py")
        elif package["role"] == "tooling":
            continue
        elif not package["directories"]:
            conflicts.append(f"{rel(package['manifest'])}: ships no readable source directory, so the "
                             "neutral rules would scan nothing")
    return conflicts


def _rn_tooling_conflicts(packages, hosts) -> list[str]:
    conflicts = []
    # THE PRICE OF THE TOOLING CLASSIFICATION, CHECKED. See the block above `NPM_MANIFEST`.
    by_key = {package["key"]: package for package in packages}
    shipped = [directory for package in packages if package["role"] == "neutral"
               for directory in package["directories"]] + [host["directory"] for host in hosts]
    for declared in RN_TOOLING_MANIFESTS:
        package = by_key.get(declared)
        if package is None:
            conflicts.append(f"{declared}: RN_TOOLING_MANIFESTS names a directory with no package.json")
            continue
        if package["role"] != "tooling":
            conflicts.append(f"{rel(package['manifest'])}: declared repository tooling in "
                             "RN_TOOLING_MANIFESTS but is not \"private\": true, so it can be published")
            continue
        document = package["document"]
        for field in ("codegenConfig", "workspaces"):
            if field in document:
                conflicts.append(f"{rel(package['manifest'])}: declared repository tooling but declares "
                                 f"`{field}`, which builds or links what it governs")
        if any(_within(package["directory"], directory) for directory in shipped):
            conflicts.append(f"{rel(package['manifest'])}: declared repository tooling inside a shipped "
                             "or host directory")
    return conflicts


def _rn_host_role_conflicts(packages, hosts) -> list[str]:
    conflicts = []
    neutral = target_roots()
    for host in hosts:
        key, directory = host["key"], host["directory"]
        if not _rn_source_files(host["directories"], RN_SCRIPT_EXTENSIONS):
            conflicts.append(f"{key}: declared in REACT_NATIVE_HOSTS but holds no script sources, so "
                             "Rule 6 would scan nothing")
            continue
        conflicts += _rn_host_build_conflicts(key, directory, packages, neutral)
        conflicts += _rn_host_test_conflicts(key, directory)
        conflicts += _rn_host_test_import_conflicts(key, host)
    return conflicts

def _rn_host_build_conflicts(key, directory, packages, neutral) -> list[str]:
    conflicts = []
    for package in packages:
        if package["role"] != "tooling" and _within(directory, package["directory"]):
            conflicts.append(f"{key}: {rel(package['manifest'])} governs it, so it is an npm "
                             "package, not a host")
    for manifest in (SWIFT_MANIFEST_NAME,) + XCODEGEN_MANIFEST_NAMES:
        if (directory / manifest).exists():
            conflicts.append(f"{key}: holds a {manifest}, so it is also a Swift build target")
    for neutral_key, neutral_directory in neutral:
        if _within(directory, neutral_directory) or _within(neutral_directory, directory):
            conflicts.append(f"{key}: source root overlaps neutral target {neutral_key}")
    return conflicts


def _rn_host_test_conflicts(key, directory) -> list[str]:
    conflicts = []
    # THE PRICE OF SKIPPING A TEST FILE, CHECKED. See `RN_HOST_UI_TESTS`.
    for name in RN_HOST_UI_TESTS.get(key, ()):
        test = directory / name
        if not test.is_file():
            conflicts.append(f"{key}: RN_HOST_UI_TESTS declares {name}, which does not exist")
            continue
        imports = {match.group(1) for match in map(IMPORT_RE.match,
                   mask(test.read_text(encoding="utf-8")).split("\n")) if match}
        if "XCTest" not in imports:
            conflicts.append(f"{rel(test)}: declared a UI test in RN_HOST_UI_TESTS but imports "
                             "no XCTest")
    return conflicts


def _rn_host_test_import_conflicts(key, host) -> list[str]:
    conflicts = []
    for path in _rn_source_files(host["directories"], RN_SCRIPT_EXTENSIONS):
        if _rn_host_test_file(key, path):
            continue
        for number, specifier in _js_import_specifiers(path):
            resolved = _resolve_js_specifier(path, specifier)
            if resolved is not None and resolved.name.endswith((".test",) + RN_HOST_TEST_SUFFIXES):
                conflicts.append(f"{rel(path)}:{number} host source imports test file "
                                 f"{specifier}; a test file is skipped only while nothing that "
                                 "ships can reach it")
    return conflicts


def _rn_neutral_import_conflicts(packages, host_directories, test_directories) -> list[str]:
    conflicts = []
    for package in packages:
        if package["role"] != "neutral":
            continue
        for path in _rn_source_files(package["directories"], RN_SCRIPT_EXTENSIONS):
            conflicts += _rn_forbidden_import_hits(path, host_directories, test_directories)
    return conflicts

def _rn_forbidden_import_hits(path, host_directories, test_directories) -> list[str]:
    conflicts = []
    for number, specifier in _js_import_specifiers(path):
        resolved = _resolve_js_specifier(path, specifier)
        if resolved is not None and any(_within(resolved, d) for d in host_directories):
            conflicts.append(f"{rel(path)}:{number} neutral package imports host source "
                             f"{specifier}")
        if resolved is not None and any(_within(resolved, d) for d in test_directories):
            conflicts.append(f"{rel(path)}:{number} neutral package imports test-bundle "
                             f"source {specifier}")
    return conflicts


def _rn_coverage_conflicts(packages, host_directories, test_directories) -> list[str]:
    conflicts = []
    covered = ([package["directory"] for package in packages if package["role"] != "tooling"]
               + host_directories + test_directories)
    for directory, files in _rn_walk(ROOT):
        for name in files:
            if name.endswith(RN_TYPESCRIPT_EXTENSIONS) and not any(_within(directory, c) for c in covered):
                conflicts.append(f"{rel(directory / name)}: TypeScript outside every rule — no "
                                 "package.json governs it, REACT_NATIVE_HOSTS does not declare it, "
                                 "and no XcodeGen test bundle holds it")
    return conflicts


def _with_react_native(swift_check, rn_check):
    """One counter per rule per target, whatever languages the target is written in."""
    def check(target: str) -> list[str]:
        return swift_check(target) + rn_check(target)
    check.__name__ = swift_check.__name__
    return check


CHECKS = {
    "no_prose": (_with_react_native(check_no_prose, _rn_no_prose),
                 "Rule 1a - no error-description prose channel"),
    "no_authored_sentence": (_with_react_native(check_no_authored_sentence, _rn_no_authored_sentence),
                             "Rule 1b - no sentence the SDK wrote"),
    "no_vendor_identifiers": (_with_react_native(check_no_vendor_identifiers, _rn_no_vendor_identifiers),
                              "Rule 2 - no vendor wire format"),
    "no_ambient": (_with_react_native(check_no_ambient, _rn_no_ambient),
                   "Rule 3 - no ambient dependency"),
    "no_policy_numbers": (_with_react_native(check_no_policy_numbers, _rn_no_policy_numbers),
                          "Rule 4 - no unattributed policy number"),
    "no_verdict": (_with_react_native(check_no_verdict, _rn_no_verdict),
                   "Rule 5 - no verdict, no rendering"),
}
GLOBAL_CHECKS = {"layer_direction": (check_layer_direction, "Layer - the leaf stays a leaf")}
SURFACE_CHECKS = {"no_surface_escape": (_with_react_native(check_no_surface_escape, _rn_surface_escapes),
                                        "Rule 6 - the host reaches past no public surface")}
# React Native hosts only; see the block above `RN_HOST_UI_RESOURCES`.
HOST_UI_CHECKS = {"no_inline_ui": (_rn_host_inline_ui,
                                   "Host UI - look and words come from the token and locale files")}
# Every neutral rule a host or a profile is exempt from, named once.
#
# RULE 3 JOINED THIS SET ON 2026-09-17, BY OWNER DECISION, having been deliberately excluded until
# then. The excluding argument was that naming a location is the host's job but so is naming it
# EXPLICITLY. That reads the rule backwards. Rule 3 says, in the contract's own words, "the host
# names every location; the SDK opens it" — it governs the second clause. A host reading
# `Bundle.main`, `UserDefaults.standard` or the system clock is not reaching past a boundary for
# state someone should have handed it: it IS the process, those ARE its bundle, its defaults and
# the real time, and reading them is precisely the naming Rule 3 exists to demand OF it.
#
# The exclusion had a measurable cost, which is how it was caught. `Hosts/ExampleHostApp` injected
# a frozen clock — `Date(timeIntervalSince1970: 1_767_225_600)` — and its doc comment said outright
# that it did so "because Rule 3 applies to this target as well". The one target whose entire job
# is to model what an adopter writes was modelling an application that never learns what time it
# is, which no adopter can copy. The gate had stopped measuring the example and started shaping it.
#
# A CONSEQUENCE TO KEEP IN VIEW: this set is now every key in CHECKS, so a host and a profile are
# scanned by SURFACE_CHECKS alone. What still separates the two roles is not the scan —
# `classification_conflicts()` is fatal for a host and has no profile equivalent, because a profile
# cannot reach the halfway state an executable can.
HOST_EXEMPT = {"no_prose", "no_authored_sentence", "no_vendor_identifiers",
               "no_policy_numbers", "no_verdict", "no_ambient"}


def scan_plan() -> list[tuple[str, dict]]:
    """Every scanned target with the checks that govern it.

    One place, so `--report`, `measure()` and the baselines can never disagree about which rule
    applies to which target — a disagreement there is how an exemption goes unnoticed.
    """
    plan: list[tuple[str, dict]] = []
    seen: set[str] = set()
    for key, _, role in _inventory():
        if key in seen:
            continue  # one counter per target, however many source directories it owns
        seen.add(key)
        if role == "neutral":
            applicable = dict(CHECKS)
        elif role == "host":
            applicable = {name: check for name, check in CHECKS.items() if name not in HOST_EXEMPT}
            applicable.update(SURFACE_CHECKS)
            if key in REACT_NATIVE_HOSTS:
                applicable.update(HOST_UI_CHECKS)
        else:
            applicable = dict(SURFACE_CHECKS)
        plan.append((key, applicable))
    return plan


def measure() -> dict[str, int]:
    counts: dict[str, int] = {}
    for target, applicable in scan_plan():
        for name, (fn, _) in applicable.items():
            counts[f"{name}::{target}"] = len(fn(target))
    for name, (fn, _) in GLOBAL_CHECKS.items():
        counts[name] = len(fn())
    return counts


def load_baseline() -> dict:
    return json.loads(BASELINE_PATH.read_text()) if BASELINE_PATH.exists() else {}


def self_test() -> None:
    """Capture regression probes exercise this SAME rule implementation, not a parallel gate."""
    assert scoped_baseline({"r::a": 2, "r::b": 99}, {"r::a": 3, "r::b": 1}, ["a"]) == {"r::a": 2, "r::b": 1}
    assert scoped_baseline({"r::a": 2}, {}, ["a"]) == {"r::a": 2}
    for current, baseline, targets in [
        ({"r::a": 3}, {"r::a": 2}, ["a"]),
        ({"r::a": 3}, {}, ["missing"]),
        ({"r::a": 1}, {"r::a": 1, "s::a": 1}, ["a"]),
    ]:
        try:
            scoped_baseline(current, baseline, targets)
        except ValueError:
            pass
        else:
            raise AssertionError("unsafe scoped baseline banking admitted")
    # A scoped RE-ESTABLISH touches only the named targets: it may raise, add and drop THEIR
    # counters (the check changed for them), and copies every other counter as banked — neither
    # an improvement nor a regression elsewhere rides along.
    assert scoped_establish({"r::a": 5, "s::a": 1, "r::b": 0, "r::c": 9},
                            {"r::a": 2, "t::a": 4, "r::b": 3, "r::c": 1}, ["a"]) == \
        {"r::a": 5, "s::a": 1, "r::b": 3, "r::c": 1}
    try:
        scoped_establish({"r::a": 1}, {"r::a": 1}, ["missing"])
    except ValueError:
        pass
    else:
        raise AssertionError("a scoped establish must name a known target")
    global ROOT, SOURCES, MANIFEST, BASELINE_PATH, REACT_NATIVE_HOSTS
    global VENDOR_ADAPTERS, THIRD_PARTY_PACKAGES, RN_HOST_UI_TESTS, RN_HOST_UI_RESOURCES
    global RN_TOOLING_MANIFESTS
    original = (ROOT, SOURCES, MANIFEST, BASELINE_PATH, REACT_NATIVE_HOSTS,
                VENDOR_ADAPTERS, THIRD_PARTY_PACKAGES, RN_HOST_UI_TESTS, RN_HOST_UI_RESOURCES,
                RN_TOOLING_MANIFESTS)
    with tempfile.TemporaryDirectory(prefix="identity-boundary-probes-") as temporary:
        try:
            fixture, source, target = _probe_initialize_workspace(temporary)
            _probe_neutral_rules(fixture, source, target)
            _probe_module_imports(fixture, target)
            _probe_target_discovery()
            good_host, host_file, library, neutral = _probe_swift_hosts(fixture)
            _probe_vendor_profiles(good_host, library, neutral)
            _probe_xcodegen_hosts(good_host, library, neutral)
            _probe_persisted_stores(host_file)
            clean_ts, source, stray = _probe_react_native_package()
            app_source, clean_host, host_directory, host_key, surface = _probe_react_native_host(clean_ts, source)
            _probe_repository_tooling(host_directory, stray)
            jest_test = _probe_host_test_files(app_source, clean_host, host_directory, host_key, surface)
            _probe_xcodegen_test_files(clean_ts, source)
            _probe_host_presentation(app_source, clean_host, host_directory, host_key, jest_test)
            _probe_vendor_adapters(fixture, good_host, library, neutral)
            _probe_third_party_packages()
        finally:
            (ROOT, SOURCES, MANIFEST, BASELINE_PATH, REACT_NATIVE_HOSTS,
             VENDOR_ADAPTERS, THIRD_PARTY_PACKAGES, RN_HOST_UI_TESTS, RN_HOST_UI_RESOURCES,
             RN_TOOLING_MANIFESTS) = original
    print("Boundary regression probes passed, including distributable framework classification, "
          "the React Native package and host, vendor adapters and third-party code")


def scoped_baseline(current: dict[str, int], baseline: dict[str, int], targets: list[str]) -> dict[str, int]:
    """Bank named target counters without changing any other target's ceiling."""
    known = {key.split("::", 1)[1] for key in current if "::" in key}
    missing = set(targets) - known
    if missing:
        raise ValueError("unknown baseline target(s): " + ", ".join(sorted(missing)))
    selected = {key: value for key, value in current.items()
                if "::" in key and key.split("::", 1)[1] in targets}
    raised = [key for key, value in selected.items() if key in baseline and value > baseline[key]]
    if raised:
        raise ValueError("REFUSED baseline raise: " + ", ".join(sorted(raised)))
    vanished = [key for key in baseline if "::" in key and key.split("::", 1)[1] in targets and key not in current]
    if vanished:
        raise ValueError("REFUSED scoped removal; review vanished counters with full --write-baseline")
    return {**baseline, **selected}


def scoped_establish(current: dict[str, int], baseline: dict[str, int],
                     targets: list[str]) -> dict[str, int]:
    """Re-establish ONLY the named targets' counters, for when a CHECK's meaning changed for them.

    Unlike `scoped_baseline`, this may raise a named target's counter, add its new counters and drop
    its vanished ones — that is what re-establishing means — so it is reserved for `--establish`.
    Every other target's counters are copied from the banked file untouched, so an improvement
    elsewhere is not banked and a regression elsewhere is not admitted by the same command.
    """
    def target_of(key: str) -> str | None:
        return key.split("::", 1)[1] if "::" in key else None
    known = {target_of(key) for key in current} | {target_of(key) for key in baseline}
    missing = set(targets) - known
    if missing:
        raise ValueError("unknown baseline target(s): " + ", ".join(sorted(missing)))
    kept = {key: value for key, value in baseline.items() if target_of(key) not in targets}
    selected = {key: value for key, value in current.items() if target_of(key) in targets}
    return {**kept, **selected}


def main() -> int:
    args = _parse_boundary_arguments()
    if args.self_test:
        self_test()
        return 0
    targets = neutral_targets()
    if not targets:
        print("no scannable targets — is Package.swift mid-edit?")
        return 1
    if _report_classification_conflicts(args.report) == 1:
        return 1
    if _report_persistence_gaps(args.report) == 1:
        return 1
    if args.report:
        return _report_boundary_scan(targets)
    current = measure()
    baseline = load_baseline()
    updated = _update_boundary_baseline(args, current, baseline)
    if updated is not None:
        return updated
    return _evaluate_boundary_measurements(current, baseline)



def _yaml_mapping_value(lines, cursor, indent, tail, number):
    if tail.strip():
        return _yaml_scalar(tail, number), cursor
    if cursor >= len(lines):
        return None, cursor
    if lines[cursor][0] > indent:
        return _yaml_block(lines, cursor, lines[cursor][0])
    if lines[cursor][0] == indent and lines[cursor][1].startswith('- '):
        return _yaml_sequence(lines, cursor, indent)
    return None, cursor

def _yaml_sequence_entry(lines, cursor, indent):
    level, text, number = lines[cursor]
    body = text[1:].strip()
    if not body:
        cursor += 1
        if cursor < len(lines) and lines[cursor][0] > indent:
            return _yaml_block(lines, cursor, lines[cursor][0])
        return None, cursor
    body_indent = level + (len(text) - len(text[1:].lstrip()))
    head, separator, _ = body.partition(':')
    if separator and not head.strip().startswith(('[', "'", '"')):
        work = list(lines)
        work[cursor] = (body_indent, body, number)
        return _yaml_mapping(work, cursor, body_indent)
    return _yaml_scalar(body, number), cursor + 1

def _append_xcodegen_source(entry, project_root, directories):
    written = entry.get('path') if isinstance(entry, dict) else entry
    if not written:
        return None
    candidate = Path(os.path.normpath(project_root / str(written)))
    if candidate.is_dir():
        directories.append(candidate)

def _append_xcodegen_target(name, body, manifest, project_root, label, document, records):
    body = body if isinstance(body, dict) else {}
    if 'template' in body or 'templates' in body:
        raise YamlSubsetError(f'{rel(manifest)}: target {name} uses a target template, whose `type:` and `sources:` this parser does not resolve')
    body = dict(body, __name__=name)
    kind = str(body.get('type') or '')
    if kind in XCODEGEN_HOST_TYPES:
        role = 'host'
    elif kind in XCODEGEN_TEST_TYPES:
        role = 'test'
    elif kind in XCODEGEN_NEUTRAL_TYPES:
        role = 'neutral'
    else:
        role = 'unknown'
    directories: list[Path] = []
    for entry in _xcodegen_source_paths(body):
        _append_xcodegen_source(entry, project_root, directories)
    records.append({'key': f'{label}/{name}' if label else name, 'name': name, 'role': role, 'type': kind, 'manifest': manifest, 'project_root': project_root, 'directories': directories, 'body': body, 'document': document})

def _append_manifest_target(name, custom_path, package_root, is_root, label, hosts, profiles, third_party, out):
    directory = package_root / (custom_path if custom_path is not None else 'Sources/' + name)
    if not directory.is_dir():
        return None
    if is_root and name in hosts:
        role = 'host'
    elif is_root and name in profiles:
        role = 'profile'
    elif f'{label}{name}' in VENDOR_ADAPTERS:
        role = 'vendor-adapter'
    elif package_root in third_party:
        role = 'third-party'
    else:
        role = 'neutral'
    out.append((f'{label}{name}', directory, role))

def _append_inventory_record(record, out):
    if record['role'] not in {'host', 'neutral'}:
        return None
    for directory in record['directories']:
        out.append((record['key'], directory, record['role']))

def _append_host_import_conflicts(neutral_key, host_modules, conflicts):
    for path in swift_files(neutral_key):
        masked = mask(path.read_text(encoding='utf-8')).split('\n')
        for (number, line) in enumerate(masked, start=1):
            match = IMPORT_RE.match(line)
            if match and match.group(1) in host_modules:
                conflicts.append(f'{rel(path)}:{number} neutral target imports host module {match.group(1)}')

def _append_host_overlap_conflicts(key, directory, neutral, conflicts):
    for (neutral_key, neutral_directory) in neutral:
        if directory == neutral_directory or directory in neutral_directory.parents or neutral_directory in directory.parents:
            conflicts.append(f'{key}: source root overlaps neutral target {neutral_key}')

def _append_host_dependency_conflicts(name, exported, root_text, conflicts):
    if name in exported:
        conflicts.append(f'{name}: declared .executableTarget AND exported by a .library product')
    for (other, is_test, named) in _dependency_edges(root_text):
        if other != name and (not is_test) and (name in named):
            conflicts.append(f'{name}: non-test target {other} depends on it')

def _append_xcodegen_conflicts(record, declared, exported_anywhere, conflicts):
    (key, name) = (record['key'], record['name'])
    if record['role'] == 'neutral' and (not record['directories']):
        conflicts.append(f'{key}: framework declares no readable `sources:` directory')
    if record['role'] == 'unknown':
        conflicts.append(f"{key}: XcodeGen target type {record['type']!r} is neither a host application nor a test bundle, so no rule set governs it — classify it in boundary_gates.py")
    if record['role'] != 'host':
        return None
    if (record['project_root'] / SWIFT_MANIFEST_NAME).exists():
        conflicts.append(f"{key}: its directory holds BOTH a Package.swift and a {record['manifest'].name}, so the same sources are a package and an Xcode project at once")
    if name in declared:
        conflicts.append(f'{key}: a Package.swift also declares a target named {name}, so the host classification is ambiguous')
    if name in exported_anywhere:
        conflicts.append(f'{key}: a .library product exports a target named {name} — a host is exported by nothing, which is what the exemption is paid for with')
    if not record['directories']:
        conflicts.append(f'{key}: declares no readable `sources:` directory, so Rule 6 would scan nothing')

def _append_patch_problems(index, patch, where, package_root, problems):
    label = f'{where}: patches[{index}]'
    if not isinstance(patch, dict):
        problems.append(f'{label} is not an object')
        return None
    if not (isinstance(patch.get('changes'), str) and patch['changes'].strip()):
        problems.append(f'{label} does not say what it changes')
    files = patch.get('files')
    if not (isinstance(files, list) and files and all((isinstance(name, str) and name.strip() for name in files))):
        problems.append(f'{label} names no files')
        return None
    for name in files:
        if not (package_root / name).is_file():
            problems.append(f'{label} names {name}, which does not exist')

def _append_vendor_declaration_conflicts(key, vendor, roles, adapters, conflicts):
    if not (isinstance(vendor, str) and vendor.strip()):
        conflicts.append(f'{key}: VENDOR_ADAPTERS names no vendor for it')
    if key.split('/', 1)[0] == THIRD_PARTY_ROOT:
        conflicts.append(f'{key}: declared a vendor adapter under {THIRD_PARTY_ROOT}/, which holds upstream code')
    (label, _, name) = key.rpartition('/')
    package_root = ROOT / label if label else ROOT
    manifest = package_root / SWIFT_MANIFEST_NAME
    if not manifest.is_file():
        conflicts.append(f'{key}: declared in VENDOR_ADAPTERS but no Package.swift declares it')
        return None
    text = manifest.read_text(encoding='utf-8')
    if name not in {declared for (declared, _) in _target_declarations(text)}:
        conflicts.append(f'{key}: {rel(manifest)} declares no target named {name}')
        return None
    if name in {declared for (declared, _) in _declarations(text, EXECUTABLE_DECL)}:
        conflicts.append(f'{key}: an executable is a host, not a vendor adapter')
    if name not in _exported_targets(text):
        conflicts.append(f'{key}: no .library product exports it — an adapter is a library an adopter adds')
    if roles.get(key) != 'vendor-adapter':
        conflicts.append(f'{key}: declared in VENDOR_ADAPTERS but classified {roles.get(key)!r}')
    adapters[key] = (name, package_root)

def _append_vendor_target_conflicts(target, is_test, label, neutral, text, packages, manifest, adapters, conflicts):
    if is_test or f'{label}{target}' not in neutral:
        return None
    body = dict(_declarations(text, ANY_TARGET_DECL)).get(target, '')
    named = _declared_dependencies(body)
    consumed = {packages.get(package) for (_, package) in PRODUCT_DEPENDENCY.findall(body)}
    for (key, (name, package_root)) in adapters.items():
        if manifest.parent == package_root and name in named or package_root in consumed:
            conflicts.append(f'{label}{target}: neutral target depends on vendor adapter {key}')

def _append_vendor_manifest_conflicts(manifest, neutral, adapters, conflicts):
    is_root = manifest == MANIFEST
    label = '' if is_root else manifest.parent.relative_to(ROOT).as_posix() + '/'
    text = manifest.read_text(encoding='utf-8')
    packages = _local_packages(manifest, text)
    for (target, is_test, _) in _dependency_edges(text):
        _append_vendor_target_conflicts(target, is_test, label, neutral, text, packages, manifest, adapters, conflicts)

def _append_vendor_project_dependency_conflicts(dependency, declared, record, adapters, conflicts):
    if not isinstance(dependency, dict) or 'package' not in dependency:
        return None
    declaration = declared.get(str(dependency['package'])) if isinstance(declared, dict) else None
    if not isinstance(declaration, dict) or 'path' not in declaration:
        return None
    consumed = Path(os.path.normpath(record['project_root'] / str(declaration['path'])))
    for (key, (_, package_root)) in adapters.items():
        if consumed == package_root:
            conflicts.append(f"{record['key']}: neutral target depends on vendor adapter {key}")

def _append_vendor_project_conflicts(record, adapters, conflicts):
    if record['role'] != 'neutral':
        return None
    declared = record['document'].get('packages') or {}
    for dependency in record['body'].get('dependencies') or []:
        _append_vendor_project_dependency_conflicts(dependency, declared, record, adapters, conflicts)

def _append_vendor_import_conflicts(neutral_key, modules, conflicts):
    for path in swift_files(neutral_key):
        for (number, line) in enumerate(mask(path.read_text(encoding='utf-8')).split('\n'), start=1):
            match = IMPORT_RE.match(line)
            if match and match.group(1) in modules:
                conflicts.append(f'{rel(path)}:{number} neutral target imports vendor adapter {modules[match.group(1)]}')

def _append_third_party_import_conflicts(directory, package_root, ours, conflicts):
    if directory != package_root and package_root not in directory.parents:
        return None
    for path in _swift_files_in([directory]):
        for (number, line) in enumerate(mask(path.read_text(encoding='utf-8')).split('\n'), start=1):
            match = IMPORT_RE.match(line)
            if match and match.group(1) in ours:
                conflicts.append(f"{rel(path)}:{number} third-party source imports this repository's module {match.group(1)}; upstream code cannot depend on ours")

def _quoted_literal_end(text, cursor, limit):
    while cursor < limit:
        if text[cursor] == "\\":
            cursor += 2
            continue
        if text[cursor] in '\"\n':
            break
        cursor += 1
    return cursor

def _mask_span(text, cursor, limit):
    for opening, closing, skip in [('//', '\n', 0), ('/*', '*/', 2), ('"""', '"""', 3)]:
        if text.startswith(opening, cursor):
            end = text.find(closing, cursor + len(opening))
            return limit if end == -1 else end + skip, opening != '"""'
    if text[cursor] == '"':
        return min(_quoted_literal_end(text, cursor + 1, limit) + 1, limit), False
    return cursor + 1, None

def _blank_mask_span(output, start, end):
    for cursor in range(start, end):
        if output[cursor] != '\n':
            output[cursor] = ' '

def _append_prose_hits(path, code, prohibited, hits):
    offset = 0
    for (number, line) in enumerate(code.split('\n'), start=1):
        for channel in PROSE_CHANNELS:
            if channel in line:
                hits.append(f'{rel(path)}:{number} {channel}')
        for match in PROSE_SHAPE.finditer(line):
            if not _input_string_field(code, offset + match.start(), prohibited):
                hits.append(f'{rel(path)}:{number} prose-shaped member: {match.group(1)}')
        offset += len(line) + 1

def _append_vendor_identifier_hits(path, own, hits):
    if VENDOR.search(path.name):
        hits.append(f'{rel(path)}:0 filename carries a vendor name')
    code = mask(path.read_text(encoding='utf-8'), keep_literals=True)
    for (number, line) in enumerate(code.split('\n'), start=1):
        if not VENDOR.search(line):
            continue
        imported = IMPORT_RE.match(line)
        if imported and imported.group(1) in own:
            remainder = line[:imported.start(1)] + line[imported.end(1):]
            if not VENDOR.search(remainder):
                continue
        hits.append(f'{rel(path)}:{number} {line.strip()[:80]}')

def _append_rendering_hits(rendered, pixels_are_the_product, line, path, number, hits):
    if rendered in ('UIImage', 'NSImage', 'jpegData', 'pngData') and pixels_are_the_product:
        return False
    render_line = re.sub(r'\bISO8601DateFormatter\b', '', line) if rendered == 'DateFormatter' else line
    if rendered in render_line:
        hits.append(f'{rel(path)}:{number} renders: {rendered}')
        return True
    return False

def _append_verdict_line_hits(number, line, path, target, hits):
    for match in DECL.finditer(line):
        name = match.group('name')
        if name in VERDICT_EXEMPT:
            continue
        if VERDICT_PREFIX.match(name) or VERDICT_WORD.search(name):
            hits.append(f'{rel(path)}:{number} verdict-named: {name}')
            break
    pixels_are_the_product = any((token in target for token in PIXEL_TARGETS))
    for rendered in RENDER_TYPES:
        if _append_rendering_hits(rendered, pixels_are_the_product, line, path, number, hits):
            break

def _append_persisted_store_file(path, conformances, registered, refinements):
    code = mask(path.read_text(encoding='utf-8'))
    for match in STORE_CONFORMANCE.finditer(code):
        (kind, name, inherited) = (match.group(1), match.group(2), match.group(3) or '')
        if not STORE_PROTOCOL.search(inherited):
            continue
        number = code.count('\n', 0, match.start()) + 1
        if kind == 'protocol':
            refinements.append(f'{rel(path)}:{number} protocol {name} refines PersistedStore, so its conformers are stores this check cannot see — teach persistence_registry_gaps() to follow the refinement')
        else:
            conformances[name] = f'{rel(path)}:{number}'
    for match in REGISTRY_LIST.finditer(code):
        registered.update(REGISTRY_ENTRY.findall(match.group(1)))

def _append_project_dependency_escape(dependency, packages, record, manifest, hits):
    if not isinstance(dependency, dict) or 'package' not in dependency:
        return None
    package = str(dependency.get('package'))
    product = dependency.get('product')
    declaration = packages.get(package) if isinstance(packages, dict) else None
    if not isinstance(declaration, dict):
        hits.append(f'{rel(manifest)}:0 depends on package {package}, which `packages:` does not declare')
        return None
    if 'path' not in declaration:
        return None
    consumed = Path(os.path.normpath(record['project_root'] / str(declaration['path'])))
    package_manifest = consumed / SWIFT_MANIFEST_NAME
    if not package_manifest.exists():
        hits.append(f'{rel(manifest)}:0 package {package} points at {rel(consumed)}, which has no Package.swift')
        return None
    if product is None:
        hits.append(f'{rel(manifest)}:0 depends on package {package} without naming a product')
        return None
    if str(product) not in _library_product_names(package_manifest.read_text(encoding='utf-8')):
        hits.append(f'{rel(manifest)}:0 depends on {product}, which {rel(package_manifest)} does not declare as a .library product')

def _append_surface_line_escapes(number, line, path, hits):
    if TESTABLE.search(line):
        hits.append(f'{rel(path)}:{number} @testable — module-internal access')
    for match in PRIVATE_ATTRIBUTE.finditer(line):
        hits.append(f'{rel(path)}:{number} compiler-private attribute: @{match.group(1)}')
    for match in UNDERSCORED_MEMBER.finditer(line):
        before = line[:match.start()].rstrip()
        if before.endswith(('self', 'Self')):
            continue
        hits.append(f'{rel(path)}:{number} underscored member: .{match.group(1)}')
    for token in DYNAMIC_REACH:
        if token in line:
            hits.append(f'{rel(path)}:{number} reaches past access control at runtime: {token}')


def _probe_initialize_workspace(temporary) -> tuple:
    global BASELINE_PATH, MANIFEST, REACT_NATIVE_HOSTS, RN_HOST_UI_RESOURCES, RN_HOST_UI_TESTS, RN_TOOLING_MANIFESTS, ROOT, SOURCES, THIRD_PARTY_PACKAGES, VENDOR_ADAPTERS
    ROOT = Path(temporary)
    SOURCES = ROOT / "Sources"
    MANIFEST = ROOT / SWIFT_MANIFEST_NAME
    BASELINE_PATH = ROOT / "Gates/baselines.json"
    REACT_NATIVE_HOSTS = ()  # declared per probe below; the real list names real paths
    VENDOR_ADAPTERS, THIRD_PARTY_PACKAGES, RN_HOST_UI_TESTS = {}, (), {}  # likewise
    RN_HOST_UI_RESOURCES = {}  # likewise
    RN_TOOLING_MANIFESTS = ()  # likewise; declared by the tooling probes below
    target = "CaptureProbe"
    source = SOURCES / target
    source.mkdir(parents=True)
    MANIFEST.write_text('.target(name: "CaptureProbe")')
    fixture = source / "Probe.swift"
    return fixture, source, target

def _probe_neutral_rules(fixture, source, target) -> None:
    probes = [
        ('public let message = "Please hold your phone steady."', "no_authored_sentence"),
        ('let now = Date()', "no_ambient"),
        ('struct Policy { static let threshold = 0.42 }', "no_policy_numbers"),
        ('struct Result { public var isAuthentic: Bool { true } }', "no_verdict"),
        ('struct Failure: LocalizedError { var errorDescription: String? { "Failure" } }', "no_prose"),
    ]
    for text, rule in probes:
        fixture.write_text(text)
        assert CHECKS[rule][0](target), rule
    # Immutable supplied record fields carry protocol data, not SDK error prose.
    # Do not whitelist their names: any such record works, while defaults, mutation,
    # computed channels and Error conformances (including in other files) still fail.
    for declaration in [
        'public struct Input: Sendable { public let messageBody: String }',
        'public struct Receipt: Codable { public let messageHash: String\n'
        'public init(messageHash: String) { self.messageHash = messageHash } }',
    ]:
        fixture.write_text(declaration)
        assert not check_no_prose(target), check_no_prose(target)
        assert not check_no_authored_sentence(target)
    for declaration in [
        'public struct Failure: Error { public let messageBody: String }',
        'public struct CaptureFailure: Sendable { public let messageBody: String }',
        'public struct WireError: Decodable { public let messageBody: String }',
        'public struct Failure: LocalizedError { public let errorDescription: String }',
        'public struct Input: Sendable { public var messageBody: String }',
        'public struct Input { public var messageBody: String { source } }',
        'public struct Input { public func messageBody() -> String { source } }',
        'public struct Input { public let messageBody: String = source }',
        'public struct Input { public let messageBody: String\n = source }',
        'public struct Input { public let messageBody: String\n'
        'init(messageBody: String) { self.messageBody = messageBody + suffix } }',
        'public struct Input { public let messageBody: String\n'
        'init(messageBody: String = source) { self.messageBody = messageBody } }',
        'public struct Input { public let messageBody: String\n'
        'init?(messageBody: String) { self.messageBody = messageBody } }',
        'public struct Outer { struct Inner: Error { public let messageBody: String } }',
        'public struct Outer { func make() { public let messageBody: String } }',
        'public struct Input { public let messageBody: String; '
        'public var explanation: String { source } }',
        'protocol Sendable: Error {}\n'
        'public struct Input: Sendable { public let messageBody: String }',
    ]:
        fixture.write_text(declaration)
        assert check_no_prose(target), declaration
    extension = source / 'Extension.swift'
    fixture.write_text('public struct Input { public let messageBody: String }')
    extension.write_text('extension Input: Error {}')
    assert check_no_prose(target), 'separate-file error conformance must remain visible'
    extension.unlink()
    for declaration in [
        'public struct Input { public let messageBody: String\n'
        'init() { self.messageBody = "Hold your phone steady." } }',
        'public struct Input { public let messageBody: String }\n'
        'let draft = Input(messageBody: "Hold your phone steady.")',
    ]:
        fixture.write_text(declaration)
        assert check_no_authored_sentence(target), 'record classification cannot hide authored copy'
    # Wire-date parsing produces Date values, not holder-facing strings. Keep the
    # parsing-only Foundation APIs distinct from a display formatter, without
    # exempting files, identifiers, or prose just because a parser appears nearby.
    fixture.write_text('let date = try Date.ISO8601FormatStyle().parseStrategy.parse(wire)')
    assert not check_no_verdict(target)
    # Match display formatter types, not the substring in the ISO-8601 wire codec.
    # Qualification and a neighbouring wire codec must not hide a display formatter.
    for formatter in (
        "DateFormatter", "NumberFormatter", "NSDateFormatter", "NSNumberFormatter",
        "CustomDateFormatter", "DateFormatterSubclass", "CustomNumberFormatter", "NumberFormatterSubclass",
        "CustomISO8601DateFormatter", "ISO8601DateFormatterWrapper",
    ):
        for qualifier in ("", "Foundation."):
            fixture.write_text(f'let formatter = {qualifier}{formatter}()')
            hits = check_no_verdict(target)
            assert len(hits) == 1 and "renders:" in hits[0], (formatter, qualifier, hits)
    for qualifier in ("", "Foundation."):
        fixture.write_text(f'let wire = {qualifier}ISO8601DateFormatter()')
        assert not check_no_verdict(target), check_no_verdict(target)
        for formatter in ("DateFormatter", "NumberFormatter"):
            fixture.write_text(
                f'let wire = {qualifier}ISO8601DateFormatter(); let display = Foundation.{formatter}()')
            hits = check_no_verdict(target)
            assert len(hits) == 1 and f"renders: {formatter}" in hits[0], hits
    fixture.write_text(
        'let parser = Date.ParseStrategy(format: "\\(weekday: .abbreviated), '
        '\\(day: .twoDigits) \\(month: .abbreviated) \\(year: .defaultDigits) GMT", '
        'timeZone: TimeZone(secondsFromGMT: 0)!)\n'
        'let date = try parser.parse(wire)')
    assert not check_no_verdict(target)
    assert not check_no_authored_sentence(target)
    fixture.write_text(
        'let parser = Date.ISO8601FormatStyle().parseStrategy\n'
        'let formatter = DateFormatter()\n'
        'let output = formatter.string(from: date)\n'
        'let message = "Please retry your request."')
    assert check_no_verdict(target) and check_no_authored_sentence(target)
    fixture.write_text('// CalibrationProfile\nstruct Policy { static let threshold = 0.42 }')
    assert check_no_policy_numbers(target), "A comment must not exempt policy"

def _probe_module_imports(fixture, target) -> None:
    own_module = SOURCES / "KenshikiImportProbe"
    own_module.mkdir()
    (own_module / "Module.swift").write_text("")
    MANIFEST.write_text('.target(name: "CaptureProbe"), .target(name: "KenshikiImportProbe")')
    for prefix in ["", "public ", "package ", "internal ", "fileprivate ", "private ",
                   "@preconcurrency internal "]:
        for member in ["", "struct "]:
            spelling = prefix + "import " + member + "KenshikiImportProbe"
            if member:
                spelling += ".Record"
            fixture.write_text(spelling)
            assert not check_no_vendor_identifiers(target), spelling
        fixture.write_text(prefix + "import ExternalPulseProvider")
        assert check_no_vendor_identifiers(target), "an external vendor import is not ours"
    for spelling in [
        'internal import KenshikiImportProbe; let wire = "pulse.check"',
        "internal import struct KenshikiImportProbe.PulseRecord",
    ]:
        fixture.write_text(spelling)
        assert check_no_vendor_identifiers(target), "the module exception must not hide vendor data"
    # The same syntax must still expose a forbidden leaf dependency.
    leaf = SOURCES / LEAF
    leaf.mkdir()
    leaf_file = leaf / "ImportProbe.swift"
    MANIFEST.write_text('.target(name: "CaptureProbe"), .target(name: "KenshikiEvidenceCore")')
    for prefix in ["internal ", "@preconcurrency public "]:
        leaf_file.write_text(prefix + "import Security")
        assert check_layer_direction(), "a qualified import must not hide a leaf dependency"
        leaf_file.write_text(prefix + "import Foundation")
        assert not check_layer_direction()
    leaf_file.unlink()
    leaf.rmdir()
    fixture.write_text("")
    MANIFEST.write_text('.target(name: "CaptureProbe")')

def _probe_target_discovery() -> None:
    new = SOURCES / "CaptureNew"
    new.mkdir()
    (new / "New.swift").write_text('let timestamp = Date()')
    MANIFEST.write_text('.target(name: "CaptureProbe"), .target(name: "CaptureNew")')
    counts = measure()
    assert counts[NEW_TARGET_AMBIENT_KEY] == 1
    # Subpackages with equal folder/target names remain distinct, and custom source paths scan.
    for prefix in ["Packages", "ThirdParty"]:
        package = ROOT / prefix / "SameName"
        (package / "CustomCode").mkdir(parents=True)
        (package / SWIFT_MANIFEST_NAME).write_text('.target(name: "Provider", path: "CustomCode")')
        (package / "CustomCode/Input.swift").write_text('let clock = Date()')
    counts = measure()
    assert counts["no_ambient::Packages/SameName/Provider"] == 1
    assert counts["no_ambient::ThirdParty/SameName/Provider"] == 1
    ignored = ROOT / ".build/checkouts/Hidden"
    (ignored / "Sources/Hidden").mkdir(parents=True)
    (ignored / SWIFT_MANIFEST_NAME).write_text('.target(name: "Hidden")')
    (ignored / "Sources/Hidden/Hidden.swift").write_text('let clock = Date()')
    assert not any("Hidden" in key for key in neutral_targets())
    assert not _target_declarations('// .target(name: "CommentOnly")')
    # A nested native source target at path dot must not scan its manifest as runtime Swift.
    native = ROOT / "Packages/Native"
    native.mkdir(parents=True)
    (native / SWIFT_MANIFEST_NAME).write_text('.target(name: "Native", path: ".")')
    assert swift_files("Packages/Native/Native") == []

def _probe_swift_hosts(fixture) -> tuple:
    host_source = SOURCES / "SampleHost"
    host_source.mkdir()
    host_file = host_source / "Host.swift"
    # CaptureInternal is unexported but a neutral target depends on it, which is what an
    # ordinary internal module looks like: not a profile, and not importable by an adopter.
    (SOURCES / "CaptureInternal").mkdir()
    (SOURCES / "CaptureInternal/Internal.swift").write_text("let internalClock = Date()")
    library = ('.library(name: "CaptureProbe", targets: ["CaptureProbe"]), '
               '.library(name: "CaptureNew", targets: ["CaptureNew"]), ')
    neutral = ('.target(name: "CaptureProbe", dependencies: ["CaptureInternal"]), '
               '.target(name: "CaptureNew"), .target(name: "CaptureInternal"), ')
    good_host = '.executableTarget(name: "SampleHost", dependencies: ["CaptureProbe"])'
    host_file.write_text(PROBE_IMPORT)
    MANIFEST.write_text(library + neutral + good_host)
    assert host_targets() == ["SampleHost"], host_targets()
    assert "SampleHost" not in neutral_targets()
    assert not classification_conflicts()
    for spelling in ["internal import SampleHost", "@preconcurrency public import SampleHost"]:
        fixture.write_text(spelling)
        assert any("neutral target imports host module SampleHost" in hit
                   for hit in classification_conflicts()), spelling
    fixture.write_text("")
    # A host authoring prose, naming its vendor, carrying a threshold and returning a
    # verdict is a host doing its job. Those four rules get no counter for it at all.
    host_file.write_text(
        'import CaptureProbe\n'
        'let copy = "Hold the phone steady against the back cover."\n'
        'let label = "com.kenshiki.sample.queue"\n'
        'struct Policy { static let threshold = 0.42 }\n'
        'public var isApproved: Bool { true }\n')
    counts = measure()
    for exempt in HOST_EXEMPT:
        assert f"{exempt}::SampleHost" not in counts, exempt
    assert counts["no_surface_escape::SampleHost"] == 0
    # DECISION 1, OWNER, 2026-09-17: RULE 3 IS EXEMPT FOR A HOST TOO. A host reading the
    # clock, its own bundle or its own defaults is not ambient reach — it is the process,
    # and that IS the naming Rule 3 demands of it. The CHECK must still SEE these (the rule
    # did not change); what changed is that a host is not SCANNED for it.
    host_file.write_text(
        "import CaptureProbe\n"
        "let now = Date()\n"
        "let bundle = Bundle.main\n"
        "let defaults = UserDefaults.standard\n")
    assert len(check_no_ambient("SampleHost")) == 3, check_no_ambient("SampleHost")
    assert "no_ambient::SampleHost" not in measure(), "a host is not scanned for Rule 3"
    assert set(dict(scan_plan())["SampleHost"]) == set(SURFACE_CHECKS)
    # The exemption moved; the rule did not. A NEUTRAL target reading the clock is still debt.
    assert measure()[NEW_TARGET_AMBIENT_KEY] == 1
    assert measure()["no_ambient::CaptureInternal"] == 1
    # Rule 6 bites on every door an ordinary import does not open.
    host_file.write_text(PROBE_IMPORT)
    for reach in [PROBE_TESTABLE_IMPORT,
                  PROBE_SPI_IMPORT,
                  "@_implementationOnly import CaptureProbe\n",
                  "@_exported import CaptureProbe\n",
                  "import CaptureProbe\nlet state = probe._internalState\n",
                  PROBE_MIRROR_SOURCE,
                  'import CaptureProbe\nlet type = NSClassFromString("Probe")\n']:
        host_file.write_text(reach)
        assert check_no_surface_escape("SampleHost"), reach
    host_file.write_text("import CaptureProbe\nlet own = self._hostStorage\n")
    assert not check_no_surface_escape("SampleHost"), "a host's OWN storage is not a reach"
    # THE FORGERY PROBE. No sentence a source file writes about itself can mint a host.
    host_file.write_text(PROBE_IMPORT)
    (SOURCES / "CaptureNew/New.swift").write_text(
        "// host target. example app. sample only. @testable allowed. CalibrationProfile.\n"
        "let timestamp = Date()")
    assert "CaptureNew" in neutral_targets(), "a comment must not mint a host"
    assert host_targets() == ["SampleHost"]
    assert measure()[NEW_TARGET_AMBIENT_KEY] == 1
    # Nor can a target be a host AND remain part of the SDK surface.
    MANIFEST.write_text(library + '.library(name: "SampleHost", targets: ["SampleHost"]), '
                        + neutral + '.executableTarget(name: "SampleHost")')
    assert any(".library product" in line for line in classification_conflicts())
    MANIFEST.write_text(library + neutral + '.executableTarget(name: "SampleHost"), '
                        '.target(name: "Consumer", dependencies: ["SampleHost"])')
    assert any("depends on it" in line for line in classification_conflicts())
    MANIFEST.write_text(
        library + neutral + '.executableTarget(name: "SampleHost", path: "Sources/CaptureProbe")')
    assert any("overlaps" in line for line in classification_conflicts())
    # The manifest half of Rule 6: widened access, and a module no adopter could import.
    MANIFEST.write_text(library + neutral + '.executableTarget(name: "SampleHost", '
                        'dependencies: ["CaptureInternal"], '
                        'swiftSettings: [.unsafeFlags(["-enable-testing"])])')
    manifest_hits = check_no_surface_escape("SampleHost")
    assert any("unsafeFlags" in hit for hit in manifest_hits)
    assert any("enables testing" in hit for hit in manifest_hits)
    assert any("no .library product exports" in hit for hit in manifest_hits)
    # Only the ROOT manifest may declare a host: a vendored package cannot exempt itself.
    vendored = ROOT / "Packages/Vendored"
    (vendored / "Sources/VendorTool").mkdir(parents=True)
    (vendored / SWIFT_MANIFEST_NAME).write_text('.executableTarget(name: "VendorTool")')
    (vendored / "Sources/VendorTool/Tool.swift").write_text("let clock = Date()")
    assert "Packages/Vendored/VendorTool" in neutral_targets()
    assert "no_prose::Packages/Vendored/VendorTool" in measure()

    # --- DECISION 2: A PROFILE IS A SHAPE IN THE BUILD GRAPH, NOT A NAME ---------------
    # `PROFILE_TARGETS` was the literal set {"KenshikiPulseProfile", "ExampleAgencyProfile"}
    # until 2026-09-17, so a one-line manifest edit bought exemption from all five neutral
    # rules — a cheaper forgery than the comment that took Rule 4 from 35 to 0, sitting
    # beside the host rule built to make exactly that impossible. Probed the way that one
    # is: attempt the forgery, and assert the gate refuses it.
    return good_host, host_file, library, neutral

def _probe_vendor_profiles(good_host, library, neutral) -> None:
    profile_file = SOURCES / "ExampleAgencyProfile/Profile.swift"
    profile_file.parent.mkdir()
    profile_file.write_text(
        'let copy = "Hold the phone steady against the back cover."\n'
        'let label = "com.kenshiki.agency.queue"\n'
        'struct Policy { static let threshold = 0.42 }\n'
        'let now = Date()\n')
    support = SOURCES / "ProfileSupport"
    support.mkdir()
    (support / "Support.swift").write_text("let supportClock = Date()")
    forged = '.target(name: "ExampleAgencyProfile"), .target(name: "ProfileSupport"), '
    reaching = ('.target(name: "CaptureProbe", '
                'dependencies: ["CaptureInternal", "ExampleAgencyProfile"]), '
                '.target(name: "CaptureNew"), .target(name: "CaptureInternal"), ')

    # THE FORGERY: the reserved NAME, on a target a `.library` product still exports.
    MANIFEST.write_text(
        library
        + '.library(name: "ExampleAgencyProfile", targets: ["ExampleAgencyProfile"]), '
          '.library(name: "ProfileSupport", targets: ["ProfileSupport"]), '
        + neutral + forged + good_host)
    assert profile_targets() == [], "a NAME must not mint a profile"
    assert "ExampleAgencyProfile" in neutral_targets()
    assert measure()[PROFILE_AMBIENT_KEY] == 1
    assert measure()["no_authored_sentence::ExampleAgencyProfile"] == 1

    # THE SECOND FORGERY: strip a real module's `.library` product so it falls out of the
    # neutral rule set. Refused while any neutral target still imports it, which is the
    # whole point — the exemption costs a module the ability to be reached at all.
    MANIFEST.write_text(
        library + '.library(name: "ProfileSupport", targets: ["ProfileSupport"]), '
        + reaching + forged + good_host)
    assert profile_targets() == [], "a module a neutral target imports is not a profile"
    assert PROFILE_AMBIENT_KEY in measure()

    # THE HONEST PROFILE: no product exports it, nothing neutral reaches it. Exempt from
    # all five neutral rules, and still bound by Rule 6.
    MANIFEST.write_text(library + neutral + forged + good_host)
    assert profile_targets() == ["ExampleAgencyProfile", "ProfileSupport"], profile_targets()
    counts = measure()
    for exempt in HOST_EXEMPT:
        assert f"{exempt}::ExampleAgencyProfile" not in counts, exempt
    assert counts["no_surface_escape::ExampleAgencyProfile"] == 0

    # THE FIXED POINT. Demote a candidate a neutral target reaches, and whatever only that
    # candidate was holding up is demoted with it — otherwise one hop of indirection
    # (`ExampleAgencyProfile -> ProfileSupport`) would launder the second target's debt.
    MANIFEST.write_text(
        library + reaching
        + '.target(name: "ExampleAgencyProfile", dependencies: ["ProfileSupport"]), '
          '.target(name: "ProfileSupport"), ' + good_host)
    assert profile_targets() == [], profile_targets()
    assert "no_ambient::ProfileSupport" in measure()
    MANIFEST.write_text(
        library + neutral
        + '.target(name: "ExampleAgencyProfile", dependencies: ["ProfileSupport"]), '
          '.target(name: "ProfileSupport"), ' + good_host)
    assert profile_targets() == ["ExampleAgencyProfile", "ProfileSupport"]

    # A HOST IS NOT A PROFILE. SampleHost satisfies all three profile conditions, and the
    # host role carries strictly more obligation — `classification_conflicts()` — so host
    # must win the classification rather than the cheaper role.
    MANIFEST.write_text(library + neutral + forged + good_host)
    assert host_targets() == ["SampleHost"]
    assert "SampleHost" not in profile_targets()

    # RULE 6'S MANIFEST HALF REACHES A PROFILE, not only a host. Neither of these escapes
    # appears anywhere in the Swift files, so if this does not look, nothing does.
    MANIFEST.write_text(
        library + neutral + '.target(name: "ExampleAgencyProfile", '
        'dependencies: ["CaptureInternal"], '
        'swiftSettings: [.unsafeFlags(["-enable-testing"])]), '
        '.target(name: "ProfileSupport"), ' + good_host)
    profile_hits = check_no_surface_escape("ExampleAgencyProfile")
    assert any("unsafeFlags" in hit for hit in profile_hits), profile_hits
    assert any("no .library product exports" in hit for hit in profile_hits), profile_hits

    # A VENDORED SUBPACKAGE CANNOT MINT A PROFILE either. `Provider` is exported by no
    # product and reached by nothing, and stays neutral because the ROOT manifest never
    # named it — the same condition that stops a dependency minting a host.
    assert "Packages/SameName/Provider" in neutral_targets()

    # DELETING THE WHOLE `products:` ARRAY is the one bulk edit that would otherwise
    # reclassify every module at once. A manifest that exports nothing has no profiles.
    MANIFEST.write_text(neutral + forged + good_host)
    assert profile_targets() == [], profile_targets()
    assert PROFILE_AMBIENT_KEY in measure()

    # --- DECISION 3: AN XCODEGEN APPLICATION IS A HOST, AND CANNOT BE FORGED INTO ONE ---
    # Every target above came from a `Package.swift`. An iOS application cannot be a
    # SwiftPM target at all, so the only kind of host a person can hold in their hand was
    # invisible to every rule — including Rule 6, the one rule that governs hosts. These
    # probes are written the way the Rule 4 and profile forgeries are: attempt the cheat,
    # assert the gate refuses it.
    MANIFEST.write_text(library + neutral + good_host)

def _probe_xcodegen_hosts(good_host, library, neutral) -> None:
    app = ROOT / "Hosts/SampleApp"
    (app / "AppSources").mkdir(parents=True)
    (app / "Extra").mkdir()
    (app / APP_SOURCE_PATH).write_text(PROBE_IMPORT)
    (app / EXTRA_SOURCE_PATH).write_text(PROBE_IMPORT)
    project = app / XCODEGEN_PROJECT_NAME
    app_key = "Hosts/SampleApp/SampleApp"
    good_project = (
        "name: SampleApp\n"
        "packages:\n"
        "  SDK:\n"
        "    path: ../..\n"
        "targets:\n"
        "  SampleApp:\n"
        "    type: application\n"
        "    sources: [AppSources, Extra]\n"
        "    dependencies:\n"
        "      - package: SDK\n"
        "        product: CaptureProbe\n")
    project.write_text(good_project)
    assert app_key in host_targets(), host_targets()
    assert app_key not in neutral_targets()
    assert not classification_conflicts(), classification_conflicts()
    # A host authoring prose, naming its vendor, holding a threshold, returning a verdict
    # and reading the clock is a host doing its job — exactly as for an SPM host.
    (app / APP_SOURCE_PATH).write_text(
        'import CaptureProbe\n'
        'let copy = "Hold the phone steady against the back cover."\n'
        'let label = "com.kenshiki.sample.queue"\n'
        'struct Policy { static let threshold = 0.42 }\n'
        'public var isApproved: Bool { true }\n'
        'let now = Date()\n')
    counts = measure()
    for exempt in HOST_EXEMPT:
        assert f"{exempt}::{app_key}" not in counts, exempt
    assert counts[f"no_surface_escape::{app_key}"] == 0
    # THE ADVERSARIAL ONE: a `project.yml` host must not escape Rule 6.
    (app / APP_SOURCE_PATH).write_text(PROBE_TESTABLE_IMPORT)
    hits = check_no_surface_escape(app_key)
    assert any("@testable" in hit for hit in hits), hits
    assert measure()[f"no_surface_escape::{app_key}"] >= 1
    for reach in [PROBE_SPI_IMPORT,
                  "import CaptureProbe\nlet state = probe._internalState\n",
                  PROBE_MIRROR_SOURCE]:
        (app / APP_SOURCE_PATH).write_text(reach)
        assert check_no_surface_escape(app_key), reach
    (app / APP_SOURCE_PATH).write_text(PROBE_IMPORT)
    # EVERY `sources:` DIRECTORY IS SCANNED. One entry per directory exists precisely so a
    # reach cannot be parked in the second one.
    (app / EXTRA_SOURCE_PATH).write_text(
        PROBE_MIRROR_SOURCE)
    assert check_no_surface_escape(app_key), "a second sources directory must be scanned"
    (app / EXTRA_SOURCE_PATH).write_text(PROBE_IMPORT)
    assert not check_no_surface_escape(app_key)
    # THE FORGERY THAT WOULD MATTER: point `sources:` at a neutral module and collect the
    # exemption for it. Refused as a conflict, and the module keeps its own counters — the
    # exemption is not transferable by writing a YAML file next door.
    project.write_text(
        good_project.replace("sources: [AppSources, Extra]", "sources: [../../Sources/CaptureNew]"))
    assert any(NEUTRAL_OVERLAP_MESSAGE in line for line in classification_conflicts()), \
        classification_conflicts()
    assert measure()[NEW_TARGET_AMBIENT_KEY] == 1
    # THE CLAIM, CHECKED: nothing in a `Package.swift` can name this target. The only
    # spelling that tries is declaring a target of the same name, and that is ambiguous
    # rather than permitted.
    project.write_text(good_project)
    MANIFEST.write_text(library + neutral + good_host + ', .target(name: "SampleApp")')
    assert any("ambiguous" in line for line in classification_conflicts()), \
        classification_conflicts()
    MANIFEST.write_text(library + '.library(name: "SampleApp", targets: ["SampleApp"]), '
                        + neutral + good_host)
    assert any("exports a target named SampleApp" in line
               for line in classification_conflicts())
    MANIFEST.write_text(library + neutral + good_host)
    # A DIRECTORY THAT IS BOTH A PACKAGE AND AN XCODE PROJECT is not classifiable.
    (app / SWIFT_MANIFEST_NAME).write_text('.target(name: "SampleApp")')
    assert any("at once" in line for line in classification_conflicts()), \
        classification_conflicts()
    (app / SWIFT_MANIFEST_NAME).unlink()
    # THE MANIFEST HALF OF RULE 6, in `project.yml` spelling: a setting that makes
    # @testable compile, and a product no `.library` declares.
    project.write_text(good_project.replace(
        "    dependencies:",
        "    settings:\n      base:\n        ENABLE_TESTABILITY: YES\n    dependencies:"))
    assert any("ENABLE_TESTABILITY" in hit for hit in check_no_surface_escape(app_key))
    project.write_text(good_project.replace("product: CaptureProbe",
                                            "product: CaptureInternal"))
    assert any(".library product" in hit for hit in check_no_surface_escape(app_key)), \
        check_no_surface_escape(app_key)
    # A TEST BUNDLE IS NOT SCANNED — parity with `.testTarget`, which no rule has ever
    # scanned. `--report` prints what it would have scored, so it is excluded, not hidden.
    project.write_text(good_project
                       + "  SampleTests:\n    type: bundle.unit-test\n    sources: [Extra]\n")
    assert "Hosts/SampleApp/SampleTests" not in host_targets()
    assert "no_surface_escape::Hosts/SampleApp/SampleTests" not in measure()
    assert not classification_conflicts(), classification_conflicts()
    # A framework remains SDK code and receives all neutral checks.
    project.write_text(good_project
                       + "  SampleKit:\n    type: framework\n    sources: [Extra]\n")
    framework_key = "Hosts/SampleApp/SampleKit"
    assert framework_key in neutral_targets()
    assert framework_key not in host_targets()
    (app / EXTRA_SOURCE_PATH).write_text('let timestamp = Date()')
    assert measure()[f"no_ambient::{framework_key}"] == 1
    assert set(dict(scan_plan())[framework_key]) == set(CHECKS)
    assert any(NEUTRAL_OVERLAP_MESSAGE in line for line in classification_conflicts())
    (app / EXTRA_SOURCE_PATH).write_text(PROBE_IMPORT)
    # A TYPE NOBODY HAS CLASSIFIED IS A CONFLICT, never a silent pass.
    project.write_text(good_project
                       + "  SampleKit:\n    type: app-extension\n    sources: [Extra]\n")
    assert any("neither a host application nor" in line
               for line in classification_conflicts()), classification_conflicts()
    # AN UNREADABLE MANIFEST FAILS CLOSED. A parser that returned {} here would turn every
    # YAML construct it had not met into a silent exemption.
    project.write_text("targets:\n  SampleApp:\n    type: application\n"
                       "    sources: &anchor [AppSources]\n")
    try:
        host_targets()
        raise AssertionError("an unreadable project.yml must fail the gate, not vanish")
    except YamlSubsetError:
        pass
    # HALF A DECLARATION IS NOT A DECLARATION. `include:` can put targets in another file
    # and a target template can supply `type:` and `sources:`; either read partially would
    # classify a target from half its declaration, so both fail closed.
    for partial in ["include: [other.yml]\n" + good_project,
                    good_project.replace("    type: application\n",
                                         "    template: AppTemplate\n")]:
        project.write_text(partial)
        try:
            host_targets()
            raise AssertionError("a partially readable project.yml must fail the gate")
        except YamlSubsetError:
            pass
    # AND THE ROLE DIES WITH THE FILE: no `project.yml`, no host, no counters.
    project.unlink()
    assert app_key not in host_targets()
    assert not any("SampleApp" in key for key in measure())

def _probe_persisted_stores(host_file) -> None:
    store_file = SOURCES / "CaptureProbe/Probe.swift"
    registry_file = SOURCES / "CaptureNew/New.swift"
    store_file.write_text("extension BarometerTape: PersistedStore {}\n")
    registry_file.write_text(
        "enum ProbeStores: PersistedStoreRegistry {\n"
        "    public static let allStores: [PersistedStoreType] = [BarometerTape.self]\n"
        "}\n")
    assert not persistence_registry_gaps(), persistence_registry_gaps()
    # THE ADVERSARIAL PROBE. The store ships; the registry never learns about it. This is
    # what happened four times to `PulseDataEraser.eraseLocalData`, each time to a real
    # store holding real holder data.
    registry_file.write_text(
        "enum ProbeStores: PersistedStoreRegistry {\n"
        "    public static let allStores: [PersistedStoreType] = []\n"
        "}\n")
    gaps = persistence_registry_gaps()
    assert any("BarometerTape" in line for line in gaps), gaps
    assert any("Sources/CaptureProbe/Probe.swift:1" in line for line in gaps), gaps
    # ONE MISSING AMONG SEVERAL, which is the shape that actually happens. A check that
    # only noticed an empty registry would wave a partly correct list through.
    store_file.write_text("extension BarometerTape: PersistedStore {}\n"
                          "extension VerifiedCallContacts: PersistedStore {}\n")
    registry_file.write_text("let allStores: [PersistedStoreType] = [BarometerTape.self]\n")
    gaps = persistence_registry_gaps()
    assert len(gaps) == 1 and "VerifiedCallContacts" in gaps[0], gaps
    # A HOST'S LIST IS NOT A REGISTRY. `Hosts/SensorHost` held exactly such an array, in
    # the one target whose job is to prove the public surface is sufficient. If a host
    # could satisfy this check, it could take its hand-written list back and read green.
    registry_file.write_text("")
    host_file.write_text("import CaptureProbe\nlet allStores: [PersistedStoreType] = "
                         "[BarometerTape.self, VerifiedCallContacts.self]\n")
    assert len(persistence_registry_gaps()) == 2, persistence_registry_gaps()
    host_file.write_text(PROBE_IMPORT)
    # A PROTOCOL REFINING THE CONTRACT would make its own conformers stores under a name
    # this check does not look for, so it is refused rather than read as zero — the same
    # fail-closed rule as `include:` in a project.yml.
    store_file.write_text("public protocol SqliteStore: PersistedStore {}\n")
    assert any("refines" in line for line in persistence_registry_gaps())
    store_file.write_text("")
    assert not persistence_registry_gaps(), persistence_registry_gaps()

def _probe_react_native_package() -> tuple:
    package = ROOT / "ReactNative/probe-capture"
    (package / "src/specs").mkdir(parents=True)
    (package / "ios").mkdir()
    (package / NPM_MANIFEST_NAME).write_text(json.dumps({
        "name": "@probe/capture", "files": ["src", "ios", "Frameworks"],
        "codegenConfig": {"name": "ProbeSpec", "jsSrcsDir": "src/specs", "ios": {
            "modulesProvider": {"NativeProbe": "RCTProbe"},
            "componentProvider": {"ProbePreview": "PRBPreviewView"}}}}))
    (package / "ProbeCapture.podspec").write_text("  s.public_header_files = 'ios/PRBPublic.h'\n")
    rn_key = "ReactNative/probe-capture"
    source, native = package / "src/index.tsx", package / "ios/PRBProbe.mm"
    header = package / "ios/PRBPublic.h"
    (package / "ios/PRBPrivate.h").write_text("@interface PRBPrivate : NSObject\n@end\n")
    (package / "src/specs/NativeProbe.ts").write_text(
        "import type {TurboModule} from 'react-native';\n"
        "import {TurboModuleRegistry, codegenNativeComponent} from 'react-native';\n"
        "export interface Spec extends TurboModule { perform(op: string): Promise<string>; }\n"
        "export default TurboModuleRegistry.getEnforcing<Spec>('NativeProbe');\n"
        "export const Preview = codegenNativeComponent('ProbePreview');\n")
    clean_ts = (
        "import React from 'react';\n"
        "import Native from './specs/NativeProbe';\n"
        "export type Failure = 'invalidConfiguration' | 'busy' | 'cancelled';\n"
        "export type Check = {name: string; reason: string; requiresLocation: boolean;\n"
        "  kind: 'passport-read-v1'; protocols: Record<'pace' | 'bac', 'succeeded' | 'failed'>;\n"
        "  subscribe(listener: (event: Check) => void): () => void;\n"
        "};\n"
        "export class ProbeSession {\n"
        "  private constructor(public readonly id: string) {}\n"
        "  private isBusy = false;\n"
        "  static async create(): Promise<ProbeSession> { return new ProbeSession(await Native.perform('create')); }\n"
        "  private async command<T>(operation: string, payload: object = {}): Promise<T> {\n"
        "    return JSON.parse(await Native.perform(operation)) as T;\n"
        "  }\n"
        "  readPassport(options: Check): Promise<Check> { return this.command('readPassport', options); }\n"
        "  at(value: string): Date { return new Date(value); }\n"
        "}\n"
        "export function ProbeImage(props: {session: ProbeSession; image: 'reference' | 'selfie'}) {\n"
        "  return <Preview sessionId={props.session.id} kind={`${props.image}Image`} />;\n"
        "}\n")
    clean_mm = ('#import "PRBPublic.h"\n'
                "static const auto defaults = std::make_shared<const ProbeProps>();\n"
                "+ (BOOL)requiresMainQueueSetup { return YES; }\n"
                'reject(@"invalidConfiguration", @"invalidConfiguration", nil);\n')
    clean_h = "FOUNDATION_EXPORT BOOL PRBRegisterProvider(id provider, NSError **error);\n"
    source.write_text(clean_ts)
    native.write_text(clean_mm)
    header.write_text(clean_h)
    assert rn_key in neutral_targets(), neutral_targets()
    assert set(dict(scan_plan())[rn_key]) == set(CHECKS)
    assert not classification_conflicts(), classification_conflicts()
    for rule, (check, _) in CHECKS.items():
        assert not check(rn_key), (rule, check(rn_key))
    # Real lexical owners, not indentation or brace balance: compiler-emitted locals
    # are local even at column zero, and source decoys must never conceal module state.
    local_scopes = (
        "export function invoke() {\nlet local;\nvar other;\n}\n"
        "export const arrow = () => {\nlet local;\n};\n"
        "export const expression = function () {\nvar local;\n};\n"
        "export function* iterator() {\nlet local;\nyield local;\n}\n"
        "export class Owner { constructor() {\nlet local;\n}\n"
        "method() {\nvar local;\n}\nget value() {\nlet local;\nreturn local;\n}\n"
        "set value(input) {\nvar local = input;\n}\n}\n"
        "export const object = { method() {\nlet local;\n} };\n")
    source.write_text(local_scopes)
    assert not _rn_no_ambient(rn_key), _rn_no_ambient(rn_key)
    decoys = [
        "// { function pretend() {\n",
        "/* { function pretend() { */\n",
        "const brace = '{ function pretend() {';\n",
        "const brace = `} ${(() => { let local; return '{'; })()} {`;\n",
        "const brace = /[{}]/;\n",
        "const astral = '😀';\n",
    ]
    declarations = ["let shared;", "  var shared;", "export let shared;",
                    "let {shared} = owner;", "var [shared] = owner;",
                    "{ let shared; }", "for (let shared of values) {}"]
    for decoy in decoys:
        for declaration in declarations:
            source.write_text(decoy + declaration + "\n" + local_scopes)
            hits = _rn_no_ambient(rn_key)
            assert len(hits) == 1 and ":2 " in hits[0], (decoy, declaration, hits)
    # Only exact syntax in a directive prologue qualifies. The same prose as a value,
    # a late expression, a block statement or a template must remain visible to Rule 1b.
    for script in [
        '"use strict";\nexport {};\n',
        "'use strict';\nexport {};\n",
        "export function invoke() { 'use strict'; let local; }\n",
        "export const invoke = () => { 'use strict'; let local; };\n",
        "// 😀 {\n'use strict';\nexport {};\n",
    ]:
        source.write_text(script)
        assert not _rn_no_authored_sentence(rn_key), (script, _rn_no_authored_sentence(rn_key))
    for script in [
        "export const words = 'use strict';\n",
        "export {}; 'use strict';\n",
        "{ 'use strict'; }\n",
        "`use strict`;\n",
        "function invoke() { const word = 'code'; 'use strict'; }\n",
        "'use\\x20strict';\n",
    ]:
        source.write_text(script)
        syntax = _rn_script_syntax({source: script})[source]
        assert not syntax["strict"], (script, syntax)
        # Escaped source is separately outside this lexical sentence discriminator;
        # it still receives no directive exemption.
        if "\\" not in script:
            assert _rn_no_authored_sentence(rn_key), script
    source.write_text("export const broken = ;\n")
    assert any("cannot establish TypeScript syntax" in hit
               for hit in classification_conflicts()), classification_conflicts()
    source.write_text(clean_ts)
    assert not classification_conflicts(), classification_conflicts()
    planted = [
        ("no_prose", source, "export function failureMessage(code: string): string { return code; }\n"),
        ("no_prose", source, "export function fail() { throw new Error('busy'); }\n"),
        ("no_prose", native, "NSDictionary *info = @{NSLocalizedDescriptionKey: code};\n"),
        ("no_authored_sentence", source, "export const copy = 'Hold the phone steady against the back cover.';\n"),
        ("no_authored_sentence", source, "export const hint = (group: string) => `Reading ${group}, keep the phone still.`;\n"),
        ("no_authored_sentence", source, "export function Hint() { return <Text>Hold the phone steady.</Text>; }\n"),
        ("no_authored_sentence", native, 'reject(@"busy", @"The camera could not start.", nil);\n'),
        ("no_vendor_identifiers", source, "export const queue = 'com.kenshiki.capture';\n"),
        ("no_vendor_identifiers", source, "export class PulseSession {}\n"),
        # The package's OWN product name gets no exemption: the contract grants none.
        ("no_vendor_identifiers", source, "export {IdentityCaptureSession} from '@kenshiki/identity-capture';\n"),
        ("no_vendor_identifiers", native, 'static NSString *const label = @"pulse.check";\n'),
        ("no_ambient", source, "export const stamp = () => Date.now();\n"),
        ("no_ambient", source, "export const stamp = () => new Date();\n"),
        ("no_ambient", source, "import {NativeModules} from 'react-native';\nexport const m = NativeModules.RCTProbe;\n"),
        ("no_ambient", source, "import {TurboModuleRegistry} from 'react-native';\nexport const m = TurboModuleRegistry.get('NativeProbe');\n"),
        ("no_ambient", source, "let shared: ProbeSession | undefined;\n"),
        ("no_ambient", source, "AppState.addEventListener('change', () => {});\n"),
        ("no_ambient", native, "NSDate *now = [NSDate date];\n"),
        ("no_ambient", native, "dispatch_once(&once, ^{ runtime = [PRBRuntime new]; });\n"),
        ("no_ambient", native, "dispatch_async(dispatch_get_main_queue(), ^{ resolve(nil); });\n"),
        ("no_policy_numbers", source, "export const pollInterval = 3.5;\n"),
        ("no_policy_numbers", source, "export class Policy { static readonly threshold = 0.42; }\n"),
        ("no_policy_numbers", source, "// CalibrationProfile, measured against our population\nexport const threshold = 0.42;\n"),
        ("no_policy_numbers", native, "static const double kThreshold = 0.42;\n"),
        ("no_verdict", source, "export function isApproved(score: number): boolean { return score > 1; }\n"),
        ("no_verdict", source, "export const isEligible = (score: number): boolean => score > 1;\n"),
        ("no_verdict", source, "export type Readiness = {permitsCapture: boolean};\n"),
        ("no_verdict", source, "export class Gate { get isLocked(): boolean { return true; } }\n"),
        ("no_verdict", source, "export const label = (d: Date) => d.toLocaleDateString();\n"),
        ("no_verdict", header, "- (BOOL)isApproved;\n"),
        ("no_verdict", native, "NSDateFormatter *formatter = [NSDateFormatter new];\n"),
    ]
    for rule, path, addition in planted:
        kept = path.read_text()
        path.write_text(kept + addition)
        assert CHECKS[rule][0](rn_key), (rule, addition)
        path.write_text(kept)
    vendor_file = package / "src/KenshikiBridge.ts"
    vendor_file.write_text("export {};\n")
    assert any("filename" in hit for hit in CHECKS["no_vendor_identifiers"][0](rn_key))
    vendor_file.unlink()
    for rule, (check, _) in CHECKS.items():
        assert not check(rn_key), ("planting must not leak", rule, check(rn_key))
    # A package nobody can classify fails closed, and so does one the gate cannot read.
    tool = ROOT / "Tools/Web"
    tool.mkdir(parents=True)
    for manifest in ['{"name": "web-tool", "private": true}', "{not json"]:
        (tool / NPM_MANIFEST_NAME).write_text(manifest)
        assert any("Tools/Web/package.json" in line for line in classification_conflicts()), manifest
    (tool / NPM_MANIFEST_NAME).unlink()
    # No TypeScript can be born outside the rules.
    stray = ROOT / "Stray/stray.ts"
    stray.parent.mkdir()
    stray.write_text("export const now = Date.now();\n")
    assert any(UNGOVERNED_TYPESCRIPT_MESSAGE in line for line in classification_conflicts())
    stray.unlink()
    # --- the React Native host ------------------------------------------------------------
    return clean_ts, source, stray

def _probe_react_native_host(clean_ts, source) -> tuple:
    global REACT_NATIVE_HOSTS
    host_directory = ROOT / PROBE_HOST_PATH
    host_directory.mkdir(parents=True)
    REACT_NATIVE_HOSTS = (PROBE_HOST_PATH,)
    host_key = PROBE_HOST_PATH
    app_source = host_directory / "App.tsx"
    clean_host = (
        "import React from 'react';\n"
        "import {ProbeSession} from '@probe/capture';\n"
        "import type {Check} from '@probe/capture';\n"
        "import {styles} from './Styles';\n"
        "jest.mock('@probe/capture', () => ({}));\n"
        "const copy = 'Hold the phone steady against the back cover.';\n"
        "const label = 'com.kenshiki.sample.queue';\n"
        "export const threshold = 0.42;\n"
        "export const isApproved = (): boolean => true;\n"
        "const now = Date.now();\n")
    app_source.write_text(clean_host)
    (host_directory / APP_DELEGATE_NAME).write_text("import UIKit\n")
    (host_directory / HOST_CONFIG_SCRIPT_NAME).write_text(
        "config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'\n")
    assert host_key in host_targets() and host_key not in neutral_targets()
    assert set(dict(scan_plan())[host_key]) == set(SURFACE_CHECKS) | set(HOST_UI_CHECKS)
    assert not classification_conflicts(), classification_conflicts()
    counts = measure()
    for exempt in HOST_EXEMPT:
        assert f"{exempt}::{host_key}" not in counts, exempt
    assert counts[f"no_surface_escape::{host_key}"] == 0, check_no_surface_escape(host_key)
    surface = SURFACE_CHECKS["no_surface_escape"][0]
    for reach in [
        "import {Spec} from '@probe/capture/src/specs/NativeProbe';\n",
        "import {ProbeSession as S} from '../../ReactNative/probe-capture/src/index';\n",
        "const internals = require('@probe/capture/src/index');\n",
        "jest.mock('@probe/capture/src/specs/NativeProbe');\n",
        "import {TurboModuleRegistry} from 'react-native';\nconst m = TurboModuleRegistry.get('NativeProbe');\n",
        "import {NativeModules} from 'react-native';\nconst m = NativeModules.RCTProbe;\n",
        "const module = 'NativeProbe';\n",
        "// @ts-ignore\nconst session = ProbeSession.create();\n",
        "const forged = new ProbeSession('id');\n",
        "const run = (session: ProbeSession) => session['command']('x');\n",
    ]:
        app_source.write_text(clean_host + reach)
        assert surface(host_key), reach
    app_source.write_text(clean_host)
    bridge = host_directory / "Bridge.mm"
    for reach in ['#import "PRBPrivate.h"\n', 'Class probe = NSClassFromString(@"PRBProbe");\n']:
        bridge.write_text(reach)
        assert surface(host_key), reach
    bridge.write_text('#import "PRBPublic.h"\n')
    assert not surface(host_key), surface(host_key)
    bridge.unlink()
    (host_directory / APP_DELEGATE_NAME).write_text("@testable import ProbeRuntime\n")
    assert surface(host_key), "the Swift half of Rule 6 binds a React Native host"
    (host_directory / APP_DELEGATE_NAME).write_text("import UIKit\n")
    (host_directory / HOST_CONFIG_SCRIPT_NAME).write_text(
        "config.build_settings['ENABLE_TESTABILITY'] = 'YES'\n")
    assert any("ENABLE_TESTABILITY" in hit for hit in surface(host_key))
    (host_directory / HOST_CONFIG_SCRIPT_NAME).write_text("")
    assert not surface(host_key), surface(host_key)
    # THE PRICE OF THE EXEMPTION, CHECKED. A neutral package that imports the host...
    source.write_text(clean_ts + "import {styles} from '../../../Examples/ProbeHost/Styles';\n")
    assert any("neutral package imports host source" in line for line in classification_conflicts())
    source.write_text(clean_ts)
    # ...a host the package itself governs, a host inside a Swift neutral target, a host that
    # is also a Swift build target, and a declaration naming nothing: each one is refused.
    (SOURCES / "CaptureProbe/Bridge.ts").write_text("export {};\n")
    for declared, expected in [("ReactNative/probe-capture/src", GOVERNED_MESSAGE),
                               ("Sources/CaptureProbe", NEUTRAL_OVERLAP_MESSAGE),
                               ("Examples/Missing", "holds no script sources")]:
        REACT_NATIVE_HOSTS = (declared,)
        assert any(expected in line for line in classification_conflicts()), \
            (declared, classification_conflicts())
    (SOURCES / "CaptureProbe/Bridge.ts").unlink()
    REACT_NATIVE_HOSTS = (host_key,)
    (host_directory / SWIFT_MANIFEST_NAME).write_text("")
    assert any("also a Swift build target" in line for line in classification_conflicts())
    (host_directory / SWIFT_MANIFEST_NAME).unlink()
    assert not classification_conflicts(), classification_conflicts()
    # REPOSITORY TOOLING (owner decision, 2026-10-09). The root's private manifest is a
    # conflict until declared; declared, it governs neither the host nor any TypeScript.
    return app_source, clean_host, host_directory, host_key, surface

def _probe_repository_tooling(host_directory, stray) -> None:
    global RN_TOOLING_MANIFESTS
    tooling = ROOT / NPM_MANIFEST_NAME
    tooling.write_text('{"name": "quality", "private": true, "devDependencies": {}}')
    assert any(line.startswith("package.json:") and "classify it" in line
               for line in classification_conflicts()), classification_conflicts()
    assert any(GOVERNED_MESSAGE in line for line in classification_conflicts())
    RN_TOOLING_MANIFESTS = (".",)
    assert not classification_conflicts(), classification_conflicts()
    # A package.json inside a shipped path is still caught: in the host, in the package's
    # shipped sources, or declared as tooling there.
    for planted in [host_directory / NPM_MANIFEST_NAME,
                    ROOT / "ReactNative/probe-capture/src/package.json"]:
        planted.write_text('{"name": "planted", "private": true}')
        assert any(rel(planted) in line for line in classification_conflicts()), \
            (planted, classification_conflicts())
        if planted.parent == host_directory:
            assert any(GOVERNED_MESSAGE in line for line in classification_conflicts())
        RN_TOOLING_MANIFESTS = (".", rel(planted.parent))
        assert any("tooling inside a shipped or host directory" in line
                   for line in classification_conflicts()), classification_conflicts()
        RN_TOOLING_MANIFESTS = (".",)
        planted.unlink()
    # A tooling manifest that could ship, link, or build what it governs is refused, and so
    # is a declaration that names nothing.
    for manifest, expected in [('{"name": "quality"}', "can be published"),
                               ('{"private": true, "workspaces": ["Examples/*"]}', "`workspaces`"),
                               ('{"private": true, "codegenConfig": {}}', "`codegenConfig`")]:
        tooling.write_text(manifest)
        assert any(expected in line for line in classification_conflicts()), \
            (manifest, classification_conflicts())
    tooling.unlink()
    assert any("names a directory with no package.json" in line
               for line in classification_conflicts())
    tooling.write_text('{"name": "quality", "private": true}')
    # Tooling covers no TypeScript: a stray file is still outside every rule.
    stray.parent.mkdir(exist_ok=True)
    stray.write_text("export const now = Date.now();\n")
    assert any(UNGOVERNED_TYPESCRIPT_MESSAGE in line for line in classification_conflicts())
    stray.unlink()
    assert not classification_conflicts(), classification_conflicts()
    # What the tooling installs is a dependency tree, not a target: a Package.swift inside
    # node_modules declares nothing this gate scans.
    installed = ROOT / "node_modules/probe-native/Package.swift"
    installed.parent.mkdir(parents=True)
    installed.write_text('.target(name: "InstalledProbe")')
    (installed.parent / "Sources/InstalledProbe").mkdir(parents=True)
    (installed.parent / "Sources/InstalledProbe/Probe.swift").write_text("let now = Date()\n")
    assert not any("InstalledProbe" in key for key in neutral_targets()), neutral_targets()
    assert not any("InstalledProbe" in key for key in measure()), "an install tree is not measured"
    shutil.rmtree(ROOT / "node_modules")
    tooling.unlink()
    RN_TOOLING_MANIFESTS = ()
    assert not classification_conflicts(), classification_conflicts()

def _probe_host_test_files(app_source, clean_host, host_directory, host_key, surface) -> object:
    global RN_HOST_UI_TESTS
    reach = "import {Spec} from '@probe/capture/src/specs/NativeProbe';\n"
    jest_test = host_directory / "Flow.test.tsx"
    jest_test.write_text(clean_host + reach)
    assert not surface(host_key), surface(host_key)
    assert not classification_conflicts(), classification_conflicts()
    # ...but only while nothing that ships imports it.
    app_source.write_text(clean_host + "import {helper} from './Flow.test';\n")
    assert any("host source imports test file" in line for line in classification_conflicts())
    app_source.write_text(clean_host)
    # The UI test is skipped because it is DECLARED, not because of its name or its import.
    ui_test = host_directory / ARTIFACT_TEST_NAME
    ui_test.write_text("import XCTest\n@testable import ProbeRuntime\n")
    assert surface(host_key), "an undeclared UI test is host source"
    RN_HOST_UI_TESTS = {host_key: (ARTIFACT_TEST_NAME,)}
    assert not surface(host_key), surface(host_key)
    assert not classification_conflicts(), classification_conflicts()
    ui_test.write_text("@testable import ProbeRuntime\n")
    assert any("imports no XCTest" in line for line in classification_conflicts())
    ui_test.unlink()
    assert any("does not exist" in line for line in classification_conflicts())
    RN_HOST_UI_TESTS = {}
    jest_test.unlink()
    assert not classification_conflicts(), classification_conflicts()
    # TYPESCRIPT IN AN XCODEGEN TEST BUNDLE is a seen file in an excluded target, not a
    # file outside every rule — and a neutral package still may not import from it.
    return jest_test

def _probe_xcodegen_test_files(clean_ts, source) -> None:
    runtime = ROOT / "Distribution/ProbeRuntime"
    (runtime / "Tests/Fixtures").mkdir(parents=True)
    fixture_ts = runtime / "Tests/Fixtures/Schema.ts"
    fixture_ts.write_text("export const fixtures = {};\n")
    assert any(UNGOVERNED_TYPESCRIPT_MESSAGE in line for line in classification_conflicts())
    (runtime / XCODEGEN_PROJECT_NAME).write_text(
        "name: ProbeRuntime\n"
        "targets:\n"
        "  ProbeRuntimeTests:\n"
        "    type: bundle.unit-test\n"
        "    sources:\n"
        "      - path: Tests\n"
        "        excludes: [\"Fixtures/**\"]\n")
    assert not classification_conflicts(), classification_conflicts()
    source.write_text(clean_ts + "import {fixtures} from "
                      "'../../../Distribution/ProbeRuntime/Tests/Fixtures/Schema';\n")
    assert any("imports test-bundle source" in line for line in classification_conflicts())
    source.write_text(clean_ts)
    assert not classification_conflicts(), classification_conflicts()

def _probe_host_presentation(app_source, clean_host, host_directory, host_key, jest_test) -> None:
    global RN_HOST_UI_RESOURCES
    inline_ui = HOST_UI_CHECKS["no_inline_ui"][0]
    clean_screen = (
        "import React from 'react';\n"
        "import {StyleSheet, Text, View} from 'react-native';\n"
        "import {color, size, spacing, text} from './ui/tokens.generated';\n"
        "import {t} from './locales/i18n';\n"
        "const styles = StyleSheet.create({body: {...text.body, color: color.text, padding: spacing.md},\n"
        "  root: {flex: 1, justifyContent: 'flex-end', width: '100%', maxHeight: size.sheetMaxHeight}});\n"
        "export const Screen = () => <View style={styles.root} testID=\"open-phone\">\n"
        "  <Text accessibilityRole=\"header\" style={styles.body}>{t('hub.title')}</Text>\n"
        "  {[1, 2].map(n => <Text key={`row-${n}`}>{t('hub.title')}</Text>)}\n"
        "</View>;\n")
    app_source.write_text(clean_screen)
    assert not inline_ui(host_key), inline_ui(host_key)
    for planted in [
        "const a = {color: '#fff'};\n",
        "const a = {backgroundColor: '#0008'};\n",
        "const a = {color: 'rgba(0, 0, 0, 0.5)'};\n",
        "const a = {borderColor: 'white'};\n",
        "const a = {color: PlatformColor('systemRed')};\n",
        "const a = {color: DynamicColorIOS({light: x, dark: y})};\n",
        "const a = {fontSize: 18};\n",
        "const a = {lineHeight: 26};\n",
        "const a = {fontWeight: '700'};\n",
        "const a = {borderRadius: 14};\n",
        "const a = {borderTopLeftRadius: 28};\n",
        "const a = {padding: 24};\n",
        "const a = {marginHorizontal: .5};\n",
        "const a = {gap: 16};\n",
        "const copy = 'Hold the phone steady against the back cover.';\n",
        "const hint = (group: string) => `Reading ${group}, keep the phone still.`;\n",
        "export const Hint = () => <Text>Hold the phone steady.</Text>;\n",
        "export const Label = () => <Text accessibilityLabel=\"Passport chip photo\" />;\n",
    ]:
        app_source.write_text(clean_screen + planted)
        assert inline_ui(host_key), planted
    app_source.write_text(clean_screen)
    # Test files are not scanned, as for Rule 6.
    jest_test.write_text(clean_screen + "const copy = 'Hold the phone steady.';\n")
    assert not inline_ui(host_key), inline_ui(host_key)
    jest_test.unlink()
    # A generated module is host source until it is declared...
    (host_directory / "ui").mkdir()
    generated = host_directory / GENERATED_TOKEN_PATH
    generated_text = ("export const color = {onTint: '#FFFFFF'};\n"
                      "export const copy = 'Hold the phone steady.';\n")
    generated.write_text(generated_text)
    assert len(inline_ui(host_key)) == 2, inline_ui(host_key)
    generator = host_directory / GENERATOR_SCRIPT_NAME
    generator.write_text(
        "import pathlib, sys\n"
        f"expected = {generated_text!r}\n"
        "path = pathlib.Path(__file__).with_name('ui') / 'tokens.generated.ts'\n"
        "fresh = path.is_file() and path.read_text() == expected\n"
        "sys.exit(0 if sys.argv[1:] == ['--check'] and fresh else 1)\n")
    tokens_declaration = {"generator": GENERATOR_SCRIPT_NAME, "generated": (GENERATED_TOKEN_PATH,)}
    RN_HOST_UI_RESOURCES = {host_key: (tokens_declaration,)}
    # ...and declared, it is exempt only while its generator says it is fresh.
    assert not inline_ui(host_key), inline_ui(host_key)
    assert not classification_conflicts(), classification_conflicts()
    generated.write_text(generated_text + "export const forged = {fontSize: 18};\n")
    assert not inline_ui(host_key), "the exemption is by declaration"
    assert any("--check failed" in line for line in classification_conflicts()), \
        classification_conflicts()
    generated.write_text(generated_text)
    assert not classification_conflicts(), classification_conflicts()
    # GENERATED UI DATA, 2026-10-09. JSON a script imports is read by no check, so an
    # undeclared JSON import is a finding; declared, it is held to its own generator.
    data = host_directory / "presentation/copy.json"
    data.parent.mkdir()
    data_text = '{"hint": "Hold the phone steady."}\n'
    data.write_text(data_text)
    app_source.write_text(clean_screen + "import words from './presentation/copy.json';\n")
    assert any("imports UI data no generator declares" in hit for hit in inline_ui(host_key)), \
        inline_ui(host_key)
    data_generator = host_directory / "presentation/generate.py"
    data_generator.write_text(
        "import pathlib, sys\n"
        f"expected = {data_text!r}\n"
        "path = pathlib.Path(__file__).with_name('copy.json')\n"
        "fresh = path.is_file() and path.read_text() == expected\n"
        "sys.exit(0 if sys.argv[1:] == ['--check'] and fresh else 1)\n")
    data_declaration = {"generator": "presentation/generate.py",
                        "generated": ("presentation/copy.json",)}
    RN_HOST_UI_RESOURCES = {host_key: (tokens_declaration, data_declaration)}
    assert not inline_ui(host_key), inline_ui(host_key)
    assert not classification_conflicts(), classification_conflicts()
    # Each declaration's generator is checked on its own: hand-written data is a conflict
    # even while the other generator is fresh.
    data.write_text('{"hint": "Written by hand."}\n')
    assert any("presentation/generate.py --check failed" in line
               for line in classification_conflicts()), classification_conflicts()
    data.write_text(data_text)
    assert not classification_conflicts(), classification_conflicts()
    # A declared file must be a script or JSON data inside the host.
    for written in ("presentation/copy.txt", "../Elsewhere/copy.json"):
        RN_HOST_UI_RESOURCES = {host_key: (tokens_declaration,
                                           dict(data_declaration, generated=(written,)))}
        assert any("is not a script or JSON data inside the host" in line
                   for line in classification_conflicts()), (written, classification_conflicts())
    RN_HOST_UI_RESOURCES = {host_key: (tokens_declaration,)}
    app_source.write_text(clean_screen)
    data_generator.unlink()
    data.unlink()
    data.parent.rmdir()
    assert not classification_conflicts(), classification_conflicts()
    # A declaration naming nothing, or naming an undeclared host, is refused.
    generator.unlink()
    assert any("generator generate.py does not exist" in line for line in classification_conflicts())
    RN_HOST_UI_RESOURCES = {"Examples/Elsewhere": ({"generator": GENERATOR_SCRIPT_NAME, "generated": ()},)}
    assert any("REACT_NATIVE_HOSTS does not declare" in line for line in classification_conflicts())
    RN_HOST_UI_RESOURCES = {}
    generated.unlink()
    (host_directory / "ui").rmdir()
    app_source.write_text(clean_host)
    assert not classification_conflicts(), classification_conflicts()

def _probe_vendor_adapters(fixture, good_host, library, neutral) -> None:
    global VENDOR_ADAPTERS
    MANIFEST.write_text(library + neutral + good_host)
    adapter = ROOT / "Packages/ProbeAdapter"
    (adapter / "Sources/ProbeAdapter").mkdir(parents=True)
    adapter_source = adapter / "Sources/ProbeAdapter/Adapter.swift"
    adapter_manifest = adapter / SWIFT_MANIFEST_NAME
    adapter_key = "Packages/ProbeAdapter/ProbeAdapter"
    good_adapter = ('.package(name: "Root", path: "../.."), '
                    '.library(name: "ProbeAdapter", targets: ["ProbeAdapter"]), '
                    '.target(name: "ProbeAdapter", dependencies: '
                    '[.product(name: "CaptureProbe", package: "Root")])')
    adapter_manifest.write_text(good_adapter)
    vendor_job = ('import CaptureProbe\n'
                  'public struct WireFailure: LocalizedError { public var errorDescription: String? '
                  '{ "The Pulse service refused the request." } }\n'
                  'let route = "com.pulse.identity.v1"\n'
                  'struct Limits { static let maximumBytes = 33554432 }\n'
                  'let sent = Date()\n'
                  'public var isAccepted: Bool { true }\n')
    adapter_source.write_text(vendor_job)
    (adapter / "README.md").write_text("This is a vendor adapter, not a neutral component.\n")
    # A README, a directory and a vendor-shaped body do not mint the role.
    assert adapter_key in neutral_targets(), "text must not mint a vendor adapter"
    counts = measure()
    for rule in CHECKS:
        assert counts[f"{rule}::{adapter_key}"] >= 1, rule
    # THE HONEST DECLARATION: exempt from the five, bound by Rule 6, no conflict.
    VENDOR_ADAPTERS = {adapter_key: "Probe"}
    assert adapter_key not in neutral_targets()
    assert set(dict(scan_plan())[adapter_key]) == set(SURFACE_CHECKS)
    counts = measure()
    for exempt in HOST_EXEMPT:
        assert f"{exempt}::{adapter_key}" not in counts, exempt
    assert counts[f"no_surface_escape::{adapter_key}"] == 0, check_no_surface_escape(adapter_key)
    assert not classification_conflicts(), classification_conflicts()
    # Rule 6 binds it: the source half...
    for reach in [PROBE_TESTABLE_IMPORT,
                  PROBE_SPI_IMPORT,
                  PROBE_MIRROR_SOURCE]:
        adapter_source.write_text(reach)
        assert check_no_surface_escape(adapter_key), reach
    adapter_source.write_text(vendor_job)
    # ...and the manifest half, in its own Package.swift.
    adapter_manifest.write_text(good_adapter.replace(
        "package: \"Root\")]", "package: \"Root\")], swiftSettings: [.unsafeFlags([\"-enable-testing\"])]"))
    hits = check_no_surface_escape(adapter_key)
    assert any("unsafeFlags" in hit for hit in hits) and any("enables testing" in hit for hit in hits), hits
    adapter_manifest.write_text(good_adapter.replace('name: "CaptureProbe", package',
                                                     'name: "CaptureInternal", package'))
    assert any("does not declare as a .library product" in hit
               for hit in check_no_surface_escape(adapter_key)), check_no_surface_escape(adapter_key)
    adapter_manifest.write_text(good_adapter)
    assert not check_no_surface_escape(adapter_key)
    # THE PRICE, CHECKED. A neutral target that depends on the adapter...
    MANIFEST.write_text(library + neutral.replace(
        '.target(name: "CaptureNew")',
        '.target(name: "CaptureNew", dependencies: [.product(name: "ProbeAdapter", '
        'package: "ProbeAdapter")])') + good_host
        + ', .package(path: "Packages/ProbeAdapter")')
    assert any("CaptureNew: neutral target depends on vendor adapter" in line
               for line in classification_conflicts()), classification_conflicts()
    MANIFEST.write_text(library + neutral + good_host)
    # ...a neutral source that imports it...
    fixture.write_text("internal import ProbeAdapter\n")
    assert any("neutral target imports vendor adapter" in line
               for line in classification_conflicts()), classification_conflicts()
    fixture.write_text("")
    # ...a neutral XcodeGen framework that depends on its package...
    kit = ROOT / "Distribution/ProbeKit"
    (kit / "Sources").mkdir(parents=True)
    (kit / "Sources/Kit.swift").write_text(PROBE_IMPORT)
    (kit / XCODEGEN_PROJECT_NAME).write_text(
        "name: ProbeKit\n"
        "packages:\n"
        "  ProbeAdapter:\n"
        "    path: ../../Packages/ProbeAdapter\n"
        "targets:\n"
        "  ProbeKit:\n"
        "    type: framework\n"
        "    sources: [Sources]\n"
        "    dependencies:\n"
        "      - package: ProbeAdapter\n"
        "        product: ProbeAdapter\n")
    assert any("Distribution/ProbeKit/ProbeKit: neutral target depends on vendor adapter" in line
               for line in classification_conflicts()), classification_conflicts()
    (kit / XCODEGEN_PROJECT_NAME).unlink()
    assert not classification_conflicts(), classification_conflicts()
    # ...an adapter no library exports, an unnamed vendor, a declaration naming nothing.
    adapter_manifest.write_text('.target(name: "ProbeAdapter")')
    assert any("no .library product exports it" in line for line in classification_conflicts())
    adapter_manifest.write_text(good_adapter)
    VENDOR_ADAPTERS = {adapter_key: " "}
    assert any("names no vendor" in line for line in classification_conflicts())
    VENDOR_ADAPTERS = {"Packages/Missing/Missing": "Probe"}
    assert any("no Package.swift declares it" in line for line in classification_conflicts())
    assert adapter_key in neutral_targets(), "an undeclared adapter is neutral again"
    VENDOR_ADAPTERS = {adapter_key: "Probe"}
    # Leaving the five neutral rules does not take an adapter's stores out of erase-all.
    adapter_source.write_text("extension ProbeTape: PersistedStore {}\n")
    assert any("ProbeTape" in line for line in persistence_registry_gaps()), persistence_registry_gaps()
    adapter_source.write_text(vendor_job)
    assert not classification_conflicts(), classification_conflicts()

def _probe_third_party_packages() -> None:
    global THIRD_PARTY_PACKAGES
    upstream = ROOT / PROBE_UPSTREAM_PATH
    (upstream / "Sources/ProbeUpstream").mkdir(parents=True)
    (upstream / SWIFT_MANIFEST_NAME).write_text(
        '.library(name: "ProbeUpstream", targets: ["ProbeUpstream"]), .target(name: "ProbeUpstream")')
    (upstream / "LICENSE").write_text("MIT License\n")
    upstream_source = upstream / "Sources/ProbeUpstream/Reader.swift"
    upstream_code = ('import Foundation\n'
                     'public struct ReaderFailure: LocalizedError { public var errorDescription: '
                     'String? { "Hold your iPhone near the passport." } }\n'
                     'struct Timing { static let timeout = 20.0 }\n'
                     'let started = Date()\n'
                     'public var isPassportValid: Bool { true }\n')
    upstream_source.write_text(upstream_code)
    tp_key = "ThirdParty/ProbeUpstream/ProbeUpstream"
    provenance_path = upstream / THIRD_PARTY_PROVENANCE
    good_provenance = {
        "upstream": {"name": "ProbeUpstream", "version": "1.2.3",
                     "url": "https://example.org/probe-upstream", "licence": "MIT",
                     "licenceFile": "LICENSE"},
        "patches": [{"id": "guard", "files": ["Sources/ProbeUpstream/Reader.swift"],
                     "changes": "Guards an empty array before removeFirst()."}]}
    provenance_path.write_text(json.dumps(good_provenance))
    # A provenance file alone does not mint the role: undeclared, it is neutral.
    assert tp_key in neutral_targets(), "a provenance file must not mint third-party"
    assert measure()[f"no_ambient::{tp_key}"] == 1
    # THE HONEST DECLARATION.
    THIRD_PARTY_PACKAGES = (PROBE_UPSTREAM_PATH,)
    assert tp_key not in neutral_targets()
    assert set(dict(scan_plan())[tp_key]) == set(SURFACE_CHECKS)
    counts = measure()
    for exempt in HOST_EXEMPT:
        assert f"{exempt}::{tp_key}" not in counts, exempt
    assert counts[f"no_surface_escape::{tp_key}"] == 0, check_no_surface_escape(tp_key)
    assert not classification_conflicts(), classification_conflicts()
    # Rule 6 binds a local patch like any other source.
    upstream_source.write_text(upstream_code + "let fields = Mirror(reflecting: started)\n")
    assert check_no_surface_escape(tp_key)
    upstream_source.write_text(upstream_code)
    # MISSING OR INCOMPLETE PROVENANCE IS FATAL, and the package is neutral meanwhile.
    incomplete = []
    for field in PROVENANCE_FIELDS:
        broken = json.loads(json.dumps(good_provenance))
        del broken["upstream"][field]
        incomplete.append((broken, f"upstream.{field} is missing"))
    for mutate, expected in [
        (lambda d: d["upstream"].update(url="http://example.org/probe"), "not an https URL"),
        (lambda d: d["upstream"].update(licenceFile="COPYING"), "does not exist"),
        (lambda d: d.pop("patches"), "`patches` is not a list"),
        (lambda d: d["patches"][0].pop("changes"), "does not say what it changes"),
        (lambda d: d["patches"][0].update(files=[]), "names no files"),
        (lambda d: d["patches"][0].update(files=["Sources/Gone.swift"]), "which does not exist"),
    ]:
        broken = json.loads(json.dumps(good_provenance))
        mutate(broken)
        incomplete.append((broken, expected))
    for broken, expected in incomplete:
        provenance_path.write_text(json.dumps(broken))
        assert any(expected in line for line in classification_conflicts()), \
            (expected, classification_conflicts())
        assert tp_key in neutral_targets(), expected
    provenance_path.write_text("{not json")
    assert any("missing or unreadable" in line for line in classification_conflicts())
    provenance_path.unlink()
    assert any("missing or unreadable" in line for line in classification_conflicts())
    assert measure()[f"no_ambient::{tp_key}"] == 1
    provenance_path.write_text(json.dumps(good_provenance))
    assert not classification_conflicts(), classification_conflicts()
    # Upstream code cannot import ours: moving SDK code into ThirdParty buys a conflict.
    upstream_source.write_text(PROBE_IMPORT + upstream_code)
    assert any("third-party source imports this repository's module CaptureProbe" in line
               for line in classification_conflicts()), classification_conflicts()
    upstream_source.write_text(upstream_code)
    # Declared outside ThirdParty/, or with no package: refused.
    THIRD_PARTY_PACKAGES = ("Packages/SameName",)
    assert any("not a directory directly under ThirdParty/" in line
               for line in classification_conflicts())
    THIRD_PARTY_PACKAGES = ("ThirdParty/Missing",)
    assert any("holds no Package.swift" in line for line in classification_conflicts())
    THIRD_PARTY_PACKAGES = (PROBE_UPSTREAM_PATH,)
    # An UNDECLARED ThirdParty package stays neutral: the directory grants nothing.
    assert measure()["no_ambient::ThirdParty/SameName/Provider"] == 1
    assert not classification_conflicts(), classification_conflicts()

    assert not BASELINE_PATH.exists(), "Self tests must never create or bank baselines"

def _parse_boundary_arguments():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--report", action="store_true")
    parser.add_argument("--self-test", action="store_true", help="run adversarial/discovery regression probes")
    parser.add_argument("--write-baseline", action="store_true")
    parser.add_argument("--establish", action="store_true",
                        help="re-establish every baseline; only when a CHECK definition changed")
    parser.add_argument("--baseline-target", action="append", default=[],
                        help="with --write-baseline, bank only this exact target; may repeat; refuses raises")
    args = parser.parse_args()
    if args.baseline_target and (args.write_baseline == args.establish or args.report or args.self_test):
        parser.error("--baseline-target requires exactly one of --write-baseline or --establish")
    return args

def _report_classification_conflicts(report):
    conflicts = classification_conflicts()
    if conflicts:
        print("HOST CLASSIFICATION CONFLICT. An .executableTarget is claiming the host exemption")
        print("from the five neutral rules while still being part of the SDK surface. A target is a")
        print("host or it is neutral; there is no baseline for being both.")
        for line in conflicts:
            print(f"  ✗  {line}")
        if not report:
            return 1
        print()

def _report_persistence_gaps(report):
    gaps = persistence_registry_gaps()
    if gaps:
        print("UNREGISTERED PERSISTED STORE. A store conforms to PersistedStore — it leaves")
        print("holder data on the device — and no registry's `allStores` names it, so the public")
        print("eraseAll() walks past it. A hand-written list is only safe while something fails")
        print("when it is wrong; this is that something. Add the store to its module's registry.")
        for line in gaps:
            print(f"  ✗  {line}")
        if not report:
            return 1
        print()

def _report_xcodegen_inventory():
    for record in _xcodegen_records():
        where = ", ".join(rel(directory) for directory in record["directories"]) or "nothing"
        if record["role"] in {"host", "neutral"}:
            print(f"XcodeGen {record['role']} {record['key']} ({record['type']}) scanning {where}")
        else:
            # An excluded target is still a SEEN target. The count is what Rule 6 WOULD score
            # if a test bundle were scanned as a host, printed so the exclusion argued above
            # `XCODEGEN_TEST_TYPES` can be judged against a number instead of taken on trust.
            would = len(_surface_escapes_in_files(_swift_files_in(record["directories"])))
            print(f"XcodeGen {record['role']} target {record['key']} ({record['type']}) NOT "
                  f"scanned; Rule 6 would score {would} over {where}")

def _report_npm_inventory():
    for record in _npm_records():
        where = ", ".join(rel(directory) for directory in record["directories"]) or "nothing"
        print(f"npm {record['role']} {record['key']} ({record['name'] or 'unnamed'}) scanning {where}")

def _report_react_native_inventory():
    for record in _rn_host_records():
        print(f"React Native host {record['key']} (REACT_NATIVE_HOSTS) scanning "
              f"{rel(record['directory'])}")
        tests = _rn_host_test_files(record["key"])
        scripts = [path for path in tests if not path.name.endswith(".swift")]
        would = (len(_rn_surface_escapes(record["key"], files=scripts))
                 + len(_surface_escapes_in_files([path for path in tests
                                                  if path.name.endswith(".swift")])))
        print(f"  {len(tests)} test file(s) NOT scanned; Rule 6 would score {would}")

def _report_vendor_adapter_inventory(roles):
    for key, vendor in sorted(VENDOR_ADAPTERS.items()):
        print(f"vendor adapter {key} (VENDOR_ADAPTERS, vendor {vendor}) — {roles.get(key, 'absent')}; "
              "exempt from the five neutral rules, bound by Rule 6")

def _report_third_party_inventory(roles):
    for written in THIRD_PARTY_PACKAGES:
        keys = [key for key, directory, _ in _inventory()
                if directory == ROOT / written or ROOT / written in directory.parents]
        print(f"third-party {written} (THIRD_PARTY_PACKAGES, {THIRD_PARTY_PROVENANCE}) — "
              + ", ".join(f"{key}: {roles.get(key)}" for key in _unique(keys)))

def _report_target_findings():
    for target, applicable in scan_plan():
        for name, (fn, label) in applicable.items():
            hits = fn(target)
            if hits:
                print(f"=== {target} / {label} — {len(hits)} ===")
                for hit in hits[:10]:
                    print(f"  {hit}")

def _report_global_findings():
    for name, (fn, label) in GLOBAL_CHECKS.items():
        hits = fn()
        print(f"\n=== {label} — {len(hits)} ===")
        for hit in hits:
            print(f"  {hit}")

def _report_boundary_scan(targets):
    hosts = host_targets()
    profiles = profile_targets()
    print(f"scanning {len(targets)} neutral targets from package/project manifests: {', '.join(targets)}")
    print(f"host/example targets (exempt from the five neutral rules; bound by Rule 6): {(', '.join(hosts) if hosts else 'none')}")
    print(f"vendor profiles (same exemption, same Rule 6; classified structurally, never by name): {(', '.join(profiles) if profiles else 'none')}")
    _report_xcodegen_inventory()
    _report_npm_inventory()
    _report_react_native_inventory()
    roles = {key: role for (key, _, role) in _inventory()}
    _report_vendor_adapter_inventory(roles)
    _report_third_party_inventory(roles)
    (stores, registered, _) = _persisted_stores()
    print(f'persisted stores: {len(stores)} conformance(s) in shipped library targets, {len(stores) - len(set(stores) - registered)} named by a registry')
    print()
    _report_target_findings()
    _report_global_findings()
    return 0

def _establish_named_baseline(args, current, baseline):
    try:
        updated = scoped_establish(current, baseline, args.baseline_target)
    except ValueError as error:
        print(error)
        return 1
    BASELINE_PATH.write_text(json.dumps(updated, indent=2, sort_keys=True) + "\n")
    print("RE-ESTABLISHED the named targets only. Honest only when a CHECK's definition changed")
    print("for them; every other counter is exactly as banked:")
    for key in sorted(set(baseline) | set(updated)):
        if baseline.get(key) != updated.get(key):
            print(f"  {key}: {baseline.get(key, 'absent')} -> {updated.get(key, 'dropped')}")
    return 0

def _establish_all_baselines(args, current, baseline):
    BASELINE_PATH.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
    print("RE-ESTABLISHED every baseline. Honest only when a CHECK's definition changed;")
    print("if the CODE changed, use --write-baseline, which refuses raises.")
    print(f"  {len(current)} counters, {sum(current.values())} total findings")
    return 0

def _bank_named_baseline(args, current, baseline):
    try:
        updated = scoped_baseline(current, baseline, args.baseline_target)
    except ValueError as error:
        print(error)
        return 1
    BASELINE_PATH.write_text(json.dumps(updated, indent=2, sort_keys=True) + "\n")
    print("banked exact targets; all other counters unchanged: " + ", ".join(args.baseline_target))
    return 0

def _bank_all_baselines(args, current, baseline):
    raised = [f"{k}: {baseline[k]} -> {v}" for k, v in current.items()
              if k in baseline and v > baseline[k]]
    if raised:
        print("REFUSED — a baseline is banked after an improvement, never raised to admit one:")
        for line in raised:
            print(f"  {line}")
        return 1
    # PRUNE, and say what was pruned. The old merge was `{**baseline, **current}`, which
    # could never drop a key: a counter that stopped being measured stayed in the file at its
    # last value, and nothing printed. Writing `current` alone drops it — so the drop has to
    # be announced, loudly and with the value, because this is the channel by which debt
    # leaves without being paid. Reclassifying one module as a host or profile retires its
    # five neutral counters at once; for KenshikiIdentity that would be 184 findings.
    vanished = {k: v for k, v in baseline.items() if k not in current}
    BASELINE_PATH.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
    print(f"banked {len(current)} counters, {sum(current.values())} total")
    if vanished:
        print(f"\n  DROPPED {len(vanished)} counter(s) that are no longer measured, carrying")
        print(f"  {sum(vanished.values())} finding(s) with them. If a target was reclassified")
        print("  rather than deleted, this is debt being retired without being paid:")
        for key, was in sorted(vanished.items()):
            print(f"      {key}: was {was}")
    return 0

def _compare_boundary_measurements(current, baseline):
    failed = False
    unbaselined = []
    by_rule: dict[str, list[int]] = {}
    for key, value in sorted(current.items()):
        allowed = baseline.get(key)
        rule = key.split("::")[0]
        got, cap = by_rule.get(rule, [0, 0])
        by_rule[rule] = [got + value, cap + (allowed or 0)]
        if allowed is None:
            unbaselined.append(key)
        elif value > allowed:
            failed = True
            print(f"  ✗  {key}: {value}, baseline {allowed} (+{value - allowed})")
    return failed, unbaselined, by_rule

def _report_rule_totals(by_rule):
    for rule, (got, cap) in sorted(by_rule.items()):
        label = (CHECKS.get(rule) or SURFACE_CHECKS.get(rule) or HOST_UI_CHECKS.get(rule)
                 or GLOBAL_CHECKS.get(rule) or (None, rule))[1]
        mark = "✗"
        if got == cap:
            mark = "·"
        elif got < cap:
            mark = "↓"
        print(f"  {mark}  {label}: {got} (baseline {cap})")

def _report_missing_baselines(unbaselined):
    print(f"\n  {len(unbaselined)} counter(s) unmeasured — a target with no baseline is a")
    print("  target outside the rules. Run --write-baseline.")
    for key in unbaselined[:6]:
        print(f"      {key}")

def _report_vanished_baselines(vanished, baseline):
    carried = sum(baseline[key] for key in vanished)
    print(f"\n  {len(vanished)} counter(s) VANISHED, carrying {carried} finding(s). A counter")
    print("  that stops being measured is how debt leaves without being paid. If the target")
    print("  was genuinely deleted, run --write-baseline, which drops it and prints what it")
    print("  dropped. If it was reclassified, the findings did not go anywhere.")
    for key in vanished[:6]:
        print(f"      {key}: was {baseline[key]}")

def _update_boundary_baseline(args, current, baseline):
    if args.establish:
        operation = _establish_named_baseline if args.baseline_target else _establish_all_baselines
        return operation(args, current, baseline)
    if args.write_baseline:
        operation = _bank_named_baseline if args.baseline_target else _bank_all_baselines
        return operation(args, current, baseline)
    return None

def _evaluate_boundary_measurements(current, baseline):
    failed, unbaselined, by_rule = _compare_boundary_measurements(current, baseline)
    _report_rule_totals(by_rule)
    if unbaselined:
        failed = True
        _report_missing_baselines(unbaselined)
    vanished = sorted(key for key in baseline if key not in current)
    if vanished:
        failed = True
        _report_vanished_baselines(vanished, baseline)
    if failed:
        print("\nA boundary rule regressed, or a target is unmeasured.")
        print("docs/boundary-contract.md says why each rule exists. Baselines shrink; never raise.")
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
