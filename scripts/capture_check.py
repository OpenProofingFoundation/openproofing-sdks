#!/usr/bin/env python3
"""Execute optional iOS capture tests with source-bound, complete native evidence."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
sys.path.insert(0, str(ROOT))
from check import require_python  # noqa: E402
from presentation_check import safe_path, simulator_destination  # noqa: E402
from quality.capture_evidence import required_ids, validate  # noqa: E402


def sources():
    paths = [ROOT/'biometric/Package.swift', ROOT/'biometric/Gates/capture-tests.json',
             Path(__file__), ROOT/'quality/capture_evidence.py']
    paths.extend((ROOT/'biometric/ios').rglob('*.swift'))
    return {path.relative_to(ROOT).as_posix(): hashlib.sha256(safe_path(path).read_bytes()).hexdigest()
            for path in sorted(paths)}


def run():
    output = safe_path(ROOT/'.build/capture')
    output.mkdir(parents=True, exist_ok=True)
    attempt = Path(tempfile.mkdtemp(prefix='ios-', dir=output))
    result = attempt/'tests.xcresult'
    log_path = attempt/'execution.log'
    started_ns = time.time_ns()
    required = required_ids(json.loads((ROOT/'biometric/Gates/capture-tests.json').read_text()),
                            [path.read_text() for path in sorted((ROOT/'biometric/ios/Tests/CaptureTests').glob('*.swift'))])
    receipt = {'startedUTC': datetime.now(timezone.utc).isoformat(), 'sourceSHA256': sources(),
               'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
               'gitStatus': subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True),
               'host': platform.platform(), 'requiredIDs': sorted(required), 'passed': False,
               'scope': 'Synthetic iOS capture execution; no physical camera, depth or accessibility acceptance'}
    try:
        destination = simulator_destination()
        command = ['xcodebuild', '-scheme', 'KenshikiBiometricSDK-Package', '-destination', destination,
                   '-derivedDataPath', str(attempt/'build'), '-resultBundlePath', str(result),
                   '-only-testing:CaptureTests', '-parallel-testing-enabled', 'NO',
                   '-collect-test-diagnostics', 'never', 'CODE_SIGNING_ALLOWED=NO', 'test']
        receipt['command'] = command
        receipt['destination'] = destination
        with log_path.open('w') as log:
            completed = subprocess.run(command, cwd=ROOT/'biometric', stdout=log,
                                       stderr=subprocess.STDOUT, timeout=1800, check=False)
        if completed.returncode:
            raise ValueError('Native capture command failed: '+str(completed.returncode))
        payloads = {}
        for kind in ('summary', 'tests'):
            payloads[kind] = json.loads(subprocess.check_output(
                ['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(result)], text=True))
            (attempt/(kind+'.json')).write_text(json.dumps(payloads[kind], indent=2)+'\n')
        receipt['executedIDs'] = validate(payloads['summary'], payloads['tests'], required, started_ns)
        receipt['toolchain'] = subprocess.check_output(['xcodebuild', '-version'], text=True)
        receipt['sdkVersion'] = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
        receipt['devicesAndConfigurations'] = payloads['summary'].get('devicesAndConfigurations', [])
        artifacts = sorted((attempt/'build/Build/Products').glob('Debug-iphonesimulator/*.xctest/*'))
        binaries = [path for path in artifacts if path.is_file() and path.name == 'CaptureTests']
        if not binaries:
            raise ValueError('Missing native capture test binary')
        receipt['artifactSHA256'] = {path.relative_to(attempt).as_posix(): hashlib.sha256(safe_path(path).read_bytes()).hexdigest()
                                     for path in binaries}
        receipt['endSourceSHA256'] = sources()
        if receipt['sourceSHA256'] != receipt['endSourceSHA256']:
            raise ValueError('Capture source inputs changed during execution')
        receipt['resultSHA256'] = {path.relative_to(attempt).as_posix(): hashlib.sha256(safe_path(path).read_bytes()).hexdigest()
                                   for path in sorted(result.rglob('*')) if path.is_file()}
        receipt['passed'] = True
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        receipt['error'] = type(error).__name__+': '+str(error)
    receipt['finishedUTC'] = datetime.now(timezone.utc).isoformat()
    if log_path.exists():
        receipt['logSHA256'] = hashlib.sha256(log_path.read_bytes()).hexdigest()
    (attempt/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(('PASS' if receipt['passed'] else 'FAIL')+' iOS capture: '+str(attempt/'receipt.json'), flush=True)
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    require_python()
    raise SystemExit(run())
