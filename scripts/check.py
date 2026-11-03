#!/usr/bin/env python3
"""Run root governance and the selected native SDK lanes, preserving scoped receipts."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = ('document', 'passport', 'biometric')
LANES = ('guards', 'macos', 'ios-device', 'ios-simulator', 'android')
PRESENTATION_LANES = ('macos', 'ios-device', 'ios-simulator', 'ios-ui', 'android')
NATIVE_CHECK_SUFFIX = '/scripts/check.sh'
NIST_CHECK = 'biometric/nist/check.py'
PRESENTATION_CHECK = 'scripts/presentation_check.py'
CAPTURE_CHECK = 'scripts/capture_check.py'
PASSPORT_CHECK = 'scripts/passport_check.py'
DOCUMENT_CHECK = 'scripts/document_capture_check.py'
PULSE_CHECK = 'scripts/pulse_check.py'
SENSORS_CHECK = 'foundation/sensors/check.py'
LICENCE_CHECK = 'quality/licence_check_guards.py'
LICENCE_INSTALL = ('npm', 'ci', '--ignore-scripts', '--prefix', 'services/licence-check')
COMPILERS = {'Linux': 'g++-13', 'Darwin': 'clang++'}


def require_python():
    expected = (ROOT/'.python-version').read_text().strip()
    if platform.python_version() != expected:
        raise RuntimeError('Python '+expected+' required; use bash scripts/python.sh to run project tooling')


GOVERNANCE = (
    ('root-config', ('node', 'scripts/monorepo-guards.mjs')),
    ('root-lock', ('node', 'scripts/lock-integrity.mjs')),
    ('sensors-boundaries', (sys.executable, SENSORS_CHECK, '--guards')),
    ('licence-check-boundaries', (sys.executable, LICENCE_CHECK)),
    ('root-regressions', (sys.executable, '-m', 'unittest', 'discover', '-s', 'governance/tests', '-p', 'test_*.py')),
    ('architecture', (sys.executable, 'governance/architecture/validate_architecture.py')),
    ('presentation-boundaries', (sys.executable, 'quality/presentation_guards.py')),
    ('pulse-boundaries', (sys.executable, 'quality/pulse_guards.py')),
    ('reader-runtime', (sys.executable, 'quality/reader_parity.py')),
    ('design-resources', (sys.executable, 'design-system/generate.py', '--check')),
    ('design-regressions', (sys.executable, '-m', 'unittest', 'discover', '-s', 'design-system/tests', '-p', 'test_*.py')),
)
APPROVED_COMMANDS = {command: command for _, command in GOVERNANCE}
APPROVED_COMMANDS.update({('bash', name+NATIVE_CHECK_SUFFIX, lane): ('bash', name+NATIVE_CHECK_SUFFIX, lane)
                          for name in PRODUCTS for lane in LANES})
APPROVED_COMMANDS.update({(sys.executable, NIST_CHECK, '--compiler', compiler):
                         (sys.executable, NIST_CHECK, '--compiler', compiler)
                         for compiler in COMPILERS.values()})
APPROVED_COMMANDS.update({(sys.executable, PRESENTATION_CHECK, '--platform', lane):
                         (sys.executable, PRESENTATION_CHECK, '--platform', lane)
                         for lane in PRESENTATION_LANES})
APPROVED_COMMANDS[(sys.executable, CAPTURE_CHECK)] = (sys.executable, CAPTURE_CHECK)
APPROVED_COMMANDS[(sys.executable, DOCUMENT_CHECK)] = (sys.executable, DOCUMENT_CHECK)
APPROVED_COMMANDS[(sys.executable, PASSPORT_CHECK)] = (sys.executable, PASSPORT_CHECK)
APPROVED_COMMANDS.update({(sys.executable, PULSE_CHECK, '--platform', lane):
                         (sys.executable, PULSE_CHECK, '--platform', lane)
                         for lane in ('macos', 'ios-device', 'ios-simulator')})
APPROVED_COMMANDS.update({(sys.executable, SENSORS_CHECK, '--platform', lane):
                         (sys.executable, SENSORS_CHECK, '--platform', lane)
                         for lane in ('macos', 'ios-device', 'ios-simulator')})
APPROVED_COMMANDS[LICENCE_INSTALL] = LICENCE_INSTALL
APPROVED_COMMANDS[(sys.executable, LICENCE_CHECK, '--execute')] = (sys.executable, LICENCE_CHECK, '--execute')
APPROVED_LABELS = {sdk+'-'+lane+'-'+label for sdk in PRODUCTS+('all',)
                   for lane in LANES+('all', 'nist') for label, _ in GOVERNANCE}
APPROVED_LABELS.update(name+'-'+lane for name in PRODUCTS for lane in LANES)
APPROVED_LABELS.update('sensors-'+lane for lane in ('macos', 'ios-device', 'ios-simulator'))
APPROVED_LABELS.update({'biometric-nist', 'biometric-capture-ios', 'passport-nfc-ios', 'document-capture-ios'})
APPROVED_LABELS.update('pulse-'+lane for lane in ('macos', 'ios-device', 'ios-simulator'))
APPROVED_LABELS.update('presentation-'+lane for lane in PRESENTATION_LANES)
APPROVED_LABELS.update({'licence-check-dependencies', 'licence-check-packages'})
PRUNE = {'.git', '.build', '.gradle', '.kotlin', 'build', 'node_modules', '__pycache__', '.swiftpm', 'DerivedData'}


def input_hashes():
    hashes = {}
    for folder, dirs, names in os.walk(ROOT):
        dirs[:] = sorted(d for d in dirs if d not in PRUNE)
        for name in sorted(names):
            path = Path(folder)/name
            if path.is_file() and not path.is_symlink():
                hashes[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def run(label, command, hashes):
    # Resolve only to repository-owned constant argv; callers cannot supply a new executable or option.
    try:
        command = list(APPROVED_COMMANDS[tuple(command)])
    except (KeyError, TypeError) as error:
        raise ValueError('Unapproved validation command') from error
    if label not in APPROVED_LABELS:
        raise ValueError('Unapproved validation receipt label')
    output = ROOT/'.build/validation'
    output.mkdir(parents=True, exist_ok=True)
    log_path = output/(label+'.log')
    started = datetime.now(timezone.utc).isoformat()
    start = time.monotonic()
    print('RUN '+label, flush=True)
    try:
        with log_path.open('w') as log:
            result = subprocess.run(command, cwd=ROOT, text=True, stdout=log, stderr=subprocess.STDOUT, timeout=2400)
        code = result.returncode
    except (OSError, subprocess.TimeoutExpired) as error:
        with log_path.open('a') as log:
            log.write(type(error).__name__+': lane execution failed\n')
        code = 1
    artifacts = {}
    for name in PRODUCTS:
        for artifact in list((ROOT/name/'api').glob('*.json')) + list((ROOT/name/'android').glob('*/build/outputs/aar/*.aar')):
            artifacts[artifact.relative_to(ROOT).as_posix()] = hashlib.sha256(artifact.read_bytes()).hexdigest()
    receipt = {
        'lane': label, 'startedUTC': started, 'finishedUTC': datetime.now(timezone.utc).isoformat(),
        'seconds': round(time.monotonic()-start, 3), 'command': command,
        'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'gitStatus': subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True),
        'host': {'system': platform.system(), 'release': platform.release(), 'machine': platform.machine()},
        'sourceSHA256': hashes, 'artifactSHA256': artifacts,
        'log': log_path.relative_to(ROOT).as_posix(), 'logSHA256': hashlib.sha256(log_path.read_bytes()).hexdigest(),
        'exitCode': code, 'passed': code == 0,
        'scope': 'Executed command and log only; build success does not establish installed/device acceptance or implemented behavior.'
    }
    (output/(label+'.json')).write_text(json.dumps(receipt, indent=2)+'\n')
    print(('PASS ' if code == 0 else 'FAIL ')+label, flush=True)
    if code:
        print(log_path.read_text()[-16000:], flush=True)
    return code == 0


def run_presentation(args, hashes):
    if args.sdk != 'all' or args.platform != 'all':
        return []
    return [run('presentation-'+lane, [sys.executable, PRESENTATION_CHECK, '--platform', lane], hashes)
            for lane in PRESENTATION_LANES]


def run_capture(args, hashes):
    if args.sdk not in ('all', 'biometric') or args.platform != 'all':
        return []
    return [run('biometric-capture-ios', [sys.executable, CAPTURE_CHECK], hashes)]


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', choices=PRODUCTS+('all',), default='all')
    parser.add_argument('--platform', choices=LANES+('all', 'nist'), default='guards')
    args = parser.parse_args()
    if args.platform == 'nist' and args.sdk not in ('biometric', 'all'):
        parser.error('NIST tooling belongs to the biometric capability')
    return args


def selected_lanes(args):
    if args.platform == 'all':
        return list(LANES)
    if args.platform == 'nist':
        return []
    return [args.platform]


def run_capability_lanes(products, lanes, hashes):
    # Every selected lane runs even if another capability's lane fails.
    results = []
    for name in products:
        for lane in lanes:
            results.append(run(name+'-'+lane, ['bash', name+NATIVE_CHECK_SUFFIX, lane], hashes))
    return results


def run_additional_capability_checks(args, products, hashes):
    results = []
    if 'biometric' in products and args.platform in ('all', 'nist'):
        compiler = 'g++-13' if platform.system() == 'Linux' else 'clang++'
        results.append(run('biometric-nist', [sys.executable, NIST_CHECK, '--compiler', compiler], hashes))
    if 'document' in products and args.platform == 'all':
        results.append(run('document-capture-ios', [sys.executable, DOCUMENT_CHECK], hashes))
    if 'passport' in products and args.platform == 'all':
        results.append(run('passport-nfc-ios', [sys.executable, PASSPORT_CHECK], hashes))
    return results


def run_pulse(args, hashes):
    if args.sdk != 'all' or args.platform != 'all':
        return []
    return [run('pulse-'+lane, [sys.executable, PULSE_CHECK, '--platform', lane], hashes)
            for lane in ('macos', 'ios-device', 'ios-simulator')]


def run_sensors(args, hashes):
    lanes = ('macos', 'ios-device', 'ios-simulator') if args.platform == 'all' else (args.platform,)
    return [run('sensors-'+lane, [sys.executable, SENSORS_CHECK, '--platform', lane], hashes)
            for lane in lanes if lane in ('macos', 'ios-device', 'ios-simulator')]


def run_licence(args, hashes):
    if args.platform != 'all':
        return []
    installed = run('licence-check-dependencies', LICENCE_INSTALL, hashes)
    if not installed:
        return [False]
    return [True, run('licence-check-packages', [sys.executable, LICENCE_CHECK, '--execute'], hashes)]


def main():
    require_python()
    args = parse_arguments()
    hashes = input_hashes()
    scope = args.sdk+"-"+args.platform
    results = [run(scope+"-"+label, command, hashes) for label, command in GOVERNANCE]
    if not all(results):
        return 1
    products = PRODUCTS if args.sdk == 'all' else (args.sdk,)
    results.extend(run_capability_lanes(products, selected_lanes(args), hashes))
    results.extend(run_additional_capability_checks(args, products, hashes))
    results.extend(run_capture(args, hashes))
    results.extend(run_presentation(args, hashes))
    results.extend(run_pulse(args, hashes))
    results.extend(run_sensors(args, hashes))
    results.extend(run_licence(args, hashes))
    return int(not all(results))


if __name__ == '__main__':
    raise SystemExit(main())
