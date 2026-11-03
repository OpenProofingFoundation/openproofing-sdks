#!/usr/bin/env python3
"""Verify the capture bridge receipt, recipe, exports and shipped-content policy.

Usage:
  python3 scripts/verify_capture_bridge.py [--directory DIR]
  python3 scripts/verify_capture_bridge.py --scan FILE_OR_DIRECTORY...

The first form verifies DIR/DocumentOpenCVBridge.xcframework against DIR/build-receipt.json
(default DIR: .build/native). The second form only scans shipped files for build-host
paths and internal names; the packaging script uses it for every file it ships.

Upstream prebuilts carry their makers' build-machine paths. The allowlist scopes reviewed rules
to named components. Retired document-reader components are prohibited in delivered content.
"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAME = "DocumentOpenCVBridge"
BUILD_SCRIPT = ROOT / "scripts/build_capture_bridge.py"
ALLOWLIST = ROOT / "scripts/upstream-path-allowlist.json"
EXPORTS = {"_IEOpenCVDetectDocumentQuadrilateralRGBA", "_IEOpenCVID1Matrices", "_IEOpenCVWarpRGBA", "_IEOpenCVAnalyzeCardRGB", "_IEOpenCVCardAnalysisPoints", "_IEOpenCVCardAnalysisOffsets", "_IEOpenCVCardAnalysisMask", "_IEOpenCVCardAnalysisRelease"}
PREFIX_MAPS = ["-ffile-prefix-map=<root>=.", "-fdebug-prefix-map=<root>=."]
MACH_O_MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
                b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
# An absolute path inside a Mach-O string section or load command is a build-host path unless it
# names an iOS runtime location that the loader or libc resolves on the phone.
RUNTIME_PREFIXES = ("/System/Library/", "/usr/lib/", "/dev/")
# Text and other non-Mach-O files legitimately contain route paths and base64; there, a path is
# rejected when it starts at a build-host filesystem root.
HOST_ROOTS = ("/Users/", "/home/", "/tmp/", "/private/", "/var/folders/", "/var/tmp/", "/Volumes/",
              "/Applications/", "/opt/", "/root/")
ABSOLUTE_PATH = re.compile(r"(?<![A-Za-z0-9_.~+:/-])/[A-Za-z][A-Za-z0-9_.+@-]*(?:/[A-Za-z0-9_.+@-]+)+")
PRINTABLE_RUN = re.compile(rb"[\x20-\x7e]{4,}")
# Internal names that no shipped file may carry. Case-sensitive. A term ending in a lowercase
# letter must not run on into a lowercase letter ("Personal", "demosaicing" are ordinary words),
# a term starting in lowercase must not continue a word ("xshfx"), and an all-capitals term must
# not sit inside a longer capitalised word ("HASHFUNC"); identifiers such as "PersonaDocumentReader"
# or "SHF-device" still match. Product names (Pulse, Sensors) remain public.
INTERNAL_NAMES = ["/Users", "/tmp", "shf", "SHF", "BlinkID", "Persona", "Camara", "MicroBilt",
                  "Codex", "Claude", "demo", "Regula", "regula", "DocumentReader", "DocumentReaderCore", "RegulaCommon"]


def term_pattern(term):
    capitals = term.isalpha() and term.isupper()
    start = "(?<![A-Za-z])" if term[0].islower() else "(?<![A-Z])" if capitals else ""
    end = "(?![a-z])" if term[-1].islower() else "(?![A-Z])" if capitals else ""
    return start + re.escape(term) + end


INTERNAL_NAME = re.compile("|".join(term_pattern(term) for term in INTERNAL_NAMES))


class VerificationError(Exception):
    pass


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_allowlist():
    """Load component rules and pinned vendor-file rules after verifying their recorded provenance.

    An item with "prefix" exempts any path starting with it; an item with "line" exempts only a
    strings(1) line exactly equal to it. "path" matches one complete parsed path. File pins are
    checked against this tree. The packaging script checks the OpenSSL package, version and
    checksum against the runtime build resolution before staging that binary."""
    allowlist = json.loads(ALLOWLIST.read_text())
    exempt = {}
    for entry in allowlist["entries"]:
        pin = entry["pin"]
        if "file" in pin:
            recorded = json.loads((ROOT / pin["file"]).read_text())[pin["key"]]
            if recorded != pin["value"]:
                raise VerificationError(f"{ALLOWLIST.name}: {entry['component']} is pinned to {pin['value']}, "
                                        f"but {pin['file']} records {recorded}")
        exempt.setdefault(entry["binary"], []).extend(entry["prefixes"])
    catalog_pin = allowlist.get("vendorCatalog")
    if catalog_pin:
        path = ROOT / catalog_pin["file"]
        if sha256(path) != catalog_pin["sha256"]:
            raise VerificationError("Vendor scanner catalog differs from its reviewed pin")
        catalog = json.loads(path.read_text())
        if catalog.get("schemaVersion") != 1:
            raise VerificationError("Unsupported vendor scanner catalog")
        files = {}
        for artifact in catalog["artifacts"]:
            for relative, rules in artifact.get("scannerExceptions", {}).items():
                identity = artifact["component"] + ".xcframework/" + relative
                files[identity] = (artifact["fileSHA256"][relative], rules)
        exempt["__pinned_files__"] = files
    return exempt


def exemptions(path, allowlist):
    """Apply only the reviewed component/file rules; matching a vendor folder alone grants nothing."""
    items = allowlist.get(path.name, []) if path.parent.name == path.name + ".framework" else []
    for identity, (digest, rules) in allowlist.get("__pinned_files__", {}).items():
        parts = Path(identity).parts
        if path.parts[-len(parts):] == parts:
            scoped_paths = [path, *list(path.parents)[:len(parts) - 1]]
            if any(parent.is_symlink() for parent in scoped_paths) or sha256(path) != digest:
                raise VerificationError("Vendor file differs from its reviewed scanner pin: " + identity)
            items = [*items, *rules]
    return (tuple(item["prefix"] for item in items if "prefix" in item),
            {item["line"] for item in items if "line" in item},
            {item["path"] for item in items if "path" in item})


def is_mach_o(path):
    with path.open("rb") as handle:
        return handle.read(4) in MACH_O_MAGIC


def mach_o_strings(path):
    # strings(1) without -a reads every section except __TEXT,__text, so machine code is not
    # misread as text. Load commands are not sections; otool lists their paths separately.
    data = subprocess.check_output(["strings", str(path)], text=True, errors="replace").splitlines()
    commands = subprocess.check_output(["otool", "-l", str(path)], text=True, errors="replace")
    data += [line.split()[1] for line in commands.splitlines()
             if line.strip().startswith(("name ", "path "))]
    return data


def host_paths(path, allowlist):
    """Return the sorted build-host paths and internal names found in one file."""
    raw_lines = mach_o_strings(path) if is_mach_o(path) else [
        run.decode("ascii") for run in PRINTABLE_RUN.findall(path.read_bytes())]
    prohibited = re.compile(r"regula(?:common|forensics)?(?![a-z])|documentreader(?:core)?", re.I)
    component_names = [path.name, *(parent.name for parent in path.parents
                                    if parent.suffix in {".framework", ".xcframework", ".dSYM"})]
    if any(prohibited.search(value) for value in [*component_names, *raw_lines]):
        return ["prohibited retired document-reader component"]
    exempt, exempt_lines, exempt_paths = exemptions(path, allowlist)
    # JSON writers escape "/" as "\\/" (the runtime's *.abi.json does); unescape before matching.
    if is_mach_o(path):
        lines = [line.replace("\\/", "/") for line in mach_o_strings(path) if line not in exempt_lines]
        found = {match for line in lines for match in ABSOLUTE_PATH.findall(line)
                 if not match.startswith(RUNTIME_PREFIXES + exempt) and match not in exempt_paths}
    else:
        lines = [run.decode("ascii").replace("\\/", "/") for run in PRINTABLE_RUN.findall(path.read_bytes())
                 if run.decode("ascii") not in exempt_lines]
        found = {match for line in lines for match in ABSOLUTE_PATH.findall(line)
                 if match.startswith(HOST_ROOTS) and not match.startswith(exempt) and match not in exempt_paths}
    for line in lines:
        # An exempt upstream path is removed before names are matched ("/tmp" inside OpenSSL's
        # "/var/folders/.../T/tmp.*" prefix); the rest of the line is still matched.
        remainder = ABSOLUTE_PATH.sub(lambda m: "" if m.group(0).startswith(exempt)
                                     or m.group(0) in exempt_paths else m.group(0), line)
        found |= {f"internal name {match.group(0)!r} in: {line.strip()[:160]}"
                  for match in INTERNAL_NAME.finditer(remainder)}
    return sorted(found)


def scan(paths):
    """Map each file under the given paths to its findings; files without any are omitted."""
    allowlist = load_allowlist()
    findings = {}
    for given in paths:
        files = sorted(p for p in given.rglob("*") if p.is_file()) if given.is_dir() else [given]
        for file in files:
            hits = host_paths(file, allowlist)
            if hits:
                findings[str(file)] = hits
    return findings


def report_and_fail(findings):
    lines = []
    for file, hits in findings.items():
        lines.append(f"{file}: {len(hits)} finding(s)")
        lines += ["  " + hit for hit in hits[:20]]
        if len(hits) > 20:
            lines.append(f"  ... {len(hits) - 20} more")
    raise VerificationError("Build-host paths or internal names in shipped files:\n" + "\n".join(lines))


def verify_bridge(directory):
    artifact = directory / (NAME + ".xcframework")
    receipt = json.loads((directory / "build-receipt.json").read_text())
    if receipt.get("buildScriptSHA256") != sha256(BUILD_SCRIPT):
        raise VerificationError("The bridge was not built by the current scripts/build_capture_bridge.py: "
                                "rebuild it so the recorded recipe is the recipe in this tree.")
    missing_maps = [flag for flag in PREFIX_MAPS if flag not in receipt.get("compilerFlags", [])]
    if missing_maps:
        raise VerificationError("The bridge receipt lacks the source prefix maps: " + ", ".join(missing_maps))
    bridge = ROOT / "native/DocumentOpenCVBridge"
    current_sources = {str(p.relative_to(ROOT)) for p in bridge.rglob("*")
                       if p.is_file() and p.suffix in {".h", ".hpp", ".cpp", ".mm"}}
    if current_sources != set(receipt["sourceInputs"]):
        raise VerificationError("Bridge source set differs from its receipt; rebuild required")
    for relative, digest in receipt["sourceInputs"].items():
        if sha256(ROOT / relative) != digest:
            raise VerificationError("Bridge source changed since the recorded build: " + relative)
    entries=list(artifact.rglob('*'))
    if artifact.is_symlink() or any(p.is_symlink() for p in entries):
        raise VerificationError("Bridge artifact symlink is forbidden")
    actual_files={p.relative_to(artifact).as_posix() for p in entries if p.is_file()}
    if actual_files != set(receipt["artifactFiles"]):
        raise VerificationError("Bridge artifact tree differs from its receipt")
    for relative, digest in receipt["artifactFiles"].items():
        if sha256(artifact / relative) != digest:
            raise VerificationError("Bridge artifact differs from its receipt: " + relative)
    count = 0
    for binary in sorted(artifact.glob("*/" + NAME + ".framework/" + NAME)):
        architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(binary)], text=True).split()
        for arch in architectures:
            actual = set(subprocess.check_output(["xcrun", "nm", "-arch", arch, "-gUj", str(binary)],
                                                 text=True).splitlines())
            if actual != EXPORTS:
                raise VerificationError(f"Unexpected exports in {binary} ({arch}): {sorted(actual ^ EXPORTS)}")
            count += 1
    if count != 5:
        raise VerificationError(f"Expected 5 bridge architectures, found {count}")
    findings = scan([artifact])
    if findings:
        report_and_fail(findings)
    return receipt, count


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--directory", type=Path, default=ROOT / ".build/native")
    parser.add_argument("--scan", type=Path, nargs="+")
    args = parser.parse_args()
    try:
        if args.scan:
            findings = scan([path.resolve() for path in args.scan])
            if findings:
                report_and_fail(findings)
            print(f"No unapproved build-host paths or internal names in {len(args.scan)} scanned path(s)")
            return
        receipt, count = verify_bridge(args.directory.resolve())
    except VerificationError as error:
        raise SystemExit("verify_capture_bridge: " + str(error))
    print(f"Verified capture bridge: {len(receipt['sourceInputs'])} source inputs, "
          f"{len(receipt['artifactFiles'])} artifact files, {count} architectures, recipe "
          f"{receipt['buildScriptSHA256'][:12]}, no unapproved build-host paths or internal names")


if __name__ == "__main__":
    main()
