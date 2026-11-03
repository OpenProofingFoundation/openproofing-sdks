#!/usr/bin/env python3
"""Fail closed over the foundation package inventory and dependency direction."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DEPENDENCIES = json.loads((ROOT/'foundation/dependencies.json').read_text())
SQLCIPHER_URL = DEPENDENCIES['externalPackages'][0]['url']
SQLCIPHER_REVISION = DEPENDENCIES['externalPackages'][0]['revision']
SOURCE_SUFFIXES = {'.swift', '.c', '.h', '.m', '.mm', '.cpp', '.hpp'}


def validate_manifest(text):
    """The reviewed SQLCipher supplier is the sole external foundation dependency."""
    dependencies = re.findall(r'\.package\s*\((.*?)\)', text, re.DOTALL)
    required = rf'\s*url:\s*"{re.escape(SQLCIPHER_URL)}"\s*,\s*revision:\s*"{SQLCIPHER_REVISION}"\s*'
    if len(dependencies) != 1 or not re.fullmatch(required, dependencies[0]):
        raise ValueError('Foundation requires the reviewed revision-pinned SQLCipher supplier')
    if re.search(r'\.(?:plugin|binaryTarget|unsafeFlags)\s*\(', text):
        raise ValueError('Foundation build execution/artifact policy changed')


def permitted_imports(name):
    for scope, modules in DEPENDENCIES['importOverrides'].items():
        if name == scope or scope.endswith('/') and name.startswith(scope):
            return set(modules)
    return set(DEPENDENCIES['defaultImports'])


def validate(root=ROOT):
    inventory = json.loads((root/'foundation/sources.json').read_text())
    expected = set(inventory['sources'])
    if hashlib.sha256((root/'foundation/dependencies.json').read_bytes()).hexdigest() != inventory.get('dependencyPolicySHA256'):
        raise ValueError('Unreviewed foundation supplier/import policy')
    if hashlib.sha256((root/'foundation/Package.swift').read_bytes()).hexdigest() != inventory['manifestSHA256']:
        raise ValueError('Unreviewed foundation package/target change')
    root_manifest = root/'Package.swift'
    if not root_manifest.is_file() or hashlib.sha256(root_manifest.read_bytes()).hexdigest() != inventory['rootManifestSHA256']:
        raise ValueError('Unreviewed root foundation package/target change')
    actual = {'Package.swift'} | {p.relative_to(root).as_posix() for p in (root/'foundation').rglob('*')
              if p.suffix in SOURCE_SUFFIXES and '.build' not in p.parts and '.swiftpm' not in p.parts}
    if actual != expected:
        raise ValueError('Foundation source inventory mismatch')
    for name in expected:
        if (name != 'Package.swift' and not name.startswith('foundation/')) or '..' in Path(name).parts:
            raise ValueError('Foundation inventory escapes its source boundary')
        path = root/name
        parents = (root/parent for parent in Path(name).parents if parent != Path('.'))
        if path.is_symlink() or not path.is_file() or any(parent.is_symlink() for parent in parents):
            raise ValueError('Foundation source unavailable')
        text = path.read_text()
        if name == 'foundation/motion/Package.swift':
            import importlib.util
            spec = importlib.util.spec_from_file_location('shared_motion_check', root/'foundation/motion/check.py')
            motion = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(motion)
            motion.validate(root)
        elif name in ('foundation/sensors/Package.swift', 'foundation/sensors/Integration/Consumer/Package.swift'):
            import importlib.util
            spec = importlib.util.spec_from_file_location('shared_sensors_check', root/'foundation/sensors/check.py')
            sensors = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(sensors)
            sensors.validate(root)
        elif name.endswith('Package.swift'):
            validate_manifest(text)
        elif '/Sources/' in name and path.suffix == '.swift':
            imports = set(re.findall(r'^\s*(?:@[^\n]+?\s+)?import\s+(\w+)', text, re.MULTILINE))
            if not imports <= permitted_imports(name):
                raise ValueError('Foundation depends on unreviewed module')
    validate_capture_custody(root, expected)
    return expected


def _capture_custody_provenance(root):
    provenance = json.loads((root/'foundation/capture-custody-extraction.json').read_text())
    if (provenance.get('schemaVersion') != 1 or provenance.get('destinationModule') != 'CaptureEvidenceCustody'
        or not re.fullmatch(r'[0-9a-f]{40}', provenance.get('sourceRevision', ''))):
        raise ValueError('Invalid capture custody extraction provenance')
    originals = provenance.get('sourceSHA256', {})
    if not originals or any(not name.startswith(('Sources/IdentityEvidenceStorage/Capture',
        'Tests/IdentityEvidenceStorageTests/')) or not re.fullmatch(r'[0-9a-f]{64}', value)
        for name, value in originals.items()):
        raise ValueError('Invalid capture custody source attribution')
    return provenance


def _validate_custody_destinations(root, expected, provenance):
    actual = {name for name in expected if name.startswith(('foundation/Sources/CaptureEvidenceCustody/',
        'foundation/Tests/CaptureEvidenceCustodyTests/'))}
    destinations = provenance.get('destinationSHA256', {})
    if actual != set(destinations) or any(hashlib.sha256((root/name).read_bytes()).hexdigest() != value
        for name, value in destinations.items()):
        raise ValueError('Capture custody extraction source or patch provenance changed')


def _validate_custody_manifest(text):
    declaration = re.findall(r'\.target\s*\(\s*name:\s*"CaptureEvidenceCustody"\s*,\s*dependencies:\s*\[([^]]*)\]', text)
    if len(declaration) != 1 or re.findall(r'"([^"\n]+)"', declaration[0]) != ['KenshikiProtectedStorage', 'KenshikiEvidenceManifest']:
        raise ValueError('Capture custody must select only shared protected storage and evidence manifests')
    if not re.search(r'\.library\s*\(\s*name:\s*"CaptureEvidenceCustody"\s*,\s*targets:\s*\[\s*"CaptureEvidenceCustody"\s*\]\s*\)', text):
        raise ValueError('Capture custody independent foundation product is missing')


def _validate_custody_fixture(text):
    if not text.startswith('#if DEBUG') or not text.endswith('#endif') or '@_spi(CaptureTestFixture)' not in text:
        raise ValueError('Capture custody synthetic fixtures escaped their debug-only SPI')


def validate_capture_custody(root, expected):
    """Pin extraction provenance and keep generic custody on existing foundation mechanisms."""
    provenance = _capture_custody_provenance(root)
    _validate_custody_destinations(root, expected, provenance)
    for manifest in ['Package.swift', 'foundation/Package.swift']:
        _validate_custody_manifest((root/manifest).read_text())
    for name in ['CaptureCustodyTestFixture.swift', 'CaptureSigningTestFixture.swift']:
        text = (root/'foundation/Sources/CaptureEvidenceCustody'/name).read_text().strip()
        _validate_custody_fixture(text)
    runtime = (root/'foundation/Sources/CaptureEvidenceCustody/CaptureCustodyRuntime.swift').read_text()
    if not re.search(r'public func prepareErasure\(\) async throws\s*\{\s*try await store\.prepareErasure\(\)\s*\}', runtime):
        raise ValueError('Capture custody public pre-settlement erasure fence is missing')


def simulator_destination(value):
    """Admit one simulator selector, never another xcodebuild option."""
    simulator_id = r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}'
    name = r'[A-Za-z0-9][A-Za-z0-9 ().+-]{0,79}'
    version = r'(?:latest|[0-9]{1,2}(?:\.[0-9]{1,2}){1,2})'
    pattern = (rf'platform=iOS Simulator,(?:name={name}|id={simulator_id})'
               rf'(?:,OS={version})?(?:,arch=(?:arm64|x86_64))?')
    if not re.fullmatch(pattern, value):
        raise argparse.ArgumentTypeError(
            'Use platform=iOS Simulator,name=<device> or id=<UUID>, optionally followed by OS and arch')
    return value


if __name__ == '__main__':
    validate()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--nested', action='store_true', help='Exercise the retained standalone foundation manifest')
    parser.add_argument('--platform', choices=['macos', 'ios-device', 'ios-simulator'], default='macos')
    parser.add_argument('--destination', default='platform=iOS Simulator,name=iPhone 17 Pro')
    args = parser.parse_args()
    try:
        validated_destination = simulator_destination(args.destination)
    except argparse.ArgumentTypeError as error:
        parser.error(str(error))
    output = ROOT/'.build/foundation-validation'
    output.mkdir(parents=True, exist_ok=True)
    if args.platform == 'macos':
        command = ['swift', 'test', '--package-path', str(ROOT/'foundation' if args.nested else ROOT)]
    else:
        if args.nested:
            parser.error('--nested is a macOS manifest parity lane')
        command = ['xcodebuild', 'build' if args.platform == 'ios-device' else 'test',
                   '-scheme', 'KenshikiOperationBinding-Package', '-destination',
                   'generic/platform=iOS' if args.platform == 'ios-device' else validated_destination,
                   '-derivedDataPath', str(ROOT/'.build/foundation-ios'/args.platform)]
        if args.platform == 'ios-device':
            command += ['CODE_SIGNING_ALLOWED=NO']
        else:
            command += ['-resultBundlePath', str(output/'ios-simulator.xcresult')]
    lane = ('nested' if args.nested else 'root') if args.platform == 'macos' else args.platform
    inputs = sorted(validate() | {'foundation/sources.json', 'foundation/dependencies.json',
                                 'foundation/scripts/check.py', 'foundation/capture-custody-extraction.json'})
    before = {name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in inputs}
    log = output/(lane+'.log')
    with log.open('w') as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    after = {name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in inputs}
    unchanged = before == after
    receipt = {'recordedAt': datetime.now(timezone.utc).isoformat(), 'command': command,
        'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'sourceSHA256': before, 'sourceUnchanged': unchanged, 'exitCode': result.returncode,
        'logSHA256': hashlib.sha256(log.read_bytes()).hexdigest(),
        'scope': 'Local package behavior; not installation or physical App Attest acceptance'}
    (output/(lane+'.json')).write_text(json.dumps(receipt, indent=2)+'\n')
    print(log.read_text(), end='')
    if result.returncode or not unchanged:
        raise SystemExit(result.returncode or 1)
