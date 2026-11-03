#!/usr/bin/env python3
"""Qualify the optional shared Pulse service, including actual iOS-only code."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from quality.capture_evidence import required_ids, validate  # noqa: E402
from quality.public_api import swift_surface  # noqa: E402
from quality.pulse_guards import check  # noqa: E402
from scripts.check import require_python  # noqa: E402
from scripts.presentation_check import simulator_destination  # noqa: E402

SERVICE = ROOT/'services/pulse'
SWIFTPM_BUILD = ROOT/'.build/pulse-swiftpm'
BUILD_PRODUCTS = Path('build/Build/Products')
IOS_SDKS = {'ios-device': 'iphoneos', 'ios-simulator': 'iphonesimulator'}
FIXED_INPUTS = ('Package.swift', 'Package.resolved', 'scripts/pulse_check.py',
                'scripts/check.py', 'scripts/presentation_check.py', 'quality/pulse_guards.py',
                'quality/capture_evidence.py', 'quality/public_api.py', 'foundation/dependencies.json',
                'foundation/sources.json')


def snapshot_source_files(folder):
    if folder.is_symlink() or any(parent.is_symlink() for parent in folder.parents if parent.is_relative_to(ROOT)):
        raise ValueError('Pulse qualification source directory symlink')
    entries = list(folder.rglob('*'))
    if any(path.is_symlink() for path in entries):
        raise ValueError('Pulse qualification source symlink')
    return {path for path in entries if path.is_file()
            and not {'.build', '.swiftpm', '__pycache__'} & set(path.parts)}


def source_hashes():
    roots = [SERVICE, ROOT/'foundation/Sources', ROOT/'foundation/Tests']
    files = {path for folder in roots for path in snapshot_source_files(folder)}
    files.update(ROOT/name for name in FIXED_INPUTS)
    if any(path.is_symlink() for path in files):
        raise ValueError('Pulse qualification input symlink')
    return {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(files)}


def macos_cases(path, required):
    root = ET.parse(path).getroot()
    cases = root.findall('.//testcase')
    for suite in root.iter():
        if suite.tag in {'testsuite', 'testsuites'}:
            validate_xml_suite(suite)
    identifiers = {'.'.join((case.attrib.get('classname', '').split('.')[-1], case.attrib.get('name', '').removesuffix('()')))
                   for case in cases}
    if (not cases or len(cases) != len(identifiers) or identifiers != required
            or root.findall('.//failure') or root.findall('.//error') or root.findall('.//skipped')):
        raise ValueError('Shared Pulse macOS test execution is incomplete')
    return sorted(identifiers)


def validate_xml_suite(suite):
    for name in ('failures', 'errors', 'skipped', 'expectedFailures', 'expected-failures'):
        if int(suite.attrib.get(name, '0')) != 0:
            raise ValueError('Shared Pulse macOS suite contains non-passing results')
    if 'tests' in suite.attrib and int(suite.attrib['tests']) != len(suite.findall('.//testcase')):
        raise ValueError('Shared Pulse macOS suite summary disagrees with executed cases')


def native_command(lane, attempt, destination):
    if lane == 'macos':
        return ['swift', 'test', '--scratch-path', str(SWIFTPM_BUILD), '--parallel', '--disable-swift-testing', '--filter', 'KenshikiPulsePassportTests',
                '-Xswiftc', '-warnings-as-errors', '-Xswiftc', '-strict-concurrency=complete',
                '--xunit-output', str(attempt/'tests.xml')]
    command = ['xcodebuild', '-scheme', 'KenshikiOperationBinding-Package',
               '-destination', 'generic/platform=iOS' if lane == 'ios-device' else destination,
               '-derivedDataPath', str(attempt/'build'), 'CODE_SIGNING_ALLOWED=NO',
               'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'SWIFT_STRICT_CONCURRENCY=complete']
    if lane == 'ios-device':
        return command + ['build']
    return command + ['-only-testing:KenshikiPulsePassportTests', '-parallel-testing-enabled', 'NO',
                      '-resultBundlePath', str(attempt/'tests.xcresult'), '-collect-test-diagnostics', 'never', 'test']


def execution_ids(lane, attempt, required, started):
    if lane == 'ios-device':
        return []
    if lane == 'macos':
        return macos_cases(attempt/'tests.xml', required)
    payloads = {}
    for kind in ('summary', 'tests'):
        payloads[kind] = json.loads(subprocess.check_output(
            ['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(attempt/'tests.xcresult')], text=True))
        (attempt/(kind+'.json')).write_text(json.dumps(payloads[kind], indent=2)+'\n')
    return validate(payloads['summary'], payloads['tests'], required, started)


def macos_build_folder():
    return Path(subprocess.check_output(['swift', 'build', '--scratch-path', str(SWIFTPM_BUILD), '--show-bin-path'],
                                       cwd=ROOT, text=True).strip())


def api_import_arguments(lane, attempt):
    # OperationBinding imports the existing protected-store C modules. Extract against
    # these exact build products, rather than a different checkout's header cache.
    if lane == 'macos':
        products = macos_build_folder()
        module_map = products/'KenshikiSQLCipherBridge.build/module.modulemap'
    else:
        sdk = IOS_SDKS[lane]
        products = native_products(lane, attempt)
        module_map = attempt/'build/Build/Intermediates.noindex'/('GeneratedModuleMaps-'+sdk)/'KenshikiSQLCipherBridge.modulemap'
    if not module_map.is_file() or not (products/'SQLCipher.framework').is_dir():
        raise ValueError('Exact built protected-store API dependencies unavailable')
    return ['-F', str(products), '-Xcc', '-fmodule-map-file='+str(module_map)]


def native_products(lane, attempt):
    return attempt/BUILD_PRODUCTS/('Debug-'+IOS_SDKS[lane])


def api_module_folder(lane, attempt):
    if lane == 'macos':
        return macos_build_folder()/'Modules'
    return native_products(lane, attempt)


def compiled_artifacts(lane, attempt):
    folder = (macos_build_folder()
              if lane == 'macos' else attempt/BUILD_PRODUCTS)
    artifacts = {}
    for path in sorted(folder.rglob('*')):
        relative = path.relative_to(folder)
        selected = any(part.startswith('KenshikiPulsePassport') or part.endswith('.xctest') for part in relative.parts)
        if selected and path.is_file():
            if path.is_symlink():
                raise ValueError('Shared Pulse compiled artifact symlink')
            artifacts[relative.as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not artifacts:
        raise ValueError('Shared Pulse compiled artifacts unavailable')
    return artifacts


def qualify(args):
    before = source_hashes()
    problems = check()
    if problems:
        raise ValueError('; '.join(problems))
    sources = sorted((SERVICE/'Tests/KenshikiPulsePassportTests').glob('*.swift'))
    required = required_ids(json.loads((SERVICE/'required-tests.json').read_text()), [path.read_text() for path in sources])
    output = ROOT/'.build/pulse-validation'
    output.mkdir(parents=True, exist_ok=True)
    attempt = Path(tempfile.mkdtemp(prefix=args.platform+'-', dir=output))
    receipt = {'startedUTC': datetime.now(timezone.utc).isoformat(), 'sourceSHA256': before,
               'requiredIDs': sorted(required), 'passed': False,
               'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
               'scope': 'Shared service execution and compiled API; excludes real App Attest, NFC and physical acceptance'}
    log = attempt/'execution.log'
    try:
        destination = simulator_destination() if args.platform == 'ios-simulator' else None
        command = native_command(args.platform, attempt, destination)
        receipt['command'] = command
        started = time.time_ns()
        with log.open('w') as stream:
            subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=1800, check=True)
        receipt['executedIDs'] = execution_ids(args.platform, attempt, required, started)
        actual = swift_surface(ROOT, {'swiftModule': 'KenshikiPulsePassport'}, args.platform,
                               module_folder=api_module_folder(args.platform, attempt),
                               import_arguments=api_import_arguments(args.platform, attempt))
        api = SERVICE/'api'/(args.platform+'.json')
        if args.write_api:
            api.parent.mkdir(parents=True, exist_ok=True)
            api.write_text(json.dumps(actual, indent=2, sort_keys=True)+'\n')
        elif not api.is_file() or json.loads(api.read_text()) != actual:
            raise ValueError('Shared Pulse public API drift')
        receipt['apiSHA256'] = hashlib.sha256(api.read_bytes()).hexdigest()
        receipt['artifactSHA256'] = compiled_artifacts(args.platform, attempt)
        after = source_hashes()
        receipt['endSourceSHA256'] = after
        # Only the explicitly authored API output may change during initial snapshot generation.
        if args.write_api:
            receipt['apiWritten'] = True
            authored = api.relative_to(ROOT).as_posix()
            before = {name: digest for name, digest in before.items() if name != authored}
            after = {name: digest for name, digest in after.items() if name != authored}
        if after != before:
            raise ValueError('Shared Pulse source changed during execution')
        receipt['passed'] = True
    except (OSError, ValueError, ET.ParseError, subprocess.SubprocessError) as error:
        receipt['error'] = type(error).__name__+': '+str(error)
    receipt['finishedUTC'] = datetime.now(timezone.utc).isoformat()
    if log.is_file():
        receipt['logSHA256'] = hashlib.sha256(log.read_bytes()).hexdigest()
    (attempt/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(('PASS ' if receipt['passed'] else 'FAIL ')+str(attempt/'receipt.json'))
    return int(not receipt['passed'])


if __name__ == '__main__':
    require_python()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('macos', 'ios-device', 'ios-simulator'), required=True)
    parser.add_argument('--write-api', action='store_true', help='Explicit reviewed API authoring, never used in CI')
    raise SystemExit(qualify(parser.parse_args()))
